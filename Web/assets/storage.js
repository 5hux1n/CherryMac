import {clone,fromHardware,validateProfile,lightingMappingSlots,validateSnapshot,equal} from './model.js?v=0.6.0';
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
