import {databaseOpener,strictWriteTransaction} from './database.js?v=0.6.0';
import {extendedCaptureRegions,checkedCaptureIdentity} from './extended-hardware-capture.js?v=0.6.0';

const open=databaseOpener('CherryMacExtendedCaptureJournal',1,db=>db.createObjectStore('events',{keyPath:['id','revision']}),'扩展捕获日志被其他页面占用。');
const fail=()=>{throw new Error('扩展捕获日志格式、顺序或身份不一致，保留原记录。');};
const uuid=id=>typeof id==='string'&&/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(id);
const expected=[{phase:'started',pass:0,region:'',offset:0,length:0}];
for(let pass=1;pass<=2;pass++)for(const [region,,count,capacity] of extendedCaptureRegions)for(let offset=0;offset<count;offset+=capacity)for(const phase of ['readPrepared','readAccepted'])expected.push({phase,pass,region,offset,length:Math.min(capacity,count-offset)});
for(const phase of ['saving','saved','complete'])expected.push({phase,pass:0,region:'',offset:0,length:0});
const fields=['sequence','phase','pass','region','offset','length','backupReference','detail'];
function checkedEvents(input){
  if(!Array.isArray(input)||!input.length||input.length>expected.length+1)fail();let reference=null;
  return input.map((event,index)=>{
    if(!event||Object.keys(event).length!==fields.length||fields.some(key=>!Object.hasOwn(event,key))||event.sequence!==index+1||typeof event.detail!=='string'||event.detail.length>8192||event.backupReference!==null&&!uuid(event.backupReference)||reference!==null&&event.backupReference!==reference)fail();
    if(['failed','cancelled'].includes(event.phase)){
      if(index!==input.length-1||index>=expected.length||event.pass!==0||event.region!==''||event.offset!==0||event.length!==0||!event.detail||event.backupReference!==null&&reference===null&&expected[index].phase!=='saved')fail();
    }else{
      const wanted=expected[index];if(!wanted||Object.keys(wanted).some(key=>event[key]!==wanted[key])||event.detail!=='')fail();
      if(['saved','complete'].includes(event.phase)?event.backupReference===null:event.backupReference!==null)fail();
    }
    reference=event.backupReference;return Object.fromEntries(fields.map(key=>[key,event[key]]));
  });
}
function checkedRecords(records,id){
  if(!Array.isArray(records)||records.length>325)fail();let identity=null;
  const result=records.map((record,index)=>{
    if(!record||Object.keys(record).length!==6||record.format!=='CherryMacExtendedCaptureEvent'||record.version!==1||record.id!==id||record.revision!==index+1)fail();
    const current=checkedCaptureIdentity(record.identity);
    if(identity&&Object.keys(identity).some(key=>identity[key]!==current[key]))fail();identity=current;return record;
  });
  if(result.length)checkedEvents(result.map(record=>record.event));return result;
}
export async function saveExtendedCaptureEvent(id,identity,input){
  if(!uuid(id))fail();identity=checkedCaptureIdentity(identity);const event=structuredClone(input),db=await open();
  return new Promise((resolve,reject)=>{
    const tx=strictWriteTransaction(db,'events'),store=tx.objectStore('events');let result,failure=null;
    const abort=error=>{failure=error;tx.abort();};
    const request=store.getAll(IDBKeyRange.bound([id,1],[id,325]));
    request.onsuccess=()=>{try{
      const previous=checkedRecords(request.result,id),last=previous.at(-1);
      if(last&&Object.keys(identity).some(key=>last.identity[key]!==identity[key]))fail();
      if(last&&last.revision===event.sequence){
        const normalized=checkedEvents([...previous.slice(0,-1).map(record=>record.event),event]);
        if(JSON.stringify(normalized.at(-1))!==JSON.stringify(Object.fromEntries(fields.map(key=>[key,last.event[key]]))))fail();result=last;return;
      }
      checkedEvents([...previous.map(record=>record.event),event]);
      result={format:'CherryMacExtendedCaptureEvent',version:1,id,identity,revision:event.sequence,event};
      if(new TextEncoder().encode(JSON.stringify(result)).length>32_000)fail();
      const added=store.add(result);added.onsuccess=()=>{const read=store.get([id,event.sequence]);read.onsuccess=()=>{if(JSON.stringify(read.result)!==JSON.stringify(result))abort(new Error('扩展捕获日志读回不一致。'));};};
    }catch(error){abort(error);}};
    tx.oncomplete=()=>resolve(result);tx.onerror=()=>reject(failure??tx.error??new Error('扩展捕获日志保存失败。'));tx.onabort=()=>reject(failure??tx.error??new Error('扩展捕获日志保存中止。'));
  });
}
export async function loadExtendedCaptureJournal(id){
  if(!uuid(id))fail();const db=await open();return new Promise((resolve,reject)=>{
    const tx=db.transaction('events','readonly');let result,failure=null;
    const request=tx.objectStore('events').getAll(IDBKeyRange.bound([id,1],[id,325]));
    request.onsuccess=()=>{try{result=checkedRecords(request.result,id);}catch(error){failure=error;tx.abort();}};
    tx.oncomplete=()=>resolve(result);tx.onerror=()=>reject(failure??tx.error??new Error('扩展捕获日志读取失败。'));tx.onabort=()=>reject(failure??tx.error??new Error('扩展捕获日志读取中止。'));
  });
}
