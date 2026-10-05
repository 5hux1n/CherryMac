import {clone,equal,requireThat,resolveMacros,validateProfile,validateSnapshot,officialMacroSource,canonicalJSON,officialMacroReceipt,reconcileOfficialMacroDraftReceipt,fromHardware} from './model.js?v=0.6.0';
import {MacroWriteAuthorization} from './safety.js?v=0.6.0';
import {databaseOpener} from './database.js?v=0.6.0';

// Names and recording preferences live locally; firmware stores event bytes.
const db=databaseOpener('CherryMacWebMacros',1,value=>value.createObjectStore('records',{keyPath:'id'}),'宏数据库被其他页面占用。');
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
export function macroProductPlan(profile,before,mapping=null){
  validateProfile(profile);requireThat(equal(profile.snapshot.deviceInfo,before.deviceInfo),'配置来自不同固件，请重新读取。');
  if(profile.macroStorageLayout==='officialBindings')requireThat(mapping&&equal(profile.lightingMapping,mapping),'宏草稿的默认映射与最近实际读取不同，请重新读取后重新导入配置。');
  const target=profile.macroStorageLayout==='officialBindings'?officialMacroReceipt(profile,before).expected:resolveMacros(profile);
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
export function prepareMacroMetadata(profile,snapshot,before=snapshot){
  const saved=clone(profile);saved.snapshot=clone(snapshot);saved.lightingColorEncoding='hardwareRGB';validateProfile(saved);
  const resolved=resolveMacros(saved);
  requireThat(['deviceInfo','keymap','macroData'].every(key=>equal(resolved[key],snapshot[key])),'宏名称与设备数据不一致，未保存名称。');
  const receipt=saved.macroStorageLayout==='officialBindings'?officialMacroReceipt(saved,before):null;
  if(receipt)reconcileOfficialMacroDraftReceipt(receipt,snapshot,saved.lightingMapping.factoryKeymap);
  return {format:'CherryMacMacroMetadata',version:1,profile:saved,receipt};
}
export function restoreMacroMetadata(saved,snapshot,mapping=null){
  if(saved.format!=null)requireThat(saved.format==='CherryMacMacroMetadata'&&saved.version===1,'宏名称记录格式或版本无效。');
  validateProfile(saved.profile);validateSnapshot(snapshot);
  requireThat(equal(saved.profile.snapshot.deviceInfo,snapshot.deviceInfo),'宏名称记录来自不同固件。');
  if(saved.profile.macroStorageLayout==='officialBindings'){
    requireThat(saved.format==='CherryMacMacroMetadata'&&saved.version===1&&saved.receipt&&mapping&&equal(mapping.deviceInfo,snapshot.deviceInfo),'官方宏名称记录缺少实际默认映射。');
    requireThat(canonicalJSON(saved.receipt.macros)===canonicalJSON(saved.profile.macros)&&canonicalJSON(saved.receipt.bindings)===canonicalJSON(saved.profile.macroBindings)&&canonicalJSON(saved.receipt.modes)===canonicalJSON(saved.profile.macroModes??{}),'宏名称记录与草稿不一致。');
    reconcileOfficialMacroDraftReceipt(saved.receipt,snapshot,mapping.factoryKeymap);
  }else requireThat(saved.receipt==null,'宏名称记录的存储方式不一致。');
  const profile=clone(saved.profile);profile.macroStorageLayout??='sharedLibrary';profile.snapshot=clone(snapshot);profile.lightingColorEncoding='hardwareRGB';
  if(mapping)profile.lightingMapping=clone(mapping);else delete profile.lightingMapping;
  const resolved=resolveMacros(profile);
  requireThat(['keymap','macroData'].every(key=>equal(resolved[key],snapshot[key])),'宏名称记录与完整读回数据不一致。');return profile;
}
export async function rememberMacroProfile(profile,snapshot,before=snapshot){
  const metadata=prepareMacroMetadata(profile,snapshot,before);
  await save({id:'metadata-'+crypto.randomUUID(),kind:'metadata',date:new Date().toISOString(),...metadata});
}
export async function rememberMacroProfileIfMatching(profile,snapshot){
  if(!snapshot||!equal(profile.snapshot.deviceInfo,snapshot.deviceInfo))return false;
  const candidate=clone(profile);candidate.snapshot=clone(snapshot);candidate.lightingColorEncoding='hardwareRGB';let resolved;
  try{resolved=resolveMacros(candidate);}catch{return false;}
  if(!['keymap','macroData'].every(key=>equal(resolved[key],snapshot[key])))return false;
  await rememberMacroProfile(candidate,snapshot);return true;
}
export async function recalledMacroProfile(snapshot,mapping=null){
  const records=await record('readonly',store=>store.getAll());
  for(const saved of records.filter(row=>row.kind==='metadata').sort((a,b)=>b.date.localeCompare(a.date))){
    try{return restoreMacroMetadata(saved,snapshot,mapping);
    }catch{/* Incompatible metadata cannot overwrite the hardware read. */}
  }return null;
}
export async function rememberMacroTransaction(before,target,mapping=null){
  new MacroWriteAuthorization(before,target,{allowUnbounded:true});
  let beforeMetadata=null;
  const known=await recalledMacroProfile(before,mapping);
  if(known)beforeMetadata=prepareMacroMetadata(known,before);
  else{
    const decoded=fromHardware(before);if(mapping)decoded.lightingMapping=clone(mapping);
    for(const layout of mapping?['officialBindings','sharedLibrary']:['sharedLibrary']){
      decoded.macroStorageLayout=layout;try{beforeMetadata=prepareMacroMetadata(decoded,before);break;}catch{/* Only exact reconstructable layouts can supply names. */}
    }
  }
  await save({id:'transaction-'+crypto.randomUUID(),kind:'transaction',format:'CherryMacMacroTransaction',version:2,before:clone(before),target:clone(target),beforeMetadata,date:new Date().toISOString()});
}
export function restoredMacroTransactionProfile(saved,snapshot,mapping=null){
  if(saved.beforeMetadata)try{return restoreMacroMetadata(saved.beforeMetadata,snapshot,mapping);}catch{/* Preserve the hardware recovery even if optional names cannot be reconciled. */}
  return null;
}
export async function lastMacroTransaction(){
  const rows=await record('readonly',store=>store.getAll());
  const saved=rows.filter(row=>row.kind==='transaction').sort((a,b)=>b.date.localeCompare(a.date))[0];
  requireThat(saved?.format==='CherryMacMacroTransaction'&&[1,2].includes(saved.version),'没有可恢复的宏写入记录。');
  new MacroWriteAuthorization(saved.before,saved.target,{allowUnbounded:true});return saved;
}

export async function macroLocalRecords(){return record('readonly',store=>store.getAll());}
