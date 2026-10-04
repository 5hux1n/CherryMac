import {clone,equal,requireThat,prepareHostTextInstallation,prepareHostTextBindings,validateProfile,validateSnapshot} from './model.js?v=0.6.0';

let database;
function db(){
  if(!database)database=new Promise((resolve,reject)=>{
    const request=indexedDB.open('CherryMacWebHostText',1);
    request.onupgradeneeded=()=>request.result.createObjectStore('records',{keyPath:'id'});
    request.onsuccess=()=>resolve(request.result);request.onerror=()=>reject(request.error);
    request.onblocked=()=>reject(new Error('文本数据库被其他页面占用。'));
  });return database;
}
const empty=()=>({format:'CherryMacHostTextStore',version:1,active:null,activeID:null,latest:null,records:[]});
function definition(root){if(root!==null)prepareHostTextBindings(root,Array(378).fill(0),Array(378).fill(0));}
function recordPlan(record){
  requireThat(record?.format==='CherryMacHostTextInstallation'&&record.version===1&&typeof record.id==='string'&&/^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i.test(record.id)&&['prepared','installed','failed','restored'].includes(record.phase),'文本安装记录格式无效。');
  definition(record.previousConfiguration);
  return prepareHostTextInstallation(record.officialJSON,record.factoryKeymap,record.before);
}
function stateValid(state){
  requireThat(state?.format==='CherryMacHostTextStore'&&state.version===1&&Array.isArray(state.records)&&state.records.length<=128,'文本存储格式或容量无效。');
  definition(state.active);return state;
}
const identity=r=>[r.id,r.officialJSON,r.factoryKeymap,r.before,r.previousConfiguration,r.previousID??null];
function checked(state,record){
  const saved=state.records.find(r=>r.id===record.id);
  requireThat(saved&&equal(identity(saved),identity(record)),'文本安装记录已变化，未覆盖。');recordPlan(saved);return saved;
}
function canRestore(state,record){const saved=checked(state,record),id=state.activeID??null;requireThat((id===saved.id&&equal(state.active,saved.officialJSON))||(id===(saved.previousID??null)&&equal(state.active,saved.previousConfiguration)),'主机文本配置版本已变化，未恢复安装。');return saved;}
async function readState(){
  const database=await db();return new Promise((resolve,reject)=>{
    const t=database.transaction('records','readonly'),r=t.objectStore('records').get('state');let value;
    r.onsuccess=()=>value=r.result?.state??empty();t.oncomplete=()=>{try{resolve(clone(stateValid(value)));}catch(error){reject(error);}};t.onerror=()=>reject(t.error);t.onabort=()=>reject(t.error);
  });
}
// Compare and update in one IDB transaction, so another tab cannot replace a
// newer host definition between the check and commit. No async work inside it.
async function changeState(action){
  const database=await db();return new Promise((resolve,reject)=>{
    const t=database.transaction('records','readwrite'),store=t.objectStore('records'),r=store.get('state');let result,failure;
    r.onsuccess=()=>{try{const state=clone(stateValid(r.result?.state??empty()));result=action(state);store.put({id:'state',state});}catch(error){failure=error;t.abort();}};
    t.oncomplete=()=>resolve(clone(result));t.onerror=()=>reject(failure??t.error);t.onabort=()=>reject(failure??t.error??new Error('文本资料保存失败。'));
  });
}
export class HostTextStore{
  async active(){return (await readState()).active;}
  async latest(){const state=await readState(),record=state.records.find(r=>r.id===state.latest);if(!record)return null;recordPlan(record);return clone(record);}
  async prepare(plan){
    const verified=prepareHostTextInstallation(plan.officialJSON,plan.factoryKeymap,plan.before);
    return changeState(state=>{
      requireThat(state.records.length<128,'文本安装历史已满，请先导出记录再清理网站数据。');
      const record={format:'CherryMacHostTextInstallation',version:1,id:crypto.randomUUID(),date:new Date().toISOString(),officialJSON:verified.officialJSON,factoryKeymap:verified.factoryKeymap,before:verified.before,previousConfiguration:clone(state.active),previousID:state.activeID??null,phase:'prepared'};
      state.records.push(record);state.latest=record.id;return record;
    });
  }
  async commit(record){return changeState(state=>{const saved=checked(state,record);requireThat(saved.phase==='prepared','文本安装记录当前不能提交。');requireThat((state.activeID??null)===(saved.previousID??null)&&equal(state.active,saved.previousConfiguration),'主机文本配置版本已变化，未替换。');saved.phase='installed';state.active=clone(saved.officialJSON);state.activeID=saved.id;});}
  async failed(record){return changeState(state=>{const saved=checked(state,record);if(saved.phase!=='restored')saved.phase='failed';});}
  async validateRestoration(record){canRestore(await readState(),record);}
  async restored(record){return changeState(state=>{const saved=canRestore(state,record);state.active=clone(saved.previousConfiguration);state.activeID=saved.previousID??null;saved.phase='restored';});}
  async exportRecords(){return readState();}
}
export function mergeHostTextDraft(previous,snapshot,plan){
  validateProfile(previous);validateSnapshot(snapshot,true);const result=clone(previous);requireThat(equal(previous.snapshot.deviceInfo,snapshot.deviceInfo),'文本操作设备与编辑区不同，未合并草稿。');
  for(const slot of [...plan.bindings.map(b=>b.physicalSlot),...plan.removedSlots]){result.snapshot.keymap.splice(slot*3,3,...snapshot.keymap.slice(slot*3,slot*3+3));if(result.macroBindings)delete result.macroBindings[slot];if(result.macroModes)delete result.macroModes[slot];}
  validateProfile(result);return result;
}
export {recordPlan as textRecordPlan};
