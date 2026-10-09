import {ReceiverPairingTransaction} from './receiver-pairing-transaction.js';
import {checkedReceiverPairingSelection,sameReceiverPairingSelection} from './receiver-pairing-selection.js';
import {databaseOpener,strictWriteTransaction} from './database.js?v=0.6.0';

// Evidence only. A journal cannot authorize writes or replace a complete backup.
const open=databaseOpener('CherryMacPairingTransactions',1,database=>{
  database.createObjectStore('heads',{keyPath:'id'});
  database.createObjectStore('checkpoints',{keyPath:['id','revision']});
},'配对日志数据库被其他页面占用。');
const phases=new Set(['backup','keyboardStart','receiverPrepare','receiverStart','polling','configurationCheck','configurationRestore','completed','failed','cancelled']);
const fail=message=>{throw new Error(message);};
function operationID(id){if(typeof id!=='string'||!/^[A-Za-z0-9_-]{1,128}$/.test(id))fail('配对日志标识无效。');}
function checkpoint(input){
  const value=structuredClone(input),keys=['selection','phase','backupReference','pending','operationID','pollCount','mayHaveChanged','recoveryRequired','restoreAttempted','events'];
  if(!value||Object.keys(value).length!==keys.length||keys.some(key=>!Object.hasOwn(value,key)))fail('配对日志字段不完整，保留原记录。');
  const selection=checkedReceiverPairingSelection(value.selection);
  if(!value||!phases.has(value.phase)||!Array.isArray(value.events)||value.events.length<1||value.events.length>256)fail('配对日志阶段或事件无效。');
  for(const key of ['pending','mayHaveChanged','recoveryRequired','restoreAttempted'])if(typeof value[key]!=='boolean')fail('配对日志状态无效。');
  if(!Number.isInteger(value.pollCount)||value.pollCount<0||value.pollCount>5)fail('配对日志查询次数无效。');
  if(value.backupReference!==null&&(typeof value.backupReference!=='string'||!value.backupReference.trim()||value.backupReference.length>4096))fail('配对日志备份引用无效。');
  if(value.pending?(!Number.isInteger(value.operationID)||value.operationID<1||value.operationID>value.events.length):value.operationID!==null)fail('配对日志操作编号无效。');
  const events=Array.from(value.events).map((event,index)=>{
    if(!event||Object.keys(event).length!==4||event.sequence!==index+1||!phases.has(event.phase)||typeof event.action!=='string'||!event.action.length||event.action.length>64||typeof event.detail!=='string'||event.detail.length>8192)fail('配对日志事件无效。');
    return {sequence:event.sequence,phase:event.phase,action:event.action,detail:event.detail};
  });
  const normalized={selection:structuredClone(selection),phase:value.phase,backupReference:value.backupReference,pending:value.pending,operationID:value.operationID,pollCount:value.pollCount,mayHaveChanged:value.mayHaveChanged,recoveryRequired:value.recoveryRequired,restoreAttempted:value.restoreAttempted,events};
  validateTransitions(normalized);return normalized;
}
function validateTransitions(state){
  const replay=new ReceiverPairingTransaction(state.selection);
  const prefix=()=>{const produced=replay.snapshot.events;if(produced.length>state.events.length||JSON.stringify(produced)!==JSON.stringify(state.events.slice(0,produced.length)))fail('配对日志事件不能还原保存的流程状态。');};
  prefix();while(replay.snapshot.events.length<state.events.length){
    const snapshot=replay.snapshot,event=state.events[snapshot.events.length],count=snapshot.events.length;
    switch(event.action){
      case 'backupSaved':replay.backupSaved(event.detail);break;
      case 'begin':replay.beginOperation(state.selection);break;
      case 'accepted':replay.commandAccepted(snapshot.operationID);break;
      case 'status':
        if(!['设备报告配对完成，继续核对原配置。','设备尚未报告配对完成。'].includes(event.detail))fail('配对日志查询结果无效。');
        replay.statusReceived(snapshot.operationID,event.detail==='设备报告配对完成，继续核对原配置。');break;
      case 'changed':replay.configurationChecked(snapshot.operationID,false);break;
      case 'restored':replay.configurationRestored(snapshot.operationID);break;
      case 'completed':replay.configurationChecked(snapshot.operationID,true);break;
      case 'failed':replay.fail(event.detail);break;
      case 'cancelled':replay.cancel();break;
      default:fail('配对日志含未知流程事件。');
    }
    if(replay.snapshot.events.length<=count)fail('配对日志在结束状态后仍有事件。');prefix();
  }
  if(JSON.stringify(replay.snapshot)!==JSON.stringify(state))fail('配对日志事件与最终状态不一致。');
}
function checkedRecord(value,id){
  const keys=['format','version','id','revision','savedAt','state'];
  if(!value||Object.keys(value).length!==keys.length||keys.some(key=>!Object.hasOwn(value,key))||value.format!=='CherryMacPairingCheckpoint'||value.version!==4||value.id!==id||!Number.isInteger(value.revision)||value.revision<1||value.revision>256||typeof value.savedAt!=='string'||!Number.isFinite(Date.parse(value.savedAt)))fail('配对日志格式或身份缺失，保留原记录。');
  const state=checkpoint(value.state);if(value.revision!==state.events.length)fail('配对日志事件编号不一致。');
  return {format:value.format,version:4,id,revision:value.revision,savedAt:value.savedAt,state};
}
function checkedRecords(input,id){
  if(!Array.isArray(input)||input.length>256)fail('配对日志数量异常。');
  let previous=null;return Array.from(input).map(value=>{
    const record=checkedRecord(value,id);
    if(previous&&(record.revision<=previous.revision||!sameReceiverPairingSelection(previous.state.selection,record.state.selection)||JSON.stringify(record.state.events.slice(0,previous.revision))!==JSON.stringify(previous.state.events)||(previous.state.backupReference!==null&&previous.state.backupReference!==record.state.backupReference)||['completed','failed','cancelled'].includes(previous.state.phase)))fail('配对日志历史或端点身份不连续。');
    previous=record;return record;
  });
}
export async function savePairingCheckpoint(id,input){
  operationID(id);const state=checkpoint(input),revision=state.events.length,database=await open();
  return new Promise((resolve,reject)=>{
    const tx=strictWriteTransaction(database,['heads','checkpoints']);let failure=null,result;
    const abort=error=>{failure=error;tx.abort();};
    const heads=tx.objectStore('heads'),records=tx.objectStore('checkpoints');
    const historyRequest=records.getAll(IDBKeyRange.bound([id,0],[id,256]));
    historyRequest.onsuccess=()=>{try{
      const history=checkedRecords(historyRequest.result,id),previous=history.at(-1);
      const headRequest=heads.get(id);
      headRequest.onsuccess=()=>{try{
        const head=headRequest.result===undefined?undefined:checkedRecord(headRequest.result,id);
        if(JSON.stringify(head)!==JSON.stringify(previous))fail('配对日志索引与原检查点不一致，停止追加。');
        if(previous){
          if(!sameReceiverPairingSelection(previous.state.selection,state.selection))fail('配对日志端点身份已变化，保留原记录。');
          if(previous.revision===revision&&JSON.stringify(previous.state)===JSON.stringify(state)){result=previous;return;}
          if(previous.revision>=revision||JSON.stringify(previous.state.events)!==JSON.stringify(state.events.slice(0,previous.revision))||(previous.state.backupReference!==null&&previous.state.backupReference!==state.backupReference)||['completed','failed','cancelled'].includes(previous.state.phase))fail('配对日志历史已变化或已结束，不覆盖原记录。');
        }
        result={format:'CherryMacPairingCheckpoint',version:4,id,revision,savedAt:new Date().toISOString(),state};checkedRecord(result,id);
        if(new TextEncoder().encode(JSON.stringify(result)).length>3_000_000)fail('配对日志超过大小限制。');
        const added=records.add(result);added.onsuccess=()=>{
          const read=records.get([id,revision]);read.onsuccess=()=>{try{
            if(JSON.stringify(checkedRecord(read.result,id))!==JSON.stringify(result))fail('配对日志读回不一致。');
            heads.put(result);
          }catch(error){abort(error);}};
        };
      }catch(error){abort(error);}};
    }catch(error){abort(error);}};
    tx.oncomplete=()=>resolve(result);tx.onerror=()=>reject(failure??tx.error??new Error('配对日志保存失败。'));tx.onabort=()=>reject(failure??tx.error??new Error('配对日志保存中止。'));
  });
}
export async function loadPairingJournal(id){
  operationID(id);const database=await open();return new Promise((resolve,reject)=>{
    const tx=database.transaction('checkpoints','readonly');let result,failure=null;
    const request=tx.objectStore('checkpoints').getAll(IDBKeyRange.bound([id,0],[id,256]));
    request.onsuccess=()=>{try{result=checkedRecords(request.result,id);}catch(error){failure=error;tx.abort();}};
    tx.oncomplete=()=>resolve(result);tx.onerror=()=>reject(failure??tx.error??new Error('配对日志读取失败。'));tx.onabort=()=>reject(failure??tx.error??new Error('配对日志读取中止。'));
  });
}
