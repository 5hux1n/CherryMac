import {checkedReceiverPairingSelection,sameReceiverPairingSelection} from './receiver-pairing-selection.js';
import {receiverPairingFrame,receiverPairingReply} from './receiver-pairing-frames.js';
import {databaseOpener,strictWriteTransaction} from './database.js?v=0.6.0';

// Durable evidence only; loading records never sends reports or resumes a run.
const open=databaseOpener('CherryMacPairingRawReports',1,database=>{
  database.createObjectStore('records',{keyPath:['id','sequence']}).createIndex('operation','id');
},'配对原始报告数据库被其他页面占用。');
const fail=message=>{throw new Error(message);};
const uuid=id=>{if(typeof id!=='string'||!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(id))fail('原始报告操作编号无效。');};
const exact=(value,keys)=>value&&typeof value==='object'&&!Array.isArray(value)&&Object.keys(value).length===keys.length&&keys.every(key=>Object.hasOwn(value,key));
const bytes=value=>Array.isArray(value)&&value.length<=64&&Array.from(value).every(byte=>Number.isInteger(byte)&&byte>=0&&byte<=255);
function entry(input,id){
  const value=structuredClone(input);uuid(id);
  if(!exact(value,['format','version','id','intent','phase','endpoint','selection','selector','request','reply','receivedLength','stage','error'])||value.format!=='CherryMacPairingRawExchange'||value.version!==2||value.id!==id||!Number.isInteger(value.intent)||value.intent<1||value.intent>256||!['prepared','received','accepted','failed'].includes(value.stage)||!Number.isSafeInteger(value.receivedLength)||value.receivedLength<0)fail('配对原始报告字段无效。');
  const selection=checkedReceiverPairingSelection(value.selection);
  const plan=receiverPairingFrame(value.phase,value.selector);
  if(value.endpoint!==plan.endpoint||!bytes(value.request)||JSON.stringify(value.request)!==JSON.stringify(plan.request))fail('原始请求与阶段、选择字段或端点不一致。');
  if(value.reply!==null&&(!bytes(value.reply)||value.reply.length!==Math.min(64,value.receivedLength)))fail('原始回复样本与实际长度不一致。');
  if(value.stage==='prepared'&&(value.receivedLength!==0||value.reply!==null))fail('准备阶段不能包含回复。');
  if(value.stage==='accepted')receiverPairingReply(value.reply,plan,{transportSucceeded:value.receivedLength===64});
  if(value.stage==='failed'?(typeof value.error!=='string'||!value.error.length||value.error.length>8192):value.error!==null)fail('原始报告错误字段无效。');
  return {...value,selection:structuredClone(selection)};
}
function history(input,id){
  if(!Array.isArray(input)||input.length>32)fail('配对原始报告数量超过范围。');
  let previous=null;
  return Array.from(input).map((value,index)=>{
    if(!exact(value,['format','version','id','sequence','savedAt','entry'])||value.format!=='CherryMacPairingRawLog'||value.version!==1||value.id!==id||value.sequence!==index+1||typeof value.savedAt!=='string'||!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{3})?Z$/.test(value.savedAt)||!Number.isFinite(Date.parse(value.savedAt)))fail('配对原始报告文件顺序无效。');
    const current=entry(value.entry,id);
    if(!previous){if(current.stage!=='prepared')fail('原始报告必须从准备阶段开始。');}
    else {
      if(!sameReceiverPairingSelection(previous.selection,current.selection)||previous.stage==='failed')fail('原始报告端点变化或失败后仍有追加。');
      if(current.intent===previous.intent){
        if(current.phase!==previous.phase||current.endpoint!==previous.endpoint||current.selector!==previous.selector||JSON.stringify(current.request)!==JSON.stringify(previous.request))fail('原始报告意图内容发生变化。');
        const allowed={prepared:['received','failed'],received:['accepted','failed'],accepted:['failed']};
        if(!allowed[previous.stage]?.includes(current.stage))fail('原始报告阶段不连续。');
        if(['received','accepted'].includes(previous.stage)&&(current.receivedLength!==previous.receivedLength||JSON.stringify(current.reply)!==JSON.stringify(previous.reply)))fail('原始报告回复发生变化。');
      }else if(current.intent<=previous.intent||previous.stage!=='accepted'||current.stage!=='prepared')fail('原始报告意图顺序不连续。');
    }
    previous=current;return {...value,entry:current};
  });
}
export async function savePairingRawExchange(input){
  const value=entry(input,input?.id),id=value.id,database=await open();
  return new Promise((resolve,reject)=>{
    const tx=strictWriteTransaction(database,'records');let failure=null,result;
    const abort=error=>{failure=error;tx.abort();};
    const store=tx.objectStore('records'),read=store.index('operation').getAll(IDBKeyRange.only(id),34);
    read.onsuccess=()=>{try{
      const records=history(read.result,id);
      result={format:'CherryMacPairingRawLog',version:1,id,sequence:records.length+1,savedAt:new Date().toISOString(),entry:value};
      history([...records,result],id);
      if(new TextEncoder().encode(JSON.stringify(result)).length>65536)fail('配对原始报告超过大小限制。');
      const added=store.add(result);added.onsuccess=()=>{
        const verify=store.get([id,result.sequence]);verify.onsuccess=()=>{try{
          if(JSON.stringify(verify.result)!==JSON.stringify(result))fail('配对原始报告读回不一致。');
        }catch(error){abort(error);}};
      };
    }catch(error){abort(error);}};
    tx.oncomplete=()=>resolve(result);tx.onerror=()=>reject(failure??tx.error??new Error('配对原始报告保存失败。'));tx.onabort=()=>reject(failure??tx.error??new Error('配对原始报告保存中止。'));
  });
}
export async function loadPairingRawLog(id){
  uuid(id);const database=await open();return new Promise((resolve,reject)=>{
    const tx=database.transaction('records','readonly');let failure=null,result;
    const read=tx.objectStore('records').index('operation').getAll(IDBKeyRange.only(id),34);
    read.onsuccess=()=>{try{result=history(read.result,id);}catch(error){failure=error;tx.abort();}};
    tx.oncomplete=()=>resolve(result);tx.onerror=()=>reject(failure??tx.error??new Error('配对原始报告读取失败。'));tx.onabort=()=>reject(failure??tx.error??new Error('配对原始报告读取中止。'));
  });
}
