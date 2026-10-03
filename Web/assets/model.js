import {SLOTS,WINDOWS_DEFAULTS,MEDIA_CODES,MODE_CODES} from './tables.js?v=0.5.0';
import {keys,modes} from './layout.js?v=0.5.0';
export const clone=x=>structuredClone(x);
export const equal=(a,b)=>JSON.stringify(a)===JSON.stringify(b);
export function requireThat(ok,message){if(!ok)throw new Error(message);}
export function bytes(a,n){return Array.isArray(a)&&a.length===n&&a.every(x=>Number.isInteger(x)&&x>=0&&x<=255);}
export function validateSnapshot(s,complete=false){
  requireThat(s&&s.format==='CherryMacHardware'&&s.version===1&&s.vendorID===1130&&s.productID===462,'配置不适用于这款宝可梦键盘。');
  requireThat(bytes(s.keymap,378)&&bytes(s.parameters,56)&&bytes(s.deviceInfo,34),'键位、参数或设备信息长度无效。');
  requireThat((s.colors==null&&!complete)||bytes(s.colors,378),'逐键颜色数据无效。');
  requireThat((s.macroData==null&&!complete)||bytes(s.macroData,3071),'宏存储数据无效。');
  requireThat(Number.isFinite(s.createdAt),'备份日期无效。');
}
export function validateMacro(m){
  if(m?.preferredPlayback!=null)validatePlayback(m.preferredPlayback);
  requireThat(m&&typeof m.name==='string'&&m.name.trim()&&[...m.name].length<=80&&Array.isArray(m.steps)&&m.steps.length>0&&m.steps.length<=256,'宏名称或步骤数量无效。');
  if(m.recordingDelay!=null)requireThat(typeof m.recordingDelay==='object'&&typeof m.recordingDelay.fixed==='boolean'&&Number.isInteger(m.recordingDelay.milliseconds)&&m.recordingDelay.milliseconds>=0&&m.recordingDelay.milliseconds<=60000,'固定间隔选项须为 0…60000 毫秒。');
  const held=new Set();
  for(const s of m.steps){
    const mouse=s.kind==='mouse';requireThat(s.kind==null||mouse,'宏事件类型尚未支持。');const identity=`${mouse?'mouse':'key'}:${s.usage}`;
    requireThat(Number.isInteger(s.usage)&&(mouse?[1,2,4,8,16].includes(s.usage):s.usage>=4&&s.usage<=231)&&typeof s.pressed==='boolean'&&Number.isInteger(s.delayMilliseconds)&&s.delayMilliseconds>=0&&s.delayMilliseconds<=60000,'宏按键或延迟超出范围。');
    requireThat(s.pressed?!held.has(identity):held.has(identity),'宏的按下与松开必须一一对应。');
    if(s.pressed)held.add(identity);else held.delete(identity);
  }
  requireThat(held.size===0,'宏结束时必须释放全部按键。');
}
export function encodeBank(macros){
  requireThat(Array.isArray(macros)&&macros.length<=32,'最多支持 32 个宏。');macros.forEach(validateMacro);
  const bank=Array(3071).fill(0);if(!macros.length)return bank;
  const total=16+macros.length*6+macros.reduce((n,m)=>n+m.steps.length*4,0);
  requireThat(total<=3071,'宏超过键盘存储容量。');
  const word=(o,v)=>{bank[o]=v&255;bank[o+1]=v>>8;};bank[0]=0xaa;bank[1]=0x55;word(2,total);word(4,macros.length);
  let cursor=16+macros.length*2;
  macros.forEach((m,i)=>{word(16+i*2,cursor);word(cursor,m.steps.length);m.steps.forEach((s,j)=>{
    const modifier=s.kind!=='mouse'&&s.usage>=224;
    bank.splice(cursor+4+j*4,4,s.delayMilliseconds&255,s.delayMilliseconds>>8,(s.kind==='mouse'?1:modifier?9:10)|(s.pressed?128:0),modifier?1<<(s.usage-224):s.usage);
  });cursor+=4+m.steps.length*4;});return bank;
}
export function decodeBank(bank){
  requireThat(bytes(bank,3071),'宏区长度无效。');if(bank.every(x=>x===0)||bank.every(x=>x===255))return [];
  const word=o=>bank[o]|bank[o+1]<<8;const length=word(2),count=word(4);
  requireThat(bank[0]===0xaa&&bank[1]===0x55&&count<=32&&length>=16+count*2&&length<=3071,'宏头部尚未识别，原始数据仍保留。');
  let cursor=16+count*2;const macros=[];
  for(let i=0;i<count;i++){
    const start=word(16+i*2);requireThat(start>=cursor&&start+4<=length,'宏偏移重叠或越界。');
    const n=word(start),end=start+4+n*4;requireThat(n>0&&n<=256&&end<=length,'宏事件越界。');
    const m={name:`硬件宏 ${i+1}`,steps:[]};
    for(let o=start+4;o<end;o+=4){const kind=bank[o+2]&127,code=bank[o+3];let usage;
      if(kind===1&&[1,2,4,8,16].includes(code))usage=code;
      else if(kind===10&&code<224)usage=code;
      else if(kind===9&&code>0&&(code&(code-1))===0)usage=224+Math.log2(code);
      else throw new Error('宏包含尚未支持的事件，原始数据仍保留。');
      m.steps.push({usage,pressed:!!(bank[o+2]&128),delayMilliseconds:word(o),...(kind===1?{kind:'mouse'}:{})});
    }
    validateMacro(m);macros.push(m);cursor=end;
  }return macros;
}
export function validatePlayback(p){
  requireThat(p&&['count','held','toggle'].includes(p.mode)&&Number.isInteger(p.count)&&p.count>=1&&p.count<=255&&(p.mode==='count'||p.count===1),'宏执行次数须为 1–255；持续与开关模式不使用次数。');
}
export function macroBinding(index,p={mode:'count',count:1}){
  requireThat(Number.isInteger(index)&&index>=0&&index<32,'宏索引无效。');validatePlayback(p);
  return p.mode==='count'?(p.count===1?[0x70,index,0]:[0x71,index,p.count]):[0x70,index,p.mode==='held'?1:2];
}
export function decodeMacroBinding(b,count){
  requireThat(bytes(b,3)&&b[1]<count,'宏绑定引用无效。');
  if(b[0]===0x70&&b[2]<=2)return {mode:['count','held','toggle'][b[2]],count:1};
  if(b[0]===0x71&&b[2]>=2)return {mode:'count',count:b[2]};
  throw new Error('未知宏执行方式，原始数据保留。');
}
export function fromHardware(snapshot){
  validateSnapshot(snapshot);const p={format:'CherryMacProfile',version:1,snapshot:clone(snapshot),macros:[]};
  if(!snapshot.macroData)return p;
  p.macros=decodeBank(snapshot.macroData);p.macroBindings={};p.macroModes={};
  for(let slot=0;slot<126;slot++){const b=snapshot.keymap.slice(slot*3,slot*3+3);if([0x70,0x71].includes(b[0])){
    requireThat(![6,71].includes(slot),'宏不能绑定到内部键。');p.macroModes[slot]=decodeMacroBinding(b,p.macros.length);p.macroBindings[slot]=p.macros[b[1]].name;
  }}return p;
}
export function validateProfile(p){
  requireThat(p&&p.format==='CherryMacProfile'&&p.version===1&&Array.isArray(p.macros)&&p.macros.length<=32,'配置格式或版本不受支持。');validateSnapshot(p.snapshot);p.macros.forEach(validateMacro);
  requireThat(new Set(p.macros.map(m=>m.name)).size===p.macros.length,'宏名称不能重复。');
  if(p.macroModes!=null){requireThat(typeof p.macroModes==='object'&&!Array.isArray(p.macroModes),'宏执行方式结构无效。');for(const [slot,playback] of Object.entries(p.macroModes)){requireThat(Object.hasOwn(p.macroBindings??{},slot),'宏执行方式缺少对应绑定。');validatePlayback(playback);}}
  if(p.macroBindings!=null){requireThat(typeof p.macroBindings==='object'&&!Array.isArray(p.macroBindings),'宏绑定结构无效。');
    for(const [slot,name] of Object.entries(p.macroBindings))requireThat(/^(0|[1-9]\d*)$/.test(slot)&&Number(slot)<126&&![6,71].includes(Number(slot))&&p.macros.some(m=>m.name===name),'宏绑定无效。');}
}
export function resolveMacros(p){
  validateProfile(p);requireThat(p.macroBindings!=null,'未知宏不能覆盖，请重新读取键盘。');const s=clone(p.snapshot);
  for(let slot=0;slot<126;slot++)if([0x70,0x71].includes(s.keymap[slot*3]))requireThat(Object.hasOwn(p.macroBindings,slot),'宏记录缺少绑定。');
  s.macroData=encodeBank(p.macros);for(const [slot,name] of Object.entries(p.macroBindings))s.keymap.splice(Number(slot)*3,3,...macroBinding(p.macros.findIndex(m=>m.name===name),p.macroModes?.[slot]));return s;
}
export function parseProfile(text,baseline){
  requireThat(new TextEncoder().encode(text).length<=1_000_000,'配置文件超过 1 MB。');const data=JSON.parse(text);
  if(data?.KeyList||data?.DeviceBasicInfo){requireThat(baseline,'导入 Windows 配置前请连接并读取键盘。');return importWindows(data,baseline);}
  const p=data?.format==='CherryMacHardware'?{format:'CherryMacProfile',version:1,snapshot:data,macros:[]}:data;validateProfile(p);
  // Raw backups acquire an editable library only when the firmware bank is recognized.
  if(p.macroBindings==null&&p.macros.length===0){try{return fromHardware(p.snapshot);}catch{}}
  return p;
}
const winInt=(v,name,min,max)=>{if(typeof v==='string'&&/^-?\d+$/.test(v))v=Number(v);requireThat(Number.isInteger(v)&&v>=min&&v<=max,`Windows ${name} 数据无效。`);return v;};
function physicalSlot(v){
  if(v>>16===0x20&&((v>>8)&255)===0){const slot=SLOTS[v&255];return [10,75].includes(slot)?undefined:slot;}
  return ({[0xa00300]:6,[0xa00100]:71,[0x200100]:5,[0x200200]:4,[0x200400]:17,[0x200800]:11,[0x201000]:83,[0x202000]:82,[0x204000]:65,[0x309201]:102,[0x30b600]:108,[0x30cd00]:114,[0x30b500]:120})[v];
}
// ActionInfo building block; this does not yet export a whole official document.
export function officialMacroAction(m,playback=m?.preferredPlayback??{mode:'count',count:1}){
  validateMacro(m);validatePlayback(playback);
  return {ActionType:2,ActionName:m.name,ActionContent:{
    ActionMacroType:['count','held','toggle'].indexOf(playback.mode),ActionMacroLoopValue:playback.count,
    ActionMacroFixTimeIsSelected:m.recordingDelay?.fixed?1:0,ActionMacroFixTimeValue:m.recordingDelay?.milliseconds??0,
    ActionMacroEvents:m.steps.map(s=>{const mouse=s.kind==='mouse',modifier=!mouse&&s.usage>=224;
      return {Type:mouse?1:modifier?9:10,Button:modifier?1<<(s.usage-224):s.usage,Action:s.pressed?'down':'up',Delay:s.delayMilliseconds};})
  }};
}
export function importWindows(root,baseline){
  validateSnapshot(baseline,true);requireThat(root['//']==='47'&&Array.isArray(root.KeyList)&&root.KeyList.length===126,'仅支持 Pokémon 型号 47 的 Windows 配置。');
  root.KeyList.forEach((k,i)=>requireThat(winInt(k?.DefaultAssignment,'DefaultAssignment',0,0xffffff)===WINDOWS_DEFAULTS[i],'Windows 键盘布局不匹配。'));
  for(const field of ['LightInfo','CustomLightMode'])requireThat(root[field]==null||(typeof root[field]==='object'&&!Array.isArray(root[field])),'Windows 灯效结构无效。');
  requireThat(root.ActionInfo==null||Array.isArray(root.ActionInfo),'Windows 动作结构无效。');
  const p=fromHardware(baseline),old=clone(p.macroBindings),actions=root.ActionInfo??[],imported=new Map(),physical=new Set(WINDOWS_DEFAULTS.map(physicalSlot));
  p.macroBindings=Object.fromEntries(Object.entries(old).filter(([slot])=>!physical.has(Number(slot))));
  p.macroModes=Object.fromEntries(Object.entries(p.macroModes??{}).filter(([slot])=>!physical.has(Number(slot))));
  const record=v=>{v=winInt(v,'按键动作',0,0xffffff);const b=[v>>16,(v>>8)&255,v&255];requireThat([0x20,0x30].includes(b[0]),'不支持此 Windows 按键动作。');return b;};
  const importMacro=index=>{
    if(imported.has(index))return;const a=actions[index],c=a?.ActionContent;requireThat(c&&typeof c==='object'&&!Array.isArray(c),'Windows 宏内容无效。');

    const recordingDelay={fixed:winInt(c.ActionMacroFixTimeIsSelected??0,'固定间隔选项',0,1)===1,milliseconds:winInt(c.ActionMacroFixTimeValue??0,'固定间隔值',0,60000)};
    requireThat(Array.isArray(c.ActionMacroEvents),'Windows 宏事件无效。');
    const steps=c.ActionMacroEvents.map(e=>{const type=winInt(e.Type,'事件类型',0,127),button=winInt(e.Button,'按键',0,255);let usage;
      if(type===1&&[1,2,4,8,16].includes(button))usage=button;
      else if(type===10&&button>=4&&button<224)usage=button;
      else if(type===9&&button>0&&(button&(button-1))===0)usage=224+Math.log2(button);
      else throw new Error('滚动与其他宏事件尚未支持。');requireThat(['down','up'].includes(e.Action),'宏按下／松开状态无效。');return {usage,pressed:e.Action==='down',delayMilliseconds:winInt(e.Delay,'延迟',0,60000),...(type===1?{kind:'mouse'}:{})};});
    const stem=typeof a.ActionName==='string'&&a.ActionName.trim()?[...a.ActionName].slice(0,65).join(''):'导入宏';let name=stem,j=1;while(p.macros.some(m=>m.name===name))name=`${stem} (${j++})`;
    const mode=winInt(c.ActionMacroType,'宏模式',0,2),preferredPlayback={mode:['count','held','toggle'][mode],count:mode===0?winInt(c.ActionMacroLoopValue??1,'重复次数',1,255):1};
    const macro={name,steps,recordingDelay,preferredPlayback};validateMacro(macro);p.macros.push(macro);imported.set(index,name);

  };
  actions.forEach((action,index)=>{let type;try{type=winInt(action?.ActionType,'ActionType',0,4);}catch{return;}if(type===2)importMacro(index);});
  root.KeyList.forEach((k,i)=>{
    const slot=physicalSlot(WINDOWS_DEFAULTS[i]);if(slot===undefined||[6,71].includes(slot))return;
    let b;if(winInt(k.ActionLink??0,'ActionLink',0,1)===0)b=record(k.Assignment);
    else{
      const index=winInt(k.ActionLinkIndex,'ActionLinkIndex',0,actions.length-1),a=actions[index],c=a?.ActionContent;requireThat(c&&typeof c==='object','Windows 动作引用无效。');
      const type=winInt(a.ActionType,'ActionType',0,4);
      if(type===1)b=record(c.ActionKey);
      else if(type===4){const code=MEDIA_CODES[winInt(c.ActionMedia,'ActionMedia',0,17)];b=[0x30,code&255,code>>8];}
      else if(type===2){
        importMacro(index);const name=imported.get(index);p.macroBindings[slot]=name;const mode=winInt(c.ActionMacroType,'宏模式',0,2);p.macroModes[slot]={mode:['count','held','toggle'][mode],count:mode===0?winInt(c.ActionMacroLoopValue??1,'重复次数',1,255):1};b=macroBinding(p.macros.findIndex(m=>m.name===name),p.macroModes[slot]);
      }else throw new Error('Windows 文本和其他动作尚未支持导入。');
    }p.snapshot.keymap.splice(slot*3,3,...b);
  });
  const l=root.LightInfo;if(l){const mode=MODE_CODES[winInt(l.SelectItem,'模式',0,24)];requireThat(modes.some(([v])=>v===mode),'此内置灯效尚未验证。');
    p.snapshot.parameters.splice(1,8,mode,winInt(l.Light,'亮度',0,4),4-winInt(l.Speed,'速度',0,4),winInt(l.Fx,'方向',0,1),winInt(l.MultiColor,'彩虹',0,1),...['Red','Green','Blue'].map(k=>winInt(l[k],k,0,255)));}
  const groups=root.CustomLightMode?.LightColorInfo;if(root.CustomLightMode){requireThat(Array.isArray(groups)&&groups.length===1&&groups[0].length===126,'逐键颜色组不匹配。');groups[0].forEach((c,i)=>{const slot=physicalSlot(WINDOWS_DEFAULTS[i]);if(slot!==undefined)p.snapshot.colors.splice(slot*3,3,...['Red','Green','Blue'].map(k=>winInt(c[k],k,0,255)));});}
  if(!equal(p.macroBindings,old)||imported.size)p.snapshot=resolveMacros(p);validateProfile(p);return p;
}
export function rgb(hex){requireThat(/^#[\da-f]{6}$/i.test(hex),'请输入六位 HEX 色号。');return [1,3,5].map(i=>parseInt(hex.slice(i,i+2),16));}
export const hex=b=>'#'+b.map(x=>x.toString(16).padStart(2,'0')).join('');
export function paint(s,selection,pattern,start,end){
  const targets=keys.filter(k=>selection.has(k.id));requireThat(targets.length&&targets.length===selection.size,'请选择按键。');
  const xs=targets.map(k=>k.x+k.w/2),ys=targets.map(k=>k.y+k.h/2),minX=Math.min(...xs),minY=Math.min(...ys),dx=Math.max(...xs)-minX,dy=Math.max(...ys)-minY;
  const mix=(a,b,t)=>a.map((v,i)=>Math.round(v*(1-t)+b[i]*t));
  for(const k of targets){const x=dx?(k.x+k.w/2-minX)/dx:0,y=dy?(k.y+k.h/2-minY)/dy:0;let color=start;
    if(pattern==='horizontal')color=mix(start,end,x);if(pattern==='vertical')color=mix(start,end,y);
    if(pattern==='rainbow'){const h=x*.83*6,c=1,q=1-Math.abs(h%2-1);color=([[c,q,0],[q,c,0],[0,c,q],[0,q,c],[q,0,c],[c,0,q]][Math.floor(h)]).map(v=>Math.round(v*255));}
    if(pattern==='pikachu')color=['esc','calculator'].includes(k.id)?[255,54,44]:k.id.startsWith('mod')?[78,54,18]:[255,214,0];
    if(pattern==='charizard')color=mix([255,55,0],[255,202,32],1-y);
    s.colors.splice(k.slot*3,3,...color);
  }s.parameters[1]=8;
}

// No I/O: focused UI adapters provide trusted observations and a monotonic clock.
export class MacroRecorder{
  constructor({timing='actual',fixedMilliseconds=0,startedMilliseconds}){
    requireThat(['actual','fixed','ignore'].includes(timing)&&Number.isInteger(fixedMilliseconds)&&fixedMilliseconds>=0&&fixedMilliseconds<=60000&&Number.isSafeInteger(startedMilliseconds)&&startedMilliseconds>=0,'录制间隔或时钟无效。');
    this.timing=timing;this.fixedMilliseconds=fixedMilliseconds;this.lastMilliseconds=startedMilliseconds;this.active=true;this.steps=[];this.held=new Set();
  }
  observe({usage,kind,pressed,milliseconds,repeatEvent=false}){
    requireThat(this.active,'录制已停止。');
    requireThat(Number.isSafeInteger(milliseconds)&&milliseconds>=this.lastMilliseconds&&typeof pressed==='boolean'&&(kind==null||kind==='mouse')&&Number.isInteger(usage)&&(kind==='mouse'?[1,2,4,8,16].includes(usage):usage>=4&&usage<=231),'录制事件或时钟无效。');
    const identity=`${kind==='mouse'?'mouse':'key'}:${usage}`;
    if(repeatEvent||(pressed?this.held.has(identity):!this.held.has(identity)))return;
    requireThat(this.steps.length<256,'录制最多 256 个事件，请取消或缩短操作。');
    const delayMilliseconds=this.timing==='fixed'?this.fixedMilliseconds:this.timing==='ignore'?0:Math.min(60000,milliseconds-this.lastMilliseconds);
    this.steps.push({usage,pressed,delayMilliseconds,...(kind==='mouse'?{kind}:{})});
    if(pressed)this.held.add(identity);else this.held.delete(identity);this.lastMilliseconds=milliseconds;
  }
  finish(name){requireThat(this.active&&this.held.size===0,'请先松开全部录制按键，再停止录制。');const m={name,steps:clone(this.steps),recordingDelay:{fixed:this.timing==='fixed',milliseconds:this.fixedMilliseconds}};validateMacro(m);this.active=false;return m;}
  cancel(){this.active=false;this.steps=[];this.held.clear();}
}

// Nominal event-delay budget, not a claim about measured firmware timing.
export function macroCompletionRequirements(keymap,macros){
  requireThat(bytes(keymap,378)&&Array.isArray(macros),'宏键位表或宏库无效。');
  const result={finiteDurationMilliseconds:0,repeatingBindings:[]};
  for(let slot=0;slot<126;slot++)if([0x70,0x71].includes(keymap[slot*3])){
    const record=keymap.slice(slot*3,slot*3+3),playback=decodeMacroBinding(record,macros.length),macro=macros[record[1]];validateMacro(macro);
    const cycle=macro.steps.reduce((n,s)=>n+s.delayMilliseconds,0);
    if(playback.mode==='count')result.finiteDurationMilliseconds=Math.max(result.finiteDurationMilliseconds,cycle*playback.count);
    else result.repeatingBindings.push({slot,macro:clone(macro),playback,quietMilliseconds:cycle+200});
  }
  return result;
}
export function finiteMacroDurationMilliseconds(keymap,macros){
  const result=macroCompletionRequirements(keymap,macros);
  requireThat(result.repeatingBindings.length===0,'持续与开关宏需要先确认停止，不能使用有限等待流程。');
  return result.finiteDurationMilliseconds;
}

// Passive evidence only. Callers must identify the actual observation source;
// this class does not turn a replay or an acknowledgement into hardware proof.
export class MacroExecutionEvidence {
  #macro;#playback;#source;#requiredQuiet;#observations=[];#held=new Set();#last;
  #matched=0;#observed=0;#afterStop=0;#stop=null;#stopSource=null;#failure=null;
  constructor({macro,playback,source,startedMilliseconds}){
    validateMacro(macro);validatePlayback(playback);
    requireThat(['hid','focusedBrowser','simulation'].includes(source)&&Number.isSafeInteger(startedMilliseconds)&&startedMilliseconds>=0,'执行观察来源或时钟无效。');
    this.#macro=clone(macro);this.#playback=clone(playback);this.#source=source;this.#last=startedMilliseconds;
    this.#requiredQuiet=Math.max(200,macro.steps.reduce((n,s)=>n+s.delayMilliseconds,0)+200);
  }
  get observations(){return clone(this.#observations);}
  #fail(reason){this.#failure??=reason;}
  invalidate(reason){
    if(!['observerDisconnected','focusLost','loggingFailed','cancelled','reportRejected'].includes(reason)){this.#fail('invalidInterruptionMarker');throw new Error('执行观察中断标记无效。');}
    this.#fail(reason);
  }
  observe(event){
    const mouse=event?.kind==='mouse';
    if(!(Number.isSafeInteger(event?.milliseconds)&&event.milliseconds>=this.#last&&typeof event.pressed==='boolean'&&(event.kind==null||mouse)&&Number.isInteger(event.usage)&&(mouse?[1,2,4,8,16].includes(event.usage):event.usage>=4&&event.usage<=231))){this.#fail('invalidObservation');throw new Error('执行观察事件或时钟无效。');}
    const identity=`${mouse?'mouse':'key'}:${event.usage}`;this.#last=event.milliseconds;this.#observed++;
    if(this.#observations.length<65536)this.#observations.push(clone(event));else this.#fail('captureOverflow');
    if(event.pressed?this.#held.has(identity):!this.#held.has(identity))this.#fail('unbalancedObservation');
    if(this.#stop!==null){this.#afterStop++;if(event.pressed)this.#fail('pressAfterStop');}
    if(this.#failure===null){
      const expected=this.#macro.steps[this.#matched%this.#macro.steps.length];
      const matches=expected.usage===event.usage&&(expected.kind??null)===(event.kind??null)&&expected.pressed===event.pressed;
      const beyondCount=this.#playback.mode==='count'&&this.#matched>=this.#macro.steps.length*this.#playback.count;
      if(beyondCount)this.#fail('extraEvent');else if(matches)this.#matched++;else if(this.#stop===null)this.#fail('unexpectedEvent');
    }
    if(event.pressed)this.#held.add(identity);else this.#held.delete(identity);
  }
  requestStop({milliseconds,source}){
    if(!(this.#playback.mode!=='count'&&this.#stop===null&&Number.isSafeInteger(milliseconds)&&milliseconds>=this.#last&&['physicalTriggerObserved','userAcknowledged','simulation'].includes(source))){this.#fail('invalidStopMarker');throw new Error('停止标记无效或重复。');}
    this.#stop=milliseconds;this.#stopSource=source;this.#last=milliseconds;
  }
  assessment(milliseconds){
    requireThat(Number.isSafeInteger(milliseconds)&&milliseconds>=this.#last,'评估时钟早于最后观察。');
    const cycles=Math.floor(this.#matched/this.#macro.steps.length),quiet=milliseconds-this.#last;
    const complete=this.#playback.mode==='count'?this.#matched===this.#macro.steps.length*this.#playback.count:cycles>=2;
    const status=this.#failure!==null?'failed':!complete?'waitingOutput':this.#playback.mode!=='count'&&this.#stop===null?'waitingStop':this.#held.size?'waitingRelease':quiet<this.#requiredQuiet?'waitingQuiet':'passed';
    return {status,passed:status==='passed',source:this.#source,...(this.#stopSource!==null?{stopSource:this.#stopSource}:{}),scope:'observed events only; no hardware write or power-cycle proof',completedCycles:cycles,matchedEvents:this.#matched,observedEvents:this.#observed,eventsAfterStop:this.#afterStop,held:[...this.#held].sort(),quietMilliseconds:quiet,requiredQuietMilliseconds:this.#requiredQuiet,...(this.#failure!==null?{failure:this.#failure}:{})};
  }
}

export function replayMacroExecutionLog(log){
  requireThat(log?.format==='CherryMacMacroExecution'&&log.version===1&&Array.isArray(log.events)&&log.events.length<=65536,'宏执行日志格式或长度无效。');
  const evidence=new MacroExecutionEvidence(log);let marked=false;
  requireThat(log.interruptions==null||(Array.isArray(log.interruptions)&&log.interruptions.length<=16),'执行日志中断标记无效。');
  for(const interruption of log.interruptions??[])evidence.invalidate(interruption);
  for(const event of log.events){
    if(log.stop!=null&&!marked&&log.stop.milliseconds<=event.milliseconds){evidence.requestStop(log.stop);marked=true;}
    evidence.observe(event);
  }
  if(log.stop!=null&&!marked)evidence.requestStop(log.stop);
  return evidence.assessment(log.assessedMilliseconds);
}


export function duplicateMacro(profile,name){
  validateProfile(profile);requireThat(profile.macroBindings!=null,'原硬件宏尚未解码，不能复制。');
  const p=clone(profile),original=p.macros.find(m=>m.name===name);requireThat(original,'请选择已保存的宏。');
  const stem=[...name].slice(0,65).join('');let next=`${stem} 副本`,number=2;while(p.macros.some(m=>m.name===next))next=`${stem} 副本 ${number++}`;
  const copied=clone(original);copied.name=next;p.macros.push(copied);p.snapshot=resolveMacros(p);return {profile:p,name:next};
}
export function clearMacros(profile){
  validateProfile(profile);requireThat(profile.macroBindings!=null,'原硬件宏尚未解码，不能清空。');const p=clone(profile);
  for(const slot of Object.keys(p.macroBindings))p.snapshot.keymap.splice(Number(slot)*3,3,0x20,0,0);
  p.macros=[];p.macroBindings={};p.macroModes={};p.snapshot=resolveMacros(p);return p;
}
