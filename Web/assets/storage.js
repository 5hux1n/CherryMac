import {executeDefaultTransaction,assessDefaultTransactionRecord,clone,fromHardware,validateProfile,lightingMappingSlots,validateSnapshot,equal,requireThat,assessLightingRecoveryRecord,assessLightingRestoreAttempt,officialLightingReadbackTarget} from './model.js?v=0.6.0';
let database;
function db(){if(!database)database=new Promise((resolve,reject)=>{const r=indexedDB.open('CherryMacWeb',1);r.onupgradeneeded=()=>r.result.createObjectStore('backups',{keyPath:'id'});r.onsuccess=()=>resolve(r.result);r.onerror=()=>reject(r.error);r.onblocked=()=>reject(new Error('备份数据库被其他页面占用。'));});return database;}
function transaction(database,mode,action){return new Promise((resolve,reject)=>{const t=database.transaction('backups',mode),request=action(t.objectStore('backups'));let result;request.onsuccess=()=>{result=request.result;};t.oncomplete=()=>resolve(result);t.onerror=()=>reject(t.error);t.onabort=()=>reject(t.error??new Error('备份存储失败。'));});}
export async function saveBackup(snapshot,lightingMapping=null){validateSnapshot(snapshot,true);if(lightingMapping!=null)lightingMappingSlots(lightingMapping,snapshot);const database=await db(),record={id:`${Date.now()}-${crypto.randomUUID()}`,date:new Date().toISOString(),snapshot:clone(snapshot),...(lightingMapping!=null?{lightingMapping:clone(lightingMapping)}:{})};await transaction(database,'readwrite',s=>s.put(record));const read=await transaction(database,'readonly',s=>s.get(record.id));if(!equal(read,record))throw new Error('备份校验失败，停止写入。');return record;}
export function backupConfiguration(record){
  if(record.lightingMapping==null)return clone(record.snapshot);
  let profile;try{profile=fromHardware(record.snapshot);}catch{profile={format:'CherryMacProfile',version:1,snapshot:clone(record.snapshot),macros:[]};}
  profile.lightingMapping=clone(record.lightingMapping);validateProfile(profile);return profile;
}
export async function listBackups(){const database=await db();return (await transaction(database,'readonly',s=>s.getAll())).sort((a,b)=>b.date.localeCompare(a.date));}
export function download(value,name){const blob=new Blob([JSON.stringify(value,null,2)],{type:'application/json'}),url=URL.createObjectURL(blob),a=document.createElement('a');a.href=url;a.download=name;a.click();setTimeout(()=>URL.revokeObjectURL(url),1000);}

// A one-use handoff in the new research tab's sessionStorage. No device access,
// persistent database record or upload; the receiver still validates the plan.
const lightingHandoffPrefix='CherryMacLightingHandoff:';
function handoffKey(id){if(typeof id!=='string'||!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(id))throw new Error('灯效计划标识无效。');return lightingHandoffPrefix+id;}
export function saveLightingHandoff(storage,id,review,now=Date.now()){
  const key=handoffKey(id);if(!Number.isFinite(now)||now<0)throw new Error('计划时间无效。');
  const text=JSON.stringify({format:'CherryMacLightingHandoff',version:1,createdAt:now,review});
  if(new TextEncoder().encode(text).length>3_000_000)throw new Error('灯效计划超过 3 MB。');
  storage.setItem(key,text);if(storage.getItem(key)!==text){storage.removeItem(key);throw new Error('灯效计划暂存失败。');}
}
export function takeLightingHandoff(storage,id,now=Date.now()){
  const key=handoffKey(id),text=storage.getItem(key);storage.removeItem(key);
  if(typeof text!=='string'||new TextEncoder().encode(text).length>3_000_000)throw new Error('灯效计划已取走或不可用，请返回编辑区重新准备。');
  const value=JSON.parse(text);
  if(value.format!=='CherryMacLightingHandoff'||value.version!==1||!Number.isFinite(value.createdAt)||value.createdAt<0||!Number.isFinite(now)||now<value.createdAt||now-value.createdAt>600_000)throw new Error('灯效计划已过期，请返回编辑区重新准备。');
  return value.review;
}

// This channel transports evidence only. The editor must re-read USB before
// using the result as a live baseline; no message grants write authorization.
export function lightingResultChannelName(id){return handoffKey(id)+':result';}
export function reviewLightingEditorResult(record,review){
  requireThat(new TextEncoder().encode(JSON.stringify(record)).length<=3_000_000,'灯效结果超过 3 MB。');
  requireThat(review?.format==='CherryMacLightingDraftReview'&&review.version===1&&review.hardwareReady===false,'原编辑计划无效。');
  requireThat(equal(officialLightingReadbackTarget(review.plan,review.original),review.target),'原编辑目标不一致。');
  if(record?.format==='CherryMacLightingRecoveryRecord'){
    const assessment=assessLightingRecoveryRecord(record);
    requireThat(assessment.status==='readbackMatched'&&equal(record.original,review.original)&&equal(record.plan,review.plan)&&equal(record.current,review.target),'写入结果与编辑计划不一致。');
  }else if(record?.format==='CherryMacLightingRestoreAttempt'){
    const assessment=assessLightingRestoreAttempt(record),source=record.recovery.sourceRecord;
    requireThat(['readbackMatched','alreadyMatched'].includes(assessment.status)&&equal(source.original,review.original)&&equal(source.plan,review.plan)&&equal(record.current,review.original),'恢复结果与原编辑基线不一致。');
  }else throw new Error('灯效结果类型无效。');
  return clone(record.current);
}

