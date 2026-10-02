import {clone,equal,requireThat,validateSnapshot,decodeBank} from './model.js?v=0.2.0';
import {editableSlots,modes} from './layout.js?v=0.2.0';
import {assertHardwareWriteAllowed} from './safety.js?v=0.2.0';
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
    // The parameter command resends the whole first nine bytes. An unknown
    // value cannot be declared safe merely because it matched the old mode.
    for(const i of [4,5])requireThat(wanted.parameters[i]<=1,'灯效方向或颜色选项未知；请显式选择已支持的值，不能随新参数重新发送。');
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
export async function applyConfiguration(){
  // Quarantined after a user-reported device malfunction. No read, backup,
  // write or attempted rollback may run through this entry point.
  assertHardwareWriteAllowed();
}
