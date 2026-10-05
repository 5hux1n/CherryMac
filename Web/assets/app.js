import {keys,modes,mediaActions,usageNames,describe,demoSnapshot,editableSlots} from './layout.js?v=0.6.0';
import {reviewDefaultConfiguration,extractOfficialDefaultTemplate,importWindowsLightingDraft,lightingRestorePlanFromRecord,officialSystemStageWords,officialPollingDraft,reviewLightingDraft,assessLightingRestoreAttempt,assessLightingRecoveryRecord,lightingColorSlot,clone,equal,requireThat,duplicateMacro,clearMacros,removeMacro,unassignMacro,macroWriteReview,encodeBank,fromHardware,validateProfile,resolveMacros,parseProfile,validateMacro,MacroRecorder,validatePlayback,rgb,hex,paint,validateHostTextDefinition,exportWindowsKeysAndMacros,exportWindowsKeysMacrosAndText,exportProfileWindowsLightingDraft,prepareHostTextBindings,officialHostTextPlan,resolveHostTextTrigger,editHostText} from './model.js?v=0.6.0';
import {requestHIDSelection,CherryHID,PageReleaseGate} from './hid.js?v=0.6.0';
import {applyConfiguration,applyHostTextInstallation,restoreHostTextInstallation,makeKeymapPlan,sameSnapshot} from './writer.js?v=0.6.0';
import {lightingResultChannelName,reviewLightingEditorResult,saveLightingHandoff,backupConfiguration,saveBackup,listBackups,download} from './storage.js?v=0.6.0';
import {WRITE_BLOCK_REASON} from './safety.js?v=0.6.0';
import {applyMacroWithStop,recoverMacroWithStop} from './macro-session.js?v=0.6.0';
import {mergeMacroRecoveryDraft,macroProductPlan,rememberMacroProfile,rememberMacroProfileIfMatching,recalledMacroProfile,rememberMacroTransaction,lastMacroTransaction,macroLocalRecords} from './product-macros.js?v=0.6.0';
import {HostTextStore,mergeHostTextDraft,textRecordPlan} from './product-text.js?v=0.6.0';
import {saveLog,listLogs} from './logs.js?v=0.6.0';
import {runPageOperation} from './page-operation.js?v=0.6.0';
const pageFailures=[];let pageLogTasks=Promise.resolve(),mediaSelectionRecord=null;
import {HostTextBridge} from './text-bridge.js?v=0.6.0';
const $=id=>document.getElementById(id),demo=demoSnapshot(),gate=new PageReleaseGate();
const pages={keys:['按键功能','点选一个按键，设置你习惯的功能。'],lights:['灯效','选择内置模式，或为每个按键配色。'],macros:['宏','把连续的按键操作保存为一个动作。'],profiles:['配置与备份','保存配置，管理备份，迁移你的设置。'],settings:['设备设置','管理官方配置文件中的设备设置。'],device:['设备与诊断','查看连接状态，导出问题排查资料。']};
let lightingReturnChannel=null,lightingReturnTimer=null,lightingReconnectSnapshot=null;
let recorder=null,recordingPreference=null,macroAbort=null,lightingRecordForPlan=null;
let profile=fromHardware(demo),baseline=null,baselineLightingMapping=null,hid=null,busy=false,tab='keys',lightTab='builtins',selected='calculator',selection=new Set([selected]),steps=[],pending=null;
const macroProduct=document.documentElement.dataset.macroProduct==='true';
const textProduct=document.documentElement.dataset.textProduct==='true',textStore=new HostTextStore();
let bridgeStorage=null;if(textProduct)try{bridgeStorage=sessionStorage;}catch{}
const textBridge=textProduct?new HostTextBridge({storage:bridgeStorage}):null;
let textRoot=null,textPending=null,textFactory=null,selectImportedText=null;
if(textProduct)pages.text=['文本快捷输入','安装触发键，管理主机文本配置。'];
const supported=isSecureContext&&'hid' in navigator;
function status(message,error=false){$('status').textContent=message;$('status').classList.toggle('error',error);}
function safeProfile(s){try{return fromHardware(s);}catch(error){status(`配置已读取；${error.message} 键位和灯效仍可编辑。`);return {format:'CherryMacProfile',version:1,snapshot:clone(s),macros:[]};}}
function counts(s,original){return {keys:keys.filter(k=>!equal(s.keymap.slice(k.slot*3,k.slot*3+3),original.keymap.slice(k.slot*3,k.slot*3+3))).length,colors:keys.filter(k=>{const slot=lightingColorSlot(profile,k.slot);return slot!=null&&!equal(s.colors?.slice(slot*3,slot*3+3),original.colors?.slice(slot*3,slot*3+3));}).length,params:!equal(s.parameters,original.parameters),macros:!equal(s.macroData,original.macroData)};}
function render(){
  const s=profile.snapshot,base=baseline??demo,c=counts(s,base);
  let lightingTarget=s;if(baseline&&profile.lightingColorEncoding==='officialRGB')try{lightingTarget=reviewLightingDraft(profile,baseline).target;}catch{}
  if(lightingTarget!==s){c.colors=counts(lightingTarget,base).colors;c.params=!equal(lightingTarget.parameters,base.parameters);}
  const changed=c.keys+c.colors+Number(c.params)+Number(c.macros);
  for(const k of keys){const b=document.querySelector(`.key[data-id="${k.id}"]`);b.setAttribute('aria-pressed',String(selection.has(k.id)));const slot=lightingColorSlot(profile,k.slot);b.classList.toggle('changed',tab==='lights'?slot!=null&&!equal(lightingTarget.colors?.slice(slot*3,slot*3+3),base.colors?.slice(slot*3,slot*3+3)):!equal(s.keymap.slice(k.slot*3,k.slot*3+3),base.keymap.slice(k.slot*3,k.slot*3+3)));
    const colorSlot=lightingColorSlot(profile,k.slot),color=colorSlot==null?null:s.colors?.slice(colorSlot*3,colorSlot*3+3);if(tab==='lights'&&color?.length===3){b.style.background=hex(color);b.style.color=color[0]*.2126+color[1]*.7152+color[2]*.0722>140?'#151515':'#fff';}else{b.style.background='';b.style.color='';}
    b.title=`${k.label} · ${describe(s.keymap.slice(k.slot*3,k.slot*3+3))}`;
  }
  const key=keys.find(k=>k.id===selected);$('selection-label').textContent=`已选 ${key.label}${selection.size>1?` · 共 ${selection.size} 键`:''}`;$('light-count').textContent=`${selection.size} 键`;const binding=profile.macroBindings?.[key.slot],playback=profile.macroModes?.[key.slot]??{mode:'count',count:1};$('selected-record').textContent=binding?`宏 · ${binding} · ${playback.mode==='count'?`执行 ${playback.count} 次`:playback.mode==='held'?'按住持续':'再次按键停止'}`:describe(s.keymap.slice(key.slot*3,key.slot*3+3));
  const record=s.keymap.slice(key.slot*3,key.slot*3+3),fingerprint=`${key.slot}:${record.join(',')}`;
  if(mediaSelectionRecord!==fingerprint){mediaSelectionRecord=fingerprint;const action=record[0]===0x30?mediaActions.find(item=>item.visible&&item.code===(record[1]|record[2]<<8)):null;$('media-function').value=action?String(action.index):'';}
  document.querySelectorAll('[data-tab]').forEach(b=>{const active=b.dataset.tab===tab;b.setAttribute('aria-selected',String(active));b.setAttribute('aria-controls',`pane-${b.dataset.tab}`);b.tabIndex=active?0:-1;$(`pane-${b.dataset.tab}`).hidden=!active;});
  $('page-title').textContent=pages[tab][0];$('page-description').textContent=pages[tab][1];
  const editorPage=['keys','lights','macros'].includes(tab);$('board-card').hidden=!editorPage;$('review-card').hidden=!editorPage;$('workspace').classList.toggle('single-page',!editorPage);
  document.querySelectorAll('[data-light-tab]').forEach(b=>{const active=b.dataset.lightTab===lightTab;b.setAttribute('aria-selected',String(active));b.tabIndex=active?0:-1;$(`light-${b.dataset.lightTab}`).hidden=!active;});
  $('multi-label').hidden=tab!=='lights'||lightTab!=='perkey';$('board-hint').textContent=tab==='lights'?'颜色为静态预览 · ⌘ 点击多选':'普通键保持正方形 · 点击按键进行设置';
  const online=hid&&!hid.dead&&baseline;$('connection').textContent=online?'● USB 已连接 · 已读取':'● 未连接 · 可编辑配置';$('connection').classList.toggle('connected',!!online);$('disconnect').hidden=!hid||hid.dead;$('device-status').textContent=online?(macroProduct?'已连接 · 可分别写入按键与宏':'已连接 · 配置已读取，可独立写入按键'):'尚未读取 · 可预览与编辑配置';
  $('change-title').textContent=tab==='keys'?'待写入按键':tab==='macros'&&macroProduct?'待写入宏':'编辑预览';$('changes').replaceChildren();
  for(const [name,value] of [['按键功能',`${c.keys} 键`],['逐键颜色',`${c.colors} 键`],['灯效参数',c.params?'已修改':'未修改'],['宏存储',c.macros?'已修改':'未修改']]){const line=document.createElement('div');line.className='change-line';const text=document.createElement('span'),v=document.createElement('b');text.textContent=name;v.textContent=value;line.append(text,v);$('changes').append(line);}
  let keyPlan=null,keyError=null;if(baseline)try{keyPlan=tab==='macros'&&macroProduct?macroProductPlan(profile,baseline):makeKeymapPlan(s,baseline);}catch(error){keyError=error.message;}
  $('draft-note').textContent=tab==='lights'?($('open-lighting-acceptance')?'先准备灯效计划，再进入独立页面重新读取、备份和确认；本页不会直接发送。':'仅核对并导出灯效计划；普通版尚未开放灯效发送。'):tab==='macros'&&macroProduct?(keyError??'只更新宏库与宏绑定键；灯效和设备参数保留。普通键草稿保留，可在按键页面另行写入。'):tab!=='keys'?WRITE_BLOCK_REASON:keyError??'只写入键位表。灯效、颜色与宏草稿保留在编辑区，不随按键发送。';
  document.querySelectorAll('main button,main input,main select,dialog button').forEach(e=>e.disabled=busy);
  let pollingWords=null;try{if(profile.windowsTemplateJSON)pollingWords=officialSystemStageWords(JSON.parse(profile.windowsTemplateJSON));}catch{}
  $('polling-draft-summary').textContent=pollingWords?`当前官方草稿：${[125,250,500,1000][pollingWords[3]]?`${[125,250,500,1000][pollingWords[3]]} Hz`:`原始索引 ${pollingWords[3]}（尚未核对）`}；尚未写入键盘。`:'请先导入包含设备设置的官方配置。';
  $('save-polling-draft').disabled=busy||!pollingWords;
  $('export-lighting-restore-plan').disabled=busy||!lightingRecordForPlan;
  $('discard-lighting-result').hidden=lightingReconnectSnapshot===null;
  $('review-lighting').disabled=busy||!baseline;
  if($('open-lighting-acceptance'))$('open-lighting-acceptance').disabled=busy||!baseline;
  $('connect').disabled=busy||!supported;$('read').disabled=busy||!hid||hid.dead;$('write').disabled=tab==='lights'?busy||!!recorder||!baseline:busy||!!recorder||!online||!(tab==='keys'||tab==='macros'&&macroProduct)||!keyPlan||sameSnapshot(keyPlan,baseline);$('write').textContent=tab==='lights'?($('open-lighting-acceptance')?'准备灯效写入…':'核对灯效计划…'):tab==='keys'?'写入按键':tab==='macros'&&macroProduct?'写入宏与绑定键':'此功能写入暂缓';$('confirm-write').disabled=busy; $('scope').disabled=true;$('scope').options[0].textContent=tab==='lights'?'仅灯效计划 · 按键和宏保留':tab==='macros'&&macroProduct?'宏库与绑定键 · 灯效保留':'仅按键 · 灯效和宏保留';$('macro-repeat').disabled=busy||$('macro-playback').value!=='count';
  document.querySelectorAll('[data-record],#stage-shortcut').forEach(b=>b.disabled=busy||!editableSlots.has(key.slot));
  const macroKnown=profile.macroBindings!=null;$('macro-warning').hidden=macroKnown;$('macro-warning').textContent='当前原始宏尚未识别。已保留宏数据；暂不能编辑或覆盖宏库。';
  for(const id of ['save-macro','assign-macro','unassign-macro','delete-macro','add-pair'])$(id).disabled=busy||!macroKnown||(id==='assign-macro'&&!editableSlots.has(key.slot))||(id==='unassign-macro'&&!profile.macroBindings?.[key.slot]);
  $('record-start').disabled=busy||!macroKnown||!!recorder;$('record-stop').disabled=!recorder;$('record-cancel').disabled=!recorder;
  if(recorder)recordControls(true);
  $('cancel-macro-operation').hidden=!macroAbort;$('cancel-macro-operation').disabled=!macroAbort||macroAbort.signal.aborted;
  $('recover-macro').hidden=!macroProduct;$('recover-macro').disabled=busy||!online;
  if(textProduct){$('text-bridge-pair').disabled=busy||(textBridge.paired&&!textBridge.resuming);$('text-bridge-code').disabled=busy||(textBridge.paired&&!textBridge.resuming);$('text-bridge-start').disabled=busy||!!recorder||!textBridge.paired||!textRoot;$('text-bridge-stop').disabled=busy||!textBridge.paired;$('text-bridge-unpair').disabled=busy||!textBridge.paired;$('text-bridge-state').textContent=textBridge.paired?(textBridge.resuming?'Mac 联动待核对 · 配置操作前确认服务状态':`Mac 已联动 · ${({stopped:'服务已停止',preparing:'正在准备服务',observing:'文本服务已开启',failed:'服务发生错误'})[textBridge.state]}`):'尚未连接 Mac 服务';$('text-edit-open').disabled=busy||!!recorder||!online||!textRoot;$('text-edit-value').disabled=busy;if(textFactory){const trigger=resolveHostTextTrigger(0x700+Number($('text-edit-key').value),textFactory),item=trigger&&textRoot.KeyList[trigger.logicalIndex];$('text-edit-remove').disabled=busy||item?.ActionLink!==1||textRoot.ActionInfo[item.ActionLinkIndex]?.ActionType!==3;}$('text-install').disabled=busy||!!recorder||!online||!textRoot;$('text-restore').disabled=busy||!!recorder||!online;$('text-export').disabled=busy||!textRoot;}
  if(busy)$('connect').disabled=true;
  renderMacroSummary();
}
function syncLights(){const p=profile.snapshot.parameters;$('mode').value=String(p[1]);$('brightness').value=Math.min(4,p[2]);$('brightness-label').textContent=p[2];$('speed').value=4-Math.min(4,p[3]);$('direction').value=p[4]<=1?String(p[4]):'';$('rainbow').value=p[5]<=1?String(p[5]):'';$('global-color-input').value=hex(p.slice(6,9));loadColor();}
function setColor(b){const value=hex(b);$('color').value=value;$('hex').value=value.toUpperCase();['red','green','blue'].forEach((id,i)=>$(id).value=b[i]);const strength=Math.round(Math.max(...b)*100/255);$('strength').value=strength;$('strength-label').textContent=`${strength}%`;}
function loadColor(){const k=keys.find(k=>k.id===selected),slot=lightingColorSlot(profile,k.slot);if(profile.snapshot.colors&&slot!=null)setColor(profile.snapshot.colors.slice(slot*3,slot*3+3));}
function refreshMacros(name=''){const list=$('macro-list');list.replaceChildren(new Option('新建宏',''));profile.macros.forEach(m=>list.add(new Option(m.name,m.name)));list.value=name;if(list.value!==name)list.value='';}
function loadPlayback(){const k=keys.find(k=>k.id===selected),name=profile.macroBindings?.[k.slot],p=name?(profile.macroModes?.[k.slot]??{mode:'count',count:1}):(profile.macros.find(m=>m.name===$('macro-list').value)?.preferredPlayback??{mode:'count',count:1});if(name){$('macro-list').value=name;loadMacro();}$('macro-playback').value=p.mode;$('macro-repeat').value=p.count;$('macro-repeat').disabled=p.mode!=='count'||busy;}
function loadMacro({preferDefault=false}={}){recordingPreference=null;const m=profile.macros.find(m=>m.name===$('macro-list').value);steps=clone(m?.steps??[]);const key=keys.find(k=>k.id===selected),playback=(!preferDefault&&profile.macroBindings?.[key.slot]===m?.name?profile.macroModes?.[key.slot]:null)??m?.preferredPlayback??{mode:'count',count:1};$('macro-playback').value=playback.mode;$('macro-repeat').value=playback.count;$('macro-repeat').disabled=playback.mode!=='count'||busy;$('macro-name').value=m?.name??'';renderSteps();}
function usageOptions(select,modifiers=true){for(const [u,name] of Object.entries(usageNames))if(modifiers||Number(u)<224)select.add(new Option(`${name} · ${u}`,u));}
const mouseMacroNames={1:'鼠标左键',2:'鼠标右键',4:'鼠标中键',8:'鼠标后退',16:'鼠标前进'};
function macroOptions(select){usageOptions(select);for(const [code,name] of Object.entries(mouseMacroNames))select.add(new Option(name,`mouse:${code}`));}
function setMacroUsage(step,value){if(value.startsWith('mouse:')){step.kind='mouse';step.usage=Number(value.slice(6));}else{delete step.kind;step.usage=Number(value);}}
function renderMacroSummary(){
  const element=$('macro-summary');element.classList.remove('error');
  if(profile.macroBindings==null){element.textContent='读取完整配置后显示宏容量。';return;}
  try{
    const saved=encodeBank(profile.macros),used=profile.macros.length?saved[2]|saved[3]<<8:0;
    const library=`宏库 ${profile.macros.length}/32 · 已占用 ${used}/3071 字节`;
    if(!steps.length){element.textContent=library+' · 添加或录制步骤后显示本次保存容量。';return;}
    try{
      const macro={name:$('macro-name').value.trim(),steps:clone(steps)},draft=clone(profile.macros),index=draft.findIndex(m=>m.name===$('macro-list').value);
      if(index<0)draft.push(macro);else draft[index]=macro;
      requireThat(new Set(draft.map(m=>m.name.normalize('NFC'))).size===draft.length,'宏名称已存在。');
      const bank=encodeBank(draft),next=bank[2]|bank[3]<<8,playback={mode:$('macro-playback').value,count:$('macro-playback').value==='count'?Number($('macro-repeat').value):1};validatePlayback(playback);
      const cycle=steps.reduce((sum,step)=>sum+step.delayMilliseconds,0),duration=playback.mode==='count'?`${cycle*playback.count} ms`:`每轮 ${cycle} ms · 持续执行`;
      element.textContent=library+` · 本次保存 ${next}/3071 字节 · ${steps.length} 步 · 设定等待总量：${duration}`;
    }catch(error){element.textContent=library+' · 本次保存：'+error.message;element.classList.add('error');}
  }catch(error){element.textContent='宏容量暂不可计算：'+error.message;element.classList.add('error');}
}
function renderSteps(){
  const insertion=$('macro-insert'),position=insertion.value;insertion.replaceChildren(new Option('末尾追加',''));
  steps.forEach((_,index)=>{insertion.add(new Option(`步骤 ${index+1} 前`,`before:${index}`));insertion.add(new Option(`步骤 ${index+1} 后`,`after:${index}`));});insertion.value=position;if(insertion.selectedIndex<0)insertion.value='';
  const destination=$('record-placement'),recordPosition=destination.value;destination.replaceChildren(new Option('替换全部步骤','replace'),new Option('末尾追加','append'));
  steps.forEach((_,index)=>{destination.add(new Option(`步骤 ${index+1} 前`,`before:${index}`));destination.add(new Option(`步骤 ${index+1} 后`,`after:${index}`));});destination.value=recordPosition;if(destination.selectedIndex<0)destination.value='replace';
  const parent=$('macro-steps');parent.replaceChildren();steps.forEach((step,i)=>{
  const row=document.createElement('div');row.className='macro-step';const n=document.createElement('span');n.className='step-number';n.textContent=i+1;
  const usage=document.createElement('select');macroOptions(usage);if(step.kind!=='mouse'&&!usageNames[step.usage])usage.add(new Option(`HID ${step.usage}`,step.usage));usage.value=step.kind==='mouse'?`mouse:${step.usage}`:step.usage;usage.setAttribute('aria-label',`步骤 ${i+1} 按键`);usage.onchange=()=>{setMacroUsage(step,usage.value);renderMacroSummary();};
  const state=document.createElement('select');state.add(new Option('按下','down'));state.add(new Option('松开','up'));state.value=step.pressed?'down':'up';state.setAttribute('aria-label',`步骤 ${i+1} 状态`);state.onchange=()=>{step.pressed=state.value==='down';renderMacroSummary();};
  const delay=document.createElement('input');delay.type='number';delay.min=0;delay.max=60000;delay.value=step.delayMilliseconds;delay.setAttribute('aria-label',`步骤 ${i+1} 事件后等待，毫秒`);delay.oninput=()=>{step.delayMilliseconds=delay.value===''?NaN:Number(delay.value);renderMacroSummary();};
  const unit=document.createElement('span');unit.textContent='ms';const remove=document.createElement('button');remove.textContent='删除';remove.setAttribute('aria-label',`删除步骤 ${i+1}`);remove.onclick=()=>{steps.splice(i,1);renderSteps();};const move=document.createElement('select');move.setAttribute('aria-label',`移动步骤 ${i+1}`);move.add(new Option('移动…',''));for(const [value,label] of [['top','置顶'],['up','上移'],['down','下移'],['bottom','置底']]){const option=new Option(label,value);option.disabled=(['top','up'].includes(value)&&i===0)||(['down','bottom'].includes(value)&&i===steps.length-1);move.add(option);}move.onchange=()=>{if(busy||!move.value)return;const target=({top:0,up:i-1,down:i+1,bottom:steps.length-1})[move.value];steps.splice(target,0,steps.splice(i,1)[0]);renderSteps();parent.querySelectorAll('select[aria-label^="移动步骤"]')[target]?.focus();};row.append(n,usage,state,delay,unit,move,remove);parent.append(row);
  });renderMacroSummary();}
