import {clone,equal,requireThat,prepareHostTextInstallation,prepareHostTextBindings,validateProfile,validateSnapshot} from './model.js?v=0.6.0';

import {databaseOpener} from './database.js?v=0.6.0';
const db=databaseOpener('CherryMacWebHostText',1,value=>value.createObjectStore('records',{keyPath:'id'}),'文本数据库被其他页面占用。');
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
export function validateHostTextArchive(value){
  const state=clone(stateValid(value)),ids=new Map();
  requireThat(new TextEncoder().encode(JSON.stringify(state)).length<=8_000_000,'文本恢复记录超过 8 MB。');
  for(const record of state.records){
    recordPlan(record);requireThat(!ids.has(record.id),'文本恢复记录含重复版本编号。');
    requireThat(typeof record.date==='string'&&Number.isFinite(Date.parse(record.date)),'文本恢复记录日期无效。');
    const previous=record.previousID??null;
    requireThat(previous===null?record.previousConfiguration===null:ids.has(previous)&&equal(ids.get(previous).officialJSON,record.previousConfiguration),'文本恢复记录的先前版本不完整。');
    ids.set(record.id,record);
  }
  requireThat(state.latest===null?state.records.length===0:ids.has(state.latest),'最近文本恢复记录不存在。');
  requireThat(state.activeID===null?state.active===null:ids.has(state.activeID)&&['installed','failed'].includes(ids.get(state.activeID).phase)&&equal(ids.get(state.activeID).officialJSON,state.active),'当前文本定义与版本记录不一致。');
  return state;
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
  async importRecords(value){
    const imported=validateHostTextArchive(value);
    return changeState(state=>{
      if(equal(state,imported))return imported.records.length;
      requireThat(state.records.length===0&&state.active===null&&state.activeID===null&&state.latest===null,'当前网站已有文本记录，未覆盖。请使用原记录，或在独立浏览器环境导入。');
      Object.assign(state,imported);return imported.records.length;
    });
  }
}
export function mergeHostTextDraft(previous,snapshot,plan){
  validateProfile(previous);validateSnapshot(snapshot,true);const result=clone(previous);requireThat(equal(previous.snapshot.deviceInfo,snapshot.deviceInfo),'文本操作设备与编辑区不同，未合并草稿。');
  for(const slot of [...plan.bindings.map(b=>b.physicalSlot),...plan.removedSlots]){result.snapshot.keymap.splice(slot*3,3,...snapshot.keymap.slice(slot*3,slot*3+3));if(result.macroBindings)delete result.macroBindings[slot];if(result.macroModes)delete result.macroModes[slot];}
  validateProfile(result);return result;
}
export {recordPlan as textRecordPlan};
