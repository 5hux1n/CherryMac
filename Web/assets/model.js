import {SLOTS,WINDOWS_DEFAULTS,FIRMWARE_LOGICAL_DEFAULTS,MEDIA_CODES,MODE_CODES} from './tables.js?v=0.6.0';
import {keys,modes,editableSlots} from './layout.js?v=0.6.0';
export const clone=x=>structuredClone(x);
export const equal=(a,b)=>JSON.stringify(a)===JSON.stringify(b);
export function requireThat(ok,message){if(!ok)throw new Error(message);}
export function bytes(a,n){return Array.isArray(a)&&a.length===n&&a.every(x=>Number.isInteger(x)&&x>=0&&x<=255);}
// 01CE logical matching uses factory defaults and the separate 1B LED table.
// Pure decoding only; no hardware calls. Bounds match the current RGB bank.
export function resolveLightingSlots(factoryKeymap,ledIndices){
  requireThat(bytes(factoryKeymap,378)&&bytes(ledIndices,126),'灯光映射需要完整默认键位表和 126 项 LED 索引。');
  requireThat(ledIndices.every(value=>value<126||value===255),'LED 索引超出当前颜色表范围，停止转换。');
  return FIRMWARE_LOGICAL_DEFAULTS.map((value,index)=>{
    if(index>=122&&index<=124)return null;
    for(let slot=0;slot<126;slot++){
      const offset=slot*3,record=(factoryKeymap[offset]<<16)|(factoryKeymap[offset+1]<<8)|factoryKeymap[offset+2];
      if(record===value)return ledIndices[slot]===255?null:ledIndices[slot];
    }
    return null;
  });
}
export async function captureLightingMapping(snapshot,read){
  validateSnapshot(snapshot);requireThat(typeof read==='function','灯光映射缺少读取接口。');snapshot=clone(snapshot);
  const factory=clone(await read(7,378)),indices=clone(await read(0x1b,126));
  const verifiedFactory=await read(7,378),verifiedIndices=await read(0x1b,126),info=await read(3,34),keymap=await read(8,378);
  requireThat(equal(factory,verifiedFactory)&&equal(indices,verifiedIndices)&&equal(info,snapshot.deviceInfo)&&equal(keymap,snapshot.keymap),'读取灯光映射期间配置发生变化，请重新读取。');
  const result={deviceInfo:clone(info),factoryKeymap:factory,ledIndices:indices};lightingMappingSlots(result,snapshot);return result;
}
export function lightingMappingSlots(mapping,snapshot){
  requireThat(mapping&&typeof mapping==='object'&&!Array.isArray(mapping)&&bytes(mapping.deviceInfo,34)&&equal(mapping.deviceInfo,snapshot.deviceInfo),'灯光映射与当前固件信息不一致，请重新读取。');
  return resolveLightingSlots(mapping.factoryKeymap,mapping.ledIndices);
}
export function lightingColorSlot(profile,keySlot){
  if(!profile.lightingMapping)return keySlot;
  const slot=profile.lightingMapping.ledIndices[keySlot];return Number.isInteger(slot)&&slot>=0&&slot<126?slot:null;
}
// Host text preparation only; WebHID cannot inject text into other apps.
export function officialHostTextPlan(action){
  requireThat(winInt(action?.ActionType,'ActionType',0,4)===3&&action.ActionContent&&typeof action.ActionContent.ActionText==='string','Windows 文本动作结构无效。');
  const content=action.ActionContent,originalText=content.ActionText,flag=action.ActionTextFlag===undefined?null:winInt(action.ActionTextFlag,'ActionTextFlag',0,2147483647);
  const prefix=originalText.split('\0',1)[0];
  return {name:typeof action.ActionName==='string'?action.ActionName:'文本',originalText,windowsFlag:flag??null,
    marker:prefix.length?[161,0,0]:null,
    scalarUTF16:Array.from(prefix).filter(c=>c!=='\n').map(c=>Array.from({length:c.length},(_,i)=>c.charCodeAt(i)))};
}
export function officialTextTriggerIndex(eventValue){return Number.isInteger(eventValue)&&eventValue>=0x700&&eventValue<0x800?eventValue-0x700:null;}
// Complete normalized report, including its ID. WebHID callbacks omit the ID;
// their caller must prepend reportId explicitly and verify device/session
// provenance. This pure decoder does not install listeners or authorize writes.
export function officialHostTextEvent(fullReport){
  if(!bytes(fullReport,9)||fullReport[0]!==5)return null;
  const value=fullReport[1]|fullReport[2]<<8,slot=officialTextTriggerIndex(value);
  return slot!==null&&slot<126?value:null;
}
export function resolveHostTextTrigger(eventValue,factoryKeymap){
  requireThat(bytes(factoryKeymap,378),'文本触发解析需要完整的固件默认键位表。');
  const slot=officialTextTriggerIndex(eventValue);if(slot===null||slot>=126)return null;
  const offset=slot*3,value=(factoryKeymap[offset]<<16)|(factoryKeymap[offset+1]<<8)|factoryKeymap[offset+2],logicalIndex=FIRMWARE_LOGICAL_DEFAULTS.indexOf(value);
  if(logicalIndex<0)return null;
  for(let i=0;i<slot;i++)if([0,1,2].every(j=>factoryKeymap[i*3+j]===factoryKeymap[offset+j]))return null;
  return {logicalIndex,physicalSlot:slot};
}