function stageRecord(record){const key=keys.find(k=>k.id===selected);requireThat(editableSlots.has(key.slot),'内部功能键不能改写。');const p=clone(profile);p.snapshot.keymap.splice(key.slot*3,3,...record);if(p.macroBindings)delete p.macroBindings[key.slot];if(p.macroModes)delete p.macroModes[key.slot];validateProfile(p);profile=p;status(`已为 ${key.label} 设置 ${describe(record)}，尚未写入。`);}
async function act(fn){if(busy)return;try{await fn();render();}catch(error){status(error.message,true);render();}}
async function read(){
  if(!lightingReconnectSnapshot){
    let draft=profile.snapshot;try{draft=resolveMacros(profile);}catch{}
    if(profile.windowsTemplateJSON||!sameSnapshot(draft,baseline??demo)){
      requireThat(confirm('重新读取会替换当前编辑区草稿和导入的配置资料。请先在配置与备份导出保存。继续读取？（不会写入键盘）'),'已取消读取，编辑区保留。');
    }
  }
  const s=await hid.snapshot();let mapping=null,mappingError=null;try{mapping=await hid.readLightingMapping(s);}catch(error){mappingError=error.message;}const keepLightingDraft=lightingReconnectSnapshot!==null;
  if(keepLightingDraft&&!sameSnapshot(s,lightingReconnectSnapshot)){
    baseline=null;throw new Error('新读回与返回的灯效结果不同；编辑区草稿保留，未写入。请保存草稿并核对键盘配置。');
  }
  if(keepLightingDraft&&mapping&&profile.lightingMapping&&!equal(mapping,profile.lightingMapping)){
    baseline=null;throw new Error('新读回的灯光映射与保留草稿不同；草稿保留，未写入。请保存配置并核对映射。');
  }
  baseline=clone(s);baselineLightingMapping=clone(mapping);
  if(!keepLightingDraft){profile=safeProfile(s);try{profile=await recalledMacroProfile(s)??profile;}catch(error){status('配置已读取，但本地宏名称无法读取：'+error.message,true);}}
  else{validateProfile(profile);lightingReconnectSnapshot=null;}if(mapping)profile.lightingMapping=mapping;else if(!keepLightingDraft)delete profile.lightingMapping;refreshMacros();loadMacro();loadPlayback();syncLights();try{await saveBackup(s,mapping);}catch(error){status(`读取成功，但本地备份不可用：${error.message} 请在写入时重新确认备份可用。`,true);return;}status(mappingError?'按键、灯效和宏配置已读取并备份；灯光映射未取得：'+mappingError:'已读取完整配置和灯光映射并保存本地备份。编辑后点击“写入按键”才会修改键盘。',!!mappingError);}