// Separate append-only records: retain pending entries even after later replies.
let defaultDatabase;
function defaultDB(){
  if(!defaultDatabase)defaultDatabase=new Promise((resolve,reject)=>{
    const request=indexedDB.open('CherryMacDefaultTransactions',1);let abandoned=false;
    const fail=error=>{abandoned=true;defaultDatabase=null;reject(error);};
    request.onupgradeneeded=()=>{request.result.createObjectStore('backups',{keyPath:'operationID'});request.result.createObjectStore('records',{keyPath:'sequence',autoIncrement:true});};
    request.onsuccess=()=>{const value=request.result;if(abandoned){value.close();return;}value.onversionchange=()=>{value.close();defaultDatabase=null;};resolve(value);};
    request.onerror=()=>fail(request.error);request.onblocked=()=>fail(new Error('默认恢复数据库被其他页面占用。'));
  });
  return defaultDatabase;
}
export async function saveDefaultBackup(operationID,snapshot){
  requireThat(typeof operationID==='string'&&/^[A-Za-z0-9_.-]{1,128}$/.test(operationID),'默认恢复存储标识无效。');validateSnapshot(snapshot,true);
  const value={operationID,snapshot:clone(snapshot)},database=await defaultDB();
  return new Promise((resolve,reject)=>{
    const transaction=database.transaction('backups','readwrite'),store=transaction.objectStore('backups');let failure=null;
    const fail=error=>{failure=error;transaction.abort();};
    const check=request=>{request.onsuccess=()=>{if(!equal(request.result,value))fail(new Error('默认恢复备份读回校验失败。'));};};
    const existing=store.get(operationID);existing.onsuccess=()=>{
      if(existing.result!=null){if(existing.result.operationID!==operationID||!equal(existing.result.snapshot,value.snapshot))fail(new Error('此事务已有不同备份，不覆盖。'));return;}
      const added=store.add(value);added.onsuccess=()=>check(store.get(operationID));
    };
    transaction.oncomplete=()=>resolve(clone(value));transaction.onerror=()=>reject(failure??transaction.error);transaction.onabort=()=>reject(failure??transaction.error??new Error('默认恢复备份保存失败。'));
  });
}
export async function saveDefaultTransaction(input){
  const record=clone(input);assessDefaultTransactionRecord(record);
  requireThat(new TextEncoder().encode(JSON.stringify(record)).length<=16_000_000,'默认恢复记录超过 16 MB。');
  const database=await defaultDB();
  return new Promise((resolve,reject)=>{
    const transaction=database.transaction(['backups','records'],'readwrite');let failure=null,saved=null;
    const fail=error=>{failure=error;transaction.abort();};
    const backup=transaction.objectStore('backups').get(record.operationID);backup.onsuccess=()=>{
      if(!backup.result||!equal(backup.result.snapshot,record.started)){fail(new Error('默认恢复事务与写前备份不一致。'));return;}
      const binding={direction:record.direction,sourceReview:record.sourceReview,recovery:record.recovery??null,started:record.started,source:record.trace.source};
      if(backup.result.binding!=null&&!equal(backup.result.binding,binding)){fail(new Error('默认恢复事务来源已改变，不混用记录。'));return;}
      if(backup.result.binding==null)transaction.objectStore('backups').put({...backup.result,binding});

      const store=transaction.objectStore('records'),value={operationID:record.operationID,date:new Date().toISOString(),record},added=store.add(value);
      added.onsuccess=()=>{saved={...value,sequence:added.result};const check=store.get(added.result);check.onsuccess=()=>{if(!equal(check.result,saved))fail(new Error('默认恢复日志读回校验失败。'));};};
    };
    transaction.oncomplete=()=>resolve(clone(saved));transaction.onerror=()=>reject(failure??transaction.error);transaction.onabort=()=>reject(failure??transaction.error??new Error('默认恢复日志保存失败。'));
  });
}
export async function listDefaultTransactions(){
  const database=await defaultDB();
  return new Promise((resolve,reject)=>{
    const transaction=database.transaction('records','readonly'),request=transaction.objectStore('records').getAll();let rows=[];
    request.onsuccess=()=>{rows=request.result;};transaction.oncomplete=()=>{
      try{for(const row of rows){assessDefaultTransactionRecord(row.record);requireThat(row.operationID===row.record.operationID,'默认恢复日志归属无效。');}resolve(rows.sort((a,b)=>a.sequence-b.sequence));}catch(error){reject(error);}
    };
    transaction.onerror=()=>reject(transaction.error);transaction.onabort=()=>reject(transaction.error??new Error('默认恢复日志读取失败。'));
  });
}

// Storage callbacks are fixed here; callers supply only device/session actions.
export function executeStoredDefaultTransaction(review,options){
  const operationID=options.operationID??globalThis.crypto.randomUUID();
  return executeDefaultTransaction(review,{...options,operationID,backup:snapshot=>saveDefaultBackup(operationID,snapshot),persist:record=>saveDefaultTransaction(record)});
}
