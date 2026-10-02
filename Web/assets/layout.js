import {SPECIAL, SLOTS} from './tables.js?v=0.2.0';
export const keys=[];
function add(id,label,usage,x,row,w=1,h=1,page=7){
  keys.push({id,label,usage,page,x:18+x*36,y:20+row*36,w:w*36-4,h:h*36-4,slot:SPECIAL[id]??SLOTS[usage]});
}
add('esc','Esc',41,0,0);add('cherry','CHERRY',null,1,0);
for(let i=1;i<=12;i++)add(`f${i}`,`F${i}`,57+i,2+i-1+Math.floor((i-1)/4)*.5,0);
[['print','截屏',70],['scroll','Scroll',71],['pause','Pause',72]].forEach(([id,l,u],i)=>add(id,l,u,15.5+i,0));
[['calculator','计算器',402],['mediaPrevious','上一曲',182],['mediaPlay','暂停',205],['mediaNext','下一曲',181]].forEach(([id,l,u],i)=>add(id,l,u,19+i,0,1,1,12));
[['`',53],['1',30],['2',31],['3',32],['4',33],['5',34],['6',35],['7',36],['8',37],['9',38],['0',39],['−',45],['=',46]].forEach(([l,u],i)=>add(`key${u}`,l,u,i,1.2));
add('backspace','Backspace',42,13,1.2,2);
function letters(text,x,row){[...text].forEach((l,i)=>add(`key${l.charCodeAt(0)-61}`,l,l.charCodeAt(0)-61,x+i,row));}
add('tab','Tab',43,0,2.2,1.5);letters('QWERTYUIOP',1.5,2.2);
add('key47','[',47,11.5,2.2);add('key48',']',48,12.5,2.2);add('key49','\\',49,13.5,2.2,1.5);
add('caps','Caps',null,0,3.2,1.75);letters('ASDFGHJKL',1.75,3.2);
add('key51',';',51,10.75,3.2);add('key52',"'",52,11.75,3.2);add('enter','Enter',40,12.75,3.2,2.25);
add('shiftL','Shift',null,0,4.2,2.25);letters('ZXCVBNM',2.25,4.2);
add('key54',',',54,9.25,4.2);add('key55','.',55,10.25,4.2);add('key56','/',56,11.25,4.2);add('shiftR','Shift',null,12.25,4.2,2.75);
['Ctrl','Win','Alt'].forEach((l,i)=>add(`modL${i}`,l,null,i*1.25,5.2,1.25));add('space','Space',44,3.75,5.2,6.25);
['Alt','Fn','Menu','Ctrl'].forEach((l,i)=>add(l==='Menu'?'modR3':i===3?'modR2':`modR${i}`,l,l==='Menu'?101:null,10+i*1.25,5.2,1.25));
[['insert','Ins',73],['home','Home',74],['pageUp','PgUp',75]].forEach(([id,l,u],i)=>add(id,l,u,15.5+i,1.2));
[['delete','Del',76],['end','End',77],['pageDown','PgDn',78]].forEach(([id,l,u],i)=>add(id,l,u,15.5+i,2.2));
add('up','↑',82,16.5,4.2);[['left','←',80],['down','↓',81],['right','→',79]].forEach(([id,l,u],i)=>add(id,l,u,15.5+i,5.2));
[['numLock','Num',83],['numDivide','/',84],['numMultiply','×',85],['numMinus','−',86]].forEach(([id,l,u],i)=>add(id,l,u,19+i,1.2));
[['num7','7',95],['num8','8',96],['num9','9',97]].forEach(([id,l,u],i)=>add(id,l,u,19+i,2.2));add('numPlus','+',87,22,2.2,1,2);
[['num4','4',92],['num5','5',93],['num6','6',94]].forEach(([id,l,u],i)=>add(id,l,u,19+i,3.2));
[['num1','1',89],['num2','2',90],['num3','3',91]].forEach(([id,l,u],i)=>add(id,l,u,19+i,4.2));
add('numEnter','Enter',88,22,4.2,1,2);add('num0','0',98,19,5.2,2);add('numDot','.',99,21,5.2);
export const editableSlots=new Set(keys.filter(k=>![6,71].includes(k.slot)).map(k=>k.slot));
export const modes=[[8,'自定义逐键颜色'],[0,'波纹'],[1,'光谱'],[2,'呼吸'],[10,'霓虹'],[12,'曲线'],[15,'折返'],[18,'放射'],[19,'扩散'],[21,'单点亮'],[3,'常亮'],[23,'闪电']];
export const usageNames=Object.fromEntries(keys.filter(k=>k.page===7&&k.usage).map(k=>[k.usage,k.label]));
Object.assign(usageNames,{224:'左 Ctrl',225:'左 Shift',226:'左 Option',227:'左 Command',228:'右 Ctrl',229:'右 Shift',230:'右 Option',231:'右 Command'});
export function describe(b){
  if(b[0]===0x20)return ['⌃','⇧','⌥','⌘'].filter((_,i)=>b[1]&[0x11,0x22,0x44,0x88][i]).join('')+(b[2]?(usageNames[b[2]]??`HID ${b[2]}`):b[1]?'':'禁用');
  if(b[0]===0x30)return ({402:'计算器',182:'上一曲',205:'播放 / 暂停',181:'下一曲',233:'音量增加',234:'音量降低',226:'静音'})[b[1]+(b[2]<<8)]??'媒体功能';
  if(b[0]===0x70)return `硬件宏 ${b[1]+1}`;
  return b[0]===0xa0?'键盘内部功能':b.map(x=>x.toString(16).padStart(2,'0')).join(' ');
}
export function demoSnapshot(){
  const s={format:'CherryMacHardware',version:1,vendorID:1130,productID:462,keymap:Array(378).fill(0),parameters:Array(56).fill(0),deviceInfo:Array(34).fill(0),colors:Array(378).fill(0),macroData:Array(3071).fill(0),createdAt:Date.now()/1000-978307200};
  s.deviceInfo[6]=24;s.parameters.splice(1,8,8,4,2,0,0,255,214,0);
  const mods={4:2,82:32,5:1,11:8,17:4,65:64,83:16};
  for(const k of keys){let b=k.page===12?[0x30,k.usage&255,k.usage>>8]:[0x20,mods[k.slot]??0,k.usage??(k.id==='caps'?57:0)];if([6,71].includes(k.slot))b=[0xa0,k.slot===6?3:1,0];s.keymap.splice(k.slot*3,3,...b);s.colors.splice(k.slot*3,3,255,214,0);}
  return s;
}