async function operation(fn,{localOnly=false}={}){
  if(busy)return;const action=document.activeElement?.id??'page-operation';busy=true;render();
  try{await runPageOperation(fn,{localOnly,stopObservation:()=>hid?.stopHostTextObservation(),invalidateText:()=>{if(textProduct){textFactory=null;$('text-editor').hidden=true;}},suspendHostText:async()=>{if(textBridge?.paired)await textBridge.suspend();}});}
  catch(error){
    const entry={id:crypto.randomUUID(),at:new Date().toISOString(),kind:'phase',phase:'page-failed',action,tab,error:String(error?.message??error).slice(0,4096)};
    pageFailures.push(entry);pageLogTasks=pageLogTasks.then(()=>saveLog(clone(entry))).catch(failure=>{entry.persistenceError=String(failure?.message??failure).slice(0,4096);});
    status(entry.error,true);
  }finally{busy=false;render();}
}
function switchTab(next){if(!pages[next])return;tab=next;render();}
// Build real buttons so the diagram supports mouse, keyboard and screen readers.
for(const k of keys){const b=document.createElement('button');b.className='key';b.dataset.id=k.id;b.dataset.square=String(k.w===k.h);b.textContent=k.label;b.style.left=`${k.x/864*100}%`;b.style.top=`${k.y/264*100}%`;b.style.width=`${k.w/864*100}%`;b.style.height=`${k.h/264*100}%`;b.setAttribute('aria-label',`${k.label} 键`);b.setAttribute('aria-pressed','false');b.onclick=e=>{
  selected=k.id;loadPlayback();if(tab==='lights'&&(e.metaKey||e.ctrlKey||$('multi').checked)){if(selection.has(k.id)&&selection.size>1){selection.delete(k.id);selected=[...selection][0];}else selection.add(k.id);}else selection=new Set([k.id]);if(tab==='lights')loadColor();render();
};$('keyboard').append(b);}
for(const action of mediaActions.filter(item=>item.visible))$('media-function').add(new Option(action.label,action.index));
$('shortcut-key').add(new Option('无主键（仅修饰键）',0));usageOptions($('shortcut-key'),false);macroOptions($('macro-key'));$('shortcut-key').value=21;$('macro-key').value=4;modes.forEach(([value,name])=>$('mode').add(new Option(name,value)));
function navigation(selector,switchPage){const buttons=[...document.querySelectorAll(selector)];buttons.forEach(b=>{
  b.onclick=()=>switchPage(b);b.onkeydown=e=>{if(!['ArrowLeft','ArrowRight','ArrowUp','ArrowDown','Home','End'].includes(e.key))return;e.preventDefault();const i=buttons.indexOf(b),forward=['ArrowRight','ArrowDown'].includes(e.key),next=e.key==='Home'?0:e.key==='End'?buttons.length-1:(i+(forward?1:buttons.length-1))%buttons.length;buttons[next].focus();switchPage(buttons[next]);};
});}
navigation('[data-tab]',b=>switchTab(b.dataset.tab));
navigation('[data-light-tab]',b=>{lightTab=b.dataset.lightTab;render();});
document.querySelectorAll('[data-record]').forEach(b=>b.onclick=()=>act(()=>stageRecord(b.dataset.record.split(',').map(Number))));
$('stage-media').onclick=()=>act(()=>{
  const value=$('media-function').value,action=mediaActions.find(item=>item.visible&&String(item.index)===value);
  requireThat(action,'请选择多媒体功能。');stageRecord([0x30,action.code&255,action.code>>8]);
});
$('stage-shortcut').onclick=()=>act(()=>{const mask=[...document.querySelectorAll('.modifier:checked')].reduce((n,b)=>n|Number(b.value),0);stageRecord([0x20,mask,Number($('shortcut-key').value)]);});
document.querySelectorAll('[data-region]').forEach(b=>b.onclick=()=>{const region=b.dataset.region;selection=new Set(keys.filter(k=>region==='all'||region==='main'&&k.x<576&&k.y>55||region==='function'&&k.y<55||region==='num'&&k.id.startsWith('num')||region==='arrows'&&['up','down','left','right'].includes(k.id)||region==='wasd'&&k.page===7&&[26,4,22,7].includes(k.usage)).map(k=>k.id));selected=[...selection][0];loadColor();render();});
$('color').oninput=()=>setColor(rgb($('color').value));$('hex').onchange=()=>act(()=>setColor(rgb($('hex').value)));
['red','green','blue'].forEach(id=>$(id).onchange=()=>act(()=>{const b=['red','green','blue'].map(id=>$(id).value===''?NaN:Number($(id).value));requireThat(b.every(v=>Number.isInteger(v)&&v>=0&&v<=255),'RGB 必须是 0–255 的整数。');setColor(b);}));
$('strength').oninput=()=>{const b=rgb($('color').value),peak=Math.max(...b),scale=Number($('strength').value)*255/100;setColor(b.map(v=>Math.round(peak?v/peak*scale:scale)));};
$('paint').onclick=()=>act(()=>{requireThat(profile.snapshot.colors,'请读取包含颜色的完整配置。');paint(profile.snapshot,selection,$('pattern').value,rgb($('hex').value),rgb($('end-color').value),profile.lightingMapping);syncLights();status(`已为 ${selection.size} 键加入配色，尚未写入。`);});
$('off').onclick=()=>act(()=>{requireThat(profile.snapshot.colors,'请读取包含颜色的完整配置。');paint(profile.snapshot,selection,'solid',[0,0,0],[0,0,0],profile.lightingMapping);syncLights();status('所选键已设为熄灭，尚未写入。');});
$('brightness').oninput=()=>$('brightness-label').textContent=$('brightness').value;
$('save-polling-draft').onclick=()=>act(()=>{
  requireThat(typeof profile.windowsTemplateJSON==='string','请先导入包含设备设置的 Windows 官方 JSON。');
  const value=$('polling-draft').value;requireThat(value!=='','请选择回报率，或保留原草稿。');
  const output=officialPollingDraft(JSON.parse(profile.windowsTemplateJSON),Number(value));profile.windowsTemplateJSON=JSON.stringify(output);validateProfile(profile);status('回报率已保存到官方配置草稿，尚未写入键盘。请在配置与备份导出。');
});
function closeLightingReturnChannel(){lightingReturnChannel?.close();lightingReturnChannel=null;clearTimeout(lightingReturnTimer);lightingReturnTimer=null;}
function prepareLightingReturnChannel(id,review){
  closeLightingReturnChannel();requireThat(typeof BroadcastChannel==='function','浏览器不支持编辑器结果回传。');
  const channel=new BroadcastChannel(lightingResultChannelName(id));lightingReturnChannel=channel;
  lightingReturnTimer=setTimeout(closeLightingReturnChannel,7_200_000);
  channel.onmessage=event=>{
    const value=event.data;if(value?.kind!=='lighting-editor-result'||value.id!==id)return;
    let accepted=false,error='';
    try{
      requireThat(!busy&&!recorder,'编辑器正在操作，请稍后重试返回。');
      requireThat(!hid||hid.dead,'编辑器已有 USB 会话，请先断开再返回结果。');
      requireThat(equal(baseline,review.original),'编辑器读回基线已改变，请重新准备。');
      const current=reviewLightingEditorResult(value.record,review);
      requireThat(equal(reviewLightingDraft(profile,review.original).plan,review.plan),'灯效草稿已改变；结果未覆盖编辑区。');
      // Keep all drafts, including official raw RGB. A new USB read is still
      // required before adopting this evidence as a connected baseline.
      lightingReconnectSnapshot=current;accepted=true;
      status('灯效结果已核对，全部编辑草稿保留。请重新连接并读取键盘，读回一致后继续。');
    }catch(failure){error=String(failure.message).slice(0,4096);status(error,true);}
    channel.postMessage({kind:'lighting-editor-result-ack',id,accepted,error});
    if(accepted)closeLightingReturnChannel();
    render();
  };
}
window.addEventListener('beforeunload',closeLightingReturnChannel);
if($('open-lighting-acceptance'))$('open-lighting-acceptance').onclick=()=>{
  if(busy||!baseline)return;
  if(lightingReconnectSnapshot){status('请先重新连接核对已返回的结果，再准备新的灯效计划。',true);return;}
  // Open during the click so popup blockers do not lose an async navigation.
  const view=window.open('about:blank','_blank');if(!view){status('请允许本网站打开新页面，再试一次。',true);return;}
  let sent=false;void operation(async()=>{
    try{
      const review=reviewLightingDraft(profile,baseline),id=crypto.randomUUID();
      if(hid)await hid.close();hid=null;gate.invalidate();
      requireThat(!view.closed,'验收页面已关闭，请重新准备。');
      view.sessionStorage.clear();saveLightingHandoff(view.sessionStorage,id,review);prepareLightingReturnChannel(id,review);view.opener=null;
      view.location.replace(`lighting-test.php?plan=${encodeURIComponent(id)}`);sent=true;
      status('编辑区计划已送到独立验收页面，本页 USB 已关闭。没有写入键盘；编辑区仍保留。');
    }catch(error){closeLightingReturnChannel();view.close();throw error;}
  }).finally(()=>{if(!sent)view.close();});
};
$('discard-lighting-result').onclick=()=>{
  if(busy||!lightingReconnectSnapshot)return;
  if(!confirm('放弃待核对的返回结果？当前草稿仍保留，但下次普通读取会替换草稿，请先导出保存。此操作不修改键盘。'))return;
  lightingReconnectSnapshot=null;baseline=null;
  status('返回结果已放弃，草稿仍保留。请先导出草稿，再重新读取键盘。');render();
};
$('import-lighting').onclick=()=>{if(!busy)$('lighting-draft-file').click();};
$('lighting-draft-file').onchange=()=>{
  const file=$('lighting-draft-file').files[0];$('lighting-draft-file').value='';if(!file)return;
  return operation(async()=>{
    requireThat(baseline,'请先读取键盘。');requireThat(file.size<=1_000_000,'官方配置超过 1 MB。');
    const next=importWindowsLightingDraft(profile,JSON.parse(await file.text()));
    profile=next;syncLights();loadColor();
    status('已仅载入官方灯效与配色到编辑区。键位、宏、文本及设备设置保留，尚未写入。');
  },{localOnly:true});
};
$('review-lighting').onclick=()=>operation(()=>{
  $('lighting-review-summary').textContent='';requireThat(baseline,'请先读取键盘。');
  const review=reviewLightingDraft(profile,baseline),mode=modes.find(([code])=>code===review.target.parameters[1])?.[1]??'未知模式';
  const summary=`模式：${mode}；亮度：${review.target.parameters[2]}/4；逐键颜色将改变 ${review.changedColorSlots.length} 个位置；灯效参数${review.changedParameterOffsets.length?'将更新':'保持不变'}。尚未写入键盘，按键与宏保持读回配置。`;
  $('lighting-review-summary').textContent=summary;download(review,'CherryMac-灯效写入核对.json');status(summary);
},{localOnly:true});
$('stage-lights').onclick=()=>act(()=>{const p=profile.snapshot.parameters;requireThat($('mode').value!=='','请选择已支持的灯效模式。');p[1]=Number($('mode').value);p[2]=Number($('brightness').value);p[3]=4-Number($('speed').value);if($('direction').value!=='')p[4]=Number($('direction').value);if($('rainbow').value!=='')p[5]=Number($('rainbow').value);status('灯效参数已保存到编辑区，尚未写入。');});
$('global-color').onclick=()=>act(()=>{profile.snapshot.parameters.splice(6,3,...rgb($('global-color-input').value));profile.snapshot.parameters[5]=0;$('rainbow').value='0';status('已设置内置灯效单色，尚未写入。');});
$('macro-name').oninput=renderMacroSummary;$('macro-repeat').oninput=renderMacroSummary;$('macro-playback').onchange=()=>{$('macro-repeat').disabled=$('macro-playback').value!=='count';renderMacroSummary();};$('macro-list').onchange=loadMacro;$('add-pair').onclick=()=>act(()=>{requireThat(steps.length<=254,'最多 256 个事件，请先删除部分步骤。');const event={};setMacroUsage(event,$('macro-key').value);const [where,raw]=$('macro-insert').value.split(':');let index=steps.length;if(where){index=Number(raw);requireThat(Number.isInteger(index)&&index>=0&&index<steps.length,'请选择有效插入位置。');if(where==='after')index++;}steps.splice(index,0,{...event,pressed:true,delayMilliseconds:30},{...event,pressed:false,delayMilliseconds:0});$('macro-insert').value='';renderSteps();});
$('save-macro').onclick=()=>act(async()=>{const p=clone(profile),old=$('macro-list').value,m={name:$('macro-name').value.trim(),steps:clone(steps)};const preference=recordingPreference??p.macros.find(m=>m.name===old)?.recordingDelay;if(preference!=null)m.recordingDelay=clone(preference);const preferred={mode:$('macro-playback').value,count:$('macro-playback').value==='count'?Number($('macro-repeat').value):1};validatePlayback(preferred);m.preferredPlayback=preferred;const original=p.macros.find(m=>m.name===old);if(original?.hardwareReserved!=null)m.hardwareReserved=clone(original.hardwareReserved);const source=original?.windowsActionIndex;if(source!=null)m.windowsActionIndex=source;validateMacro(m);requireThat(!p.macros.some(macro=>macro.name===m.name&&macro.name!==old),'宏名称已存在。');const index=p.macros.findIndex(m=>m.name===old);if(index<0)p.macros.push(m);else{p.macros[index]=m;for(const [slot,name] of Object.entries(p.macroBindings??{}))if(name===old)p.macroBindings[slot]=m.name;}p.snapshot=resolveMacros(p);profile=p;refreshMacros(m.name);loadMacro({preferDefault:true});render();try{await rememberMacroProfileIfMatching(p,baseline);}catch(error){status('编辑区已保存，但本地宏名称／默认方式保存失败：'+error.message,true);return;}status('宏与默认执行方式已保存到编辑区；已有绑定不变，点击分配后应用到所选键。');});
$('assign-macro').onclick=()=>act(()=>{const name=$('macro-list').value,key=keys.find(k=>k.id===selected);requireThat(name&&editableSlots.has(key.slot),'请选择已保存的宏和可配置按键。');const p=clone(profile);const playback={mode:$('macro-playback').value,count:$('macro-playback').value==='count'?Number($('macro-repeat').value):1};validatePlayback(playback);p.macroBindings[key.slot]=name;p.macroModes??={};p.macroModes[key.slot]=playback;p.snapshot=resolveMacros(p);profile=p;status(`已将 ${name} 分配到 ${key.label}，尚未写入。`);});
$('copy-macro').onclick=()=>act(()=>{const copy=duplicateMacro(profile,$('macro-list').value);profile=copy.profile;refreshMacros(copy.name);loadMacro();status('已复制宏；原绑定保留，副本尚未绑定或写入。');});
$('clear-macros').onclick=()=>act(()=>{profile=clearMacros(profile);refreshMacros();loadMacro();loadPlayback();status('宏已从编辑区清空，原宏绑定键设为禁用；尚未写入，可撤销修改。');});
$('delete-macro').onclick=()=>act(()=>{profile=removeMacro(profile,$('macro-list').value);refreshMacros();loadMacro();status('已删除宏，原绑定键设为禁用，尚未写入。');});
$('unassign-macro').onclick=()=>act(()=>{const key=keys.find(k=>k.id===selected);profile=unassignMacro(profile,key.slot);loadPlayback();status(`已解除 ${key.label} 的宏绑定并设为禁用；宏库保留，尚未写入。`);});
$('connect').onclick=()=>{
  if(busy)return;status('请在浏览器弹窗中选择 CHERRY USB 键盘。');
  const selection=requestHIDSelection(()=>navigator.hid.requestDevice({filters:[{vendorId:1130,productId:462,usagePage:0xff1c,usage:0x92}]}));
  return operation(async()=>{
    const device=await selection();if(hid)await hid.close();baseline=null;baselineLightingMapping=null;
    hid=new CherryHID(device,{macroProduct,textProduct,log:saveLog,progress:message=>status(message+'…'),onDisconnect:error=>{status(error.message,true);render();}});
    await hid.open();await read();
  });
};
$('read').onclick=()=>operation(read);$('disconnect').onclick=()=>operation(async()=>{if(hid)await hid.close();hid=null;status('已断开配置接口，键盘仍可正常输入。');});
$('discard').onclick=()=>act(async()=>{const snapshot=baseline??demo;profile=await recalledMacroProfile(snapshot)??safeProfile(snapshot);if(baseline){if(baselineLightingMapping)profile.lightingMapping=clone(baselineLightingMapping);else delete profile.lightingMapping;}refreshMacros();loadMacro();loadPlayback();syncLights();status('已撤销编辑区修改，实体键盘没有变化。');});
$('import').onclick=()=>$('file').click();
$('file').onchange=()=>operation(async()=>{
  const file=$('file').files[0];$('file').value='';if(!file)return;
  requireThat(file.size<=3_000_000,'配置文件超过 3 MB。');
  const raw=await file.text(),root=JSON.parse(raw),p=parseProfile(raw,baseline,{deferHostText:textProduct,lightingMapping:profile.lightingMapping});
  const mixed=textProduct&&typeof p.hostTextJSON==='string';
  // Both parsers validate before replacing either editor. No HID writes here.
  if(mixed)selectImportedText(JSON.parse(p.hostTextJSON),file.name);
  else if(textProduct){textRoot=null;$('text-summary').textContent='本配置未包含文本定义；输入服务保持关闭。';$('text-bindings').replaceChildren();}
  profile=p;refreshMacros();loadMacro();loadPlayback();syncLights();
  status(mixed?'配置已分流：键位和宏在编辑区，文本在文本页。文本键保留当前配置，需另行安装；尚未写入。':'配置已导入编辑区，尚未写入键盘。');
});
$('review-default').onclick=()=>$('default-review-file').click();
$('default-review-file').onchange=()=>operation(async()=>{
  const file=$('default-review-file').files[0];$('default-review-file').value='';if(!file)return;
  const before=baseline,mapping=baselineLightingMapping;
  requireThat(before&&mapping,'请先读取键盘，取得完整配置和固件默认键位表。');
  requireThat(file.size<=16_000_000,'默认文件超过 16 MB。');
  const text=await file.text();
  requireThat(baseline===before&&baselineLightingMapping===mapping,'读取资料已改变，请重新核对。');
  const review=reviewDefaultConfiguration(text,before,mapping);
  $('default-review-summary').textContent=`按键差异 ${review.changedKeySlots.length} 个；灯效参数差异 ${review.changedParameterOffsets.length} 项。内部键差异 ${review.protectedChangedSlots.length} 个；涉及宏绑定 ${review.macroBindingSlots.length} 个；未支持的默认键记录 ${review.unsupportedFactorySlots.length} 个。设备设置的 ${review.pendingSystemFields.length} 个字段仍待确认，默认颜色差异 ${review.defaultColorPlan.changedColorSlots.length} 个，已纳入离线候选；颜色／键位恢复事务尚未接入。宏存储处理仍待核对。候选保留原始宏存储，完整恢复尚未开放。`;
  download(review,'CherryMac-default-review.json');
  status('已导出默认恢复核对计划，包含当前配置与宏；未修改编辑区或写入键盘。');
},{localOnly:true});
$('import-default').onclick=()=>$('default-file').click();
$('default-file').onchange=()=>operation(async()=>{
  const file=$('default-file').files[0];$('default-file').value='';if(!file)return;
  requireThat(baseline,'请先读取键盘，再载入官方默认草稿。');
  requireThat(file.size<=16_000_000,'默认文件超过 16 MB。');
  const root=extractOfficialDefaultTemplate(await file.text());
  const next=parseProfile(JSON.stringify(root),baseline,{deferHostText:textProduct,lightingMapping:profile.lightingMapping});
  if(!confirm('载入官方默认草稿会替换当前编辑区。请先导出需要保留的配置。默认键位、灯效与文件设置只载入草稿，原始宏存储保留；不会写入键盘，完整恢复默认尚未开放。')){status('已取消载入，编辑区保留。');return;}
  if(textProduct){textRoot=null;$('text-summary').textContent='默认草稿未包含文本定义；输入服务保持关闭。';$('text-bindings').replaceChildren();}
  profile=next;refreshMacros();loadMacro();loadPlayback();syncLights();
  status('官方默认配置已载入编辑区，原始宏存储保留；尚未写入，完整恢复默认仍待补齐。');
});
$('export').onclick=()=>act(()=>{const output=clone(profile);if(textProduct){delete output.hostTextJSON;if(textRoot!==null)output.hostTextJSON=JSON.stringify(textRoot);}validateProfile(output);requireThat(new TextEncoder().encode(JSON.stringify(output,null,2)).length<=3_000_000,'配置文件超过 3 MB，请精简文本或分别导出。');download(output,'CherryMac-profile.json');status('配置已导出，包含选中的文本定义；文本恢复记录需在文本页另行导出。');});
$('export-windows').onclick=()=>act(()=>{requireThat(typeof profile.windowsTemplateJSON==='string','请先导入本型号的 Windows 官方 JSON，作为导出模板。');const template=JSON.parse(profile.windowsTemplateJSON),mixed=textProduct&&textRoot!==null;const output=mixed?exportWindowsKeysMacrosAndText(profile,template,textRoot,baseline):exportWindowsKeysAndMacros(profile,template);download(exportProfileWindowsLightingDraft(profile,output),'CHERRY-configuration.json');const lightingNote=profile.lightingColorEncoding==='officialRGB'?'包含当前灯效草稿':'包含当前内置灯效；逐键配色沿用导入模板';status(`${mixed?'已合并导出 Windows 格式键位、宏与文本':'已导出 Windows 格式键位与宏'}；${lightingNote}；设备设置沿用导入模板。`);});
$('show-backups').onclick=()=>act(async()=>{const records=await listBackups();$('backups').replaceChildren();if(!records.length)$('backups').textContent='暂无本地备份。';for(const record of records){const row=document.createElement('div');row.className='backup-row';const date=document.createElement('span');date.textContent=new Date(record.date).toLocaleString();const get=document.createElement('button');get.textContent='下载';get.onclick=()=>download(backupConfiguration(record),`CherryMac-before-write-${record.id}.json`);const restore=document.createElement('button');restore.textContent='导入编辑区';restore.onclick=()=>act(()=>{profile=parseProfile(JSON.stringify(backupConfiguration(record)));refreshMacros();loadMacro();loadPlayback();syncLights();switchTab('keys');status('备份已导入编辑区。核对改动后点击“写入按键”恢复；灯效和宏不会写入。');});row.append(date,get,restore);$('backups').append(row);}});
$('diagnostics').onclick=()=>operation(async()=>{
  await Promise.all([hid?.logTasks,pageLogTasks]);
  const results=await Promise.allSettled([listLogs(),listBackups(),macroLocalRecords()]),names=['usbLogs','backups','macroLocalRecords'],records={},storageErrors={};
  results.forEach((result,i)=>{records[names[i]]=result.status==='fulfilled'?result.value:[];if(result.status==='rejected')storageErrors[names[i]]=result.reason?.message??String(result.reason);});
  if(hid?.loggingError)storageErrors.sessionLogging=hid.loggingError;
  if(pageFailures.some(entry=>entry.persistenceError))storageErrors.pageLogging='部分页面错误未能保存到数据库，现有页面记录已附在 pageFailures。';
  const evidence={format:'CherryMacWebDiagnostics',version:1,webVersion:'0.6.0',capturedAt:new Date().toISOString(),browser:navigator.userAgent,origin:location.origin,baseline:clone(baseline),draft:clone(profile),...records,sessionLogs:clone(hid?.history??[]),pageFailures:clone(pageFailures),logError:storageErrors.usbLogs??storageErrors.sessionLogging??null,storageErrors,note:'包含可读取的本地备份与操作日志；storageErrors 非空表示对应资料不完整。未自动上传。'};
  download(evidence,'CherryMac-diagnostics.json');status(Object.keys(storageErrors).length?'排查资料已下载；部分本地记录无法读取，错误已写入文件，其余日志保留。':'排查资料已下载到本地，未上传。',Object.keys(storageErrors).length>0);
},{localOnly:true});
function plan(){requireThat(hid&&!hid.dead&&baseline,'请先连接并读取键盘。');return tab==='macros'&&macroProduct?macroProductPlan(profile,baseline):makeKeymapPlan(profile.snapshot,baseline);}
$('write').onclick=()=>{
  if(tab==='lights'){
    if(busy||recorder||!baseline)return;
    // Delegate synchronously so the research handoff retains the user gesture.
    ($('open-lighting-acceptance')??$('review-lighting')).click();return;
  }
  return act(()=>{const wanted=plan();pending={wanted,kind:tab==='macros'&&macroProduct?'macro':'key',before:clone(baseline),draft:clone(profile)};requireThat(!sameSnapshot(wanted,baseline),'选中的写入类别没有变化。');const c=counts(wanted,baseline);$('confirm-summary').textContent=pending.kind==='macro'?macroWriteReview(profile,baseline,wanted,Object.fromEntries(keys.map(key=>[key.slot,key.label.replaceAll('\n',' / ')])),Object.fromEntries(keys.map(key=>[key.slot,describe(wanted.keymap.slice(key.slot*3,key.slot*3+3))])))+'\n\n灯效和设备参数保留；普通键草稿保留，写入前保存完整备份。':`将修改 ${c.keys} 个按键。灯效、颜色与宏区保留原配置。`;$('confirm').showModal();});
};
$('cancel-write').onclick=()=>{$('confirm').close();pending=null;};
$('confirm-write').onclick=e=>{let wanted;try{gate.acknowledge(e);wanted=pending;requireThat(wanted,'没有待写入配置。');requireThat(equal(profile,wanted.draft)&&sameSnapshot(baseline,wanted.before),'编辑区或读取基线已变化，请重新确认。');}catch(error){status(error.message,true);return;}$('confirm').close();pending=null;void operation(async()=>{
  let after;
  if(wanted.kind==='macro'){macroAbort=new AbortController();render();}
  try{const options={signal:macroAbort?.signal,gate,backup:async snapshot=>{await saveBackup(snapshot);status('写入前备份已保存。');},progress:message=>status(message+'…')};
    if(wanted.kind==='macro'){await rememberMacroTransaction(wanted.before,wanted.wanted);after=await applyMacroWithStop(hid,wanted.wanted,wanted.before,options);}
    else after=await applyConfiguration(hid,wanted.wanted,wanted.before,options);}
  catch(error){baseline=null;if(macroAbort?.signal.aborted)throw new Error('宏操作已停止发送。请重新读取，或使用配置页的宏恢复入口；保存的原配置与目标记录仍在本机。');throw error;}
  finally{macroAbort=null;}
  baseline=clone(after);if(wanted.kind==='macro'){for(let slot=0;slot<126;slot++){const offset=slot*3;if(!equal(wanted.before.keymap.slice(offset,offset+3),after.keymap.slice(offset,offset+3)))profile.snapshot.keymap.splice(offset,3,...after.keymap.slice(offset,offset+3));}}else profile.snapshot.keymap=clone(after.keymap);
  if(wanted.kind==='macro'){profile.snapshot.macroData=clone(after.macroData);try{await rememberMacroProfile(profile,after);}catch(error){status('宏已写入并读回一致，但本地名称保存失败：'+error.message,true);return;}}
  syncLights();status((wanted.kind==='macro'?'宏与绑定键':'按键')+'写入完成，完整读回一致。备份和日志已自动保存；其他草稿尚未写入。');
});};
$('recover-macro').onclick=e=>{if(busy||!macroProduct)return;try{gate.acknowledge(e);}catch(error){status(error.message,true);return;}void operation(async()=>{
  const previous=clone(profile),saved=await lastMacroTransaction();macroAbort=new AbortController();render();
  try{const after=await recoverMacroWithStop(hid,saved.before,saved.target,{signal:macroAbort.signal,gate,backup:saveBackup,progress:message=>status(message+'…')});baseline=clone(after);const restored=await recalledMacroProfile(after)??safeProfile(after);try{profile=mergeMacroRecoveryDraft(restored,previous,saved.before,saved.target);}catch(error){throw new Error(`键盘宏已恢复且读回一致，但草稿合并失败：${error.message}。原编辑区保留，尚未写入。`);}refreshMacros();loadMacro();loadPlayback();syncLights();status('已恢复最近宏写入前配置，完整读回一致；普通键与灯效草稿保留。');}
  catch(error){baseline=null;if(macroAbort.signal.aborted)throw new Error('宏恢复已停止发送。恢复记录仍保留，重连后可再次恢复。');throw error;}
  finally{macroAbort=null;}
});};
$('cancel-macro-operation').onclick=()=>{macroAbort?.abort();render();status('已请求停止发送，正在等待当前 USB 回复；原配置与恢复记录保留。');};
window.addEventListener('beforeunload',e=>{if(busy){e.preventDefault();e.returnValue='';}});
if(!supported){$('compatibility').hidden=false;$('compatibility').textContent=!isSecureContext?'当前网址不是安全环境。请使用 HTTPS 或 localhost 打开，才能连接 USB 键盘。':'此浏览器不支持 WebHID。请在电脑上的 Chrome 或 Edge 打开；当前仍可预览与编辑配置。';}
refreshMacros();syncLights();render();status(textProduct?'文本安装开发预览 · 连接不会自动写入，跨应用输入需 Mac 客户端服务。':macroProduct?'宏模块开发预览 · 连接不会自动写入；灯效写入暂缓。':'预览模式 · 连接读取后可独立写入按键；灯效和宏写入暂缓。');