// Data routing only; callers must separately establish device/report identity
// and rebuild on configuration changes or reconnect. This does not authorize HID.
export function prepareHostTextBindings(root,factoryKeymap,currentKeymap){
  requireThat(bytes(factoryKeymap,378)&&bytes(currentKeymap,378),'文本路由需要完整的默认和当前键位表。');
  requireThat(root?.['//']==='47'&&Array.isArray(root.KeyList)&&root.KeyList.length===126&&Array.isArray(root.ActionInfo),'Windows 文本配置结构无效。');
  requireThat(new TextEncoder().encode(JSON.stringify(root)).length<=1_000_000,'Windows 文本配置过大。');
  root.KeyList.forEach((key,i)=>requireThat(winInt(key?.DefaultAssignment,'DefaultAssignment',0,0xffffff)===WINDOWS_DEFAULTS[i],'Windows 键盘布局不匹配。'));
  officialSystemStageWords(root);
  const bindings=new Map();
  for(let slot=0;slot<126;slot++){
    const trigger=resolveHostTextTrigger(0x700+slot,factoryKeymap),offset=slot*3;
    if(!trigger||![161,0,0].every((v,i)=>currentKeymap[offset+i]===v))continue;
    const key=root.KeyList[trigger.logicalIndex];if(winInt(key.ActionLink??0,'ActionLink',0,1)!==1)continue;
    const index=winInt(key.ActionLinkIndex,'ActionLinkIndex',0,Math.max(0,root.ActionInfo.length-1)),action=root.ActionInfo[index];requireThat(action,'文本动作引用无效。');
    if(winInt(action.ActionType,'ActionType',0,4)!==3)continue;
    const plan=officialHostTextPlan(action);if(plan.marker===null)continue;
    bindings.set(slot,{...trigger,actionIndex:index,plan});
  }
  // Freeze the prepared routing context; later draft edits cannot alter it.
  return eventValue=>{const slot=officialTextTriggerIndex(eventValue);return bindings.has(slot)?clone(bindings.get(slot)):null;};
}

export function officialKeyRecord(value){value=winInt(value,'按键动作',0,0xffffff);const result=[value>>16,(value>>8)&255,value&255];requireThat([32,48].includes(result[0]),'Windows 配置包含尚未支持的按键动作。');return result;}
export function editHostText(root,factoryKeymap,physicalSlot,text,name='文本'){
  root=clone(root);prepareHostTextBindings(root,factoryKeymap,Array(378).fill(0));
  const trigger=resolveHostTextTrigger(0x700+physicalSlot,factoryKeymap);
  requireThat(editableSlots.has(physicalSlot)&&trigger,'此按键没有可编辑的文本位置。');
  const logical=trigger.logicalIndex,key=root.KeyList[logical],actions=root.ActionInfo;
  const references=new Map();
  for(const item of root.KeyList)if(winInt(item.ActionLink??0,'ActionLink',0,1)===1){const index=winInt(item.ActionLinkIndex,'ActionLinkIndex',0,Math.max(0,actions.length-1));requireThat(actions[index],'文本配置含无效动作引用。');references.set(index,(references.get(index)??0)+1);}
  const link=winInt(key.ActionLink??0,'ActionLink',0,1);let oldIndex=null;
  if(link===1){oldIndex=winInt(key.ActionLinkIndex,'ActionLinkIndex',0,Math.max(0,actions.length-1));requireThat(actions[oldIndex],'文本动作引用无效。');}
  if(text!==null){
    requireThat(typeof name==='string'&&typeof text==='string','名称或文本无效。');name=name.normalize('NFC');
    requireThat(name.trim()&&[...name].length<=80&&text.length&&!text.includes('\0'),'请填写有效名称和非空文本；文本不能含 NUL。');
    text=text.replaceAll('\r\n','\n').replaceAll('\r','\n').replaceAll('\n','\r\n');
    let action={},replace=null;
    if(oldIndex!==null&&winInt(actions[oldIndex].ActionType,'ActionType',0,4)===3){action=clone(actions[oldIndex]);if(references.get(oldIndex)===1)replace=oldIndex;}
    action.ActionContent={...(action.ActionContent??{}),ActionText:text};action.ActionType=3;action.ActionTextFlag=1;action.ActionName=name;
    const index=replace??actions.length;if(replace===null)actions.push(action);else actions[index]=action;
    key.ActionLink=1;key.ActionLinkIndex=index;key.Assignment=WINDOWS_DEFAULTS[logical];
  }else{
    requireThat(oldIndex!==null&&winInt(actions[oldIndex].ActionType,'ActionType',0,4)===3,'此按键没有文本绑定。');
    officialKeyRecord(WINDOWS_DEFAULTS[logical]);key.ActionLink=0;key.ActionLinkIndex=-1;key.Assignment=WINDOWS_DEFAULTS[logical];
  }
  prepareHostTextBindings(root,factoryKeymap,Array(378).fill(0));return root;
}

// Pure installation plan, never a WebHID write authorization. Text is kept
// in officialJSON on the host; only the trigger marker belongs to firmware.
export function prepareHostTextInstallation(root,factoryKeymap,baseline){
  root=clone(root);baseline=clone(baseline);factoryKeymap=clone(factoryKeymap);
  validateSnapshot(baseline,true);
  requireThat(baseline.deviceInfo[6]===24&&bytes(factoryKeymap,378),'准备文本安装需要本型号完整配置和默认键位表。');
  requireThat(root?.['//']==='47'&&Array.isArray(root.KeyList)&&root.KeyList.length===126&&Array.isArray(root.ActionInfo),'Windows 文本配置结构无效。');
  requireThat(new TextEncoder().encode(JSON.stringify(root)).length<=1_000_000,'Windows 文本配置过大。');
  root.KeyList.forEach((key,i)=>requireThat(winInt(key?.DefaultAssignment,'DefaultAssignment',0,0xffffff)===WINDOWS_DEFAULTS[i],'Windows 键盘布局不匹配。'));
  officialSystemStageWords(root);
  const slots=new Map(),expected=clone(baseline),bindings=[],removedSlots=[];
  for(let slot=0;slot<126;slot++){const trigger=resolveHostTextTrigger(0x700+slot,factoryKeymap);if(trigger)slots.set(trigger.logicalIndex,slot);}
  root.KeyList.forEach((key,logicalIndex)=>{
    if(winInt(key.ActionLink??0,'ActionLink',0,1)===0){
      const slot=slots.get(logicalIndex);
      if(slot!==undefined&&equal(baseline.keymap.slice(slot*3,slot*3+3),[161,0,0])&&key.Assignment!==undefined){
        requireThat(editableSlots.has(slot),'隐藏或内部文本位置不能还原。');
        const assignment=winInt(key.Assignment,'Assignment',0,0xffffff);
        requireThat(assignment===WINDOWS_DEFAULTS[logicalIndex],'解除文本绑定只支持还原默认键，请在按键页单独设置其他功能。');
        expected.keymap.splice(slot*3,3,...officialKeyRecord(assignment));removedSlots.push(slot);
      }return;
    }
    const actionIndex=winInt(key.ActionLinkIndex,'ActionLinkIndex',0,Math.max(0,root.ActionInfo.length-1)),action=root.ActionInfo[actionIndex];
    requireThat(action,'文本安装配置的动作引用无效。');
    if(winInt(action.ActionType,'ActionType',0,4)!==3)return;
    const plan=officialHostTextPlan(action);if(plan.marker===null)return;
    requireThat(plan.windowsFlag===null||plan.windowsFlag===1,'文本动作标志尚未支持，未准备安装。');
    const physicalSlot=slots.get(logicalIndex);
    requireThat(physicalSlot!==undefined,'文本键在固件默认表中没有对应位置。');
    requireThat(editableSlots.has(physicalSlot),'内部功能键与隐藏位置不能安装文本绑定。');
    requireThat(![112,113].includes(baseline.keymap[physicalSlot*3]),'文本键当前绑定宏，请先解除宏绑定。');
    expected.keymap.splice(physicalSlot*3,3,...plan.marker);
    bindings.push({logicalIndex,physicalSlot,actionIndex,plan});
  });
  requireThat(bindings.length>0||removedSlots.length>0,'配置没有可安装的非空文本绑定或待还原文本键。');
  bindings.sort((a,b)=>a.physicalSlot-b.physicalSlot);
  const changedSlots=[...bindings.map(b=>b.physicalSlot),...removedSlots].filter(slot=>[0,1,2].some(i=>baseline.keymap[slot*3+i]!==expected.keymap[slot*3+i])).sort((a,b)=>a-b);
  return {before:baseline,expected,factoryKeymap,officialJSON:root,bindings,changedSlots,removedSlots:removedSlots.sort((a,b)=>a-b)};
}

