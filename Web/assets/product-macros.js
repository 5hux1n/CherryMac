import {clone,equal,requireThat,resolveMacros,validateProfile,validateSnapshot,officialMacroSource,canonicalJSON} from './model.js?v=0.6.0';
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
export function mergeMacroRecoveryDraft(restored,previous,before,target){
  validateProfile(restored);validateSnapshot(before);validateSnapshot(target);
  requireThat(['deviceInfo','keymap','parameters','colors','macroData'].every(key=>equal(restored.snapshot[key],before[key])),'宏恢复读回与原配置不一致，未合并编辑区。');
  if(!previous||!equal(previous.snapshot.deviceInfo,restored.snapshot.deviceInfo))return clone(restored);
  validateProfile(previous);const result=clone(restored);
  result.snapshot.parameters=clone(previous.snapshot.parameters);result.snapshot.colors=clone(previous.snapshot.colors);
  if(previous.lightingColorEncoding!=null)result.lightingColorEncoding=previous.lightingColorEncoding;else delete result.lightingColorEncoding;
  for(const field of ['lightingMapping','hostTextJSON']){
    if(previous[field]!=null)result[field]=clone(previous[field]);else delete result[field];
  }
  if(previous.windowsTemplateJSON!=null){
    const root=JSON.parse(previous.windowsTemplateJSON);
    requireThat(root.ActionInfo==null||Array.isArray(root.ActionInfo),'当前官方草稿动作列表无效，未合并编辑区。');
    const actions=clone(root.ActionInfo??[]);
    result.macros.forEach((macro,index)=>{
      const source=officialMacroSource(restored,restored.macros[index]);if(!source)return;
      let destination=actions.findIndex(action=>canonicalJSON(action)===canonicalJSON(source));
      if(destination<0){destination=actions.length;actions.push(clone(source));}
      macro.windowsActionIndex=destination;
    });
    if(root.ActionInfo!=null||actions.length)root.ActionInfo=actions;
    result.windowsTemplateJSON=JSON.stringify(root);
  }

  for(let slot=0;slot<126;slot++){
    const offset=slot*3;
    if(![before,target,previous.snapshot].some(s=>[0x70,0x71].includes(s.keymap[offset])))result.snapshot.keymap.splice(offset,3,...previous.snapshot.keymap.slice(offset,offset+3));
  }
  validateProfile(result);return result;
}
export async function rememberMacroProfile(profile,snapshot){
  const saved=clone(profile);saved.snapshot=clone(snapshot);saved.lightingColorEncoding='hardwareRGB';validateProfile(saved);
  const resolved=resolveMacros(saved);
  requireThat(['deviceInfo','keymap','macroData'].every(key=>equal(resolved[key],snapshot[key])),'宏名称与设备数据不一致，未保存名称。');
  await save({id:'metadata-'+crypto.randomUUID(),kind:'metadata',date:new Date().toISOString(),profile:saved});
}
export async function rememberMacroProfileIfMatching(profile,snapshot){
  if(!snapshot||!equal(profile.snapshot.deviceInfo,snapshot.deviceInfo))return false;
  const candidate=clone(profile);candidate.snapshot=clone(snapshot);candidate.lightingColorEncoding='hardwareRGB';let resolved;
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
      const profile=clone(saved.profile);profile.snapshot=clone(snapshot);profile.lightingColorEncoding='hardwareRGB';
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
