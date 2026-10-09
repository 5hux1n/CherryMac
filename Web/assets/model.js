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
export const macroStepIsMovement=s=>s?.kind==='mouseX'||s?.kind==='mouseY';
export const macroStepMovementValue=s=>s.pressed?-(s.usage===0?256:s.usage):s.usage;
export function setMacroMovementValue(step,value){
  requireThat(macroStepIsMovement(step)&&Number.isInteger(value)&&value>=-256&&value<=255,'鼠标位移须为 -256…255 的整数。');step.usage=Math.abs(value)%256;step.pressed=value<0;
}
export function validateMacro(m){return validateMacroWithin(m,762);}
function validateMacroWithin(m,maximumEvents){
  if(m?.hardwareReserved!=null)requireThat(bytes(m.hardwareReserved,2),'宏保留数据长度无效。');
  if(m?.preferredPlayback!=null)validatePlayback(m.preferredPlayback);
  if(m?.windowsActionIndex!=null)requireThat(Number.isInteger(m.windowsActionIndex)&&m.windowsActionIndex>=0,'宏来源动作索引无效。');
  requireThat(m&&typeof m.name==='string'&&m.name.trim()&&[...m.name.normalize('NFC')].length<=80&&Array.isArray(m.steps)&&m.steps.length<=maximumEvents,'宏名称或步骤数量无效。');
  if(m.recordingDelay!=null)requireThat(typeof m.recordingDelay==='object'&&typeof m.recordingDelay.fixed==='boolean'&&Number.isInteger(m.recordingDelay.milliseconds)&&m.recordingDelay.milliseconds>=0&&m.recordingDelay.milliseconds<=60000,'固定间隔选项须为 0…60000 毫秒。');
  const held=new Set();
  for(const s of m.steps){
    const mouse=s.kind==='mouse',movement=macroStepIsMovement(s);requireThat(s.kind==null||mouse||movement,'宏事件类型尚未支持。');const identity=`${mouse?'mouse':'key'}:${s.usage}`;
    requireThat(Number.isInteger(s.usage)&&(movement?s.usage>=0&&s.usage<=255:mouse?[1,2,4,8,16].includes(s.usage):s.usage>=4&&s.usage<=231)&&typeof s.pressed==='boolean'&&Number.isInteger(s.delayMilliseconds)&&s.delayMilliseconds>=0&&s.delayMilliseconds<=60000,'宏按键或延迟超出范围。');
    if(movement)continue;
    requireThat(s.pressed?!held.has(identity):held.has(identity),'宏的按下与松开必须一一对应。');
    if(s.pressed)held.add(identity);else held.delete(identity);
  }
  requireThat(held.size===0,'宏结束时必须释放全部按键。');
}
export function encodeBank(macros,headerReserved=[]){
  requireThat(Array.isArray(headerReserved)&&(headerReserved.length===0||bytes(headerReserved,10)),'宏头部保留数据长度无效。');
  requireThat(Array.isArray(macros)&&macros.length<=32,'最多支持 32 个宏。');macros.forEach(m=>validateMacroWithin(m,256));
  const bank=Array(3071).fill(0);if(!macros.length)return bank;
  const total=16+macros.length*6+macros.reduce((n,m)=>n+m.steps.length*4,0);
  requireThat(total<=3071,'宏超过键盘存储容量。');
  const word=(o,v)=>{bank[o]=v&255;bank[o+1]=v>>8;};bank[0]=0xaa;bank[1]=0x55;word(2,total);word(4,macros.length);
  if(headerReserved.length)bank.splice(6,10,...headerReserved);
  let cursor=16+macros.length*2;
  macros.forEach((m,i)=>{word(16+i*2,cursor);word(cursor,m.steps.length);m.steps.forEach((s,j)=>{
    const modifier=s.kind==null&&s.usage>=224;
    bank.splice(cursor+4+j*4,4,s.delayMilliseconds&255,s.delayMilliseconds>>8,(s.kind==='mouseX'?4:s.kind==='mouseY'?5:s.kind==='mouse'?1:modifier?9:10)|(s.pressed?128:0),modifier?1<<(s.usage-224):s.usage);
  });if(m.hardwareReserved)bank.splice(cursor+2,2,...m.hardwareReserved);cursor+=4+m.steps.length*4;});return bank;
}
export function decodeBank(bank){return decodeBankWithin(bank,126,762);}
function decodeBankWithin(bank,maximumRecords,maximumEvents){
  requireThat(bytes(bank,3071),'宏区长度无效。');if(bank.every(x=>x===0)||bank.every(x=>x===255))return [];
  const word=o=>bank[o]|bank[o+1]<<8;const length=word(2),count=word(4);
  requireThat(bank[0]===0xaa&&bank[1]===0x55&&count<=maximumRecords&&length>=16+count*2&&length<=3071,'宏头部尚未识别，原始数据仍保留。');
  let cursor=16+count*2;const macros=[];
  for(let i=0;i<count;i++){
    const start=word(16+i*2);requireThat(start>=cursor&&start+4<=length,'宏偏移重叠或越界。');
    const n=word(start),end=start+4+n*4;requireThat(n<=maximumEvents&&end<=length,'宏事件越界。');
    const m={name:`硬件宏 ${i+1}`,steps:[]};
    const reserved=bank.slice(start+2,start+4);if(reserved.some(b=>b!==0))m.hardwareReserved=reserved;
    for(let o=start+4;o<end;o+=4){const kind=bank[o+2]&127,code=bank[o+3];let usage;
      if(kind===1&&[1,2,4,8,16].includes(code))usage=code;
      else if(kind===4||kind===5)usage=code;
      else if(kind===10&&code<224)usage=code;
      else if(kind===9&&code>0&&(code&(code-1))===0)usage=224+Math.log2(code);
      else throw new Error('宏包含尚未支持的事件，原始数据仍保留。');
      m.steps.push({usage,pressed:!!(bank[o+2]&128),delayMilliseconds:word(o),...(kind===4?{kind:'mouseX'}:kind===5?{kind:'mouseY'}:kind===1?{kind:'mouse'}:{})});
    }
    validateMacroWithin(m,maximumEvents);macros.push(m);cursor=end;
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
  validateSnapshot(snapshot);const p={format:'CherryMacProfile',version:1,snapshot:clone(snapshot),macros:[],lightingColorEncoding:'hardwareRGB'};
  if(!snapshot.macroData)return p;
  p.macros=decodeBank(snapshot.macroData);p.macroBindings={};p.macroModes={};
  for(let slot=0;slot<126;slot++){const b=snapshot.keymap.slice(slot*3,slot*3+3);if([0x70,0x71].includes(b[0])){
    requireThat(![6,71].includes(slot),'宏不能绑定到内部键。');p.macroModes[slot]=decodeMacroBinding(b,p.macros.length);p.macroBindings[slot]=p.macros[b[1]].name;
  }}if(p.macros.length>32||p.macros.some(m=>m.steps.length>256))p.macroStorageLayout='officialBindings';return p;
}
export function validateProfile(p){
  requireThat(p&&p.format==='CherryMacProfile'&&[1,2].includes(p.version)&&Array.isArray(p.macros)&&(p.macroStorageLayout==='officialBindings'||p.macros.length<=32),'配置格式或版本不受支持。');validateSnapshot(p.snapshot);requireThat(p.macroStorageLayout==null||['sharedLibrary','officialBindings'].includes(p.macroStorageLayout),'宏存储方式无效。');p.macros.forEach(m=>validateMacroWithin(m,p.macroStorageLayout==='officialBindings'?762:256));if(p.lightingMapping!=null)lightingMappingSlots(p.lightingMapping,p.snapshot);
  if(p.lightingColorEncoding!=null)requireThat(['hardwareRGB','officialRGB'].includes(p.lightingColorEncoding),'灯效颜色来源无效。');
  if(p.lightingRawSlots!=null){requireThat(p.lightingColorEncoding==='hardwareRGB'&&p.snapshot.colors!=null&&Array.isArray(p.lightingRawSlots)&&p.lightingRawSlots.length<=126&&equal(p.lightingRawSlots,[...new Set(p.lightingRawSlots)].sort((a,b)=>a-b)),'逐键颜色来源记录无效。');lightingMappingSlots(p.lightingMapping,p.snapshot);const mapped=new Set(p.lightingMapping.ledIndices.filter(slot=>slot<126));requireThat(p.lightingRawSlots.every(slot=>Number.isInteger(slot)&&mapped.has(slot)),'原始颜色位置不在实际 LED 映射中。');}
  if(p.windowsTemplateJSON!=null){requireThat(typeof p.windowsTemplateJSON==='string','官方配置模板无效。');validateWindowsTemplate(JSON.parse(p.windowsTemplateJSON),new TextEncoder().encode(p.windowsTemplateJSON).length);}
  if(p.hostTextJSON!=null){requireThat(typeof p.hostTextJSON==='string','文本配置定义无效。');validateHostTextDefinition(JSON.parse(p.hostTextJSON));}
  p.macros.forEach(m=>officialMacroSource(p,m));
  requireThat(new Set(p.macros.map(m=>macroNameKey(m.name))).size===p.macros.length,'宏名称不能重复。');
  if(p.macroModes!=null){requireThat(typeof p.macroModes==='object'&&!Array.isArray(p.macroModes),'宏执行方式结构无效。');for(const [slot,playback] of Object.entries(p.macroModes)){requireThat(Object.hasOwn(p.macroBindings??{},slot),'宏执行方式缺少对应绑定。');validatePlayback(playback);}}
  if(p.macroBindings!=null){requireThat(typeof p.macroBindings==='object'&&!Array.isArray(p.macroBindings),'宏绑定结构无效。');
    for(const [slot,name] of Object.entries(p.macroBindings))requireThat(/^(0|[1-9]\d*)$/.test(slot)&&Number(slot)<126&&![6,71].includes(Number(slot))&&p.macros.some(m=>sameMacroName(m.name,name)),'宏绑定无效。');}
}
export function resolveMacros(p){
  validateProfile(p);requireThat(p.macroBindings!=null,'未知宏不能覆盖，请重新读取键盘。');if(p.macroStorageLayout==='officialBindings')return officialMacroReceipt(p).expected;const s=clone(p.snapshot);
  for(let slot=0;slot<126;slot++)if([0x70,0x71].includes(s.keymap[slot*3]))requireThat(Object.hasOwn(p.macroBindings,slot),'宏记录缺少绑定。');
  const header=s.macroData?.[0]===0xaa&&s.macroData[1]===0x55?s.macroData.slice(6,16):[];
  s.macroData=encodeBank(p.macros,header);for(const [slot,name] of Object.entries(p.macroBindings))s.keymap.splice(Number(slot)*3,3,...macroBinding(p.macros.findIndex(m=>sameMacroName(m.name,name)),p.macroModes?.[slot]));return s;
}
export function portableProfile(profile){validateProfile(profile);const output=clone(profile);if(output.lightingRawSlots!=null)output.version=2;return output;}
export function parseProfile(text,baseline,options={}){
  requireThat(new TextEncoder().encode(text).length<=3_000_000,'配置文件超过 3 MB。');const data=JSON.parse(text);
  if(data?.KeyList||data?.DeviceBasicInfo){requireThat(baseline,'导入 Windows 配置前请连接并读取键盘。');requireThat(new TextEncoder().encode(text).length<=1_000_000,'Windows 配置文件超过 1 MB。');return importWindows(data,baseline,options);}
  const p=data?.format==='CherryMacHardware'?{format:'CherryMacProfile',version:1,snapshot:data,macros:[]}:data;validateProfile(p);
  if(p.lightingRawSlots!=null)p.version=2;
  // Raw backups acquire an editable library only when the firmware bank is recognized.
  if(p.macroBindings==null&&p.macros.length===0){try{const editable=fromHardware(p.snapshot);editable.version=p.version;if(p.windowsTemplateJSON!=null)editable.windowsTemplateJSON=p.windowsTemplateJSON;if(p.hostTextJSON!=null)editable.hostTextJSON=p.hostTextJSON;if(p.lightingMapping!=null)editable.lightingMapping=clone(p.lightingMapping);if(p.lightingRawSlots!=null)editable.lightingRawSlots=clone(p.lightingRawSlots);if(p.lightingColorEncoding!=null)editable.lightingColorEncoding=p.lightingColorEncoding;else delete editable.lightingColorEncoding;return editable;}catch{}}
  if(p.macroBindings)for(const [slot,name] of Object.entries(p.macroBindings))p.macroBindings[slot]=p.macros.find(m=>sameMacroName(m.name,name)).name;
  return p;
}
const winInt=(v,name,min,max)=>{if(typeof v==='string'&&/^-?\d+$/.test(v))v=Number(v);requireThat(Number.isInteger(v)&&v>=min&&v<=max,`Windows ${name} 数据无效。`);return v;};
// Official defaults use JSON booleans for these two flags; exports also use integers.
const winLightFlag=(v,name,max=1)=>winInt(typeof v==='boolean'?Number(v):v,name,0,max);
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
// Pure extraction of an official all-model default file; no USB identity or IO.
export function extractOfficialDefaultTemplate(text){
  requireThat(typeof text==='string'&&new TextEncoder().encode(text).length<=16_000_000,'需要官方 DefaultData 配置文件（不超过 16 MB）。');
  const document=JSON.parse(text.replace(/^\uFEFF/,''));
  requireThat(document&&typeof document==='object'&&!Array.isArray(document)&&Array.isArray(document.Device)&&document.Device.length<=128&&document.Device.every(row=>row&&typeof row==='object'&&!Array.isArray(row)),'默认文件缺少设备列表。');
  const matches=document.Device.filter(row=>row&&typeof row==='object'&&!Array.isArray(row)&&row['//']==='47');
  requireThat(matches.length===1,'默认文件必须包含唯一的型号 47。');
  const root=clone(matches[0]);
  requireThat(root.MacroInfo==null&&(root.ActionInfo==null||Array.isArray(root.ActionInfo)&&root.ActionInfo.length===0)&&Array.isArray(root.KeyList)&&root.KeyList.length===126,'默认文件包含宏或动作，不能作为原始默认配置。');
  for(const key of root.KeyList)requireThat(winInt(key?.Assignment,'Assignment',0,0xffffff)===winInt(key?.DefaultAssignment,'DefaultAssignment',0,0xffffff)&&winInt(key?.ActionLink??0,'ActionLink',0,1)===0,'默认文件包含修改后的键位。');
  root.ActionInfo=[];
  validateWindowsTemplate(root,new TextEncoder().encode(JSON.stringify(root)).length);
  const parameters=prepareOfficialLightingParameters(root,0);
  requireThat(modes.some(([code])=>code===parameters.head[1]),'默认灯效不在本型号已核对范围。');
  return root;
}
function validateWindowsTemplate(root,size){
  requireThat(size<=1_000_000&&root?.['//']==='47'&&Array.isArray(root.KeyList)&&root.KeyList.length===126,'需要本型号的官方配置模板（不超过 1 MB）。');
  root.KeyList.forEach((k,i)=>requireThat(winInt(k?.DefaultAssignment,'DefaultAssignment',0,0xffffff)===WINDOWS_DEFAULTS[i],'Windows 键盘布局不匹配。'));
  officialSystemStageWords(root);
}
// Shared official event decoding for full configurations and .mac files.
function decodeMacroEventObjects(events){
  return events.map(e=>{const type=winInt(e.Type,'事件类型',0,127),button=winInt(e.Button,'按键',0,255);let usage;
      if(type===1&&[1,2,4,8,16].includes(button))usage=button;
      else if(type===4||type===5)usage=button;
      else if(type===10&&button>=4&&button<224)usage=button;
      else if(type===9&&button>0&&(button&(button-1))===0)usage=224+Math.log2(button);
      else throw new Error('滚动与其他宏事件尚未支持。');requireThat(['down','up'].includes(e.Action),'宏按下／松开状态无效。');return {usage,pressed:e.Action==='down',delayMilliseconds:winInt(e.Delay,'延迟',0,60000),...(type===4?{kind:'mouseX'}:type===5?{kind:'mouseY'}:type===1?{kind:'mouse'}:{})};});
 }
export function decodeMacroStepFile(raw,maximumEvents=762){
  requireThat(typeof raw==='string'&&new TextEncoder().encode(raw).length<=3_000_000,'宏文件超过 3 MB。');
  const root=JSON.parse(raw.trim()),events=root===null?[]:root;requireThat(Array.isArray(events),'独立 .mac 文件须为事件数组或 null；完整配置请在配置页导入。');
  requireThat(events.length<=maximumEvents,`宏文件超过当前格式的 ${maximumEvents} 事件上限，请先启用扩展宏编辑。`);
  requireThat(events.every(e=>e&&typeof e==='object'&&!Array.isArray(e)&&Object.keys(e).every(k=>['Type','Button','Action','Delay'].includes(k))),'独立宏含附加事件字段，请使用完整官方配置导入以保留来源。');
  const steps=decodeMacroEventObjects(events);validateMacroWithin({name:'事件文件',steps},maximumEvents);return steps;
}
export function encodeMacroStepFile(macro,profile=null){
  validateMacro(macro);const generated=officialMacroAction(macro,{mode:'count',count:1}),source=profile?officialMacroSource(profile,macro):null;
  const action=source?mergeOfficialMacro(source,generated):generated,raw=JSON.stringify(action.ActionContent.ActionMacroEvents,null,2);
  requireThat(new TextEncoder().encode(raw).length<=3_000_000,'宏文件超过 3 MB。');return raw;
}
export function officialMacroAction(m,playback=m?.preferredPlayback??{mode:'count',count:1}){
  validateMacro(m);validatePlayback(playback);
  return {ActionType:2,ActionName:m.name,ActionContent:{
    ActionMacroType:['count','held','toggle'].indexOf(playback.mode),ActionMacroLoopValue:playback.count,
    ActionMacroFixTimeIsSelected:m.recordingDelay?.fixed?1:0,ActionMacroFixTimeValue:m.recordingDelay?.milliseconds??0,
    ActionMacroEvents:m.steps.length?m.steps.map(s=>{const mouse=s.kind==='mouse',modifier=s.kind==null&&s.usage>=224;
      return {Type:s.kind==='mouseX'?4:s.kind==='mouseY'?5:mouse?1:modifier?9:10,Button:modifier?1<<(s.usage-224):s.usage,Action:s.pressed?'down':'up',Delay:s.delayMilliseconds};}):null
  }};
}
export function canonicalJSON(value){
  const sorted=x=>Array.isArray(x)?x.map(sorted):x&&typeof x==='object'?Object.fromEntries(Object.keys(x).sort().map(k=>[k,sorted(x[k])])):x;
  return JSON.stringify(sorted(value));
}
function officialMacroEvents(content){
  requireThat(content&&typeof content==='object'&&!Array.isArray(content)&&Object.hasOwn(content,'ActionMacroEvents'),'Windows 宏缺少事件字段。');
  const events=content.ActionMacroEvents;requireThat(events===null||Array.isArray(events)&&events.length<=762,'Windows 宏事件无效。');return events??[];
}
function mergeOfficialMacro(original,next){
  const content=original.ActionContent;
  requireThat(content&&typeof content==='object'&&!Array.isArray(content),'官方宏模板结构无效。');
  const result={...clone(original),...next,ActionContent:{...clone(content),...next.ActionContent}};
  const known=['Type','Button','Action','Delay'];
  const events=officialMacroEvents(content);officialMacroEvents(next.ActionContent);
  events.forEach((event,i)=>{
    requireThat(event&&typeof event==='object'&&!Array.isArray(event),'官方宏事件模板无效。');
    const extras=Object.fromEntries(Object.entries(event).filter(([k])=>!known.includes(k)));
    if(!Object.keys(extras).length)return;
    const target=result.ActionContent.ActionMacroEvents?.[i];
    requireThat(target&&winInt(event.Type,'Type',0,127)===target.Type&&winInt(event.Button,'Button',0,255)===target.Button&&event.Action===target.Action,'宏步骤变化后无法对应未知事件字段，不能无损导出。');
    result.ActionContent.ActionMacroEvents[i]={...extras,...target};
  });if(!officialMacroEvents(result.ActionContent).length&&!events.length)result.ActionContent.ActionMacroEvents=clone(content.ActionMacroEvents);return result;
}
function hasOfficialMacroExtras(action){
  const content=action.ActionContent;requireThat(content&&typeof content==='object'&&!Array.isArray(content),'官方宏模板结构无效。');
  const events=officialMacroEvents(content);
  return Object.keys(action).some(k=>!['ActionType','ActionName','ActionContent'].includes(k))||Object.keys(content).some(k=>!['ActionMacroType','ActionMacroLoopValue','ActionMacroFixTimeIsSelected','ActionMacroFixTimeValue','ActionMacroEvents'].includes(k))||events.some(e=>Object.keys(e??{}).some(k=>!['Type','Button','Action','Delay'].includes(k)));
}
export function officialMacroSource(profile,macro){
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
  const keyVariants=new Map();
  const addKeyAction=b=>{
    const value=b[0]*65536+b[1]*256+b[2];if(keyVariants.has(value))return keyVariants.get(value);
    const media=b[0]===0x30?MEDIA_CODES.indexOf(b[1]+b[2]*256):-1;
    const existing=actions.findIndex(action=>{try{const type=winInt(action.ActionType,'ActionType',0,4),content=action.ActionContent;if(type===1)return winInt(content?.ActionKey,'ActionKey',1,0xffffff)===value;return type===4&&media>=0&&winInt(content?.ActionMedia,'ActionMedia',0,MEDIA_CODES.length-1)===media;}catch{return false;}});
    if(existing>=0){keyVariants.set(value,existing);return existing;}const index=actions.length;
    actions.push({ActionType:media>=0?4:1,ActionName:`按键配置 ${index+1}`,ActionContent:{ActionKey:media>=0?0:value,ActionMedia:Math.max(0,media),ActionMacroFixTimeIsSelected:0,ActionMacroFixTimeValue:0,ActionMacroLoopValue:1,ActionMacroMskeyIsSelected:0,ActionMacroType:0,ActionText:''}});keyVariants.set(value,index);return index;
  };
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
    }else if([0x70,0x71].includes(b[0])){const index=profile.macros.findIndex(m=>sameMacroName(m.name,profile.macroBindings?.[slot]));requireThat(index>=0,'宏库与绑定名称不一致，不能导出。');const playback=profile.macroModes?.[slot]??{mode:'count',count:1};k.ActionLink=1;k.ActionLinkIndex=add(index,playback);k.Assignment=k.DefaultAssignment;}
    else{requireThat([0x20,0x30].includes(b[0]),'此按键动作尚不能导出到官方格式。');k.Assignment=b[0]*65536+b[1]*256+b[2];const isFactory=profile.lightingMapping&&equal(b,profile.lightingMapping.factoryKeymap.slice(slot*3,slot*3+3));k.ActionLink=isFactory?0:1;k.ActionLinkIndex=isFactory?-1:addKeyAction(b);}
  });
  // Official actions with different modes import as separate library items.
  // Check that representation still fits before returning a usable document.
  if(profile.macroStorageLayout!=='officialBindings')encodeBank(emitted);root.ActionInfo=actions;
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
// A profile-aware export preserves the distinction between raw and stored RGB.
export function officialPollingDraft(template,index){
  const root=clone(template);validateWindowsTemplate(root,new TextEncoder().encode(JSON.stringify(root)).length);requireThat(Number.isInteger(index)&&index>=0&&index<=3,'本型号官方草稿回报率只支持 125、250、500、1000 Hz。');
  requireThat(officialSystemStageWords(root)!=null,'请先导入包含设备设置的 Windows 官方 JSON。');root.SystemStages.ReportSelectItem=index;
  requireThat(new TextEncoder().encode(JSON.stringify(root)).length<=1_000_000,'官方配置草稿超过 1 MB。');return root;
}
export function exportProfileWindowsLightingDraft(profile,template){
  validateProfile(profile);const root=clone(template);validateWindowsTemplate(root,new TextEncoder().encode(JSON.stringify(root)).length);
  if(profile.lightingColorEncoding==='officialRGB'){
    // The official 0x483410 setter creates just LightColorInfo's RGBA array.
    // Only a genuinely absent table may be initialized; malformed imported
    // tables stay errors, and an existing template's extra fields survive.
    if(root.CustomLightMode==null){
      lightingMappingSlots(profile.lightingMapping,profile.snapshot);
      root.CustomLightMode={LightColorInfo:[Array.from({length:126},()=>({Red:0,Green:0,Blue:0,Alpha:0}))]};
    }
    return exportWindowsLightingDraft(profile.snapshot,root,profile.lightingMapping);
  }
  const p=profile.snapshot.parameters;
  if(p[1]===8){
    const groups=root.CustomLightMode?.LightColorInfo;
    requireThat(profile.lightingColorEncoding==='hardwareRGB'&&Array.isArray(groups)&&groups.length===1&&Array.isArray(groups[0])&&groups[0].length===126,'合并逐键配色需要原 Windows 颜色表；请导出 CherryMac JSON 保存位置来源。');
    const slots=lightingMappingSlots(profile.lightingMapping,profile.snapshot),raw=new Set(profile.lightingRawSlots??[]),candidate=clone(profile);
    candidate.snapshot.colors=Array(378).fill(0);candidate.lightingColorEncoding='officialRGB';delete candidate.lightingRawSlots;
    groups[0].forEach((entry,index)=>{
      requireThat(entry&&typeof entry==='object'&&!Array.isArray(entry),'逐键颜色记录结构无效。');
      const rgb=['Red','Green','Blue'].map(name=>winInt(entry[name],name,0,255));if(Object.hasOwn(entry,'Alpha'))winInt(entry.Alpha,'Alpha',0,255);
      const slot=slots[index];if(slot!=null)candidate.snapshot.colors.splice(slot*3,3,...(raw.has(slot)?profile.snapshot.colors.slice(slot*3,slot*3+3):rgb));
    });
    const output=exportWindowsLightingDraft(candidate.snapshot,root,profile.lightingMapping),actual=prepareOfficialCustomColors(output,profile.snapshot,profile.lightingMapping);
    const expected=planCustomLighting(profile,{bank:0,transportSelector:0,chunkCapacity:56,beginRequired:true}).stages.filter(stage=>stage.name==='customColors').flatMap(stage=>stage.writes.flatMap(write=>write.data));
    requireThat(actual.length===378&&equal(actual,expected),'原 Windows 颜色表无法在当前亮度下完整保留此草稿；请导出 CherryMac JSON，避免未修改按键变色。');return output;
  }
  const light=root.LightInfo,selected=MODE_CODES.indexOf(p[1]);
  requireThat(light&&typeof light==='object'&&!Array.isArray(light)&&modes.some(([v])=>v===p[1])&&selected>=0&&p[2]<=4&&p[3]<=4&&p[4]<=1&&p[5]<=1,'当前灯效参数或官方模板无效，不能导出。');
  Object.assign(light,{SelectItem:selected,Light:p[2],Speed:4-p[3],Fx:p[4],MultiColor:p[5],Red:p[6],Green:p[7],Blue:p[8],LightOpenFlag:p[21]});
  requireThat(new TextEncoder().encode(JSON.stringify(root)).length<=1_000_000,'导出的官方配置文件过大。');return root;
}
export function exportWindowsLightingDraft(snapshot,template,lightingMapping=null){
  validateSnapshot(snapshot,true);const root=clone(template);validateWindowsTemplate(root,new TextEncoder().encode(JSON.stringify(root)).length);
  const light=root.LightInfo,custom=root.CustomLightMode,groups=custom?.LightColorInfo;
  requireThat(light&&typeof light==='object'&&!Array.isArray(light)&&custom&&typeof custom==='object'&&!Array.isArray(custom)&&Array.isArray(groups)&&groups.length===1&&Array.isArray(groups[0])&&groups[0].length===126&&Array.isArray(snapshot.colors),'导出灯效需要完整读取配色和带 126 项颜色表的官方模板。');
  const mapping=lightingMapping==null?null:lightingMappingSlots(lightingMapping,snapshot);
  const p=snapshot.parameters,selected=MODE_CODES.indexOf(p[1]);requireThat(modes.some(([v])=>v===p[1])&&selected>=0&&p[2]<=4&&p[3]<=4&&p[4]<=1&&p[5]<=1,'当前灯效参数超出本型号已核对范围，不能导出。');
  Object.assign(light,{SelectItem:selected,Light:p[2],Speed:4-p[3],Fx:p[4],MultiColor:p[5],Red:p[6],Green:p[7],Blue:p[8],LightOpenFlag:p[21]});
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
  if(lightingMapping!=null){p.lightingMapping=clone(lightingMapping);p.macroStorageLayout='officialBindings';}
  p.windowsTemplateJSON=JSON.stringify(root);
  const oldModes=clone(p.macroModes??{});
  if(deferHostText&&validateHostTextDefinition(root)>0)p.hostTextJSON=p.windowsTemplateJSON;
  p.macroBindings=Object.fromEntries(Object.entries(old).filter(([slot])=>!physical.has(Number(slot))));
  p.macroModes=Object.fromEntries(Object.entries(p.macroModes??{}).filter(([slot])=>!physical.has(Number(slot))));
  const record=v=>{v=winInt(v,'按键动作',0,0xffffff);const b=[v>>16,(v>>8)&255,v&255];requireThat([0x20,0x30].includes(b[0]),'不支持此 Windows 按键动作。');return b;};
  const importMacro=index=>{
    if(imported.has(index))return;const a=actions[index],c=a?.ActionContent;requireThat(c&&typeof c==='object'&&!Array.isArray(c),'Windows 宏内容无效。');

    const recordingDelay={fixed:winInt(c.ActionMacroFixTimeIsSelected??0,'固定间隔选项',0,1)===1,milliseconds:winInt(c.ActionMacroFixTimeValue??0,'固定间隔值',0,60000)};
    const events=officialMacroEvents(c);
    const steps=decodeMacroEventObjects(events);
    const stem=typeof a.ActionName==='string'&&a.ActionName.trim()?macroNameStem(a.ActionName):'导入宏';let name=stem,j=1;while(p.macros.some(m=>sameMacroName(m.name,name)))name=`${stem} (${j++})`;
    const mode=winInt(c.ActionMacroType,'宏模式',0,2),preferredPlayback={mode:['count','held','toggle'][mode],count:mode===0?winInt(c.ActionMacroLoopValue??1,'重复次数',1,255):1};
    const macro={name,steps,recordingDelay,preferredPlayback,windowsActionIndex:index};validateMacro(macro);p.macros.push(macro);imported.set(index,name);

  };
  actions.forEach((action,index)=>{let type;try{type=winInt(action?.ActionType,'ActionType',0,4);}catch{return;}if(type===2)importMacro(index);});
  root.KeyList.forEach((k,i)=>{
    const slot=physicalSlot(WINDOWS_DEFAULTS[i]);if(slot===undefined||[6,71].includes(slot))return;
    let b;if(winInt(k.ActionLink??0,'ActionLink',0,1)===0)b=record(k.Assignment);
    else{
      const index=winInt(k.ActionLinkIndex,'ActionLinkIndex',0,actions.length-1),a=actions[index],c=a?.ActionContent;
      const type=winInt(a?.ActionType,'ActionType',0,4);requireThat(type===0||c&&typeof c==='object'&&!Array.isArray(c),'Windows 动作内容无效。');
      if(type===0)b=record(k.DefaultAssignment);
      else if(type===1)b=record(c.ActionKey);
      else if(type===4){const code=MEDIA_CODES[winInt(c.ActionMedia,'ActionMedia',0,17)];b=[0x30,code&255,code>>8];}
      else if(type===2){
        importMacro(index);const name=imported.get(index);p.macroBindings[slot]=name;const mode=winInt(c.ActionMacroType,'宏模式',0,2);p.macroModes[slot]={mode:['count','held','toggle'][mode],count:mode===0?winInt(c.ActionMacroLoopValue??1,'重复次数',1,255):1};b=macroBinding(p.macroStorageLayout==='officialBindings'?0:p.macros.findIndex(m=>sameMacroName(m.name,name)),p.macroModes[slot]);
      }else if(type===3){officialHostTextPlan(a);if(deferHostText){if(old[slot]!=null)p.macroBindings[slot]=old[slot];if(oldModes[slot]!=null)p.macroModes[slot]=oldModes[slot];return;}throw new Error('此配置含文本绑定，请使用带“文本”页的预览，在该页单独选择和安装。普通配置导入保留原编辑区。');}else throw new Error('Windows 文本和其他动作尚未支持导入。');
    }p.snapshot.keymap.splice(slot*3,3,...b);
  });
  const l=root.LightInfo;if(l){const mode=MODE_CODES[winInt(l.SelectItem,'模式',0,24)];requireThat(modes.some(([v])=>v===mode),'此内置灯效尚未验证。');
    p.snapshot.parameters.splice(1,8,mode,winInt(l.Light,'亮度',0,4),4-winInt(l.Speed,'速度',0,4),winInt(l.Fx,'方向',0,1),winLightFlag(l.MultiColor,'彩虹'),...['Red','Green','Blue'].map(k=>winInt(l[k],k,0,255)));
    if(Object.hasOwn(l,'LightOpenFlag'))p.snapshot.parameters[21]=winLightFlag(l.LightOpenFlag,'LightOpenFlag',255);}
  const groups=root.CustomLightMode?.LightColorInfo;if(root.CustomLightMode){requireThat(Array.isArray(groups)&&groups.length===1&&Array.isArray(groups[0])&&groups[0].length===126,'逐键颜色组不匹配。');groups[0].forEach((c,i)=>{requireThat(c&&typeof c==='object'&&!Array.isArray(c),'逐键颜色记录结构无效。');const rgb=['Red','Green','Blue'].map(k=>winInt(c[k],k,0,255));if(Object.hasOwn(c,'Alpha'))winInt(c.Alpha,'Alpha',0,255);const slot=lightingSlots===null?physicalSlot(WINDOWS_DEFAULTS[i]):lightingSlots[i];if(slot!=null)p.snapshot.colors.splice(slot*3,3,...rgb);});}
  if(root.CustomLightMode)p.lightingColorEncoding='officialRGB';
  if(!equal(p.macroBindings,old)||imported.size)p.snapshot=resolveMacros(p);validateProfile(p);return p;
}
// Explicit ColorPalette editing only. Never round-trip imported/stored RGB.
export function hslColor(hue,saturation,lightness){
  requireThat([hue,saturation,lightness].every(Number.isInteger)&&hue>=0&&hue<=360&&saturation>=0&&saturation<=200&&lightness>=0&&lightness<=200,'H 须为 0～360，S 和 L 须为 0～200 的整数。');
  const f=Math.fround,h=f(hue/360),s=f(saturation/200),l=f(lightness/200),q=l<.5?f(l*f(1+s)):f(f(l+s)-f(l*s)),p=f(f(2*l)-q);
  const channel=offset=>{let t=f(h+offset);if(t<0)t=f(t+1);if(t>1)t=f(t-1);let value;
    if(s===0)value=l;else if(f(6*t)<1)value=f(p+f(f(f(q-p)*6)*t));else if(f(2*t)<1)value=q;else if(f(3*t)<2)value=f(p+f(f(f(q-p)*f(f(2/3)-t))*6));else value=p;
    return Math.max(0,Math.min(255,Math.trunc(f(value*255))));};
  return [channel(f(1/3)),channel(0),channel(f(-1/3))];
}
export function colorHSL(color){
  requireThat(Array.isArray(color)&&color.length===3&&color.every(v=>Number.isInteger(v)&&v>=0&&v<=255),'RGB 颜色无效。');
  const f=Math.fround,[r,g,b]=color.map(v=>f(v/255)),hi=Math.max(r,g,b),lo=Math.min(r,g,b),delta=f(hi-lo),l=f(f(hi+lo)/2);
  if(delta===0)return [0,0,Math.trunc(f(l*200))];
  const s=l<.5?f(delta/f(hi+lo)):f(delta/f(f(2-hi)-lo));let h;
  if(hi===r)h=f(f(f(g-b)/delta)+(g<b?6:0));else if(hi===g)h=f(f(f(b-r)/delta)+2);else h=f(f(f(r-g)/delta)+4);
  h=f(h/6);return [Math.max(0,Math.min(360,Math.trunc(f(h*360)))),Math.max(0,Math.min(200,Math.trunc(f(s*200)))),Math.max(0,Math.min(200,Math.trunc(f(l*200))))];
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
export function importWindowsLightingDraft(profile,template){
  validateProfile(profile);const source=clone(template);validateWindowsTemplate(source,new TextEncoder().encode(JSON.stringify(source)).length);
  const light=source.LightInfo;requireThat(light&&typeof light==='object'&&!Array.isArray(light),'官方配置缺少灯效设置。');
  const mode=MODE_CODES[winInt(light.SelectItem,'SelectItem',0,24)];requireThat(modes.some(([code])=>code===mode),'此灯效模式尚未支持。');
  const result=clone(profile),root=typeof profile.windowsTemplateJSON==='string'?JSON.parse(profile.windowsTemplateJSON):clone(source);
  if(typeof profile.windowsTemplateJSON!=='string')delete root.SystemStages;
  result.snapshot.parameters.splice(1,8,mode,winInt(light.Light,'Light',0,4),4-winInt(light.Speed,'Speed',0,4),winInt(light.Fx,'Fx',0,1),winLightFlag(light.MultiColor,'MultiColor'),...['Red','Green','Blue'].map(key=>winInt(light[key],key,0,255)));
  result.snapshot.parameters[21]=winLightFlag(light.LightOpenFlag,'LightOpenFlag',255);
  root.LightInfo=clone(light);
  if(Object.hasOwn(source,'CustomLightMode')){
    const custom=source.CustomLightMode,groups=custom?.LightColorInfo;
    requireThat(custom&&typeof custom==='object'&&!Array.isArray(custom)&&Array.isArray(groups)&&groups.length===1&&Array.isArray(groups[0])&&groups[0].length===126&&Array.isArray(result.snapshot.colors),'官方配色需要完整的 126 项颜色表和当前颜色区。');
    const mapping=profile.lightingMapping==null?null:lightingMappingSlots(profile.lightingMapping,profile.snapshot);
    groups[0].forEach((entry,index)=>{
      requireThat(entry&&typeof entry==='object'&&!Array.isArray(entry),'逐键颜色记录结构无效。');
      const bytes=['Red','Green','Blue'].map(key=>winInt(entry[key],key,0,255));if(Object.hasOwn(entry,'Alpha'))winInt(entry.Alpha,'Alpha',0,255);
      const slot=mapping===null?physicalSlot(WINDOWS_DEFAULTS[index]):mapping[index];if(slot!=null)result.snapshot.colors.splice(slot*3,3,...bytes);
    });
    root.CustomLightMode=clone(custom);result.lightingColorEncoding='officialRGB';delete result.lightingRawSlots;
  }else requireThat(mode!==8,'自定义模式缺少官方原始颜色表。');
  result.windowsTemplateJSON=JSON.stringify(root);validateProfile(result);return result;
}
// This format is separate from lightingPlan; ordinary lamp IO cannot accept it.
function defaultBankReports(command,data,preflight=false){
  requireThat([9,0x0b].includes(command)&&bytes(data,378),'默认恢复步骤需要完整 378 字节原始数据。');
  const encode=(command,payload=[])=>{const b=Array(64).fill(0);b[0]=4;b[3]=command;b.splice(4,payload.length,...payload);const sum=b.slice(3).reduce((n,v)=>n+v,0);b[1]=sum&255;b[2]=sum>>8;return b;};
  const reports=[{stage:0,kind:preflight?'preflight':'begin',delayMilliseconds:0,request:preflight?encode(3,[34,0,0,0]):encode(1)}];
  const buffer=Array(64).fill(0);buffer[0]=4;buffer[3]=command;
  // Official helpers retain prior payload padding in the final short report.
  for(let offset=0;offset<378;offset+=56){const chunk=data.slice(offset,offset+56);buffer[4]=chunk.length;buffer[5]=offset&255;buffer[6]=offset>>8;buffer.splice(8,chunk.length,...chunk);const sum=buffer.slice(3).reduce((n,v)=>n+v,0);buffer[1]=sum&255;buffer[2]=sum>>8;reports.push({stage:0,kind:'data',delayMilliseconds:0,request:[...buffer]});}
  reports.push({stage:0,kind:'finish',delayMilliseconds:10,request:encode(2)});return reports;
}
// Compute an offline candidate and unresolved scopes, without authorizing IO.
export function reviewDefaultConfiguration(text,baseline,mapping){
  validateSnapshot(baseline,true);const colorSlots=lightingMappingSlots(mapping,baseline);
  // USB0102 info[5] is 170, not the model's logical position count. Use
  // validated bank sizes and the matching LED map, preserving all IO gates.
  requireThat(baseline.deviceInfo[6]===24&&baseline.parameters[0]===0&&WINDOWS_DEFAULTS.length===126&&colorSlots.length===WINDOWS_DEFAULTS.length&&baseline.keymap.length===WINDOWS_DEFAULTS.length*3&&baseline.colors.length===WINDOWS_DEFAULTS.length*3,'默认恢复核对需要本型号配置 0 的完整读取基线和 126 项映射。');
  const template=extractOfficialDefaultTemplate(text);
  const lightingPlan=planOfficialLighting(template,baseline,mapping,{bank:0,transportSelector:0,chunkCapacity:56,beginRequired:true});
  requireThat(lightingPlan.stages.length===1,'默认恢复核对目前需要内置灯效默认模板，逐键模式模板尚未接入此流程。');
  const candidate=officialLightingReadbackTarget(lightingPlan,baseline);
  candidate.keymap=clone(mapping.factoryKeymap);validateSnapshot(candidate,true);
  // Model 47 registers 126 color entries, resized by 541330. This color
  // stage remains separate from the parameter-only lightingPlan.
  const redLogicalIndices=[44,64,65,66,96,113,114,115],targetColors=Array(378).fill(0),mapped=new Set();
  colorSlots.forEach((slot,logical)=>{if(slot===null)return;mapped.add(slot);targetColors.splice(slot*3,3,254,redLogicalIndices.includes(logical)?0:254,redLogicalIndices.includes(logical)?0:254);});
  const defaultColorPlan={hardwareReady:false,logicalEntryCount:126,pendingTransportIntegration:true,redLogicalIndices,coefficient:255,targetColors,mappedColorSlots:[...mapped].sort((a,b)=>a-b),changedColorSlots:Array.from({length:126},(_,slot)=>slot).filter(slot=>!equal(targetColors.slice(slot*3,slot*3+3),baseline.colors.slice(slot*3,slot*3+3))),bank:0,transportSelector:0,chunkCapacity:56,beginRequired:true,reports:defaultBankReports(0x0b,targetColors),restoreReports:defaultBankReports(0x0b,baseline.colors)};
  const defaultKeyPlan={hardwareReady:false,bank:0,transportSelector:0,chunkCapacity:56,pendingTransportIntegration:true,pendingSenderLengthState:false,senderLengthBytes:378,targetKeymap:clone(mapping.factoryKeymap),reports:defaultBankReports(9,mapping.factoryKeymap,true),restoreReports:defaultBankReports(9,baseline.keymap,true)};
  candidate.colors=clone(targetColors);validateSnapshot(candidate,true);
  const changedKeySlots=Array.from({length:126},(_,slot)=>slot).filter(slot=>!equal(candidate.keymap.slice(slot*3,slot*3+3),baseline.keymap.slice(slot*3,slot*3+3)));
  const protectedChangedSlots=changedKeySlots.filter(slot=>!editableSlots.has(slot));
  const macroBindingSlots=changedKeySlots.filter(slot=>[0x70,0x71].includes(baseline.keymap[slot*3]));
  const unsupportedFactorySlots=changedKeySlots.filter(slot=>{const [type,,usage]=candidate.keymap.slice(slot*3,slot*3+3);return !(type===0x30||type===0x20&&(usage===0||usage>=4&&usage<224));});
  return {format:'CherryMacDefaultConfigurationReview',version:7,hardwareReady:false,original:clone(baseline),candidate,officialTemplateJSON:JSON.stringify(template),factoryKeymap:clone(mapping.factoryKeymap),lightingMapping:clone(mapping),lightingPlan,changedKeySlots,defaultColorPlan,defaultKeyPlan,officialStageOrder:['defaultColors','factoryKeys','parameters'],changedParameterOffsets:Array.from({length:56},(_,i)=>i).filter(i=>candidate.parameters[i]!==baseline.parameters[i]),protectedChangedSlots,macroBindingSlots,unsupportedFactorySlots,pendingSystemFields:['Repeat','RepeatDelay','Key6Flag','ReportSelectItem','RFReportSelectItem','WFlag','WinFlag'],retainedMacroStorage:true,pendingColorRestore:true,pendingMacroStorageSemantics:true,completeRestoreImplemented:false};
}
// Offline only: exact source reconstruction before matching known write prefixes.
export function reviewDefaultRestoreProgress(review,current){
  requireThat(review?.format==='CherryMacDefaultConfigurationReview'&&review.version===7&&review.hardwareReady===false,'默认恢复记录版本无效。');
  const rebuilt=reviewDefaultConfiguration(JSON.stringify({Device:[JSON.parse(review.officialTemplateJSON)]}),review.original,review.lightingMapping);
  const canonical=value=>Array.isArray(value)?value.map(canonical):value&&typeof value==='object'?Object.fromEntries(Object.keys(value).sort().map(key=>[key,canonical(value[key])])):value;
  requireThat(JSON.stringify(canonical(review))===JSON.stringify(canonical(rebuilt)),'默认恢复记录与保留的原始资料不一致，停止核对。');
  validateSnapshot(current,true);
  const same=(a,b)=>['deviceInfo','keymap','parameters','colors','macroData'].every(field=>equal(a[field],b[field]));
  const state=clone(rebuilt.original),matchedDataPrefixes=[];let count=0;
  if(same(state,current))matchedDataPrefixes.push(0);
  const stages=[['colors',rebuilt.defaultColorPlan.reports],['keymap',rebuilt.defaultKeyPlan.reports],['parameters',officialLightingReports(rebuilt.lightingPlan)]];
  for(const [field,reports] of stages)for(const report of reports.filter(r=>r.kind==='data')){
    const bytes=report.request,length=bytes[4],offset=bytes[5]|bytes[6]<<8;
    const limit=field==='parameters'?56:378,command=field==='parameters'?6:field==='keymap'?9:0x0b;
    requireThat(bytes.length===64&&bytes[3]===command&&length>0&&length<=56&&offset+length<=limit,'默认恢复分包超出已知范围，停止核对。');
    state[field].splice(offset,length,...bytes.slice(8,8+length));count++;
    if(same(state,current))matchedDataPrefixes.push(count);
  }
  requireThat(same(state,rebuilt.candidate),'默认恢复分包不能重建候选，停止核对。');
  requireThat(matchedDataPrefixes.length>0,'当前配置不属于此次默认恢复的原始、目标或分包前缀，停止覆盖。');
  return {format:'CherryMacDefaultRestoreProgress',version:1,hardwareReady:false,completeRestoreImplemented:false,matchedDataPrefixes,totalDataReports:count,configurationMatchesOriginal:same(current,rebuilt.original),configurationMatchesCandidate:same(current,rebuilt.candidate)};
}
// Our bounded rollback order, separate from the official forward reset order.
export function defaultRecoveryPlan(review,current){
  const progress=reviewDefaultRestoreProgress(review,current),reports=[];
  if(!progress.configurationMatchesOriginal){
    for(const packet of officialLightingReports(review.lightingPlan)){
      packet.stage=0;
      if(packet.kind==='data'){
        const offset=packet.request[5]|packet.request[6]<<8,length=packet.request[4];
        packet.request.splice(8,length,...review.original.parameters.slice(offset,offset+length));
        const sum=packet.request.slice(3).reduce((n,v)=>n+v,0);packet.request[1]=sum&255;packet.request[2]=sum>>8;
      }
      reports.push(packet);
    }
    reports.push(...clone(review.defaultKeyPlan.restoreReports).map(packet=>({...packet,stage:1})),...clone(review.defaultColorPlan.restoreReports).map(packet=>({...packet,stage:2})));
  }
  return {format:'CherryMacDefaultRecoveryPlan',version:1,hardwareReady:false,completeRestoreImplemented:false,sourceReview:clone(review),before:clone(current),expected:clone(review.original),reports,stageOrder:['parameters','originalKeys','originalColors']};
}
export function reviewDefaultRecoveryProgress(plan,current){
  requireThat(plan?.format==='CherryMacDefaultRecoveryPlan'&&plan.version===1&&plan.hardwareReady===false&&plan.completeRestoreImplemented===false,'默认恢复撤回记录格式无效。');
  const rebuilt=defaultRecoveryPlan(plan.sourceReview,plan.before);
  const canonical=value=>Array.isArray(value)?value.map(canonical):value&&typeof value==='object'?Object.fromEntries(Object.keys(value).sort().map(key=>[key,canonical(value[key])])):value;
  requireThat(JSON.stringify(canonical(plan))===JSON.stringify(canonical(rebuilt)),'默认恢复撤回记录与原始资料不一致，停止核对。');
  validateSnapshot(current,true);
  const same=(a,b)=>['deviceInfo','keymap','parameters','colors','macroData'].every(field=>equal(a[field],b[field]));
  const state=clone(rebuilt.before),matchedDataPrefixes=[];let count=0;
  if(same(state,current))matchedDataPrefixes.push(0);
  for(const packet of rebuilt.reports.filter(p=>p.kind==='data')){
    const bytes=packet.request,length=bytes[4],offset=bytes[5]|bytes[6]<<8,field=bytes[3]===6?'parameters':bytes[3]===9?'keymap':'colors';
    const limit=field==='parameters'?56:378;
    requireThat(bytes.length===64&&[6,9,0x0b].includes(bytes[3])&&length>0&&length<=56&&offset+length<=limit,'撤回分包超出已知范围。');
    state[field].splice(offset,length,...bytes.slice(8,8+length));count++;
    if(same(state,current))matchedDataPrefixes.push(count);
  }
  requireThat(same(state,rebuilt.expected),'撤回分包不能重建原始配置。');
  requireThat(matchedDataPrefixes.length>0,'当前配置不属于此次撤回的分包前缀，停止覆盖。');
  return {format:'CherryMacDefaultRecoveryProgress',version:1,hardwareReady:false,completeRestoreImplemented:false,matchedDataPrefixes,totalDataReports:count,configurationMatchesOriginal:same(current,rebuilt.expected)};
}
export function defaultConfigurationReports(review){
  reviewDefaultRestoreProgress(review,review.original);
  return [...clone(review.defaultColorPlan.reports).map(p=>({...p,stage:0})),...clone(review.defaultKeyPlan.reports).map(p=>({...p,stage:1})),...officialLightingReports(review.lightingPlan).map(p=>({...p,stage:2}))];
}
function reviewDefaultTrace(trace,reports,deviceInfo){
  requireThat(trace?.format==='CherryMacDefaultTrace'&&bytes(deviceInfo,34),'默认恢复日志格式无效。');
  const basic=reviewLightingReportTrace(reports,{...trace,format:'CherryMacLightingTrace'});
  const result={...basic,format:'CherryMacDefaultTraceReview'};
  for(let index=0;index<basic.acceptedReports;index++){
    if(reports[index].request[3]!==3)continue;
    if(!equal(trace.entries[index].reply.slice(8,42),deviceInfo)){
      requireThat(index===trace.entries.length-1,'默认恢复日志在设备查询不一致后仍继续发送。');
      result.status='failed';result.acceptedReports=index;result.failedIndex=index;break;
    }
  }
  return result;
}
export function assessDefaultTransactionRecord(record){
  requireThat(record?.format==='CherryMacDefaultTransactionRecord'&&record.version===2&&record.hardwareReady===false&&typeof record.operationID==='string'&&/^[A-Za-z0-9_.-]{1,128}$/.test(record.operationID)&&['forward','recovery'].includes(record.direction)&&typeof record.failure==='string'&&new TextEncoder().encode(record.failure).length<=4096,'默认恢复事务记录格式无效。');
  let reports,target;
  if(record.direction==='forward'){
    requireThat(record.recovery==null,'前向记录不能混入撤回计划。');reports=defaultConfigurationReports(record.sourceReview);target=record.sourceReview.candidate;
    validateSnapshot(record.started,true);requireThat(sameDefaultConfiguration(record.started,record.sourceReview.original),'前向事务起始配置与基线不一致。');
  }else{
    requireThat(record.recovery!=null,'撤回记录缺少原始撤回计划。');reviewDefaultRecoveryProgress(record.recovery,record.recovery.before);
    const canonical=value=>Array.isArray(value)?value.map(canonical):value&&typeof value==='object'?Object.fromEntries(Object.keys(value).sort().map(key=>[key,canonical(value[key])])):value;
    requireThat(JSON.stringify(canonical(record.sourceReview))===JSON.stringify(canonical(record.recovery.sourceReview)),'撤回记录的来源不一致。');
    const initial=reviewDefaultRecoveryProgress(record.recovery,record.started);reports=initial.configurationMatchesOriginal?[]:record.recovery.reports;target=record.recovery.expected;
  }
  const traceReview=reviewDefaultTrace(record.trace,reports,record.sourceReview.original.deviceInfo);
  let readbackMatches=false,recoveryStatus='unavailable',matchedDataPrefixes=[];
  if(record.current!=null){
    validateSnapshot(record.current,true);readbackMatches=['deviceInfo','keymap','parameters','colors','macroData'].every(field=>equal(record.current[field],target[field]));
    try{const progress=record.direction==='recovery'?reviewDefaultRecoveryProgress(record.recovery,record.current):reviewDefaultRestoreProgress(record.sourceReview,record.current);matchedDataPrefixes=progress.matchedDataPrefixes;recoveryStatus=progress.configurationMatchesOriginal?'unchanged':'available';}catch{recoveryStatus='unrecognized';}
  }
  const status=record.failure||traceReview.status==='failed'?'failed':traceReview.status!=='complete'?'incomplete':record.current==null?'readbackMissing':readbackMatches?'readbackMatched':'readbackMismatch';
  return {format:'CherryMacDefaultTransactionAssessment',version:1,hardwareReady:false,operationID:record.operationID,direction:record.direction,status,traceReview,readbackMatches,recoveryStatus,matchedDataPrefixes};
}
// Inspect retained files without USB; a recorded readback is not a current read.
export function inspectDefaultTransaction(record){
  const assessment=assessDefaultTransactionRecord(record);
  const originalProfile={format:'CherryMacProfile',version:1,snapshot:clone(record.sourceReview.original),macros:[],lightingMapping:clone(record.sourceReview.lightingMapping)};
  validateProfile(originalProfile);
  let recoveryPlan=null,recoveryIssue='';
  if(record.current!=null){
    if(assessment.recoveryStatus==='unrecognized')recoveryIssue='记录中的读回不属于已知分包进度，不能据此生成撤回计划。';
    else{recoveryPlan=record.direction==='recovery'?clone(record.recovery):defaultRecoveryPlan(record.sourceReview,record.current);reviewDefaultRecoveryProgress(recoveryPlan,record.current);}
  }else recoveryIssue='记录缺少读回；保留原始备份，实际撤回前需重新读取键盘。';
  return {format:'CherryMacDefaultTransactionInspection',version:1,hardwareReady:false,assessment,readbackAvailable:record.current!=null,failure:record.failure,originalProfile,recoveryPlan,recoveryIssue};
}
const sameDefaultConfiguration=(a,b)=>['deviceInfo','keymap','parameters','colors','macroData'].every(field=>equal(a[field],b[field]));
// Injectable transaction only; no WebHID import, write permission or retry.
export async function executeDefaultTransaction(review,{recovery=null,source,operationID=globalThis.crypto.randomUUID(),assertCurrent,cancelled,read,backup,persist,clock,wait,exchange}){
  review=clone(review);recovery=clone(recovery);
  const record={format:'CherryMacDefaultTransactionRecord',version:2,hardwareReady:false,operationID,direction:recovery?'recovery':'forward',sourceReview:review,recovery,started:clone(recovery?.before??review.original),trace:{format:'CherryMacDefaultTrace',version:1,source,entries:[]},current:null,failure:''};
  assessDefaultTransactionRecord(record);
  const describe=error=>{const text=String(error?.message??error).trim()||'默认恢复操作失败。';return new TextDecoder().decode(new TextEncoder().encode(text).slice(0,4000));};
  const check=async()=>{await assertCurrent();requireThat(!cancelled(),'默认恢复流程已取消。');};
  await check();record.started=clone(await read());await assertCurrent();assessDefaultTransactionRecord(record);
  const reports=recovery?(reviewDefaultRecoveryProgress(recovery,record.started).configurationMatchesOriginal?[]:clone(recovery.reports)):defaultConfigurationReports(review);
  await backup(clone(record.started));await persist(clone(record));
  try{
    await check();const verified=clone(await read());validateSnapshot(verified,true);await assertCurrent();
    requireThat(sameDefaultConfiguration(verified,record.started),'备份后配置发生变化，未发送默认恢复指令。');
  }catch(error){record.failure=describe(error);assessDefaultTransactionRecord(record);await persist(clone(record));return record;}
  for(const report of reports){
    try{await check();await wait(report.delayMilliseconds);await check();}catch(error){record.failure=describe(error);break;}
    const entry={request:clone(report.request),sentMilliseconds:clock()};record.trace.entries.push(entry);
    assessDefaultTransactionRecord(record);await persist(clone(record));
    try{await check();const reply=Array.from(await exchange(clone(report.request)));await assertCurrent();entry.reply=reply;}catch(error){entry.error=describe(error);}
    entry.endedMilliseconds=clock();const assessment=assessDefaultTransactionRecord(record);await persist(clone(record));
    if(assessment.traceReview.status==='failed'){record.failure=entry.error||'默认恢复回复校验失败。';break;}
  }
  try{await assertCurrent();const current=clone(await read());validateSnapshot(current,true);await assertCurrent();record.current=clone(current);}catch(error){if(!record.failure)record.failure=describe(error);}
  if(!record.failure&&!assessDefaultTransactionRecord(record).readbackMatches)record.failure='默认恢复读回与目标不一致。';
  assessDefaultTransactionRecord(record);await persist(clone(record));return record;
}
export function reviewDefaultLighting(text,baseline,mapping){
  validateSnapshot(baseline,true);const slots=lightingMappingSlots(mapping,baseline);
  requireThat(baseline.deviceInfo[6]===24&&WINDOWS_DEFAULTS.length===126&&slots.length===WINDOWS_DEFAULTS.length&&baseline.keymap.length===WINDOWS_DEFAULTS.length*3&&baseline.colors.length===WINDOWS_DEFAULTS.length*3,'默认灯效需要本型号完整配置和 126 项映射。');
  // Official DefaultData0…4 agree for model 47; no profile selection needed at bank 0.
  const parameters=text==null?{head:[0,23,4,2,0,1,0,255,0],lightOpenFlag:0}:prepareOfficialLightingParameters(extractOfficialDefaultTemplate(text),0),red=new Set([44,64,65,66,96,113,114,115]),colors=Array(378).fill(0);
  slots.forEach((slot,logical)=>{if(slot!=null)colors.splice(slot*3,3,254,red.has(logical)?0:254,red.has(logical)?0:254);});
  const options={bank:0,transportSelector:0,chunkCapacity:56,beginRequired:true},plan=assembleLightingPlan(parameters,null,options);
  plan.defaultColorData=colors;plan.stages.unshift({name:'defaultColors',beginRequired:true,beginCommand:1,writes:Array.from({length:Math.ceil(378/56)},(_,i)=>({command:0x0b,offset:i*56,flag:0,data:colors.slice(i*56,(i+1)*56)})),finishCommand:2,finishDelayMilliseconds:10});
  const target=officialLightingReadbackTarget(plan,baseline);
  return {format:'CherryMacLightingDraftReview',version:1,hardwareReady:false,plan,original:clone(baseline),target,changedParameterOffsets:Array.from({length:56},(_,i)=>i).filter(i=>baseline.parameters[i]!==target.parameters[i]),changedColorSlots:Array.from({length:126},(_,i)=>i).filter(i=>!equal(baseline.colors.slice(i*3,i*3+3),target.colors.slice(i*3,i*3+3))),lightingMapping:clone(mapping)};
}
export function reviewLightingDraft(profile,baseline){
  validateProfile(profile);validateSnapshot(baseline,true);validateSnapshot(profile.snapshot,true);
  requireThat(equal(profile.snapshot.deviceInfo,baseline.deviceInfo),'请先读取当前键盘，配置与基线的固件信息必须一致。');
  if(profile.snapshot.parameters[1]===8)requireThat(profile.lightingMapping!=null,'逐键写入核对需要读取灯光映射。');
  const options={bank:0,transportSelector:0,chunkCapacity:56,beginRequired:true};
  const plan=profile.snapshot.parameters[1]===8
    ?planCustomLighting(profile,options)
    :typeof profile.windowsTemplateJSON==='string'
      ?planOfficialLighting(exportProfileWindowsLightingDraft(profile,JSON.parse(profile.windowsTemplateJSON)),baseline,profile.lightingMapping,options)
      :planBuiltInLighting(profile.snapshot,options);
  const target=officialLightingReadbackTarget(plan,baseline);
  const encodedBlackColorSlots=target.parameters[1]===8?[...new Set(lightingMappingSlots(profile.lightingMapping,profile.snapshot).filter(slot=>slot!=null))].sort((a,b)=>a-b).filter(slot=>(profile.lightingColorEncoding==='officialRGB'||(profile.lightingRawSlots??[]).includes(slot))&&profile.snapshot.colors.slice(slot*3,slot*3+3).some(byte=>byte!==0)&&target.colors.slice(slot*3,slot*3+3).every(byte=>byte===0)):null;
  const review={format:'CherryMacLightingDraftReview' ,version:1,hardwareReady:false,plan,original:clone(baseline),target,changedParameterOffsets:Array.from({length:56},(_,i)=>i).filter(i=>baseline.parameters[i]!==target.parameters[i]),changedColorSlots:Array.from({length:126},(_,i)=>i).filter(i=>!equal(baseline.colors.slice(i*3,i*3+3),target.colors.slice(i*3,i*3+3))),...(profile.lightingMapping?{lightingMapping:clone(profile.lightingMapping)}:{}),...(encodedBlackColorSlots!==null?{encodedBlackColorSlots}:{})};
  if(target.parameters[1]===8){const rawDraft=clone(profile);rawDraft.snapshot.parameters[0]=target.parameters[0];review.rawLightingMetadata=captureRawLightingMetadata(rawDraft,target);requireThat(review.rawLightingMetadata!==null,'无法保存与逐键计划对应的原始配色，请重新准备。');}
  return review;
}
export function planOfficialLighting(template,baseline,lightingMapping,{bank,transportSelector,chunkCapacity,beginRequired}){
  validateSnapshot(baseline,true);
  requireThat(Number.isInteger(bank)&&bank>=0&&bank<=127&&[0,1].includes(transportSelector)&&Number.isInteger(chunkCapacity)&&chunkCapacity>=1&&chunkCapacity<=56&&typeof beginRequired==='boolean','配置地址、传输分支或报告容量超出离线计划范围。');
  if(lightingMapping!=null)lightingMappingSlots(lightingMapping,baseline);
  const parameters=prepareOfficialLightingParameters(template,bank);
  requireThat(modes.some(([code])=>code===parameters.head[1]),'此灯效不在本型号已核对的模式列表中。');
  let colors=null;
  if(parameters.head[1]===8){requireThat(lightingMapping!=null,'官方逐键颜色计划需要有效 LED 映射。');colors=prepareOfficialCustomColors(template,baseline,lightingMapping);}
  return assembleLightingPlan(parameters,colors,{bank,transportSelector,chunkCapacity,beginRequired});
}
// Direct built-in editing reuses the confirmed sender without interpreting
// a brightness-scaled firmware RGB bank as an unscaled custom-color source.
export function newCustomLightingDraft(profile){
  validateProfile(profile);validateSnapshot(profile.snapshot,true);
  requireThat(profile.lightingMapping!=null,'请先读取键盘，取得 LED 映射。');lightingMappingSlots(profile.lightingMapping,profile.snapshot);
  const result=clone(profile);result.snapshot.colors=Array(378).fill(0);result.snapshot.parameters[1]=8;result.lightingColorEncoding='officialRGB';delete result.lightingRawSlots;
  validateProfile(result);return result;
}
// Official 509C00 clears the entire logical RGB table, retaining alpha/extras.
export function clearCustomLightingDraft(profile){
  const result=newCustomLightingDraft(profile);
  if(typeof result.windowsTemplateJSON==='string'){
    const root=JSON.parse(result.windowsTemplateJSON);validateWindowsTemplate(root,new TextEncoder().encode(result.windowsTemplateJSON).length);
    if(root.CustomLightMode!=null){
      const custom=root.CustomLightMode,groups=custom.LightColorInfo;
      requireThat(custom&&typeof custom==='object'&&!Array.isArray(custom)&&Array.isArray(groups)&&groups.length===1&&Array.isArray(groups[0])&&groups[0].length===126,'官方逐键颜色表无效，不能清空。');
      for(const color of groups[0]){requireThat(color&&typeof color==='object'&&!Array.isArray(color),'官方颜色项无效。');for(const name of ['Red','Green','Blue']){winInt(color[name],name,0,255);color[name]=0;}if(Object.hasOwn(color,'Alpha'))winInt(color.Alpha,'Alpha',0,255);}
      result.windowsTemplateJSON=JSON.stringify(root);requireThat(new TextEncoder().encode(result.windowsTemplateJSON).length<=1_000_000,'官方模板过大。');
    }
  }
  validateProfile(result);return result;
}
function editorLightingParameters(snapshot,{bank,transportSelector,chunkCapacity,beginRequired}){
  validateSnapshot(snapshot,true);
  requireThat(Number.isInteger(bank)&&bank>=0&&bank<=127&&[0,1].includes(transportSelector)&&Number.isInteger(chunkCapacity)&&chunkCapacity>=1&&chunkCapacity<=56&&typeof beginRequired==='boolean','配置地址、传输分支或报告容量超出离线计划范围。');
  const p=snapshot.parameters;
  requireThat(modes.some(([code])=>code===p[1])&&p[2]<=4&&p[3]<=4&&p[4]<=1&&p[5]<=1,'当前灯效参数超出本型号已核对范围，请先保存有效模式、亮度、速度和方向。');
  return {head:[bank,...p.slice(1,9)],lightOpenFlag:p[21]};
}
export function planBuiltInLighting(snapshot,options){
  const parameters=editorLightingParameters(snapshot,options);
  requireThat(parameters.head[1]!==8,'逐键配色需要新建配色或导入 Windows 官方原始配色。');
  return assembleLightingPlan(parameters,null,options);
}
export function planCustomLighting(profile,options){
  validateProfile(profile);const parameters=editorLightingParameters(profile.snapshot,options);
  requireThat(parameters.head[1]===8&&['officialRGB','hardwareRGB'].includes(profile.lightingColorEncoding),'请先读取已知存储色和 LED 映射，或新建／导入原始配色。');
  requireThat(profile.lightingMapping!=null,'逐键配色需要有效 LED 映射。');
  const slots=lightingMappingSlots(profile.lightingMapping,profile.snapshot),coefficient=OFFICIAL_BRIGHTNESS_COEFFICIENTS[parameters.head[2]],colors=profile.lightingColorEncoding==='officialRGB'?Array(378).fill(0):clone(profile.snapshot.colors);
  const rawSlots=profile.lightingColorEncoding==='officialRGB'?new Set(slots.filter(slot=>slot!=null)):new Set(profile.lightingRawSlots??[]);
  // Utility zeroes the color bank and only fills logical entries with LEDs.
  // Full official palettes start zeroed; stored-base drafts retain untouched bytes.
  // Only positions with known raw RGB receive host brightness encoding.
  for(const slot of rawSlots)for(let channel=0;channel<3;channel++)colors[slot*3+channel]=(profile.snapshot.colors[slot*3+channel]*coefficient)>>8;
  return assembleLightingPlan(parameters,colors,options);
}
function assembleLightingPlan(parameters,colors,{bank,transportSelector,chunkCapacity,beginRequired}){
  const finishCommand=transportSelector===1?0x82:2,flag=transportSelector===1?0:0x55;
  const chunks=(command,offset,flag,data)=>Array.from({length:Math.ceil(data.length/chunkCapacity)},(_,i)=>({command,offset:offset+i*chunkCapacity,flag,data:data.slice(i*chunkCapacity,(i+1)*chunkCapacity)}));
  const stage=(name,writes)=>({name,beginRequired,beginCommand:transportSelector===1?0x81:1,writes,finishCommand,finishDelayMilliseconds:10});
  const stages=[stage('parameters',[...chunks(6,bank*64,flag,parameters.head),...chunks(6,bank*64+21,flag,[parameters.lightOpenFlag]),...chunks(6,bank*64+24,flag,[1])])];
  if(colors!==null)stages.push(stage('customColors',chunks(transportSelector===1?0x8b:0x0b,bank*512,0,colors)));
  return {format:'CherryMacOfficialLightingPlan',version:2,hardwareReady:false,bank,transportSelector,chunkCapacity,stages};
}
// Offline rendering only; this object is never a transport authorization.
export function officialLightingReports(plan){
  requireThat(plan?.format==='CherryMacOfficialLightingPlan'&&plan.version===2&&plan.hardwareReady===false&&Number.isInteger(plan.bank)&&plan.bank>=0&&plan.bank<=127&&[0,1].includes(plan.transportSelector)&&Number.isInteger(plan.chunkCapacity)&&plan.chunkCapacity>=1&&plan.chunkCapacity<=56&&Array.isArray(plan.stages),'灯效候选计划格式无效。');
  const {bank,transportSelector,chunkCapacity}=plan,parameters=plan.stages[plan.defaultColorData==null?0:1];
  requireThat(parameters&&typeof parameters.beginRequired==='boolean'&&Array.isArray(parameters.writes)&&parameters.writes.length>=3,'灯效候选参数布局无效。');
  const head=parameters.writes.slice(0,-2).flatMap(w=>w.data),tail=parameters.writes.at(-2).data;
  requireThat(bytes(head,9)&&head[0]===bank&&modes.some(([code])=>code===head[1])&&head[2]<=4&&head[3]<=4&&head[4]<=1&&head[5]<=1&&bytes(tail,1),'灯效候选参数布局无效。');
  const beginCommand=transportSelector===1?0x81:1,finishCommand=transportSelector===1?0x82:2,flag=transportSelector===1?0:0x55;
  const chunks=(command,offset,flag,data)=>Array.from({length:Math.ceil(data.length/chunkCapacity)},(_,i)=>({command,offset:offset+i*chunkCapacity,flag,data:data.slice(i*chunkCapacity,(i+1)*chunkCapacity)}));
  const stage=(name,writes)=>({name,beginRequired:parameters.beginRequired,beginCommand,writes,finishCommand,finishDelayMilliseconds:10});
  const expected=[stage('parameters',[...chunks(6,bank*64,flag,head),...chunks(6,bank*64+21,flag,tail),...chunks(6,bank*64+24,flag,[1])])];
  if(plan.defaultColorData!=null){requireThat(bytes(plan.defaultColorData,378),'默认配色阶段长度无效。');expected.unshift(stage('defaultColors',chunks(transportSelector===1?0x8b:0x0b,bank*512,0,plan.defaultColorData)));}
  else if(head[1]===8){requireThat(plan.stages.length===2&&Array.isArray(plan.stages[1].writes),'缺少独立颜色阶段。');const colors=plan.stages[1].writes.flatMap(w=>w.data);requireThat(bytes(colors,378),'颜色阶段长度无效。');expected.push(stage('customColors',chunks(transportSelector===1?0x8b:0x0b,bank*512,0,colors)));}
  // Compare fields independent of JSON object property order.
  requireThat(plan.stages.length===expected.length&&plan.stages.every((s,i)=>{const e=expected[i];return s.name===e.name&&s.beginRequired===e.beginRequired&&s.beginCommand===e.beginCommand&&s.finishCommand===e.finishCommand&&s.finishDelayMilliseconds===e.finishDelayMilliseconds&&s.writes.length===e.writes.length&&s.writes.every((w,j)=>{const v=e.writes[j];return w.command===v.command&&w.offset===v.offset&&w.flag===v.flag&&equal(w.data,v.data);});}),'灯效候选计划的指令顺序或写入范围被修改。');
  const encode=(command,payload=[])=>{const b=Array(64).fill(0);b[0]=4;b[3]=command;b.splice(4,payload.length,...payload);const sum=b.slice(3).reduce((n,v)=>n+v,0);b[1]=sum&255;b[2]=sum>>8;return b;};
  return expected.flatMap((s,index)=>[...(s.beginRequired?[{stage:index,kind:'begin',delayMilliseconds:0,request:encode(s.beginCommand)}]:[]),...s.writes.map(w=>({stage:index,kind:'data',delayMilliseconds:0,request:encode(w.command,[w.data.length,w.offset&255,w.offset>>8,w.flag,...w.data])})),{stage:index,kind:'finish',delayMilliseconds:10,request:encode(s.finishCommand)}]);
}

const lightingConfigurationEqual=(a,b)=>['deviceInfo','keymap','parameters','colors','macroData'].every(field=>equal(a[field],b[field]));
// Restore payloads are reconstructed solely from retained raw original data.
export function lightingRestoreReports(recovery){
  requireThat(recovery?.format==='CherryMacLightingRestorePlan'&&recovery.version===1&&recovery.hardwareReady===false,'灯效恢复计划格式无效。');
  const {sourceRecord,before}=recovery;assessLightingRecoveryRecord(sourceRecord);
  const review=officialLightingRecoveryReview(sourceRecord.plan,sourceRecord.original,before);
  const encode=(command,payload=[])=>{const bytes=Array(64).fill(0);bytes[0]=4;bytes[3]=command;bytes.splice(4,payload.length,...payload);const sum=bytes.slice(3).reduce((n,v)=>n+v,0);bytes[1]=sum&255;bytes[2]=sum>>8;return bytes;};
  return sourceRecord.plan.stages.flatMap((stage,index)=>{
    const writes=review.restoreData.filter(write=>stage.writes.some(w=>w.command===write.command&&w.offset===write.offset));if(!writes.length)return [];
    return [...(stage.beginRequired?[{stage:index,kind:'begin',delayMilliseconds:0,request:encode(stage.beginCommand)}]:[]),...writes.map(w=>({stage:index,kind:'data',delayMilliseconds:0,request:encode(w.command,[w.data.length,w.offset&255,w.offset>>8,w.flag,...w.data])})),{stage:index,kind:'finish',delayMilliseconds:stage.finishDelayMilliseconds,request:encode(stage.finishCommand)}];
  });
}
export function reviewLightingRestoreProgress(recovery,current){
  const reports=lightingRestoreReports(recovery);validateSnapshot(current,true);
  let state=clone(recovery.before),count=0;const matchedWritePrefixes=[];
  if(lightingConfigurationEqual(state,current))matchedWritePrefixes.push(0);
  for(const report of reports.filter(r=>r.kind==='data')){
    const bytes=report.request;state=applyLightingCandidate(state,{command:bytes[3],offset:bytes[5]+bytes[6]*256,data:bytes.slice(8,8+bytes[4])});count++;
    if(lightingConfigurationEqual(state,current))matchedWritePrefixes.push(count);
  }
  requireThat(matchedWritePrefixes.length>0,'配置不是本次恢复的完整分块前缀，停止覆盖。');
  return {format:'CherryMacLightingRestoreProgress',version:1,hardwareReady:false,matchedWritePrefixes,configurationMatchesOriginal:lightingConfigurationEqual(current,recovery.sourceRecord.original)};
}
export function assessLightingRestoreAttempt(attempt){
  requireThat(attempt?.format==='CherryMacLightingRestoreAttempt'&&attempt.version===1&&attempt.hardwareReady===false&&typeof attempt.operationID==='string'&&/^[A-Za-z0-9_.-]{1,128}$/.test(attempt.operationID)&&typeof attempt.failure==='string'&&new TextEncoder().encode(attempt.failure).length<=4096,'恢复执行记录格式无效。');
  const initial=reviewLightingRestoreProgress(attempt.recovery,attempt.started),packets=initial.configurationMatchesOriginal?[]:lightingRestoreReports(attempt.recovery),traceReview=reviewLightingReportTrace(packets,attempt.trace);
  let configurationMatchesOriginal=false,recoveryStatus='unavailable';
  if(attempt.current!=null){validateSnapshot(attempt.current,true);configurationMatchesOriginal=lightingConfigurationEqual(attempt.current,attempt.recovery.sourceRecord.original);try{reviewLightingRestoreProgress(attempt.recovery,attempt.current);recoveryStatus=configurationMatchesOriginal?'unchanged':'available';}catch{recoveryStatus='unrecognized';}}
  const status=attempt.failure||traceReview.status==='failed'?'failed':traceReview.status!=='complete'?'incomplete':!configurationMatchesOriginal?'readbackMismatch':initial.configurationMatchesOriginal?'alreadyMatched':'readbackMatched';
  return {format:'CherryMacLightingRestoreAssessment',version:1,hardwareReady:false,traceReview,configurationMatchesOriginal,status,recoveryStatus};
}
export async function executeLightingRestore(recovery,{source,operationID=globalThis.crypto.randomUUID(),assertCurrent,cancelled,read,backup,persist,clock,wait,exchange}){
  recovery=clone(recovery);lightingRestoreReports(recovery);
  const check=async()=>{await assertCurrent();requireThat(!cancelled(),'灯效恢复已取消。');};
  await check();const started=await read(),initial=reviewLightingRestoreProgress(recovery,started),reports=initial.configurationMatchesOriginal?[]:lightingRestoreReports(recovery);
  const attempt={format:'CherryMacLightingRestoreAttempt',version:1,hardwareReady:false,operationID,recovery,started:clone(started),trace:{format:'CherryMacLightingTrace',version:1,source,entries:[]},current:null,failure:''};
  assessLightingRestoreAttempt(attempt);await backup(clone(started));await persist(clone(attempt));await check();
  const verified=await read();validateSnapshot(verified,true);requireThat(lightingConfigurationEqual(started,verified),'恢复备份后配置发生变化，未发送。');
  for(const report of reports){
    try{await check();await wait(report.delayMilliseconds);await check();}catch(error){attempt.failure=String(error.message||error);break;}
    const entry={request:clone(report.request),sentMilliseconds:clock()};attempt.trace.entries.push(entry);assessLightingRestoreAttempt(attempt);await persist(clone(attempt));
    try{await check();entry.reply=Array.from(await exchange(clone(report.request)));}catch(error){entry.error=String(error.message||error);}
    entry.endedMilliseconds=clock();const assessment=assessLightingRestoreAttempt(attempt);await persist(clone(attempt));
    if(assessment.traceReview.status==='failed'){attempt.failure=entry.error||'恢复回复校验失败。';break;}
  }
  try{await assertCurrent();const current=await read();validateSnapshot(current,true);await assertCurrent();attempt.current=clone(current);}catch(error){if(!attempt.failure)attempt.failure=String(error.message||error);}
  if(!attempt.failure&&!assessLightingRestoreAttempt(attempt).configurationMatchesOriginal)attempt.failure='恢复读回与原始备份不一致。';
  assessLightingRestoreAttempt(attempt);await persist(clone(attempt));return attempt;
}
export function lightingRestorePlanFromRecord(record){
  let recovery,state;
  if(record?.format==='CherryMacLightingRestoreAttempt'){
    state=assessLightingRestoreAttempt(record).recoveryStatus;recovery=clone(record.recovery);
  }else{
    state=assessLightingRecoveryRecord(record).recoveryStatus;requireThat(record.current!=null,'记录没有完整读回，不能生成恢复计划。');
    recovery={format:'CherryMacLightingRestorePlan',version:1,hardwareReady:false,sourceRecord:clone(record),before:clone(record.current)};
  }
  requireThat(['available','unchanged'].includes(state),state==='unrecognized'?'记录包含范围外或无法识别的变化，不能生成恢复计划。':'记录没有完整读回，不能生成恢复计划。');
  lightingRestoreReports(recovery);return recovery;
}
export function assessLightingRecoveryRecord(record){
  requireThat(record?.format==='CherryMacLightingRecoveryRecord'&&record.version===1&&record.hardwareReady===false&&typeof record.operationID==='string'&&/^[A-Za-z0-9_.-]{1,128}$/.test(record.operationID)&&typeof record.failure==='string'&&new TextEncoder().encode(record.failure).length<=4096,'灯效恢复记录格式无效。');
  const target=officialLightingReadbackTarget(record.plan,record.original),traceReview=reviewOfficialLightingTrace(record.plan,record.trace);
  let readbackMatches=false,recoveryStatus='unavailable',matchedWritePrefixes=[],restoreData=[];
  if(record.current!=null){
    validateSnapshot(record.current,true);readbackMatches=lightingConfigurationEqual(record.current,target);
    try{const recovery=officialLightingRecoveryReview(record.plan,record.original,record.current);recoveryStatus=recovery.requiresRecovery?'available':'unchanged';matchedWritePrefixes=recovery.matchedWritePrefixes;restoreData=recovery.restoreData;}catch{recoveryStatus='unrecognized';}
  }
  const status=record.failure||traceReview.status==='failed'?'failed':traceReview.status!=='complete'?'incomplete':readbackMatches?'readbackMatched':'readbackMismatch';
  return {format:'CherryMacLightingRecordAssessment',version:1,hardwareReady:false,operationID:record.operationID,status,traceReview,readbackMatches,recoveryStatus,matchedWritePrefixes,restoreData};
}
// Injectable transaction; no import or connection to the WebHID sender.
export async function executeOfficialLightingCandidate(plan,baseline,{source,operationID=globalThis.crypto.randomUUID(),assertCurrent,cancelled,read,backup,persist,clock,wait,exchange}){
  plan=clone(plan);baseline=clone(baseline);
  const reports=officialLightingReports(plan),target=officialLightingReadbackTarget(plan,baseline);
  const trace={format:'CherryMacLightingTrace',version:1,source,entries:[]};reviewOfficialLightingTrace(plan,trace);
  const record=(current=null,failure='')=>({format:'CherryMacLightingRecoveryRecord',version:1,hardwareReady:false,operationID,plan:clone(plan),original:clone(baseline),trace:clone(trace),current:clone(current),failure});
  assessLightingRecoveryRecord(record());
  const check=async()=>{await assertCurrent();requireThat(!cancelled(),'灯效流程已取消。');};
  await check();const fresh=await read();validateSnapshot(fresh,true);requireThat(lightingConfigurationEqual(fresh,baseline),'灯效基线已改变，请重新读取。');
  await backup(clone(fresh));await persist(record());await check();
  const afterBackup=await read();validateSnapshot(afterBackup,true);requireThat(lightingConfigurationEqual(afterBackup,baseline),'备份后配置发生变化，未发送灯效指令。');
  let failure='';
  for(const report of reports){
    try{await check();await wait(report.delayMilliseconds);await check();}catch(error){failure=String(error.message||error);break;}
    const entry={request:clone(report.request),sentMilliseconds:clock()};trace.entries.push(entry);
    reviewOfficialLightingTrace(plan,trace);await persist(record());
    try{await check();entry.reply=Array.from(await exchange(clone(report.request)));}catch(error){entry.error=String(error.message||error);}
    entry.endedMilliseconds=clock();const assessment=reviewOfficialLightingTrace(plan,trace);await persist(record());
    if(assessment.status==='failed'){failure=entry.error||'灯效回复校验失败。';break;}
  }
  let current=null;
  try{await assertCurrent();const value=await read();validateSnapshot(value,true);await assertCurrent();current=clone(value);}catch(error){if(!failure)failure=String(error.message||error);}
  const matches=current!=null&&lightingConfigurationEqual(current,target);
  if(!failure&&!matches)failure='灯效读回与目标不一致。';
  const final=record(current,failure);assessLightingRecoveryRecord(final);await persist(clone(final));
  return {trace,current,readbackMatches:!failure&&matches,failure,record:final};
}
// Pure trace review. Accepted replies are not proof of flash persistence.
export function reviewOfficialLightingTrace(plan,trace){return reviewLightingReportTrace(officialLightingReports(plan),trace);}
function reviewLightingReportTrace(expected,trace){
  requireThat(trace?.format==='CherryMacLightingTrace'&&trace.version===1&&['simulation','usbTrace'].includes(trace.source)&&Array.isArray(trace.entries)&&trace.entries.length<=expected.length,'灯效日志格式无效。');
  let acceptedReports=0,previousEnd=0,status='incomplete',failedIndex=-1;
  trace.entries.forEach((entry,index)=>{
    const report=expected[index],last=index===trace.entries.length-1;
    requireThat(equal(entry.request,report.request)&&Number.isSafeInteger(entry.sentMilliseconds)&&entry.sentMilliseconds>=previousEnd&&entry.sentMilliseconds-previousEnd>=report.delayMilliseconds,'灯效日志指令、顺序或结束等待时间不匹配。');
    if(entry.endedMilliseconds!=null){
      requireThat(Number.isSafeInteger(entry.endedMilliseconds)&&entry.endedMilliseconds>=entry.sentMilliseconds&&(entry.reply!=null)!==(entry.error!=null),'灯效日志回复或时钟无效。');previousEnd=entry.endedMilliseconds;
      if(entry.error!=null){requireThat(typeof entry.error==='string'&&entry.error.trim().length>0&&last,'灯效日志在失败后仍继续发送。');status='failed';failedIndex=index;}
      else {
        const reply=entry.reply,request=report.request,sum=request.slice(3).reduce((n,v)=>n+v,0);
        const valid=bytes(reply,64)&&reply[0]===4&&reply[3]===request[3]&&equal(reply.slice(4,8),request.slice(4,8))&&reply[7]!==255&&reply[7]!==254&&reply[1]===(sum&255)&&reply[2]===(sum>>8);
        if(valid)acceptedReports++;else{requireThat(last,'灯效日志在无效回复后仍继续发送。');status='failed';failedIndex=index;}
      }
    }else requireThat(entry.reply==null&&entry.error==null&&last,'灯效日志缺少回复后仍继续发送。');
  });
  if(acceptedReports===expected.length)status='complete';
  return {format:'CherryMacLightingTraceReview',version:1,hardwareReady:false,source:trace.source,status,acceptedReports,expectedReports:expected.length,failedIndex};
}
const applyLightingCandidate=(snapshot,write)=>{const result=clone(snapshot),field=write.command===6?'parameters':'colors';result[field].splice(write.offset,write.data.length,...write.data);return result;};
export function officialLightingReadbackTarget(plan,baseline){
  officialLightingReports(plan);validateSnapshot(baseline,true);
  requireThat(plan.bank===0&&baseline.parameters[0]===0,'读回模型仅支持有完整基线的配置 0，不能推断其他配置区。');
  return plan.stages.flatMap(s=>s.writes).reduce(applyLightingCandidate,clone(baseline));
}
export function officialLightingRecoveryReview(plan,original,current){
  officialLightingReadbackTarget(plan,original);validateSnapshot(current,true);
  const writes=plan.stages.flatMap(s=>s.writes),matchedWritePrefixes=[];let state=clone(original);
  if(lightingConfigurationEqual(current,state))matchedWritePrefixes.push(0);
  writes.forEach((write,index)=>{state=applyLightingCandidate(state,write);if(lightingConfigurationEqual(current,state))matchedWritePrefixes.push(index+1);});
  requireThat(matchedWritePrefixes.length>0,'当前配置不是本次原表／目标或完整分块前缀，停止自动恢复分析。');
  const restoreData=writes.flatMap(write=>{const field=write.command===6?'parameters':'colors',data=original[field].slice(write.offset,write.offset+write.data.length),now=current[field].slice(write.offset,write.offset+write.data.length);return equal(data,now)?[]:[{command:write.command,offset:write.offset,flag:write.flag,data}];});
  return {format:'CherryMacLightingRecoveryReview',version:1,hardwareReady:false,matchedWritePrefixes,requiresRecovery:!lightingConfigurationEqual(current,original),restoreData};
}

export function prepareOfficialLightingParameters(template,bank){
  validateWindowsTemplate(template,new TextEncoder().encode(JSON.stringify(template)).length);
  requireThat(Number.isInteger(bank)&&bank>=0&&bank<=255&&template.LightInfo,'需要完整官方灯效参数和可表示为单字节的配置编号。');
  const light=template.LightInfo,selected=winInt(light.SelectItem,'SelectItem',0,24);
  const head=[bank,MODE_CODES[selected],winInt(light.Light,'Light',0,4),4-winInt(light.Speed,'Speed',0,4),winInt(light.Fx,'Fx',0,1),winLightFlag(light.MultiColor,'MultiColor'),...['Red','Green','Blue'].map(name=>winInt(light[name],name,0,255))];
  return {head,lightOpenFlag:winLightFlag(light.LightOpenFlag,'LightOpenFlag',255)};
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
  constructor({timing='actual',fixedMilliseconds=0,startedMilliseconds,maximumEvents=762}){
    requireThat(['actual','fixed','ignore'].includes(timing)&&Number.isInteger(fixedMilliseconds)&&fixedMilliseconds>=0&&fixedMilliseconds<=60000&&Number.isSafeInteger(startedMilliseconds)&&startedMilliseconds>=0,'录制间隔或时钟无效。');
    requireThat(Number.isInteger(maximumEvents)&&maximumEvents>=2&&maximumEvents<=762,'录制事件上限无效。');
    this.maximumEvents=maximumEvents;this.timing=timing;this.fixedMilliseconds=fixedMilliseconds;this.lastMilliseconds=startedMilliseconds;this.active=true;this.steps=[];this.held=new Set();
  }
  observe({usage,kind,pressed,milliseconds,repeatEvent=false}){
    requireThat(this.active,'录制已停止。');
    requireThat(Number.isSafeInteger(milliseconds)&&milliseconds>=this.lastMilliseconds&&typeof pressed==='boolean'&&(kind==null||kind==='mouse')&&Number.isInteger(usage)&&(kind==='mouse'?[1,2,4,8,16].includes(usage):usage>=4&&usage<=231),'录制事件或时钟无效。');
    const identity=`${kind==='mouse'?'mouse':'key'}:${usage}`;
    if(repeatEvent||(pressed?this.held.has(identity):!this.held.has(identity)))return;
    requireThat(this.steps.length<this.maximumEvents,`本次录制最多 ${this.maximumEvents} 个事件，请取消或缩短操作。`);
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
    requireThat(macro.steps.length>0&&!macro.steps.some(macroStepIsMovement),'空宏或位移宏不能通过当前按键观察判定执行成功，请使用独立触发／位移验收。');
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
  const names=macroStorageNames(profile);const name=index=>names[index]??next[index].name;
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
function macroRemovalRecord(profile,slot,mode){
  requireThat(Number.isInteger(slot)&&slot>=0&&slot<126&&![6,71].includes(slot),'内部键不能解除宏绑定。');
  requireThat(['disabled','factory'].includes(mode),'请选择解绑后的按键功能。');if(mode==='disabled')return [0x20,0,0];
  requireThat(profile.lightingMapping,'恢复默认功能需要读取到的完整默认键位表。');lightingMappingSlots(profile.lightingMapping,profile.snapshot);
  const record=profile.lightingMapping.factoryKeymap.slice(slot*3,slot*3+3);
  requireThat(record[0]===0x20&&(record[2]===0||record[2]>=4&&record[2]<224)||record[0]===0x30,'此按键的默认记录尚未支持，不能猜测默认功能。');return record;
}
export function removeMacro(profile,name,mode='disabled'){
  validateProfile(profile);requireThat(profile.macroBindings!=null,'原硬件宏尚未解码，不能删除。');
  requireThat(profile.macros.some(m=>sameMacroName(m.name,name)),'请选择已保存的宏。');const p=clone(profile);
  for(const [slot,binding] of Object.entries(p.macroBindings))if(sameMacroName(binding,name)){
    p.snapshot.keymap.splice(Number(slot)*3,3,...macroRemovalRecord(p,Number(slot),mode));delete p.macroBindings[slot];if(p.macroModes)delete p.macroModes[slot];
  }
  p.macros=p.macros.filter(m=>!sameMacroName(m.name,name));p.snapshot=resolveMacros(p);return p;
}
export function unassignMacro(profile,slot,mode='disabled'){
  validateProfile(profile);requireThat(Object.hasOwn(profile.macroBindings??{},slot),'所选键没有宏绑定。');const p=clone(profile);
  p.snapshot.keymap.splice(Number(slot)*3,3,...macroRemovalRecord(p,Number(slot),mode));delete p.macroBindings[slot];if(p.macroModes)delete p.macroModes[slot];
  p.snapshot=resolveMacros(p);return p;
}
export function clearMacros(profile,mode='disabled'){
  validateProfile(profile);requireThat(profile.macroBindings!=null,'原硬件宏尚未解码，不能清空。');const p=clone(profile);
  for(const slot of Object.keys(p.macroBindings))p.snapshot.keymap.splice(Number(slot)*3,3,...macroRemovalRecord(p,Number(slot),mode));
  p.macros=[];p.macroBindings={};p.macroModes={};p.snapshot=resolveMacros(p);return p;
}

// Editor-only raw RGB provenance, separate from verified hardware backups.
export function validateRawLightingMetadata(value){
  requireThat(value?.format==='CherryMacRawLightingMetadata'&&[1,2].includes(value.version)&&bytes(value.rawColors,378)&&(value.version===1?value.rawSlots==null:Array.isArray(value.rawSlots)),'本地原始配色资料无效。');
  validateSnapshot(value.snapshot,true);lightingMappingSlots(value.lightingMapping,value.snapshot);
  requireThat(value.snapshot.parameters[1]===8,'本地配色资料不是逐键模式。');
  const draft={format:'CherryMacProfile',version:1,snapshot:clone(value.snapshot),macros:[],lightingMapping:clone(value.lightingMapping),lightingColorEncoding:value.version===1?'officialRGB':'hardwareRGB',...(value.version===2?{lightingRawSlots:clone(value.rawSlots)}:{})};
  draft.snapshot.colors=clone(value.rawColors);
  const plan=planCustomLighting(draft,{bank:0,transportSelector:0,chunkCapacity:56,beginRequired:true});
  requireThat(equal(officialLightingReadbackTarget(plan,value.snapshot).colors,value.snapshot.colors),'本地原始配色与保存的硬件颜色不一致。');
}
export function captureRawLightingMetadata(profile,current){
  validateProfile(profile);validateSnapshot(current,true);
  if(!['officialRGB','hardwareRGB'].includes(profile.lightingColorEncoding)||current.parameters[1]!==8||profile.lightingMapping==null)return null;
  // Matching local editor provenance is separate from authorizing a write;
  // do not require an unrelated firmware commit marker to have value 1.
  if(!equal(profile.snapshot.deviceInfo,current.deviceInfo)||![0,1,2,3,4,5,6,7,8,21].every(offset=>profile.snapshot.parameters[offset]===current.parameters[offset]))return null;
  const plan=planCustomLighting(profile,{bank:0,transportSelector:0,chunkCapacity:56,beginRequired:true});
  if(!equal(officialLightingReadbackTarget(plan,current).colors,current.colors))return null;
  const value={format:'CherryMacRawLightingMetadata',version:1,snapshot:clone(current),rawColors:clone(profile.snapshot.colors),lightingMapping:clone(profile.lightingMapping)};
  if(profile.lightingColorEncoding==='hardwareRGB'){value.version=2;value.rawSlots=clone(profile.lightingRawSlots??[]);}
  validateRawLightingMetadata(value);return value;
}
export function adoptRawLightingMetadata(profile,value){
  validateRawLightingMetadata(value);validateProfile(profile);
  if(!equal(profile.lightingMapping,value.lightingMapping)||!['deviceInfo','parameters','colors'].every(field=>equal(profile.snapshot[field],value.snapshot[field])))return null;
  const next=clone(profile);next.snapshot.colors=clone(value.rawColors);next.lightingColorEncoding=value.version===1?'officialRGB':'hardwareRGB';if(value.version===2){next.lightingRawSlots=clone(value.rawSlots);next.version=2;}else delete next.lightingRawSlots;validateProfile(next);return next;
}

// Offline official layout only. The production writer uses resolveMacros and
// cannot consume this object as a write authorization or hardware snapshot.
export function prepareOfficialMacroStorage({macros,bindings,modes={},factoryKeymap,deviceInfo,headerReserved=[]}){
  requireThat(bytes(factoryKeymap,378)&&bytes(deviceInfo,34)&&deviceInfo[6]===24&&(headerReserved.length===0||bytes(headerReserved,10)),'官方宏布局需要本型号完整默认键位表、容量信息和有效保留数据。');
  requireThat(Array.isArray(macros)&&bindings&&typeof bindings==='object'&&!Array.isArray(bindings)&&modes&&typeof modes==='object'&&!Array.isArray(modes),'宏库或绑定结构无效。');
  const editorEventLimit=Math.trunc((deviceInfo[6]*128-22)/4);
  macros.forEach(m=>validateMacroWithin(m,editorEventLimit));
  requireThat(new Set(macros.map(m=>macroNameKey(m.name))).size===macros.length,'宏名称不能重复。');
  for(const slot of Object.keys(modes))requireThat(Object.hasOwn(bindings,slot),'宏执行方式缺少对应绑定。');
  const logicalBySlot=new Map();
  FIRMWARE_LOGICAL_DEFAULTS.forEach((value,logical)=>{
    let slot=-1;for(let i=0;i<126;i++)if(((factoryKeymap[i*3]<<16)|(factoryKeymap[i*3+1]<<8)|factoryKeymap[i*3+2])===value){slot=i;break;}
    if(slot<0)return;
    requireThat(!logicalBySlot.has(slot)||!Object.hasOwn(bindings,slot),'默认键位映射含重复逻辑位置，停止宏转换。');
    if(!logicalBySlot.has(slot))logicalBySlot.set(slot,logical);
  });
  const ordered=Object.keys(bindings).map(key=>{
    requireThat(/^(0|[1-9]\d*)$/.test(key)&&Number(key)<126&&![6,71].includes(Number(key))&&logicalBySlot.has(Number(key))&&macros.some(m=>sameMacroName(m.name,bindings[key])),'宏绑定在固件默认表中没有唯一可配置位置。');
    validatePlayback(modes[key]??{mode:'count',count:1});return Number(key);
  }).sort((a,b)=>logicalBySlot.get(a)-logicalBySlot.get(b));
  if(!ordered.length)return {hardwareReady:false,editorEventLimit,usedBytes:0,records:[],bank:null};
  const indices=ordered.map(slot=>macros.findIndex(m=>sameMacroName(m.name,bindings[slot])));
  const total=16+ordered.length*6+indices.reduce((sum,index)=>sum+macros[index].steps.length*4,0);
  requireThat(total<=3071,'已绑定宏超过存储容量；同一宏绑定多个键会分别占用空间。');
  const bank=Array(3071).fill(0),records=[];const word=(offset,value)=>{bank[offset]=value&255;bank[offset+1]=value>>8;};
  bank[0]=0xaa;bank[1]=0x55;word(2,total);word(4,ordered.length);
  if(headerReserved.length)bank.splice(6,10,...headerReserved);
  let cursor=16+ordered.length*2;
  ordered.forEach((slot,ordinal)=>{
    const libraryIndex=indices[ordinal],m=macros[libraryIndex],p=modes[slot]??{mode:'count',count:1};
    const binding=p.mode==='count'?(p.count===1?[0x70,ordinal,0]:[0x71,ordinal,p.count]):[0x70,ordinal,p.mode==='held'?1:2];
    word(16+ordinal*2,cursor);word(cursor,m.steps.length);
    if(m.hardwareReserved)bank.splice(cursor+2,2,...m.hardwareReserved);
    m.steps.forEach((s,j)=>{const modifier=s.kind==null&&s.usage>=224;bank.splice(cursor+4+j*4,4,s.delayMilliseconds&255,s.delayMilliseconds>>8,(s.kind==='mouseX'?4:s.kind==='mouseY'?5:s.kind==='mouse'?1:modifier?9:10)|(s.pressed?128:0),modifier?1<<(s.usage-224):s.usage);});
    records.push({logicalIndex:logicalBySlot.get(slot),physicalSlot:slot,libraryIndex,ordinal,offset:cursor,eventCount:m.steps.length,binding});cursor+=4+m.steps.length*4;
  });
  return {hardwareReady:false,editorEventLimit,usedBytes:total,records,bank};
}

// This record preserves names and unbound drafts across per-binding storage.
// It is neither a HID authorization nor proof of an actual device transaction.
export function prepareOfficialMacroDraftReceipt({before,factoryKeymap,macros,bindings,modes={},removedKeyAssignments=null}){
  validateSnapshot(before);requireThat(bytes(before.macroData,3071),'保存宏草稿对应关系需要完整原始宏区。');
  const headerReserved=before.macroData[0]===0xaa&&before.macroData[1]===0x55?before.macroData.slice(6,16):[];
  const layout=prepareOfficialMacroStorage({macros,bindings,modes,factoryKeymap,deviceInfo:before.deviceInfo,headerReserved}),expected=clone(before);
  if(removedKeyAssignments!=null){
    requireThat(typeof removedKeyAssignments==='object'&&!Array.isArray(removedKeyAssignments),'解绑后的按键记录无效。');
    for(const [key,record] of Object.entries(removedKeyAssignments)){
      const slot=Number(key);requireThat(/^(0|[1-9]\d*)$/.test(key)&&slot<126&&![6,71].includes(slot)&&!Object.hasOwn(bindings,slot)&&[0x70,0x71].includes(before.keymap[slot*3])&&bytes(record,3)&&((record[0]===0x20&&(record[2]===0||record[2]>=4&&record[2]<224))||record[0]===0x30),'解绑后的按键记录无效或超出宏写入范围。');
    }
  }
  for(let slot=0;slot<126;slot++)if([0x70,0x71].includes(before.keymap[slot*3])&&!Object.hasOwn(bindings,slot)){
    requireThat(![6,71].includes(slot),'原宏覆盖内部键，停止转换。');expected.keymap.splice(slot*3,3,...(removedKeyAssignments?.[slot]??[0x20,0,0]));
  }
  for(const r of layout.records)expected.keymap.splice(r.physicalSlot*3,3,...r.binding);
  if(layout.bank!==null)expected.macroData.splice(0,layout.usedBytes,...layout.bank.slice(0,layout.usedBytes));
  return clone({format:'CherryMacOfficialMacroDraftReceipt',version:1,hardwareReady:false,before,factoryKeymap,macros,bindings,modes,...(removedKeyAssignments&&Object.keys(removedKeyAssignments).length?{removedKeyAssignments}:{}),layout,expected});
}
export function validateOfficialMacroDraftReceipt(receipt){
  requireThat(receipt?.format==='CherryMacOfficialMacroDraftReceipt'&&receipt.version===1&&receipt.hardwareReady===false,'官方宏草稿记录格式或版本无效。');
  const rebuilt=prepareOfficialMacroDraftReceipt(receipt);
  requireThat(canonicalJSON(rebuilt)===canonicalJSON(receipt),'宏草稿记录与重新生成的绑定、存储数据不一致。');
}
export function reconcileOfficialMacroDraftReceipt(receipt,observed,factoryKeymap){
  validateOfficialMacroDraftReceipt(receipt);validateSnapshot(observed);
  requireThat(equal(factoryKeymap,receipt.factoryKeymap)&&equal(observed.deviceInfo,receipt.expected.deviceInfo)&&equal(observed.keymap,receipt.expected.keymap)&&equal(observed.macroData,receipt.expected.macroData),'读回配置与官方宏草稿记录不一致，未采用宏名称或合并草稿。');
  if(receipt.layout.bank!==null){
    const decoded=decodeBankWithin(observed.macroData,126,receipt.layout.editorEventLimit);
    requireThat(decoded.length===receipt.layout.records.length,'宏读回记录数量不一致。');
    decoded.forEach((m,index)=>{const source=receipt.macros[receipt.layout.records[index].libraryIndex];const events=steps=>steps.map(s=>[s.usage,s.pressed,s.delayMilliseconds,s.kind??null]);requireThat(equal(events(m.steps),events(source.steps))&&equal(m.hardwareReserved??[0,0],source.hardwareReserved??[0,0]),'宏事件或保留数据读回不一致。');});
  }
  return clone({hardwareReady:false,configurationMatches:true,snapshot:observed,macros:receipt.macros,bindings:receipt.bindings,modes:receipt.modes,records:receipt.layout.records});
}

export function officialMacroReceipt(profile,before=profile.snapshot){
  validateProfile(profile);requireThat(equal(profile.snapshot.deviceInfo,before.deviceInfo),'配置来自不同固件，请重新读取。');
  requireThat(profile.lightingMapping&&equal(profile.lightingMapping.deviceInfo,before.deviceInfo),'官方宏写入需要重新读取完整默认键位映射。');
  requireThat(profile.macroBindings!=null,'未知宏不能覆盖，请先读取完整配置。');
  const removedKeyAssignments={};
  for(let slot=0;slot<126;slot++)if([0x70,0x71].includes(before.keymap[slot*3])&&!Object.hasOwn(profile.macroBindings,slot)&&![0x70,0x71].includes(profile.snapshot.keymap[slot*3]))removedKeyAssignments[slot]=profile.snapshot.keymap.slice(slot*3,slot*3+3);
  return prepareOfficialMacroDraftReceipt({before,factoryKeymap:profile.lightingMapping.factoryKeymap,macros:profile.macros,bindings:profile.macroBindings,modes:profile.macroModes??{},removedKeyAssignments:Object.keys(removedKeyAssignments).length?removedKeyAssignments:null});
}
export function macroStorageUsage(profile){
  if(profile.macroStorageLayout==='officialBindings')return officialMacroReceipt(profile).layout.usedBytes;
  const bank=encodeBank(profile.macros);return profile.macros.length?bank[2]|bank[3]<<8:0;
}
export function macroStorageNames(profile){
  if(profile.macroStorageLayout==='officialBindings')return officialMacroReceipt(profile).layout.records.map(r=>profile.macros[r.libraryIndex].name);
  return profile.macros.map(m=>m.name);
}

// Extracted RGB facts from official color_option_info.config; 20 slots retain duplicates.
export const officialColorPresets=Object.freeze(["#FF0000", "#FF7200", "#FFF005", "#00D70F", "#0099FF", "#3153FF", "#5E01D2", "#FF16A9", "#FF008A", "#FFA800", "#8DFF8D", "#3DEFFF", "#004891", "#FFFFFF", "#FFFFFF", "#3153FF", "#5E01D2", "#EE00F1", "#FF008A", "#FFA800"]);
export function defaultLightingColorLibrary(){return {format:'CherryMacLightingColorLibrary',version:1,colors:[...officialColorPresets]};}
export function validateLightingColorLibrary(value){
  requireThat(value&&value.format==='CherryMacLightingColorLibrary'&&value.version===1&&Array.isArray(value.colors)&&value.colors.length===20,'颜色收藏必须包含 20 个色卡。');
  requireThat(value.colors.every(color=>typeof color==='string'&&/^#[0-9A-F]{6}$/.test(color)),'收藏颜色格式无效。');return clone(value);
}

export function parseLightingColorLibrary(text){
  requireThat(typeof text==='string'&&new TextEncoder().encode(text).length<=4096,'颜色收藏文件不能超过 4 KB。');return validateLightingColorLibrary(JSON.parse(text));
}
export function paintLightingProfile(profile,selection,pattern,start,end){
  validateProfile(profile);requireThat(['officialRGB','hardwareRGB'].includes(profile.lightingColorEncoding),'颜色来源未知，请先读取键盘或导入已知配色。');
  const next=clone(profile);paint(next.snapshot,selection,pattern,start,end,next.lightingMapping);
  if(next.lightingColorEncoding==='hardwareRGB'){
    lightingMappingSlots(next.lightingMapping,next.snapshot);const raw=new Set(next.lightingRawSlots??[]);
    for(const key of keys.filter(key=>selection.has(key.id))){const slot=lightingColorSlot(next,key.slot);requireThat(slot!=null,'所选键没有有效 LED 映射。');raw.add(slot);}
    next.lightingRawSlots=[...raw].sort((a,b)=>a-b);next.version=2;
  }
  validateProfile(next);return next;
}

export function makeLightingEditorDraft(profile){
  const value={format:'CherryMacLightingEditorDraft',version:1,profile:portableProfile(profile)};validateLightingEditorDraft(value);return value;
}
export function validateLightingEditorDraft(value){
  requireThat(value?.format==='CherryMacLightingEditorDraft'&&value.version===1,'灯效草稿格式不受支持。');validateProfile(value.profile);
  requireThat(value.profile.snapshot.colors!=null,'灯效草稿缺少完整配色。');
  if(value.profile.snapshot.parameters[1]===8)requireThat(value.profile.lightingMapping!=null&&value.profile.lightingColorEncoding!=null,'逐键草稿缺少映射或颜色来源。');
  requireThat(new TextEncoder().encode(JSON.stringify(value)).length<=3_000_000,'灯效草稿超过 3 MB，请导出配置文件。');
}
export function mergeLightingEditorDraft(value,current){
  validateLightingEditorDraft(value);validateProfile(current);const saved=value.profile;
  requireThat(equal(saved.snapshot.deviceInfo,current.snapshot.deviceInfo)&&equal(saved.lightingMapping??null,current.lightingMapping??null),'灯效草稿与当前型号或映射不同，请先读取同一键盘再载入。');
  const next=clone(current);for(const offset of [1,2,3,4,5,6,7,8,21])next.snapshot.parameters[offset]=saved.snapshot.parameters[offset];
  next.snapshot.colors=clone(saved.snapshot.colors);
  for(const field of ['lightingColorEncoding','lightingRawSlots']){if(saved[field]!=null)next[field]=clone(saved[field]);else delete next[field];}
  if(next.lightingRawSlots!=null)next.version=2;
  if(current.windowsTemplateJSON!=null&&saved.windowsTemplateJSON!=null){const root=JSON.parse(current.windowsTemplateJSON),donor=JSON.parse(saved.windowsTemplateJSON);if(root.LightInfo&&typeof root.LightInfo==='object'&&!Array.isArray(root.LightInfo)&&donor.LightInfo&&typeof donor.LightInfo==='object'&&!Array.isArray(donor.LightInfo))for(const name of ['SelectItem','Light','Speed','Fx','MultiColor','Red','Green','Blue','LightOpenFlag'])if(Object.hasOwn(donor.LightInfo,name))root.LightInfo[name]=clone(donor.LightInfo[name]);if(Object.hasOwn(donor,'CustomLightMode'))root.CustomLightMode=clone(donor.CustomLightMode);next.windowsTemplateJSON=JSON.stringify(root);}
  validateProfile(next);return next;
}
