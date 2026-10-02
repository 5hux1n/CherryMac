import {clone,equal,requireThat,validateSnapshot,decodeBank} from './model.js';
import {editableSlots,modes} from './layout.js';
import {packet,sleep} from './hid.js';
export const sameSnapshot=(a,b)=>['keymap','parameters','colors','macroData'].every(k=>equal(a[k],b[k]));
const slots=s=>Array.from({length:126},(_,i)=>i).filter(i=>[0x70,0x71].includes(s.keymap[i*3]));
function macroDuration(s,indices){const macros=decodeBank(s.macroData);let max=0;
  for(const i of indices){const b=s.keymap.slice(i*3,i*3+3);requireThat(b[0]===0x70&&b[2]===0&&b[1]<macros.length,'循环或未知宏绑定尚不支持写入。');max=Math.max(max,macros[b[1]].steps.reduce((n,s)=>n+s.delayMilliseconds,0));}return max;
}
export function validatePlan(wanted,before){
  validateSnapshot(wanted,true);validateSnapshot(before,true);
  requireThat(equal(wanted.deviceInfo,before.deviceInfo),'配置来自不同设备或固件，请重新读取。');
  requireThat(wanted.parameters[0]===before.parameters[0]&&equal(wanted.parameters.slice(9),before.parameters.slice(9)),'配置改变了未知系统参数。');
  if(!equal(wanted.parameters,before.parameters)){
    requireThat(modes.some(([v])=>v===wanted.parameters[1])&&wanted.parameters[2]<=4&&wanted.parameters[3]<=4,'灯效模式、亮度或速度无效。');
    for(const i of [4,5])requireThat(wanted.parameters[i]===before.parameters[i]||wanted.parameters[i]<=1,'方向或颜色选项无效。');
  }
  const visible=new Set(editableSlots);visible.add(6);visible.add(71);
  for(let i=0;i<126;i++){
    const b=wanted.keymap.slice(i*3,i*3+3),old=before.keymap.slice(i*3,i*3+3);
    if(!equal(b,old)){
      requireThat(editableSlots.has(i),'内部键和隐藏位置不能改写。');
      requireThat((b[0]===0x20&&b[2]<224)||b[0]===0x30||(b[0]===0x70&&b[2]===0),'不支持此键位记录。');
      if(b[0]===0x70)requireThat(b[1]<decodeBank(wanted.macroData).length,'宏绑定超出宏库。');
    }
    if(!equal(wanted.colors.slice(i*3,i*3+3),before.colors.slice(i*3,i*3+3)))requireThat(visible.has(i),'隐藏灯光位置不能改写。');
  }
  if(!equal(wanted.macroData,before.macroData)){decodeBank(wanted.macroData);macroDuration(before,slots(before));macroDuration(wanted,slots(wanted));}
}
export async function applyConfiguration(hid,wanted,baseline,{gate,backup,progress=()=>{}}){
  validatePlan(wanted,baseline);progress('核对键盘当前配置');const before=await hid.snapshot();
  requireThat(sameSnapshot(before,baseline),'键盘配置已变化。请重新读取后再编辑。');if(sameSnapshot(before,wanted))return before;
  await backup(before);await gate.check();
  const bankOffsets=[];for(let o=0;o<3071;o+=54)if(!equal(wanted.macroData.slice(o,o+54),before.macroData.slice(o,o+54)))bankOffsets.push(o);
  const colorSlots=[];for(let i=0;i<126;i++)if(!equal(wanted.colors.slice(i*3,i*3+3),before.colors.slice(i*3,i*3+3)))colorSlots.push(i);
  const oldSlots=slots(before),newSlots=slots(wanted),bankChanged=bankOffsets.length>0,keysChanged=!equal(wanted.keymap,before.keymap),paramsChanged=!equal(wanted.parameters,before.parameters);
  let attempted=false;
  const send=async p=>{await gate.check();attempted=true;await hid.exchange(p);};
  const sendKeys=async data=>{for(let o=0;o<378;o+=54)await send(packet(9,o,54,data.slice(o,o+54)));};
  const sendBank=async data=>{for(const o of [...bankOffsets].reverse())await send(packet(0x15,o,Math.min(54,3071-o),data.slice(o,o+54)));};
  const sendColors=async data=>{for(const i of colorSlots)await send(packet(0x0b,i*3,3,data.slice(i*3,i*3+3)));};
  const sendParams=async data=>send(packet(6,0,9,data.slice(0,9),0x55));
  const drain=async ms=>{progress(`等待已触发的宏结束（${Math.ceil(ms/1000)} 秒）`);for(let left=ms;left>0;left-=100){await gate.check();await sleep(Math.min(left,100));}};
  const disable=async(s,list)=>{const map=clone(s.keymap);for(const slot of list)map.splice(slot*3,3,0x20,0,0);await sendKeys(map);};
  try{
    if(bankChanged){progress('写入宏存储');if(oldSlots.length){await disable(before,oldSlots);await drain(macroDuration(before,oldSlots));}await sendBank(wanted.macroData);requireThat(equal(await hid.read(0x14,3071),wanted.macroData),'宏存储读回不一致。');}
    if(keysChanged||(bankChanged&&oldSlots.length)){progress('写入键位');await sendKeys(wanted.keymap);}
    if(colorSlots.length){progress(`写入 ${colorSlots.length} 键颜色`);await sendColors(wanted.colors);}
    if(paramsChanged){progress('写入灯效参数');await sendParams(wanted.parameters);}
    progress('完整读回校验');const after=await hid.snapshot();requireThat(sameSnapshot(after,wanted),'写后读回不一致。');return after;
  }catch(error){
    if(!attempted)throw error;
    try{
      await gate.check();requireThat(!hid.dead,'USB 会话已关闭。');progress('写入失败，恢复原配置');
      if(bankChanged){const current={...before,keymap:await hid.read(8,378)};await disable(current,[...new Set([...oldSlots,...newSlots])]);await drain(Math.max(macroDuration(before,oldSlots),macroDuration(wanted,newSlots)));await sendBank(before.macroData);}
      if(keysChanged||bankChanged)await sendKeys(before.keymap);
      if(colorSlots.length)await sendColors(before.colors);if(paramsChanged)await sendParams(before.parameters);
      requireThat(sameSnapshot(await hid.snapshot(),before),'恢复读回不一致。');throw new RestoredError(`${error.message} 已恢复写入前的配置。`);
    }catch(recovery){if(recovery instanceof RestoredError)throw recovery;throw new Error(`${error.message} 自动恢复未完成：${recovery.message} 请重新连接、读取，再导入“写入前备份”恢复。`);}
  }
}
class RestoredError extends Error{}
