import {keys,modes,usageNames,describe,demoSnapshot,editableSlots} from './layout.js';
import {clone,equal,requireThat,fromHardware,validateProfile,resolveMacros,parseProfile,validateMacro,rgb,hex,paint} from './model.js';
import {CherryHID,PageReleaseGate} from './hid.js';
import {applyConfiguration,validatePlan,sameSnapshot} from './writer.js';
import {saveBackup,listBackups,download} from './storage.js';
const $=id=>document.getElementById(id),demo=demoSnapshot(),gate=new PageReleaseGate();
let profile=fromHardware(demo),baseline=null,hid=null,busy=false,tab='keys',selected='calculator',selection=new Set([selected]),steps=[],pending=null;
const supported=isSecureContext&&'hid' in navigator;
function status(message,error=false){$('status').textContent=message;$('status').classList.toggle('error',error);}
function safeProfile(s){try{return fromHardware(s);}catch(error){status(`配置已读取；${error.message} 键位和灯效仍可编辑。`);return {format:'CherryMacProfile',version:1,snapshot:clone(s),macros:[]};}}
function counts(s,original){return {keys:keys.filter(k=>!equal(s.keymap.slice(k.slot*3,k.slot*3+3),original.keymap.slice(k.slot*3,k.slot*3+3))).length,colors:keys.filter(k=>!equal(s.colors?.slice(k.slot*3,k.slot*3+3),original.colors?.slice(k.slot*3,k.slot*3+3))).length,params:!equal(s.parameters,original.parameters),macros:!equal(s.macroData,original.macroData)};}
function render(){
  const s=profile.snapshot,base=baseline??demo,c=counts(s,base),changed=c.keys+c.colors+Number(c.params)+Number(c.macros);
  for(const k of keys){const b=document.querySelector(`.key[data-id="${k.id}"]`);b.setAttribute('aria-pressed',String(selection.has(k.id)));b.classList.toggle('changed',!equal(s.keymap.slice(k.slot*3,k.slot*3+3),base.keymap.slice(k.slot*3,k.slot*3+3)));
    const color=s.colors?.slice(k.slot*3,k.slot*3+3);if(tab==='lights'&&color?.length===3){b.style.background=hex(color);b.style.color=color[0]*.2126+color[1]*.7152+color[2]*.0722>140?'#151515':'#fff';}else{b.style.background='';b.style.color='';}
    b.title=`${k.label} · ${describe(s.keymap.slice(k.slot*3,k.slot*3+3))}`;
  }
  const key=keys.find(k=>k.id===selected);$('selection-label').textContent=`已选 ${key.label}${selection.size>1?` · 共 ${selection.size} 键`:''}`;$('light-count').textContent=`${selection.size} 键`;$('selected-record').textContent=describe(s.keymap.slice(key.slot*3,key.slot*3+3));
  document.querySelectorAll('[data-tab]').forEach(b=>{const active=b.dataset.tab===tab;b.setAttribute('aria-selected',String(active));b.tabIndex=active?0:-1;$(`pane-${b.dataset.tab}`).hidden=!active;});
  $('multi-label').hidden=tab!=='lights';$('board-hint').textContent=tab==='lights'?'颜色为静态预览 · ⌘ 点击多选':'普通键保持正方形 · 点击按键进行设置';
  const online=hid&&!hid.dead&&baseline;$('connection').textContent=online?'● USB 已连接 · 已读取':'● 未连接 · 可编辑配置';$('connection').classList.toggle('connected',!!online);$('disconnect').hidden=!hid||hid.dead;
  $('change-title').textContent=baseline?(changed?'准备好你的新设置':'与读取的配置一致'):'先连接，再写入';$('changes').replaceChildren();
  for(const [name,value] of [['按键功能',`${c.keys} 键`],['逐键颜色',`${c.colors} 键`],['灯效参数',c.params?'已修改':'未修改'],['宏存储',c.macros?'已修改':'未修改']]){const line=document.createElement('div');line.className='change-line';const text=document.createElement('span'),v=document.createElement('b');text.textContent=name;v.textContent=value;line.append(text,v);$('changes').append(line);}
  $('draft-note').textContent=baseline?'编辑仅改变待写入配置，连接与导入不会自动写入。':'当前配置未与键盘核对。连接并读取后才能写入；演示数据不会发送到键盘。';
  document.querySelectorAll('main button,main input,main select,dialog button').forEach(e=>e.disabled=busy);
  $('connect').disabled=busy||!supported;$('read').disabled=busy||!hid||hid.dead;$('write').disabled=busy||!online||!changed;
  document.querySelectorAll('[data-record],#stage-shortcut').forEach(b=>b.disabled=busy||!editableSlots.has(key.slot));
  const macroKnown=profile.macroBindings!=null;$('macro-warning').hidden=macroKnown;$('macro-warning').textContent='当前原始宏尚未识别。已保留宏数据；暂不能编辑或覆盖宏库。';
  for(const id of ['save-macro','assign-macro','delete-macro','add-pair'])$(id).disabled=busy||!macroKnown||(id==='assign-macro'&&!editableSlots.has(key.slot));
  if(busy)$('connect').disabled=true;
}
function syncLights(){const p=profile.snapshot.parameters;$('mode').value=String(p[1]);$('brightness').value=Math.min(4,p[2]);$('brightness-label').textContent=p[2];$('speed').value=4-Math.min(4,p[3]);$('direction').value=p[4]<=1?String(p[4]):'';$('rainbow').value=p[5]<=1?String(p[5]):'';loadColor();}
function setColor(b){const value=hex(b);$('color').value=value;$('hex').value=value.toUpperCase();['red','green','blue'].forEach((id,i)=>$(id).value=b[i]);const strength=Math.round(Math.max(...b)*100/255);$('strength').value=strength;$('strength-label').textContent=`${strength}%`;}
function loadColor(){const k=keys.find(k=>k.id===selected);if(profile.snapshot.colors)setColor(profile.snapshot.colors.slice(k.slot*3,k.slot*3+3));}
function refreshMacros(name=''){const list=$('macro-list');list.replaceChildren(new Option('新建宏',''));profile.macros.forEach(m=>list.add(new Option(m.name,m.name)));list.value=name;if(list.value!==name)list.value='';}
function loadMacro(){const m=profile.macros.find(m=>m.name===$('macro-list').value);steps=clone(m?.steps??[]);$('macro-name').value=m?.name??'';renderSteps();}
function usageOptions(select,modifiers=true){for(const [u,name] of Object.entries(usageNames))if(modifiers||Number(u)<224)select.add(new Option(`${name} · ${u}`,u));}
function renderSteps(){const parent=$('macro-steps');parent.replaceChildren();steps.forEach((step,i)=>{
  const row=document.createElement('div');row.className='macro-step';const n=document.createElement('span');n.className='step-number';n.textContent=i+1;
  const usage=document.createElement('select');usageOptions(usage);if(!usageNames[step.usage])usage.add(new Option(`HID ${step.usage}`,step.usage));usage.value=step.usage;usage.setAttribute('aria-label',`步骤 ${i+1} 按键`);usage.onchange=()=>step.usage=Number(usage.value);
  const state=document.createElement('select');state.add(new Option('按下','down'));state.add(new Option('松开','up'));state.value=step.pressed?'down':'up';state.setAttribute('aria-label',`步骤 ${i+1} 状态`);state.onchange=()=>step.pressed=state.value==='down';
  const delay=document.createElement('input');delay.type='number';delay.min=0;delay.max=60000;delay.value=step.delayMilliseconds;delay.setAttribute('aria-label',`步骤 ${i+1} 执行前延迟，毫秒`);delay.oninput=()=>step.delayMilliseconds=delay.value===''?NaN:Number(delay.value);
  const unit=document.createElement('span');unit.textContent='ms';const remove=document.createElement('button');remove.textContent='删除';remove.setAttribute('aria-label',`删除步骤 ${i+1}`);remove.onclick=()=>{steps.splice(i,1);renderSteps();};row.append(n,usage,state,delay,unit,remove);parent.append(row);
  });}