// Record only within the visible focus area. No global hooks or HID commands.
const physicalCodes={Enter:40,Escape:41,Backspace:42,Tab:43,Space:44,Minus:45,Equal:46,BracketLeft:47,BracketRight:48,Backslash:49,Semicolon:51,Quote:52,Backquote:53,Comma:54,Period:55,Slash:56,CapsLock:57,PrintScreen:70,ScrollLock:71,Pause:72,Insert:73,Home:74,PageUp:75,Delete:76,End:77,PageDown:78,ArrowRight:79,ArrowLeft:80,ArrowDown:81,ArrowUp:82,NumLock:83,NumpadDivide:84,NumpadMultiply:85,NumpadSubtract:86,NumpadAdd:87,NumpadEnter:88,Numpad0:98,NumpadDecimal:99,ContextMenu:101,ControlLeft:224,ShiftLeft:225,AltLeft:226,MetaLeft:227,ControlRight:228,ShiftRight:229,AltRight:230,MetaRight:231};
for(let i=0;i<26;i++)physicalCodes[`Key${String.fromCharCode(65+i)}`]=4+i;
for(let i=1;i<=9;i++){physicalCodes[`Digit${i}`]=29+i;physicalCodes[`Numpad${i}`]=88+i;}physicalCodes.Digit0=39;
for(let i=1;i<=24;i++)physicalCodes[`F${i}`]=i<=12?57+i:91+i;
let recordDestination=null;
const recordClock=()=>Math.floor(performance.now());
function recordControls(active){for(const id of ['record-start','record-timing','record-delay','record-placement','record-mouse','macro-list','macro-name','save-macro','assign-macro','unassign-macro','delete-macro','copy-macro','clear-macros','macro-insert','add-pair'])$(id).disabled=active;$('record-stop').disabled=!active;$('record-cancel').disabled=!active;document.querySelectorAll('#macro-steps button,#macro-steps input,#macro-steps select').forEach(node=>node.disabled=active);}
function cancelRecording(reason){if(!recorder)return;recorder.cancel();recorder=null;recordDestination=null;recordControls(false);render();$('record-status').textContent=reason;$('record-area').textContent='录制已取消 · 原步骤保留';}
$('record-start').onclick=event=>{if(busy||profile.macroBindings==null)return;if(event.ctrlKey||event.shiftKey||event.altKey||event.metaKey){$('record-status').textContent='请先松开修饰键，再开始录制。';return;}void operation(async()=>{try{const place=$('record-placement').value;let insertionIndex=null;
  if(place==='append')insertionIndex=steps.length;else if(place!=='replace'){const [where,raw]=place.split(':');requireThat(['before','after'].includes(where),'请选择有效录制位置。');insertionIndex=Number(raw);requireThat(Number.isInteger(insertionIndex)&&insertionIndex>=0&&insertionIndex<steps.length,'请选择有效录制位置。');if(where==='after')insertionIndex++;}
  recordDestination={originalSteps:clone(steps),insertionIndex};recorder=new MacroRecorder({timing:$('record-timing').value,fixedMilliseconds:Number($('record-delay').value),startedMilliseconds:recordClock()});recordControls(true);$('record-area').textContent='正在录制 · 完全松开按键后点击停止';$('record-status').textContent='0 个事件';$('record-area').focus();}catch(error){$('record-status').textContent=error.message;}});};
