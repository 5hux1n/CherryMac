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
