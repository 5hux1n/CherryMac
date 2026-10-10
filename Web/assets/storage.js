import {makeLightingEditorDraft,validateLightingEditorDraft,defaultLightingColorLibrary,validateLightingColorLibrary} from './model.js?v=0.6.0';
import {DefaultCandidateAuthorization} from './safety.js?v=0.6.0';
import {captureRawLightingMetadata,adoptRawLightingMetadata,validateRawLightingMetadata,executeDefaultTransaction,assessDefaultTransactionRecord,clone,fromHardware,validateProfile,lightingMappingSlots,validateSnapshot,equal,requireThat,assessLightingRecoveryRecord,assessLightingRestoreAttempt,officialLightingReadbackTarget} from './model.js?v=0.6.0';
import {databaseOpener,strictWriteTransaction} from './database.js?v=0.6.0';
const db=databaseOpener('CherryMacWeb',1,value=>value.createObjectStore('backups',{keyPath:'id'}),'备份数据库被其他页面占用。');
function transaction(database,mode,action){return new Promise((resolve,reject)=>{const t=database.transaction('backups',mode),request=action(t.objectStore('backups'));let result;request.onsuccess=()=>{result=request.result;};t.oncomplete=()=>resolve(result);t.onerror=()=>reject(t.error);t.onabort=()=>reject(t.error??new Error('备份存储失败。'));});}
export async function saveBackup(snapshot,lightingMapping=null,{strict=false}={}){
  validateSnapshot(snapshot,true);if(lightingMapping!=null)lightingMappingSlots(lightingMapping,snapshot);
  const database=await db(),record={id:`${Date.now()}-${crypto.randomUUID()}`,date:new Date().toISOString(),snapshot:clone(snapshot),...(lightingMapping!=null?{lightingMapping:clone(lightingMapping)}:{})};
  if(strict){await new Promise((resolve,reject)=>{
    const t=strictWriteTransaction(database,'backups'),store=t.objectStore('backups');let verified=false;
    store.add(record).onsuccess=()=>{store.get(record.id).onsuccess=event=>{if(!equal(event.target.result,record)){t.abort();return;}verified=true;};};
    t.oncomplete=()=>verified?resolve():reject(new Error('备份未完成核对。'));
    t.onerror=()=>reject(t.error??new Error('备份保存失败。'));t.onabort=()=>reject(t.error??new Error('备份保存已中止。'));
  });}else await transaction(database,'readwrite',s=>s.put(record));
  const read=await transaction(database,'readonly',s=>s.get(record.id));if(!equal(read,record))throw new Error('备份校验失败，停止写入。');return record;
}
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
const defaultDB=databaseOpener('CherryMacDefaultTransactions',1,value=>{
  value.createObjectStore('backups',{keyPath:'operationID'});
  value.createObjectStore('records',{keyPath:'sequence',autoIncrement:true});
},'默认恢复数据库被其他页面占用。');
export async function saveDefaultBackup(operationID,snapshot){
  requireThat(typeof operationID==='string'&&/^[A-Za-z0-9_.-]{1,128}$/.test(operationID),'默认恢复存储标识无效。');validateSnapshot(snapshot,true);
  const value={operationID,snapshot:clone(snapshot)},database=await defaultDB();
  return new Promise((resolve,reject)=>{
    const transaction=strictWriteTransaction(database,'backups'),store=transaction.objectStore('backups');let failure=null,verified=false;
    const fail=error=>{failure=error;transaction.abort();};
    const check=request=>{request.onsuccess=()=>{if(!equal(request.result,value))fail(new Error('默认恢复备份读回校验失败。'));else verified=true;};};
    const existing=store.get(operationID);existing.onsuccess=()=>{
      if(existing.result!=null){if(existing.result.operationID!==operationID||!equal(existing.result.snapshot,value.snapshot))fail(new Error('此事务已有不同备份，不覆盖。'));else verified=true;return;}
      const added=store.add(value);added.onsuccess=()=>check(store.get(operationID));
    };
    transaction.oncomplete=()=>verified?resolve(clone(value)):reject(new Error('默认恢复备份尚未核对。'));transaction.onerror=()=>reject(failure??transaction.error);transaction.onabort=()=>reject(failure??transaction.error??new Error('默认恢复备份保存失败。'));
  });
}
export async function saveDefaultTransaction(input){
  const record=clone(input);assessDefaultTransactionRecord(record);
  requireThat(new TextEncoder().encode(JSON.stringify(record)).length<=16_000_000,'默认恢复记录超过 16 MB。');
  const database=await defaultDB();
  return new Promise((resolve,reject)=>{
    const transaction=strictWriteTransaction(database,['backups','records']);let failure=null,saved=null,recordVerified=false,bindingVerified=false;
    const fail=error=>{failure=error;transaction.abort();};
    const backup=transaction.objectStore('backups').get(record.operationID);backup.onsuccess=()=>{
      if(!backup.result||!equal(backup.result.snapshot,record.started)){fail(new Error('默认恢复事务与写前备份不一致。'));return;}
      const binding={direction:record.direction,sourceReview:record.sourceReview,recovery:record.recovery??null,started:record.started,source:record.trace.source};
      if(backup.result.binding!=null&&!equal(backup.result.binding,binding)){fail(new Error('默认恢复事务来源已改变，不混用记录。'));return;}
      if(backup.result.binding==null){
        const expected={...backup.result,binding},store=transaction.objectStore('backups');
        store.put(expected).onsuccess=()=>{const check=store.get(record.operationID);check.onsuccess=()=>{if(!equal(check.result,expected))fail(new Error('默认恢复来源记录读回校验失败。'));else bindingVerified=true;};};
      }else bindingVerified=true;

      const store=transaction.objectStore('records'),value={operationID:record.operationID,date:new Date().toISOString(),record},added=store.add(value);
      added.onsuccess=()=>{saved={...value,sequence:added.result};const check=store.get(added.result);check.onsuccess=()=>{if(!equal(check.result,saved))fail(new Error('默认恢复日志读回校验失败。'));else recordVerified=true;};};
    };
    transaction.oncomplete=()=>recordVerified&&bindingVerified?resolve(clone(saved)):reject(new Error('默认恢复日志或来源尚未核对。'));transaction.onerror=()=>reject(failure??transaction.error);transaction.onabort=()=>reject(failure??transaction.error??new Error('默认恢复日志保存失败。'));
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
export async function executeStoredDefaultTransaction(review,options){
  options={...options};review=clone(review);const recovery=clone(options.recovery??null),operationID=options.operationID??globalThis.crypto.randomUUID();let authorization=null;
  try{return await executeDefaultTransaction(review,{...options,recovery,operationID,
    read:async()=>{const snapshot=clone(await options.read());if(!authorization)authorization=recovery?DefaultCandidateAuthorization.recovery(recovery,snapshot):new DefaultCandidateAuthorization(review,snapshot);return snapshot;},
    backup:snapshot=>saveDefaultBackup(operationID,snapshot),persist:record=>saveDefaultTransaction(record),
    exchange:async request=>{
      requireThat(authorization,'默认恢复尚未绑定完整起始配置。');
      try{authorization.begin(request);const reply=Array.from(await options.exchange(clone(request)));await options.assertCurrent();authorization.accept(reply,request);return reply;}
      catch(error){authorization.invalidate();throw error;}
    }
  });}finally{authorization?.invalidate();}
}

const rawLightingDB=databaseOpener('CherryMacRawLighting',1,value=>{
  const store=value.createObjectStore('palettes',{keyPath:'id'});store.createIndex('date','date');
},'原始配色数据库被其他页面占用。');
export async function rememberRawLightingMetadata(profile,current){
  const metadata=captureRawLightingMetadata(profile,current);if(metadata===null)return false;
  await saveRawLightingMetadata(metadata);return true;
}
export async function saveRawLightingMetadata(value){
  const metadata=clone(value);validateRawLightingMetadata(metadata);requireThat(new TextEncoder().encode(JSON.stringify(metadata)).length<=100_000,'原始配色资料过大。');
  const record={id:crypto.randomUUID(),date:new Date().toISOString(),metadata},database=await rawLightingDB();
  await new Promise((resolve,reject)=>{
    const t=strictWriteTransaction(database,'palettes'),store=t.objectStore('palettes');let verified=false;
    store.put(record).onsuccess=()=>{
      const request=store.get(record.id);request.onsuccess=()=>{
        if(!equal(request.result,record)){t.abort();return;}verified=true;
      };
    };
    t.oncomplete=()=>verified?resolve():reject(new Error('原始配色保存未核对。'));
    t.onerror=()=>reject(t.error??new Error('原始配色保存失败。'));t.onabort=()=>reject(t.error??new Error('原始配色保存校验失败。'));
  });return true;
}
export async function listRawLightingMetadata(){
  const database=await rawLightingDB();
  return new Promise((resolve,reject)=>{
    const t=database.transaction('palettes','readonly'),request=t.objectStore('palettes').index('date').openCursor(null,'prev'),rows=[];
    request.onsuccess=()=>{const cursor=request.result;if(cursor&&rows.length<128){rows.push(cursor.value);cursor.continue();}};
    t.oncomplete=()=>resolve(rows);t.onerror=()=>reject(t.error);t.onabort=()=>reject(t.error??new Error('原始配色读取失败。'));
  });
}
export async function recalledRawLightingMetadata(profile){
  if(profile.lightingMapping==null)return null;
  for(const record of await listRawLightingMetadata()){
    try{validateRawLightingMetadata(record.metadata);const next=adoptRawLightingMetadata(profile,record.metadata);if(next!==null)return next;}catch{}
  }return null;
}

// Color-library preferences are local UI data, separate from keyboard drafts/backups.
export function loadLightingColorLibrary(storage){
  const text=storage.getItem('CherryMacLightingColorLibrary');if(text===null)return defaultLightingColorLibrary();
  requireThat(new TextEncoder().encode(text).length<=4096,'颜色收藏资料过大。');return validateLightingColorLibrary(JSON.parse(text));
}
export function saveLightingColorLibrary(storage,value){
  const text=JSON.stringify(validateLightingColorLibrary(value));storage.setItem('CherryMacLightingColorLibrary',text);
  requireThat(storage.getItem('CherryMacLightingColorLibrary')===text,'颜色收藏保存核对失败。');
}

const lightingDraftDB=databaseOpener('CherryMacLightingEditorDrafts',1,value=>value.createObjectStore('drafts',{keyPath:'id'}),'灯效草稿数据库被其他页面占用。');
export async function saveLightingEditorDraft(profile){
  const value=makeLightingEditorDraft(profile),record={id:'latest',value},database=await lightingDraftDB();
  await new Promise((resolve,reject)=>{
    const t=strictWriteTransaction(database,'drafts'),store=t.objectStore('drafts');let verified=false;
    store.put(record).onsuccess=()=>{store.get(record.id).onsuccess=event=>{if(!equal(event.target.result,record)){t.abort();return;}verified=true;};};
    t.oncomplete=()=>verified?resolve():reject(new Error('灯效草稿未完成保存核对。'));t.onerror=()=>reject(t.error??new Error('灯效草稿保存失败。'));t.onabort=()=>reject(t.error??new Error('灯效草稿保存已中止。'));
  });
}
export async function loadLightingEditorDraft(){
  const database=await lightingDraftDB();return new Promise((resolve,reject)=>{
    const t=database.transaction('drafts','readonly'),request=t.objectStore('drafts').get('latest');let value;
    request.onsuccess=()=>{value=request.result?.value;};t.oncomplete=()=>{try{validateLightingEditorDraft(value);resolve(clone(value));}catch(error){reject(error);}};
    t.onerror=()=>reject(t.error??new Error('灯效草稿读取失败。'));t.onabort=()=>reject(t.error??new Error('灯效草稿读取已中止。'));
  });
}