$('record-stop').onclick=()=>{if(!recorder)return;try{const m=recorder.finish($('macro-name').value.trim()||'录制宏',recordDestination??{});steps=clone(m.steps);recordingPreference=m.recordingDelay;recorder=null;recordDestination=null;recordControls(false);renderSteps();render();$('record-status').textContent=`已采用 ${steps.length} 个事件，点击保存宏保留。`;}catch(error){$('record-status').textContent=error.message;$('record-area').focus();}};
$('record-cancel').onclick=()=>cancelRecording('录制已取消，原步骤保留。');
function observeRecording(event,usage,pressed,kind){if(!recorder||!event.isTrusted)return;try{recorder.observe({usage,pressed,kind,milliseconds:recordClock(),repeatEvent:!!event.repeat});$('record-status').textContent=`${recorder.steps.length} 个事件 · ${recorder.held.size} 个尚未松开`;}catch(error){cancelRecording(error.message);}}
for(const [type,pressed] of [['keydown',true],['keyup',false]])$('record-area').addEventListener(type,event=>{if(!recorder)return;event.preventDefault();event.stopPropagation();if(event.isComposing||physicalCodes[event.code]==null){cancelRecording('该按键或输入法事件无法可靠识别，请手动添加。');return;}observeRecording(event,physicalCodes[event.code],pressed);});
$('record-area').addEventListener('mousedown',event=>{if(!recorder||!$('record-mouse').checked)return;event.preventDefault();observeRecording(event,({0:1,1:4,2:2,3:8,4:16})[event.button],true,'mouse');});
document.addEventListener('mouseup',event=>{if(!recorder||!$('record-mouse').checked)return;observeRecording(event,({0:1,1:4,2:2,3:8,4:16})[event.button],false,'mouse');});
$('record-area').addEventListener('contextmenu',event=>{if(recorder)event.preventDefault();});
$('record-area').addEventListener('wheel',event=>{if(!recorder||!$('record-mouse').checked||!event.isTrusted)return;event.preventDefault();cancelRecording('滚轮事件尚未支持，录制已取消；原步骤保留。');},{passive:false});
$('record-area').addEventListener('blur',event=>{if(recorder&&!['record-stop','record-cancel'].includes(event.relatedTarget?.id))cancelRecording('录制区失去焦点，已取消；原步骤保留。');});
window.addEventListener('blur',()=>cancelRecording('窗口失去焦点，已取消录制。'));
document.addEventListener('visibilitychange',()=>{if(document.hidden)cancelRecording('页面已隐藏，录制已取消。');});
document.querySelectorAll('[data-tab]').forEach(button=>button.addEventListener('click',()=>cancelRecording('已切换页面，录制已取消。')));


