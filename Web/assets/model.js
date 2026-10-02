import {SLOTS,WINDOWS_DEFAULTS,MEDIA_CODES,MODE_CODES} from './tables.js';
import {keys,modes} from './layout.js';
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
  requireThat(m&&typeof m.name==='string'&&m.name.trim()&&[...m.name].length<=80&&Array.isArray(m.steps)&&m.steps.length>0&&m.steps.length<=256,'宏名称或步骤数量无效。');
  const held=new Set();
  for(const s of m.steps){
    requireThat(Number.isInteger(s.usage)&&s.usage>=4&&s.usage<=231&&typeof s.pressed==='boolean'&&Number.isInteger(s.delayMilliseconds)&&s.delayMilliseconds>=0&&s.delayMilliseconds<=60000,'宏按键或延迟超出范围。');
    requireThat(s.pressed?!held.has(s.usage):held.has(s.usage),'宏的按下与松开必须一一对应。');
    if(s.pressed)held.add(s.usage);else held.delete(s.usage);
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
    const modifier=s.usage>=224;
    bank.splice(cursor+4+j*4,4,s.delayMilliseconds&255,s.delayMilliseconds>>8,(modifier?9:10)|(s.pressed?128:0),modifier?1<<(s.usage-224):s.usage);
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
      if(kind===10&&code<224)usage=code;
      else if(kind===9&&code>0&&(code&(code-1))===0)usage=224+Math.log2(code);
      else throw new Error('宏包含尚未支持的事件，原始数据仍保留。');
      m.steps.push({usage,pressed:!!(bank[o+2]&128),delayMilliseconds:word(o)});
    }
    validateMacro(m);macros.push(m);cursor=end;
  }return macros;
}
export function fromHardware(snapshot){
  validateSnapshot(snapshot);const p={format:'CherryMacProfile',version:1,snapshot:clone(snapshot),macros:[]};
  if(!snapshot.macroData)return p;
  p.macros=decodeBank(snapshot.macroData);p.macroBindings={};
  for(let slot=0;slot<126;slot++){const b=snapshot.keymap.slice(slot*3,slot*3+3);if([0x70,0x71].includes(b[0])){
    requireThat(b[0]===0x70&&b[2]===0&&b[1]<p.macros.length&&!([6,71].includes(slot)),'循环宏或内部绑定尚未支持，原始数据仍保留。');p.macroBindings[slot]=p.macros[b[1]].name;
  }}return p;
}
export function validateProfile(p){
  requireThat(p&&p.format==='CherryMacProfile'&&p.version===1&&Array.isArray(p.macros)&&p.macros.length<=32,'配置格式或版本不受支持。');validateSnapshot(p.snapshot);p.macros.forEach(validateMacro);
  requireThat(new Set(p.macros.map(m=>m.name)).size===p.macros.length,'宏名称不能重复。');
  if(p.macroBindings!=null){requireThat(typeof p.macroBindings==='object'&&!Array.isArray(p.macroBindings),'宏绑定结构无效。');
    for(const [slot,name] of Object.entries(p.macroBindings))requireThat(/^(0|[1-9]\d*)$/.test(slot)&&Number(slot)<126&&![6,71].includes(Number(slot))&&p.macros.some(m=>m.name===name),'宏绑定无效。');}
}
export function resolveMacros(p){
  validateProfile(p);requireThat(p.macroBindings!=null,'未知宏不能覆盖，请重新读取键盘。');const s=clone(p.snapshot);
  for(let slot=0;slot<126;slot++)if([0x70,0x71].includes(s.keymap[slot*3]))requireThat(Object.hasOwn(p.macroBindings,slot),'宏记录缺少绑定。');
  s.macroData=encodeBank(p.macros);for(const [slot,name] of Object.entries(p.macroBindings))s.keymap.splice(Number(slot)*3,3,0x70,p.macros.findIndex(m=>m.name===name),0);return s;
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
export function importWindows(root,baseline){
  validateSnapshot(baseline,true);requireThat(root['//']==='47'&&Array.isArray(root.KeyList)&&root.KeyList.length===126,'仅支持 Pokémon 型号 47 的 Windows 配置。');
  root.KeyList.forEach((k,i)=>requireThat(winInt(k?.DefaultAssignment,'DefaultAssignment',0,0xffffff)===WINDOWS_DEFAULTS[i],'Windows 键盘布局不匹配。'));
  for(const field of ['LightInfo','CustomLightMode'])requireThat(root[field]==null||(typeof root[field]==='object'&&!Array.isArray(root[field])),'Windows 灯效结构无效。');
  requireThat(root.ActionInfo==null||Array.isArray(root.ActionInfo),'Windows 动作结构无效。');
  const p=fromHardware(baseline),old=clone(p.macroBindings),actions=root.ActionInfo??[],imported=new Map(),physical=new Set(WINDOWS_DEFAULTS.map(physicalSlot));
  p.macroBindings=Object.fromEntries(Object.entries(old).filter(([slot])=>!physical.has(Number(slot))));
  const record=v=>{v=winInt(v,'按键动作',0,0xffffff);const b=[v>>16,(v>>8)&255,v&255];requireThat([0x20,0x30].includes(b[0]),'不支持此 Windows 按键动作。');return b;};
  root.KeyList.forEach((k,i)=>{
    const slot=physicalSlot(WINDOWS_DEFAULTS[i]);if(slot===undefined||[6,71].includes(slot))return;
    let b;if(winInt(k.ActionLink??0,'ActionLink',0,1)===0)b=record(k.Assignment);
    else{
      const index=winInt(k.ActionLinkIndex,'ActionLinkIndex',0,actions.length-1),a=actions[index],c=a?.ActionContent;requireThat(c&&typeof c==='object','Windows 动作引用无效。');
      const type=winInt(a.ActionType,'ActionType',0,4);
      if(type===1)b=record(c.ActionKey);
      else if(type===4){const code=MEDIA_CODES[winInt(c.ActionMedia,'ActionMedia',0,17)];b=[0x30,code&255,code>>8];}
      else if(type===2){
        if(!imported.has(index)){
          requireThat(winInt(c.ActionMacroType,'宏模式',0,2)===0&&winInt(c.ActionMacroLoopValue??1,'重复次数',1,255)===1&&winInt(c.ActionMacroFixTimeIsSelected??0,'固定延迟',0,1)===0,'仅支持单次、逐步延迟的键盘宏。');
          requireThat(Array.isArray(c.ActionMacroEvents),'Windows 宏事件无效。');
          const steps=c.ActionMacroEvents.map(e=>{const type=winInt(e.Type,'事件类型',0,127),button=winInt(e.Button,'按键',0,255);let usage;
            if(type===10&&button>=4&&button<224)usage=button;
            else if(type===9&&button>0&&(button&(button-1))===0)usage=224+Math.log2(button);
            else throw new Error('鼠标和滚动宏尚未支持。');requireThat(['down','up'].includes(e.Action),'宏按下／松开状态无效。');return {usage,pressed:e.Action==='down',delayMilliseconds:winInt(e.Delay,'延迟',0,60000)};});
          const stem=typeof a.ActionName==='string'&&a.ActionName.trim()?[...a.ActionName].slice(0,65).join(''):'导入宏';let name=stem,j=1;while(p.macros.some(m=>m.name===name))name=`${stem} (${j++})`;
          const macro={name,steps};validateMacro(macro);p.macros.push(macro);imported.set(index,name);
        }const name=imported.get(index);p.macroBindings[slot]=name;b=[0x70,p.macros.findIndex(m=>m.name===name),0];
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
