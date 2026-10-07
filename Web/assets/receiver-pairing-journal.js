import {databaseOpener} from './database.js?v=0.6.0';

// Evidence only. A journal cannot authorize writes or replace a complete backup.
const open=databaseOpener('CherryMacPairingTransactions',1,database=>{
  database.createObjectStore('heads',{keyPath:'id'});
  database.createObjectStore('checkpoints',{keyPath:['id','revision']});
},'配对日志数据库被其他页面占用。');
const phases=new Set(['backup','keyboardStart','receiverPrepare','receiverStart','polling','configurationCheck','completed','failed','cancelled']);
const fail=message=>{throw new Error(message);};
function operationID(id){if(typeof id!=='string'||!/^[A-Za-z0-9_-]{1,128}$/.test(id))fail('配对日志标识无效。');}
function checkpoint(input){
  const value=JSON.parse(JSON.stringify(input));
  if(!value||!phases.has(value.phase)||!Array.isArray(value.events)||value.events.length<1||value.events.length>256)fail('配对日志阶段或事件无效。');
  for(const key of ['pending','mayHaveChanged','recoveryRequired'])if(typeof value[key]!=='boolean')fail('配对日志状态无效。');
  if(!Number.isInteger(value.pollCount)||value.pollCount<0||value.pollCount>5)fail('配对日志查询次数无效。');
  if(value.backupReference!==null&&(typeof value.backupReference!=='string'||!value.backupReference.trim()||value.backupReference.length>4096))fail('配对日志备份引用无效。');
  if(value.pending?(!Number.isInteger(value.operationID)||value.operationID<1||value.operationID>value.events.length):value.operationID!==null)fail('配对日志操作编号无效。');
  const events=value.events.map((event,index)=>{
    if(!event||event.sequence!==index+1||!phases.has(event.phase)||typeof event.action!=='string'||!event.action.length||event.action.length>64||typeof event.detail!=='string'||event.detail.length>8192)fail('配对日志事件无效。');
    return {sequence:event.sequence,phase:event.phase,action:event.action,detail:event.detail};
  });
  return {phase:value.phase,backupReference:value.backupReference,pending:value.pending,operationID:value.operationID,pollCount:value.pollCount,mayHaveChanged:value.mayHaveChanged,recoveryRequired:value.recoveryRequired,events};
}
export async function savePairingCheckpoint(id,input){
  operationID(id);const state=checkpoint(input),revision=state.events.length;
  const database=await open();
  return new Promise((resolve,reject)=>{
    const tx=database.transaction(['heads','checkpoints'],'readwrite',{durability:'strict'});
    let failure=null,result;
    const abort=error=>{failure=error;tx.abort();};
    const heads=tx.objectStore('heads'),records=tx.objectStore('checkpoints');
    const request=heads.get(id);
    request.onsuccess=()=>{
      const previous=request.result;
      if(previous){
        if(previous.revision===revision&&JSON.stringify(previous.state)===JSON.stringify(state)){result=previous;return;}
        if(previous.revision>=revision||previous.state.events.some((event,i)=>JSON.stringify(event)!==JSON.stringify(state.events[i]))||
          (previous.state.backupReference!==null&&previous.state.backupReference!==state.backupReference)||
          ['completed','failed','cancelled'].includes(previous.state.phase)){
          abort(new Error('配对日志历史已变化或已结束，不覆盖原记录。'));return;
        }
      }
      result={format:'CherryMacPairingCheckpoint',version:1,id,revision,savedAt:new Date().toISOString(),state};
      const added=records.add(result);
      added.onsuccess=()=>{
        const read=records.get([id,revision]);
        read.onsuccess=()=>{
          if(JSON.stringify(read.result)!==JSON.stringify(result)){abort(new Error('配对日志读回不一致。'));return;}
          heads.put(result);
        };
      };
    };
    tx.oncomplete=()=>resolve(result);
    tx.onerror=()=>reject(failure??tx.error??new Error('配对日志保存失败。'));
    tx.onabort=()=>reject(failure??tx.error??new Error('配对日志保存中止。'));
  });
}
export async function loadPairingJournal(id){
  operationID(id);const database=await open();
  return new Promise((resolve,reject)=>{
    const tx=database.transaction('checkpoints','readonly');let result=[];
    const request=tx.objectStore('checkpoints').getAll(IDBKeyRange.bound([id,0],[id,256]));
    request.onsuccess=()=>{result=request.result;};
    tx.oncomplete=()=>resolve(result);
    tx.onerror=()=>reject(tx.error??new Error('配对日志读取失败。'));
    tx.onabort=()=>reject(tx.error??new Error('配对日志读取中止。'));
  });
}