if(textProduct){
  $('text-bridge-pair').onclick=()=>operation(async()=>{await textBridge.pair($('text-bridge-code').value);$('text-bridge-code').value='';status('Mac 已联动。启用文本服务前请先安装并保存相同的文本配置。');});
  $('text-bridge-start').onclick=()=>operation(async()=>{
    requireThat(textRoot&&equal(textRoot,await textStore.active()),'请先安装此文本配置，或载入已保存配置；未写入的编辑不能启用。');
    if(hid)await hid.close();hid=null;
    await textBridge.activate(clone(textRoot));status('已交给 Mac 准备文本服务。切换目标应用后使用；服务状态会自动更新。');
  });
  $('text-bridge-stop').onclick=()=>operation(async()=>status('Mac 文本服务已停止，配置接口已释放。'));
  $('text-bridge-unpair').onclick=()=>operation(async()=>{await textBridge.unpair();status('Mac 联动已解除，文本服务保持关闭。');});
  setInterval(()=>{if(textBridge.paired&&!busy)void textBridge.status().then(()=>render(),error=>{status(error.message,true);render();});},10000);
  window.addEventListener('pagehide',()=>{if(textBridge.paired)void textBridge.request('unpair',{},textBridge.token,{keepalive:true}).catch(()=>{});});
  $('text-history-import').onclick=()=>{if(!busy)$('text-history-file').click();};
  $('text-history-file').onchange=()=>{
    const file=$('text-history-file').files[0];$('text-history-file').value='';if(!file)return;
    void operation(async()=>{
      requireThat(file.size<=8_000_000,'文本恢复记录超过 8 MB。');
      const count=await textStore.importRecords(JSON.parse(await file.text()));
      status(`已导入 ${count} 条文本恢复记录，键盘未改写。恢复时仍须连接、核对并确认；输入服务未开启。`);
    });
  };
  function selectTextConfiguration(root,name){
    const count=validateHostTextDefinition(root);
    textRoot=clone(root);$('text-summary').textContent=`${name} · ${count} 个文本动作。准备安装时读取默认表并显示实体键。`;$('text-bindings').replaceChildren();
  }
  selectImportedText=selectTextConfiguration;
  function loadTextEditor(){
    const slot=Number($('text-edit-key').value),trigger=resolveHostTextTrigger(0x700+slot,textFactory),item=textRoot.KeyList[trigger.logicalIndex];
    $('text-edit-name').value='文本';$('text-edit-value').value='';$('text-edit-remove').disabled=true;
    if(item.ActionLink===1){const action=textRoot.ActionInfo[item.ActionLinkIndex];requireThat(action,'文本动作引用无效。');if(action.ActionType===3){const plan=officialHostTextPlan(action);$('text-edit-name').value=plan.name;$('text-edit-value').value=plan.originalText;$('text-edit-remove').disabled=false;}}
  }
  $('text-edit-open').onclick=()=>operation(async()=>{
    requireThat(hid&&!hid.dead&&baseline&&textRoot,'请先连接键盘并选择官方配置。');
    const before=await hid.read(8,378),factory=await hid.read(7,378),after=await hid.read(8,378);
    requireThat(equal(before,baseline.keymap)&&equal(before,after),'文本编辑准备期间键位变化，请重新读取。');
    textFactory=factory;const picker=$('text-edit-key');picker.replaceChildren();
    for(const key of keys)if(editableSlots.has(key.slot)&&resolveHostTextTrigger(0x700+key.slot,factory))picker.add(new Option(key.label.replaceAll('\n',' / '),String(key.slot)));
    requireThat(picker.options.length,'默认表没有可编辑的文本位置。');
    const initial=String(keys.find(k=>k.id===selected).slot);if([...picker.options].some(o=>o.value===initial))picker.value=initial;
    loadTextEditor();$('text-editor').hidden=false;status('编辑完成后采用，尚未写入键盘。');
  });
  $('text-edit-key').onchange=()=>act(loadTextEditor);
  function adoptText(value){
    requireThat(textRoot&&textFactory,'请先准备文本编辑。');
    const next=editHostText(textRoot,textFactory,Number($('text-edit-key').value),value,$('text-edit-name').value);
    selectTextConfiguration(next,'编辑后的文本配置');textFactory=null;$('text-editor').hidden=true;status('文本配置已修改，尚未写入。请核对安装或导出保存。');
  }
  $('text-edit-save').onclick=()=>act(()=>adoptText($('text-edit-value').value));
  $('text-edit-remove').onclick=()=>act(()=>adoptText(null));
  $('text-edit-cancel').onclick=()=>{textFactory=null;$('text-editor').hidden=true;};
  $('text-import').onclick=()=>{if(!busy)$('text-file').click();};
  $('text-file').onchange=()=>{const file=$('text-file').files[0];$('text-file').value='';if(!file)return;void operation(async()=>{requireThat(file.size<=1_000_000,'文本配置超过 1 MB。');selectTextConfiguration(JSON.parse(await file.text()),file.name);status('文本配置已选中，编辑区和键盘没有变化。');});};
  $('text-load').onclick=()=>operation(async()=>{const root=await textStore.active();requireThat(root,'没有已安装并保存的文本配置。');selectTextConfiguration(root,'已保存文本配置');status('已载入文本定义，尚未启用输入服务。');});
  $('text-export').onclick=()=>act(()=>{requireThat(textRoot,'请先选择文本配置。');download(textRoot,'CherryMac-文本配置.json');});
  $('text-history').onclick=()=>operation(async()=>{download(await textStore.exportRecords(),'CherryMac-文本恢复记录.json');status('恢复记录已导出，包含原键盘配置和文本内容，请妥善保存。');},{localOnly:true});
  $('text-install').onclick=()=>operation(async()=>{
    requireThat(hid&&!hid.dead&&baseline&&textRoot,'请先连接键盘并选择文本配置。');
    const root=clone(textRoot),before=clone(baseline),plan=await hid.readHostTextInstallation(root,before);
    textPending={kind:'install',plan,root,before,draft:clone(profile)};
    const names=Object.fromEntries(keys.map(k=>[k.slot,k.label.replaceAll('\n',' / ')]));
    const rows=[...plan.bindings.map(b=>`${names[b.physicalSlot]??'按键'} → 文本（${[...b.plan.originalText].length} 字符）`),...plan.removedSlots.map(slot=>`${names[slot]??'按键'} → 恢复默认`)];
    $('text-confirm-title').textContent='安装文本绑定';$('text-confirm-summary').textContent=rows.join('\n')+`\n\n${plan.changedSlots.length} 个键位需要写入，灯效和宏区保留。`;
    $('confirm-text').showModal();
  });
  $('text-restore').onclick=()=>operation(async()=>{
    requireThat(hid&&!hid.dead&&baseline,'请先连接并读取键盘。');
    const record=await textStore.latest();requireThat(record&&record.phase!=='restored','没有需要恢复的文本安装记录。');await textStore.validateRestoration(record);
    textPending={kind:'restore',record,plan:textRecordPlan(record),before:clone(baseline),draft:clone(profile)};
    $('text-confirm-title').textContent='恢复最近文本安装';$('text-confirm-summary').textContent='恢复安装前的键位与主机定义；其他配置变化时停止覆盖。恢复后文本输入服务不会自动开启。';$('confirm-text').showModal();
  });
  $('text-confirm-cancel').onclick=()=>{$('confirm-text').close();textPending=null;};
  $('text-confirm-send').onclick=e=>{
    let pending;
    try{gate.acknowledge(e);pending=textPending;requireThat(pending&&sameSnapshot(pending.before,baseline)&&equal(pending.draft,profile),'读取基线或编辑区变化，请重新准备。');if(pending.kind==='install')requireThat(equal(textRoot,pending.root),'文本配置变化，请重新准备。');}catch(error){status(error.message,true);return;}
    $('confirm-text').close();textPending=null;
    void operation(async()=>{
      let staged=null,after;
      const options={gate,backup:saveBackup,progress:message=>status(message+'…')};
      try{
        if(pending.kind==='install'){
          after=await applyHostTextInstallation(hid,pending.root,pending.before,{...options,saveTextConfiguration:async (root,fresh)=>{requireThat(equal(root,pending.root)&&equal(fresh.factoryKeymap,pending.plan.factoryKeymap)&&sameSnapshot(fresh.expected,pending.plan.expected),'文本定义、默认表或安装目标变化，请重新准备。');staged=await textStore.prepare(fresh);}});
          try{await textStore.commit(staged);}catch(error){throw new Error('键盘读回已通过，但主机文本配置提交失败，请保留恢复记录：'+error.message);}
        }else{
          await textStore.validateRestoration(pending.record);
          after=await restoreHostTextInstallation(hid,pending.record.officialJSON,pending.record.factoryKeymap,pending.record.before,options);
          try{await textStore.restored(pending.record);}catch(error){throw new Error('键位已恢复，但主机文本配置回退失败：'+error.message);}
          textRoot=clone(pending.record.previousConfiguration);$('text-summary').textContent=textRoot?'已恢复先前文本配置。':'已恢复；没有先前文本定义。';
        }
      }catch(error){let failure=error;if(staged)try{await textStore.failed(staged);}catch(storage){failure=new Error(error.message+' 文本记录状态更新失败：'+storage.message);}baseline=null;throw failure;}
      baseline=clone(after);profile=mergeHostTextDraft(pending.draft,after,pending.plan);refreshMacros();loadMacro();loadPlayback();syncLights();
      status(pending.kind==='install'?'文本绑定已安装，完整读回通过，主机定义已保存；跨应用输入需客户端服务。':'键位与先前主机定义已恢复；普通键和灯效草稿保留。');
    });
  };
}

