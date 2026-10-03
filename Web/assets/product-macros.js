import {clone,equal,requireThat,resolveMacros,validateProfile} from './model.js?v=0.6.0';
import {MacroWriteAuthorization} from './safety.js?v=0.6.0';

// Names and recording preferences live locally; firmware stores event bytes.
let database;
function db(){
  if(!database)database=new Promise((resolve,reject)=>{
    const request=indexedDB.open('CherryMacWebMacros',1);
    request.onupgradeneeded=()=>request.result.createObjectStore('records',{keyPath:'id'});
    request.onsuccess=()=>resolve(request.result);request.onerror=()=>reject(request.error);
    request.onblocked=()=>reject(new Error('宏数据库被其他页面占用。'));
  });return database;
}
async function record(mode,action){
  const database=await db();return new Promise((resolve,reject)=>{
    const transaction=database.transaction('records',mode),request=action(transaction.objectStore('records'));let value;
    request.onsuccess=()=>value=request.result;transaction.oncomplete=()=>resolve(value);
    transaction.onerror=()=>reject(transaction.error);transaction.onabort=()=>reject(transaction.error??new Error('宏资料保存失败。'));
  });
}
async function save(value){
  await record('readwrite',store=>store.put(clone(value)));
  requireThat(equal(await record('readonly',store=>store.get(value.id)),value),'宏资料保存校验失败，停止写入。');
}
export function macroProductPlan(profile,before){
  const target=resolveMacros(profile);
  for(let slot=0;slot<126;slot++){
    const offset=slot*3;if(![0x70,0x71].includes(before.keymap[offset])&&![0x70,0x71].includes(target.keymap[offset]))target.keymap.splice(offset,3,...before.keymap.slice(offset,offset+3));
  }
  target.parameters=clone(before.parameters);target.colors=clone(before.colors);
  return new MacroWriteAuthorization(before,target,{allowUnbounded:true}).expected;
}
export async function rememberMacroProfile(profile,snapshot){
  const saved=clone(profile);saved.snapshot=clone(snapshot);validateProfile(saved);
  const resolved=resolveMacros(saved);
  requireThat(['deviceInfo','keymap','macroData'].every(key=>equal(resolved[key],snapshot[key])),'宏名称与设备数据不一致，未保存名称。');
  await save({id:'metadata-'+crypto.randomUUID(),kind:'metadata',date:new Date().toISOString(),profile:saved});
}
export async function rememberMacroProfileIfMatching(profile,snapshot){
  if(!snapshot||!equal(profile.snapshot.deviceInfo,snapshot.deviceInfo))return false;
  const candidate=clone(profile);candidate.snapshot=clone(snapshot);let resolved;
  try{resolved=resolveMacros(candidate);}catch{return false;}
  if(!['keymap','macroData'].every(key=>equal(resolved[key],snapshot[key])))return false;
  await rememberMacroProfile(candidate,snapshot);return true;
}
export async function recalledMacroProfile(snapshot){
  const records=await record('readonly',store=>store.getAll());
  for(const saved of records.filter(row=>row.kind==='metadata').sort((a,b)=>b.date.localeCompare(a.date))){
    try{
      validateProfile(saved.profile);
      if(!equal(saved.profile.snapshot.deviceInfo,snapshot.deviceInfo))continue;
      const profile=clone(saved.profile);profile.snapshot=clone(snapshot);
      const resolved=resolveMacros(profile);
      if(['keymap','macroData'].every(key=>equal(resolved[key],snapshot[key])))return profile;
    }catch{/* Incompatible metadata cannot overwrite the hardware read. */}
  }return null;
}
export async function rememberMacroTransaction(before,target){
  new MacroWriteAuthorization(before,target,{allowUnbounded:true});
  await save({id:'transaction-'+crypto.randomUUID(),kind:'transaction',format:'CherryMacMacroTransaction',version:1,before:clone(before),target:clone(target),date:new Date().toISOString()});
}
export async function lastMacroTransaction(){
  const rows=await record('readonly',store=>store.getAll());
  const saved=rows.filter(row=>row.kind==='transaction').sort((a,b)=>b.date.localeCompare(a.date))[0];
  requireThat(saved?.format==='CherryMacMacroTransaction'&&saved.version===1,'没有可恢复的宏写入记录。');
  new MacroWriteAuthorization(saved.before,saved.target,{allowUnbounded:true});return saved;
}

export async function macroLocalRecords(){return record('readonly',store=>store.getAll());}