function stageRecord(record){const key=keys.find(k=>k.id===selected);requireThat(editableSlots.has(key.slot),'内部功能键不能改写。');const p=clone(profile);p.snapshot.keymap.splice(key.slot*3,3,...record);if(p.macroBindings)delete p.macroBindings[key.slot];validateProfile(p);profile=p;status(`已为 ${key.label} 设置 ${describe(record)}，尚未写入。`);}
async function act(fn){if(busy)return;try{await fn();render();}catch(error){status(error.message,true);render();}}
async function read(){const s=await hid.snapshot();baseline=clone(s);profile=safeProfile(s);refreshMacros();loadMacro();syncLights();try{await saveBackup(s);}catch(error){status(`读取成功，但本地备份不可用：${error.message} 写入前必须能保存备份。`,true);return;}status('已读取完整配置并保存本地备份。可以开始编辑，尚未写入。');}
async function operation(fn){if(busy)return;busy=true;render();try{await fn();}catch(error){status(error.message,true);}finally{busy=false;render();}}
function switchTab(next){tab=next;if(tab==='lights')syncLights();render();}
// Build real buttons so the diagram supports mouse, keyboard and screen readers.
for(const k of keys){const b=document.createElement('button');b.className='key';b.dataset.id=k.id;b.textContent=k.label;b.style.left=`${k.x/864*100}%`;b.style.top=`${k.y/264*100}%`;b.style.width=`${k.w/864*100}%`;b.style.height=`${k.h/264*100}%`;b.setAttribute('aria-label',`${k.label} 键`);b.setAttribute('aria-pressed','false');b.onclick=e=>{
  selected=k.id;if(tab==='lights'&&(e.metaKey||e.ctrlKey||$('multi').checked)){if(selection.has(k.id)&&selection.size>1){selection.delete(k.id);selected=[...selection][0];}else selection.add(k.id);}else selection=new Set([k.id]);if(tab==='lights')loadColor();render();
};$('keyboard').append(b);}
$('shortcut-key').add(new Option('无主键（仅修饰键）',0));usageOptions($('shortcut-key'),false);usageOptions($('macro-key'));$('shortcut-key').value=21;$('macro-key').value=4;modes.forEach(([value,name])=>$('mode').add(new Option(name,value)));
document.querySelectorAll('[data-tab]').forEach(b=>{b.onclick=()=>switchTab(b.dataset.tab);b.onkeydown=e=>{if(!['ArrowLeft','ArrowRight','Home','End'].includes(e.key))return;e.preventDefault();const tabs=[...document.querySelectorAll('[data-tab]')],i=tabs.indexOf(b),next=e.key==='Home'?0:e.key==='End'?3:(i+(e.key==='ArrowRight'?1:3))%4;tabs[next].focus();switchTab(tabs[next].dataset.tab);};});
document.querySelectorAll('[data-record]').forEach(b=>b.onclick=()=>act(()=>stageRecord(b.dataset.record.split(',').map(Number))));
$('stage-shortcut').onclick=()=>act(()=>{const mask=[...document.querySelectorAll('.modifier:checked')].reduce((n,b)=>n|Number(b.value),0);stageRecord([0x20,mask,Number($('shortcut-key').value)]);});
document.querySelectorAll('[data-region]').forEach(b=>b.onclick=()=>{const region=b.dataset.region;selection=new Set(keys.filter(k=>region==='all'||region==='main'&&k.x<576&&k.y>55||region==='function'&&k.y<55||region==='num'&&k.id.startsWith('num')||region==='arrows'&&['up','down','left','right'].includes(k.id)||region==='wasd'&&k.page===7&&[26,4,22,7].includes(k.usage)).map(k=>k.id));selected=[...selection][0];loadColor();render();});
$('color').oninput=()=>setColor(rgb($('color').value));$('hex').onchange=()=>act(()=>setColor(rgb($('hex').value)));
['red','green','blue'].forEach(id=>$(id).onchange=()=>act(()=>{const b=['red','green','blue'].map(id=>$(id).value===''?NaN:Number($(id).value));requireThat(b.every(v=>Number.isInteger(v)&&v>=0&&v<=255),'RGB 必须是 0–255 的整数。');setColor(b);}));
$('strength').oninput=()=>{const b=rgb($('color').value),peak=Math.max(...b),scale=Number($('strength').value)*255/100;setColor(b.map(v=>Math.round(peak?v/peak*scale:scale)));};
$('paint').onclick=()=>act(()=>{requireThat(profile.snapshot.colors,'请读取包含颜色的完整配置。');paint(profile.snapshot,selection,$('pattern').value,rgb($('hex').value),rgb($('end-color').value));syncLights();status(`已为 ${selection.size} 键加入配色，尚未写入。`);});
$('off').onclick=()=>act(()=>{requireThat(profile.snapshot.colors,'请读取包含颜色的完整配置。');paint(profile.snapshot,selection,'solid',[0,0,0],[0,0,0]);syncLights();status('所选键已设为熄灭，尚未写入。');});
$('brightness').oninput=()=>$('brightness-label').textContent=$('brightness').value;
$('stage-lights').onclick=()=>act(()=>{const p=profile.snapshot.parameters;requireThat($('mode').value!=='','请选择已支持的灯效模式。');p[1]=Number($('mode').value);p[2]=Number($('brightness').value);p[3]=4-Number($('speed').value);if($('direction').value!=='')p[4]=Number($('direction').value);if($('rainbow').value!=='')p[5]=Number($('rainbow').value);status('灯效参数已加入待写入配置。');});
$('global-color').onclick=()=>act(()=>{profile.snapshot.parameters.splice(6,3,...rgb($('hex').value));profile.snapshot.parameters[5]=0;$('rainbow').value='0';status('已将起点色设为内置灯效单色，尚未写入。');});
$('macro-list').onchange=loadMacro;$('add-pair').onclick=()=>{const usage=Number($('macro-key').value);steps.push({usage,pressed:true,delayMilliseconds:0},{usage,pressed:false,delayMilliseconds:30});renderSteps();};
$('save-macro').onclick=()=>act(()=>{const p=clone(profile),old=$('macro-list').value,m={name:$('macro-name').value.trim(),steps:clone(steps)};validateMacro(m);requireThat(!p.macros.some(macro=>macro.name===m.name&&macro.name!==old),'宏名称已存在。');const index=p.macros.findIndex(m=>m.name===old);if(index<0)p.macros.push(m);else{p.macros[index]=m;for(const [slot,name] of Object.entries(p.macroBindings??{}))if(name===old)p.macroBindings[slot]=m.name;}p.snapshot=resolveMacros(p);profile=p;refreshMacros(m.name);loadMacro();status('宏已保存到编辑区，尚未写入键盘。');});
$('assign-macro').onclick=()=>act(()=>{const name=$('macro-list').value,key=keys.find(k=>k.id===selected);requireThat(name&&editableSlots.has(key.slot),'请选择已保存的宏和可配置按键。');const p=clone(profile);p.macroBindings[key.slot]=name;p.snapshot=resolveMacros(p);profile=p;status(`已将 ${name} 分配到 ${key.label}，尚未写入。`);});
$('delete-macro').onclick=()=>act(()=>{const name=$('macro-list').value;requireThat(name,'请选择要删除的宏。');const p=clone(profile);for(const [slot,binding] of Object.entries(p.macroBindings))if(binding===name){p.snapshot.keymap.splice(Number(slot)*3,3,0x20,0,0);delete p.macroBindings[slot];}p.macros=p.macros.filter(m=>m.name!==name);p.snapshot=resolveMacros(p);profile=p;refreshMacros();loadMacro();status('已删除宏，原绑定键设为禁用，尚未写入。');});
$('connect').onclick=()=>operation(async()=>{status('请在浏览器弹窗中选择 CHERRY USB 键盘。');const devices=await navigator.hid.requestDevice({filters:[{vendorId:1130,productId:462,usagePage:0xff1c,usage:0x92}]});requireThat(devices.length===1,'未选择键盘，配置没有变化。');if(hid)await hid.close();baseline=null;hid=new CherryHID(devices[0],{progress:message=>status(message+'…'),onDisconnect:error=>{status(error.message,true);render();}});await hid.open();await read();});
$('read').onclick=()=>operation(read);$('disconnect').onclick=()=>operation(async()=>{if(hid)await hid.close();hid=null;status('已断开配置接口，键盘仍可正常输入。');});
$('discard').onclick=()=>act(()=>{profile=safeProfile(baseline??demo);refreshMacros();loadMacro();syncLights();status('已撤销编辑区修改，实体键盘没有变化。');});
$('import').onclick=()=>$('file').click();$('file').onchange=()=>operation(async()=>{const file=$('file').files[0];$('file').value='';if(!file)return;requireThat(file.size<=1_000_000,'配置文件超过 1 MB。');const p=parseProfile(await file.text(),baseline);profile=p;refreshMacros();loadMacro();syncLights();status('配置已导入编辑区，尚未写入键盘。');});
$('export').onclick=()=>act(()=>{validateProfile(profile);download(profile,'CherryMac-profile.json');status('已导出待写入配置。');});
$('show-backups').onclick=()=>act(async()=>{const records=await listBackups();$('backups').replaceChildren();if(!records.length)$('backups').textContent='暂无本地备份。';for(const record of records){const row=document.createElement('div');row.className='backup-row';const date=document.createElement('span');date.textContent=new Date(record.date).toLocaleString();const get=document.createElement('button');get.textContent='下载';get.onclick=()=>download(record.snapshot,`CherryMac-before-write-${record.id}.json`);const restore=document.createElement('button');restore.textContent='导入编辑区';restore.onclick=()=>act(()=>{profile=safeProfile(record.snapshot);refreshMacros();loadMacro();syncLights();status('备份已导入编辑区，确认后手动写入。');});row.append(date,get,restore);$('backups').append(row);}});
function plan(){requireThat(baseline&&hid&&!hid.dead,'请先连接并读取键盘。');const wanted=clone(profile.snapshot),scope=$('scope').value;if(scope==='keys'){wanted.parameters=clone(baseline.parameters);wanted.colors=clone(baseline.colors);}if(scope==='lights'){wanted.keymap=clone(baseline.keymap);wanted.macroData=clone(baseline.macroData);}validatePlan(wanted,baseline);return wanted;}
$('write').onclick=()=>act(()=>{pending=plan();requireThat(!sameSnapshot(pending,baseline),'选中的写入类别没有变化。');const c=counts(pending,baseline);$('confirm-summary').textContent=`将修改 ${c.keys} 个键位、${c.colors} 个按键颜色${c.params?'，以及灯效参数':''}${c.macros?'，以及宏存储':''}。`;$('confirm').showModal();});
$('cancel-write').onclick=()=>{$('confirm').close();pending=null;};
$('confirm-write').onclick=e=>{let wanted;try{gate.acknowledge(e);wanted=pending;requireThat(wanted,'没有待写入配置。');}catch(error){status(error.message,true);return;}$('confirm').close();pending=null;void operation(async()=>{
  const after=await applyConfiguration(hid,wanted,baseline,{gate,backup:async snapshot=>{await saveBackup(snapshot);status('写入前备份已保存。');},progress:message=>status(message+'…')});
  const draft=clone(profile.snapshot);baseline=clone(after);profile.snapshot=clone(after);
  if($('scope').value==='keys'){profile.snapshot.parameters=draft.parameters;profile.snapshot.colors=draft.colors;}
  if($('scope').value==='lights'){profile.snapshot.keymap=draft.keymap;profile.snapshot.macroData=draft.macroData;}
  syncLights();status('写入完成，完整读回一致。可以正常使用键盘；断电保留尚未验证。');
});};
window.addEventListener('beforeunload',e=>{if(busy){e.preventDefault();e.returnValue='';}});
if(!supported){$('compatibility').hidden=false;$('compatibility').textContent=!isSecureContext?'当前网址不是安全环境。请使用 HTTPS 或 localhost 打开，才能连接 USB 键盘。':'此浏览器不支持 WebHID。请在电脑上的 Chrome 或 Edge 打开；当前仍可预览与编辑配置。';}
refreshMacros();syncLights();render();