$('export-lighting-restore-plan').onclick=()=>act(()=>{
  requireThat(lightingRecordForPlan,'请先检查含完整、可识别读回的灯效恢复记录。');
  const recovery=lightingRestorePlanFromRecord(lightingRecordForPlan);download(recovery,'CherryMac-lighting-restore-plan.json');status('已导出原始数据恢复计划，尚未执行；计划依据记录中的保存状态，实际恢复前需要重新读取配置。');
});
$('inspect-lighting-record').onclick=()=>{if(!busy)$('lighting-record-file').click();};
$('lighting-record-file').onchange=()=>act(async()=>{
  const input=$('lighting-record-file'),file=input.files[0];input.value='';if(!file)return;
  lightingRecordForPlan=null;$('export-lighting-restore-plan').disabled=true;$('lighting-record-result').textContent='';
  requireThat(file.size<=3_000_000,'灯效恢复记录超过 3 MB。');
  const record=JSON.parse(await file.text()),review=record.format==='CherryMacLightingRestoreAttempt'?assessLightingRestoreAttempt(record):assessLightingRecoveryRecord(record);
  const state={alreadyMatched:'恢复前已与备份一致',readbackMatched:'读回符合目标',readbackMismatch:'读回未符合目标',incomplete:'日志未完成',failed:'操作失败'}[review.status];
  const recovery={available:'可分析原始数据恢复',unchanged:'配置与备份一致',unrecognized:'存在无法识别的配置变化',unavailable:'没有完整读回'}[review.recoveryStatus];
  $('lighting-record-result').textContent=`${state}；${recovery}。有效回复 ${review.traceReview.acceptedReports}/${review.traceReview.expectedReports}。未修改键盘。`;
  if(['available','unchanged'].includes(review.recoveryStatus))lightingRecordForPlan=clone(record);
  download(review,'CherryMac-lighting-recovery-assessment.json');status('已完成本地分析并下载结果，未修改编辑区或键盘。');
});