export function validateSnapshot(s,complete=false){
  requireThat(s&&s.format==='CherryMacHardware'&&s.version===1&&s.vendorID===1130&&s.productID===462,'配置不适用于这款宝可梦键盘。');
  requireThat(bytes(s.keymap,378)&&bytes(s.parameters,56)&&bytes(s.deviceInfo,34),'键位、参数或设备信息长度无效。');
  requireThat((s.colors==null&&!complete)||bytes(s.colors,378),'逐键颜色数据无效。');
  requireThat((s.macroData==null&&!complete)||bytes(s.macroData,3071),'宏存储数据无效。');
  requireThat(Number.isFinite(s.createdAt),'备份日期无效。');
}
const macroNameKey=name=>typeof name==='string'?name.normalize('NFC'):null;
const sameMacroName=(first,second)=>macroNameKey(first)===macroNameKey(second);
const macroNameStem=name=>[...name.normalize('NFC')].slice(0,65).join('');
export function validateMacro(m){
  if(m?.hardwareReserved!=null)requireThat(bytes(m.hardwareReserved,2),'宏保留数据长度无效。');
  if(m?.preferredPlayback!=null)validatePlayback(m.preferredPlayback);
  if(m?.windowsActionIndex!=null)requireThat(Number.isInteger(m.windowsActionIndex)&&m.windowsActionIndex>=0,'宏来源动作索引无效。');
  requireThat(m&&typeof m.name==='string'&&m.name.trim()&&[...m.name.normalize('NFC')].length<=80&&Array.isArray(m.steps)&&m.steps.length>0&&m.steps.length<=256,'宏名称或步骤数量无效。');
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
export function encodeBank(macros,headerReserved=[]){
  requireThat(Array.isArray(headerReserved)&&(headerReserved.length===0||bytes(headerReserved,10)),'宏头部保留数据长度无效。');
  requireThat(Array.isArray(macros)&&macros.length<=32,'最多支持 32 个宏。');macros.forEach(validateMacro);
  const bank=Array(3071).fill(0);if(!macros.length)return bank;
  const total=16+macros.length*6+macros.reduce((n,m)=>n+m.steps.length*4,0);
  requireThat(total<=3071,'宏超过键盘存储容量。');
  const word=(o,v)=>{bank[o]=v&255;bank[o+1]=v>>8;};bank[0]=0xaa;bank[1]=0x55;word(2,total);word(4,macros.length);
  if(headerReserved.length)bank.splice(6,10,...headerReserved);
  let cursor=16+macros.length*2;
  macros.forEach((m,i)=>{word(16+i*2,cursor);word(cursor,m.steps.length);m.steps.forEach((s,j)=>{
    const modifier=s.kind!=='mouse'&&s.usage>=224;
    bank.splice(cursor+4+j*4,4,s.delayMilliseconds&255,s.delayMilliseconds>>8,(s.kind==='mouse'?1:modifier?9:10)|(s.pressed?128:0),modifier?1<<(s.usage-224):s.usage);
  });if(m.hardwareReserved)bank.splice(cursor+2,2,...m.hardwareReserved);cursor+=4+m.steps.length*4;});return bank;
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
    const reserved=bank.slice(start+2,start+4);if(reserved.some(b=>b!==0))m.hardwareReserved=reserved;
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
  requireThat(p&&p.format==='CherryMacProfile'&&p.version===1&&Array.isArray(p.macros)&&p.macros.length<=32,'配置格式或版本不受支持。');validateSnapshot(p.snapshot);p.macros.forEach(validateMacro);if(p.lightingMapping!=null)lightingMappingSlots(p.lightingMapping,p.snapshot);
  if(p.windowsTemplateJSON!=null){requireThat(typeof p.windowsTemplateJSON==='string','官方配置模板无效。');validateWindowsTemplate(JSON.parse(p.windowsTemplateJSON),new TextEncoder().encode(p.windowsTemplateJSON).length);}
  if(p.hostTextJSON!=null){requireThat(typeof p.hostTextJSON==='string','文本配置定义无效。');validateHostTextDefinition(JSON.parse(p.hostTextJSON));}
  p.macros.forEach(m=>officialMacroSource(p,m));
  requireThat(new Set(p.macros.map(m=>macroNameKey(m.name))).size===p.macros.length,'宏名称不能重复。');
  if(p.macroModes!=null){requireThat(typeof p.macroModes==='object'&&!Array.isArray(p.macroModes),'宏执行方式结构无效。');for(const [slot,playback] of Object.entries(p.macroModes)){requireThat(Object.hasOwn(p.macroBindings??{},slot),'宏执行方式缺少对应绑定。');validatePlayback(playback);}}
  if(p.macroBindings!=null){requireThat(typeof p.macroBindings==='object'&&!Array.isArray(p.macroBindings),'宏绑定结构无效。');
    for(const [slot,name] of Object.entries(p.macroBindings))requireThat(/^(0|[1-9]\d*)$/.test(slot)&&Number(slot)<126&&![6,71].includes(Number(slot))&&p.macros.some(m=>sameMacroName(m.name,name)),'宏绑定无效。');}
}
export function resolveMacros(p){
  validateProfile(p);requireThat(p.macroBindings!=null,'未知宏不能覆盖，请重新读取键盘。');const s=clone(p.snapshot);
  for(let slot=0;slot<126;slot++)if([0x70,0x71].includes(s.keymap[slot*3]))requireThat(Object.hasOwn(p.macroBindings,slot),'宏记录缺少绑定。');
  const header=s.macroData?.[0]===0xaa&&s.macroData[1]===0x55?s.macroData.slice(6,16):[];
  s.macroData=encodeBank(p.macros,header);for(const [slot,name] of Object.entries(p.macroBindings))s.keymap.splice(Number(slot)*3,3,...macroBinding(p.macros.findIndex(m=>sameMacroName(m.name,name)),p.macroModes?.[slot]));return s;
}
export function parseProfile(text,baseline,options={}){
  requireThat(new TextEncoder().encode(text).length<=3_000_000,'配置文件超过 3 MB。');const data=JSON.parse(text);
  if(data?.KeyList||data?.DeviceBasicInfo){requireThat(baseline,'导入 Windows 配置前请连接并读取键盘。');requireThat(new TextEncoder().encode(text).length<=1_000_000,'Windows 配置文件超过 1 MB。');return importWindows(data,baseline,options);}
  const p=data?.format==='CherryMacHardware'?{format:'CherryMacProfile',version:1,snapshot:data,macros:[]}:data;validateProfile(p);
  // Raw backups acquire an editable library only when the firmware bank is recognized.
  if(p.macroBindings==null&&p.macros.length===0){try{const editable=fromHardware(p.snapshot);if(p.windowsTemplateJSON!=null)editable.windowsTemplateJSON=p.windowsTemplateJSON;if(p.hostTextJSON!=null)editable.hostTextJSON=p.hostTextJSON;if(p.lightingMapping!=null)editable.lightingMapping=clone(p.lightingMapping);return editable;}catch{}}
  if(p.macroBindings)for(const [slot,name] of Object.entries(p.macroBindings))p.macroBindings[slot]=p.macros.find(m=>sameMacroName(m.name,name)).name;
  return p;
}
const winInt=(v,name,min,max)=>{if(typeof v==='string'&&/^-?\d+$/.test(v))v=Number(v);requireThat(Number.isInteger(v)&&v>=min&&v<=max,`Windows ${name} 数据无效。`);return v;};
function physicalSlot(v){
  if(v>>16===0x20&&((v>>8)&255)===0){const slot=SLOTS[v&255];return [10,75].includes(slot)?undefined:slot;}
  return ({[0xa00300]:6,[0xa00100]:71,[0x200100]:5,[0x200200]:4,[0x200400]:17,[0x200800]:11,[0x201000]:83,[0x202000]:82,[0x204000]:65,[0x309201]:102,[0x30b600]:108,[0x30cd00]:114,[0x30b500]:120})[v];
}
export function officialSystemStageWords(root){
  const stages=root?.SystemStages;if(stages==null)return null;
  requireThat(typeof stages==='object'&&!Array.isArray(stages),'Windows SystemStages 结构无效。');
  // JSON struct order only; these are not USB offsets or UI value ranges.
  return ['Repeat','RepeatDelay','Key6Flag','ReportSelectItem','RFReportSelectItem','WFlag','WinFlag'].map(k=>winInt(stages[k],k,0,65535));
}
function validateWindowsTemplate(root,size){
  requireThat(size<=1_000_000&&root?.['//']==='47'&&Array.isArray(root.KeyList)&&root.KeyList.length===126,'需要本型号的官方配置模板（不超过 1 MB）。');
  root.KeyList.forEach((k,i)=>requireThat(winInt(k?.DefaultAssignment,'DefaultAssignment',0,0xffffff)===WINDOWS_DEFAULTS[i],'Windows 键盘布局不匹配。'));
  officialSystemStageWords(root);
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
function canonicalJSON(value){
  const sorted=x=>Array.isArray(x)?x.map(sorted):x&&typeof x==='object'?Object.fromEntries(Object.keys(x).sort().map(k=>[k,sorted(x[k])])):x;
  return JSON.stringify(sorted(value));
}
function mergeOfficialMacro(original,next){
  const content=original.ActionContent;
  requireThat(content&&typeof content==='object'&&!Array.isArray(content)&&Array.isArray(content.ActionMacroEvents),'官方宏模板结构无效。');
  const result={...clone(original),...next,ActionContent:{...clone(content),...next.ActionContent}};
  const known=['Type','Button','Action','Delay'];
  content.ActionMacroEvents.forEach((event,i)=>{
    requireThat(event&&typeof event==='object'&&!Array.isArray(event),'官方宏事件模板无效。');
    const extras=Object.fromEntries(Object.entries(event).filter(([k])=>!known.includes(k)));
    if(!Object.keys(extras).length)return;
    const target=result.ActionContent.ActionMacroEvents[i];
    requireThat(target&&winInt(event.Type,'Type',0,127)===target.Type&&winInt(event.Button,'Button',0,255)===target.Button&&event.Action===target.Action,'宏步骤变化后无法对应未知事件字段，不能无损导出。');
    result.ActionContent.ActionMacroEvents[i]={...extras,...target};
  });return result;
}
function hasOfficialMacroExtras(action){
  const content=action.ActionContent;requireThat(content&&typeof content==='object'&&!Array.isArray(content)&&Array.isArray(content.ActionMacroEvents),'官方宏模板结构无效。');
  return Object.keys(action).some(k=>!['ActionType','ActionName','ActionContent'].includes(k))||Object.keys(content).some(k=>!['ActionMacroType','ActionMacroLoopValue','ActionMacroFixTimeIsSelected','ActionMacroFixTimeValue','ActionMacroEvents'].includes(k))||content.ActionMacroEvents.some(e=>Object.keys(e??{}).some(k=>!['Type','Button','Action','Delay'].includes(k)));
}
function officialMacroSource(profile,macro){
  if(macro.windowsActionIndex==null)return null;
  requireThat(typeof profile.windowsTemplateJSON==='string','宏来源缺少官方模板。');
  const root=JSON.parse(profile.windowsTemplateJSON),action=root.ActionInfo?.[macro.windowsActionIndex];
  requireThat(action&&winInt(action.ActionType,'ActionType',0,4)===2,'宏来源动作索引无效。');
  hasOfficialMacroExtras(action);return action;
}
// Template-based building block. Lighting/device fields are copied unchanged;
// the full exporter must update and validate those separately before UI use.
export function exportWindowsKeysAndMacros(profile,template,{preservingTextIndices=new Set()}={}){
  validateProfile(profile);const snapshot=resolveMacros(profile),root=clone(template);
  validateWindowsTemplate(root,new TextEncoder().encode(JSON.stringify(root)).length);
  requireThat(root.ActionInfo==null||Array.isArray(root.ActionInfo),'Windows 动作结构无效。');
  const sources=profile.macros.map(m=>officialMacroSource(profile,m));
  const old=root.ActionInfo??[],actions=[],emitted=[],remap=new Map(),variants=new Map(),templates=new Map();
  old.forEach((a,i)=>{const type=winInt(a?.ActionType,'ActionType',0,4);if(type!==2){remap.set(i,actions.length);actions.push(a);}else{
    requireThat(sources.some(s=>s&&canonicalJSON(s)===canonicalJSON(a))||profile.macros.some(m=>sameMacroName(m.name,a.ActionName))||!hasOfficialMacroExtras(a),'旧宏包含无法关联到当前宏库的未知字段，不能无损导出。');
    const list=templates.get(macroNameKey(a.ActionName))??[];list.push(a);templates.set(macroNameKey(a.ActionName),list);
  }});
  const add=(index,playback)=>{validatePlayback(playback);const identity=`${index}:${playback.mode}:${playback.count}`;
    if(!variants.has(identity)){const macro=profile.macros[index],next=officialMacroAction(macro,playback),candidates=sources[index]&&old.some(a=>canonicalJSON(a)===canonicalJSON(sources[index]))?[sources[index]]:templates.get(macroNameKey(macro.name))??[],merged=candidates.map(a=>mergeOfficialMacro(a,next));
      requireThat(merged.every(a=>canonicalJSON(a)===canonicalJSON(merged[0])),'同名官方宏的附加字段不同，无法确定导出对应关系。');
      variants.set(identity,actions.length);actions.push(merged[0]??next);emitted.push(macro);}return variants.get(identity);};
  // Emit every library item, including unbound macros; a shared binding reuses
  // one action, while different modes need distinct official ActionContent.
  profile.macros.forEach((m,i)=>add(i,m.preferredPlayback??{mode:'count',count:1}));
  root.KeyList.forEach((k,i)=>{const slot=physicalSlot(WINDOWS_DEFAULTS[i]);
    if(slot===undefined||[6,71].includes(slot)){
      if(winInt(k.ActionLink??0,'ActionLink',0,1)===1){const index=winInt(k.ActionLinkIndex,'ActionLinkIndex',0,old.length-1);requireThat(remap.has(index),'内部位置引用旧宏，无法无损导出。');k.ActionLinkIndex=remap.get(index);}return;
    }
    const b=snapshot.keymap.slice(slot*3,slot*3+3);
    if(preservingTextIndices.has(i)||equal(b,[0xa1,0,0])){
      requireThat(winInt(k.ActionLink??0,'ActionLink',0,1)===1,'文本键缺少官方文本定义，无法导出。');
      const index=winInt(k.ActionLinkIndex,'ActionLinkIndex',0,old.length-1);requireThat(remap.has(index),'文本动作索引无效，无法导出。');
      const plan=officialHostTextPlan(old[index]);requireThat(!equal(b,[0xa1,0,0])||plan.marker!==null,'已安装文本键对应空定义，无法导出。');k.ActionLinkIndex=remap.get(index);
    }else if([0x70,0x71].includes(b[0])){const playback=decodeMacroBinding(b,profile.macros.length);k.ActionLink=1;k.ActionLinkIndex=add(b[1],playback);k.Assignment=k.DefaultAssignment;}
    else{requireThat([0x20,0x30].includes(b[0]),'此按键动作尚不能导出到官方格式。');k.Assignment=b[0]*65536+b[1]*256+b[2];k.ActionLink=0;k.ActionLinkIndex=-1;}
  });
  // Official actions with different modes import as separate library items.
  // Check that representation still fits before returning a usable document.
  encodeBank(emitted);root.ActionInfo=actions;
  requireThat(new TextEncoder().encode(JSON.stringify(root)).length<=1_000_000,'导出的配置文件过大。');return root;
}
// Portable draft validation does not require a connected keyboard.
export function validateHostTextDefinition(root){
  validateWindowsTemplate(root,new TextEncoder().encode(JSON.stringify(root)).length);
  requireThat(Array.isArray(root.ActionInfo),'文本配置缺少动作列表。');let count=0;
  for(const action of root.ActionInfo)if(winInt(action?.ActionType,'ActionType',0,4)===3){officialHostTextPlan(action);count++;}
  for(const key of root.KeyList)if(winInt(key.ActionLink??0,'ActionLink',0,1)===1){const index=winInt(key.ActionLinkIndex,'ActionLinkIndex',0,Math.max(0,root.ActionInfo.length-1));requireThat(root.ActionInfo[index],'文本配置动作引用无效。');}
  return count;
}
export function exportWindowsKeysMacrosAndText(profile,template,textConfiguration,baseline){
  validateSnapshot(baseline,true);const snapshot=resolveMacros(profile),root=clone(template),text=clone(textConfiguration);
  for(const value of [root,text])validateWindowsTemplate(value,new TextEncoder().encode(JSON.stringify(value)).length);
  requireThat(Array.isArray(text.ActionInfo),'文本配置缺少动作列表。');requireThat(root.ActionInfo==null||Array.isArray(root.ActionInfo),'Windows 动作结构无效。');
  const actions=root.ActionInfo??[],mapped=new Map(),preservingTextIndices=new Set();
  text.ActionInfo.forEach((a,i)=>{if(winInt(a?.ActionType,'ActionType',0,4)!==3)return;officialHostTextPlan(a);
    const old=actions.findIndex(value=>canonicalJSON(value)===canonicalJSON(a));mapped.set(i,old<0?actions.length:old);if(old<0)actions.push(a);
  });
  text.KeyList.forEach((k,i)=>{
    if(winInt(k.ActionLink??0,'ActionLink',0,1)!==1)return;
    const index=winInt(k.ActionLinkIndex,'ActionLinkIndex',0,text.ActionInfo.length-1);requireThat(text.ActionInfo[index],'文本配置动作引用无效。');if(!mapped.has(index))return;
    const slot=physicalSlot(WINDOWS_DEFAULTS[i]);requireThat(slot!==undefined&&![6,71].includes(slot),'内部或隐藏文本键尚不能合并导出。');
    const b=snapshot.keymap.slice(slot*3,slot*3+3);requireThat(equal(b,[0xa1,0,0])||equal(b,baseline.keymap.slice(slot*3,slot*3+3)),'同一个键同时有键位／宏修改和文本绑定，请先在对应页面解除冲突再导出。');
    root.KeyList[i].ActionLink=1;root.KeyList[i].ActionLinkIndex=mapped.get(index);root.KeyList[i].Assignment=k.Assignment??k.DefaultAssignment;preservingTextIndices.add(i);
  });
  root.KeyList.forEach((k,i)=>{const slot=physicalSlot(WINDOWS_DEFAULTS[i]);if(slot!==undefined&&equal(snapshot.keymap.slice(slot*3,slot*3+3),[0xa1,0,0]))requireThat(preservingTextIndices.has(i),'有已安装文本键缺少当前文本定义或待解除，请先核对文本页再导出。');});
  root.ActionInfo=actions;return exportWindowsKeysAndMacros(profile,root,{preservingTextIndices});
}
// File-only conversion; unknown light fields and unmapped colors survive.
export function exportWindowsLightingDraft(snapshot,template,lightingMapping=null){
  validateSnapshot(snapshot,true);const root=clone(template);validateWindowsTemplate(root,new TextEncoder().encode(JSON.stringify(root)).length);
  const light=root.LightInfo,custom=root.CustomLightMode,groups=custom?.LightColorInfo;
  requireThat(light&&typeof light==='object'&&!Array.isArray(light)&&custom&&typeof custom==='object'&&!Array.isArray(custom)&&Array.isArray(groups)&&groups.length===1&&Array.isArray(groups[0])&&groups[0].length===126&&Array.isArray(snapshot.colors),'导出灯效需要完整读取配色和带 126 项颜色表的官方模板。');
  const mapping=lightingMapping==null?null:lightingMappingSlots(lightingMapping,snapshot);
  const p=snapshot.parameters,selected=MODE_CODES.indexOf(p[1]);requireThat(modes.some(([v])=>v===p[1])&&selected>=0&&p[2]<=4&&p[3]<=4&&p[4]<=1&&p[5]<=1,'当前灯效参数超出本型号已核对范围，不能导出。');
  Object.assign(light,{SelectItem:selected,Light:p[2],Speed:4-p[3],Fx:p[4],MultiColor:p[5],Red:p[6],Green:p[7],Blue:p[8]});
  groups[0].forEach((entry,i)=>{requireThat(entry&&typeof entry==='object'&&!Array.isArray(entry),'逐键颜色记录结构无效。');for(const name of ['Red','Green','Blue'])winInt(entry[name],name,0,255);if(Object.hasOwn(entry,'Alpha'))winInt(entry.Alpha,'Alpha',0,255);const slot=mapping===null?physicalSlot(WINDOWS_DEFAULTS[i]):mapping[i];if(slot!=null)['Red','Green','Blue'].forEach((name,offset)=>entry[name]=snapshot.colors[slot*3+offset]);});
  requireThat(new TextEncoder().encode(JSON.stringify(root)).length<=1_000_000,'导出的官方配置文件过大。');return root;
}
export function importWindows(root,baseline,{deferHostText=false,lightingMapping=null}={}){
  officialSystemStageWords(root);
  validateSnapshot(baseline,true);requireThat(root['//']==='47'&&Array.isArray(root.KeyList)&&root.KeyList.length===126,'仅支持 Pokémon 型号 47 的 Windows 配置。');
  root.KeyList.forEach((k,i)=>requireThat(winInt(k?.DefaultAssignment,'DefaultAssignment',0,0xffffff)===WINDOWS_DEFAULTS[i],'Windows 键盘布局不匹配。'));
  for(const field of ['LightInfo','CustomLightMode'])requireThat(root[field]==null||(typeof root[field]==='object'&&!Array.isArray(root[field])),'Windows 灯效结构无效。');
  requireThat(root.ActionInfo==null||Array.isArray(root.ActionInfo),'Windows 动作结构无效。');
  const p=fromHardware(baseline),old=clone(p.macroBindings),actions=root.ActionInfo??[],imported=new Map(),physical=new Set(WINDOWS_DEFAULTS.map(physicalSlot));
  const lightingSlots=lightingMapping==null?null:lightingMappingSlots(lightingMapping,baseline);
  if(lightingMapping!=null)p.lightingMapping=clone(lightingMapping);
  p.windowsTemplateJSON=JSON.stringify(root);
  const oldModes=clone(p.macroModes??{});
  if(deferHostText&&validateHostTextDefinition(root)>0)p.hostTextJSON=p.windowsTemplateJSON;
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
    const stem=typeof a.ActionName==='string'&&a.ActionName.trim()?macroNameStem(a.ActionName):'导入宏';let name=stem,j=1;while(p.macros.some(m=>sameMacroName(m.name,name)))name=`${stem} (${j++})`;
    const mode=winInt(c.ActionMacroType,'宏模式',0,2),preferredPlayback={mode:['count','held','toggle'][mode],count:mode===0?winInt(c.ActionMacroLoopValue??1,'重复次数',1,255):1};
    const macro={name,steps,recordingDelay,preferredPlayback,windowsActionIndex:index};validateMacro(macro);p.macros.push(macro);imported.set(index,name);

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
        importMacro(index);const name=imported.get(index);p.macroBindings[slot]=name;const mode=winInt(c.ActionMacroType,'宏模式',0,2);p.macroModes[slot]={mode:['count','held','toggle'][mode],count:mode===0?winInt(c.ActionMacroLoopValue??1,'重复次数',1,255):1};b=macroBinding(p.macros.findIndex(m=>sameMacroName(m.name,name)),p.macroModes[slot]);
      }else if(type===3){officialHostTextPlan(a);if(deferHostText){if(old[slot]!=null)p.macroBindings[slot]=old[slot];if(oldModes[slot]!=null)p.macroModes[slot]=oldModes[slot];return;}throw new Error('此配置含文本绑定，请使用带“文本”页的预览，在该页单独选择和安装。普通配置导入保留原编辑区。');}else throw new Error('Windows 文本和其他动作尚未支持导入。');
    }p.snapshot.keymap.splice(slot*3,3,...b);
  });
  const l=root.LightInfo;if(l){const mode=MODE_CODES[winInt(l.SelectItem,'模式',0,24)];requireThat(modes.some(([v])=>v===mode),'此内置灯效尚未验证。');
    p.snapshot.parameters.splice(1,8,mode,winInt(l.Light,'亮度',0,4),4-winInt(l.Speed,'速度',0,4),winInt(l.Fx,'方向',0,1),winInt(l.MultiColor,'彩虹',0,1),...['Red','Green','Blue'].map(k=>winInt(l[k],k,0,255)));}
  const groups=root.CustomLightMode?.LightColorInfo;if(root.CustomLightMode){requireThat(Array.isArray(groups)&&groups.length===1&&Array.isArray(groups[0])&&groups[0].length===126,'逐键颜色组不匹配。');groups[0].forEach((c,i)=>{requireThat(c&&typeof c==='object'&&!Array.isArray(c),'逐键颜色记录结构无效。');const rgb=['Red','Green','Blue'].map(k=>winInt(c[k],k,0,255));if(Object.hasOwn(c,'Alpha'))winInt(c.Alpha,'Alpha',0,255);const slot=lightingSlots===null?physicalSlot(WINDOWS_DEFAULTS[i]):lightingSlots[i];if(slot!=null)p.snapshot.colors.splice(slot*3,3,...rgb);});}
  if(!equal(p.macroBindings,old)||imported.size)p.snapshot=resolveMacros(p);validateProfile(p);return p;
}
export function rgb(hex){requireThat(/^#[\da-f]{6}$/i.test(hex),'请输入六位 HEX 色号。');return [1,3,5].map(i=>parseInt(hex.slice(i,i+2),16));}
export const hex=b=>'#'+b.map(x=>x.toString(16).padStart(2,'0')).join('');
// Raw draft RGB only; read-back banks may already contain this scaling.
export const OFFICIAL_BRIGHTNESS_COEFFICIENTS=Object.freeze([0,65,135,195,255]);
export function officialCustomColors(raw,brightness){
  requireThat(bytes(raw,378)&&Number.isInteger(brightness)&&brightness>=0&&brightness<=4,'官方亮度转换需要完整 RGB 表和 0～4 档亮度。');
  const coefficient=OFFICIAL_BRIGHTNESS_COEFFICIENTS[brightness];return raw.map(value=>(value*coefficient)>>8);
}
// Pure file conversion; caller bank is not inferred from read-back parameters.
export function prepareOfficialLightingParameters(template,bank){
  validateWindowsTemplate(template,new TextEncoder().encode(JSON.stringify(template)).length);
  requireThat(Number.isInteger(bank)&&bank>=0&&bank<=255&&template.LightInfo,'需要完整官方灯效参数和可表示为单字节的配置编号。');
  const light=template.LightInfo,selected=winInt(light.SelectItem,'SelectItem',0,24);
  const head=[bank,MODE_CODES[selected],winInt(light.Light,'Light',0,4),4-winInt(light.Speed,'Speed',0,4),winInt(light.Fx,'Fx',0,1),winInt(light.MultiColor,'MultiColor',0,1),...['Red','Green','Blue'].map(name=>winInt(light[name],name,0,255))];
  return {head,lightOpenFlag:winInt(light.LightOpenFlag,'LightOpenFlag',0,255)};
}
export function prepareOfficialCustomColors(template,baseline,lightingMapping){
  validateSnapshot(baseline,true);validateWindowsTemplate(template,new TextEncoder().encode(JSON.stringify(template)).length);
  const light=template.LightInfo,groups=template.CustomLightMode?.LightColorInfo;
  requireThat(light&&winInt(light.SelectItem,'SelectItem',0,24)===21&&Array.isArray(groups)&&groups.length===1&&Array.isArray(groups[0])&&groups[0].length===126,'官方颜色准备仅支持完整的自定义颜色配置和当前颜色表。');
  // Official 501190 zeroes the output buffer before filling mapped colors.
  const level=winInt(light.Light,'Light',0,4),coefficient=OFFICIAL_BRIGHTNESS_COEFFICIENTS[level],slots=lightingMappingSlots(lightingMapping,baseline),result=Array(378).fill(0);
  groups[0].forEach((color,index)=>{
    requireThat(color&&typeof color==='object'&&!Array.isArray(color),'逐键颜色记录结构无效。');
    const raw=['Red','Green','Blue'].map(name=>winInt(color[name],name,0,255));if(Object.hasOwn(color,'Alpha'))winInt(color.Alpha,'Alpha',0,255);
    const slot=slots[index];if(slot!=null)result.splice(slot*3,3,...raw.map(value=>(value*coefficient)>>8));
  });return result;
}
export function officialRawChannelRange(stored,brightness){
  requireThat(Number.isInteger(stored)&&stored>=0&&stored<=255&&Number.isInteger(brightness)&&brightness>=0&&brightness<=4,'颜色或亮度数据无效。');
  const coefficient=OFFICIAL_BRIGHTNESS_COEFFICIENTS[brightness];
  if(coefficient===0){requireThat(stored===0,'该颜色无法由零亮度生成。');return [0,255];}
  const lower=Math.ceil(stored*256/coefficient),upper=Math.min(255,Math.ceil((stored+1)*256/coefficient)-1);
  requireThat(lower<=upper,'该颜色超出此档官方亮度能生成的范围。');return [lower,upper];
}
export function paint(s,selection,pattern,start,end,lightingMapping=null){
  if(lightingMapping!=null)lightingMappingSlots(lightingMapping,s);
  const slotFor=key=>lightingColorSlot({lightingMapping},key.slot);
  const targets=keys.filter(k=>selection.has(k.id));requireThat(targets.length&&targets.length===selection.size,'请选择按键。');requireThat(targets.every(k=>slotFor(k)!=null),'所选按键没有有效 LED 映射。');
  const xs=targets.map(k=>k.x+k.w/2),ys=targets.map(k=>k.y+k.h/2),minX=Math.min(...xs),minY=Math.min(...ys),dx=Math.max(...xs)-minX,dy=Math.max(...ys)-minY;
  const mix=(a,b,t)=>a.map((v,i)=>Math.round(v*(1-t)+b[i]*t));
  for(const k of targets){const x=dx?(k.x+k.w/2-minX)/dx:0,y=dy?(k.y+k.h/2-minY)/dy:0;let color=start;
    if(pattern==='horizontal')color=mix(start,end,x);if(pattern==='vertical')color=mix(start,end,y);
    if(pattern==='rainbow'){const h=x*.83*6,c=1,q=1-Math.abs(h%2-1);color=([[c,q,0],[q,c,0],[0,c,q],[0,q,c],[q,0,c],[c,0,q]][Math.floor(h)]).map(v=>Math.round(v*255));}
    if(pattern==='pikachu')color=['esc','calculator'].includes(k.id)?[255,54,44]:k.id.startsWith('mod')?[78,54,18]:[255,214,0];
    if(pattern==='charizard')color=mix([255,55,0],[255,202,32],1-y);
    s.colors.splice(slotFor(k)*3,3,...color);
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
    // Delay follows the event in the observed USB firmware execution.
    // Startup latency and time spent clicking Stop are not macro actions.
    if(this.steps.length)this.steps[this.steps.length-1].delayMilliseconds=delayMilliseconds;
    this.steps.push({usage,pressed,delayMilliseconds:0,...(kind==='mouse'?{kind}:{})});
    if(pressed)this.held.add(identity);else this.held.delete(identity);this.lastMilliseconds=milliseconds;
  }
  finish(name,{originalSteps=[],insertionIndex=null}={}){
    requireThat(this.active&&this.held.size===0,'请先松开全部录制按键，再停止录制。');requireThat(this.steps.length>0,'请先录制至少一个操作。');
    let steps=clone(this.steps);if(insertionIndex!=null){requireThat(Array.isArray(originalSteps)&&Number.isInteger(insertionIndex)&&insertionIndex>=0&&insertionIndex<=originalSteps.length,'录制插入位置无效。');steps=clone(originalSteps);steps.splice(insertionIndex,0,...clone(this.steps));}
    const m={name,steps,recordingDelay:{fixed:this.timing==='fixed',milliseconds:this.fixedMilliseconds}};validateMacro(m);this.active=false;return m;
  }
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


export function macroWriteReview(profile,before,target,labels={},descriptions={}){
  validateSnapshot(before);validateSnapshot(target);
  const old=decodeBank(before.macroData),next=decodeBank(target.macroData),changed=!equal(before.macroData,target.macroData);
  const name=index=>profile.macros[index]?.name??next[index].name;
  const lines=[`宏库：${old.length} → ${next.length} 个，${changed?'将更新':'内容保留'}。`];
  if(changed){next.slice(0,6).forEach((macro,index)=>lines.push(`准备写入：${name(index)} · ${macro.steps.length} 步`));if(next.length>6)lines.push(`另有 ${next.length-6} 个宏。`);if(!next.length)lines.push('将清空宏库。');}
  const bindings=[];
  for(let slot=0;slot<126;slot++){
    const offset=slot*3,prior=before.keymap.slice(offset,offset+3),record=target.keymap.slice(offset,offset+3);
    if(!equal(prior,record)||(changed&&[0x70,0x71].includes(record[0]))){
      let description;if([0x70,0x71].includes(record[0])){const mode=decodeMacroBinding(record,next.length);description=`${name(record[1])} · ${mode.mode==='count'?`执行 ${mode.count} 次`:mode.mode==='held'?'按住持续':'再次按键停止'}`;}
      else description=descriptions[slot]??(record[0]===0x20&&record[1]===0&&record[2]===0?'禁用':'普通按键功能');
      bindings.push(`${labels[slot]??`槽位 ${slot}`} → ${description}`);
    }
  }
  if(bindings.length){lines.push('绑定目标（含沿用绑定）：',...bindings.slice(0,8));if(bindings.length>8)lines.push(`另有 ${bindings.length-8} 个绑定目标。`);}
  return lines.join('\n');
}
export function duplicateMacro(profile,name){
  validateProfile(profile);requireThat(profile.macroBindings!=null,'原硬件宏尚未解码，不能复制。');
  const p=clone(profile),original=p.macros.find(m=>sameMacroName(m.name,name));requireThat(original,'请选择已保存的宏。');
  const stem=macroNameStem(name);let next=`${stem} 副本`,number=2;while(p.macros.some(m=>sameMacroName(m.name,next)))next=`${stem} 副本 ${number++}`;
  const copied=clone(original);copied.name=next;p.macros.push(copied);p.snapshot=resolveMacros(p);return {profile:p,name:next};
}
export function removeMacro(profile,name){
  validateProfile(profile);requireThat(profile.macroBindings!=null,'原硬件宏尚未解码，不能删除。');
  requireThat(profile.macros.some(m=>sameMacroName(m.name,name)),'请选择已保存的宏。');const p=clone(profile);
  for(const [slot,binding] of Object.entries(p.macroBindings))if(sameMacroName(binding,name)){
    p.snapshot.keymap.splice(Number(slot)*3,3,0x20,0,0);delete p.macroBindings[slot];if(p.macroModes)delete p.macroModes[slot];
  }
  p.macros=p.macros.filter(m=>!sameMacroName(m.name,name));p.snapshot=resolveMacros(p);return p;
}
export function unassignMacro(profile,slot){
  validateProfile(profile);requireThat(Object.hasOwn(profile.macroBindings??{},slot),'所选键没有宏绑定。');const p=clone(profile);
  p.snapshot.keymap.splice(Number(slot)*3,3,0x20,0,0);delete p.macroBindings[slot];if(p.macroModes)delete p.macroModes[slot];
  p.snapshot=resolveMacros(p);return p;
}
export function clearMacros(profile){
  validateProfile(profile);requireThat(profile.macroBindings!=null,'原硬件宏尚未解码，不能清空。');const p=clone(profile);
  for(const slot of Object.keys(p.macroBindings))p.snapshot.keymap.splice(Number(slot)*3,3,0x20,0,0);
  p.macros=[];p.macroBindings={};p.macroModes={};p.snapshot=resolveMacros(p);return p;
}
