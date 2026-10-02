import {clone,equal,requireThat,validateSnapshot,decodeBank} from './model.js?v=0.5.0';
import {editableSlots,modes} from './layout.js?v=0.5.0';
import {KeymapWriteAuthorization} from './safety.js?v=0.5.0';
export const sameSnapshot=(a,b)=>['deviceInfo','keymap','parameters','colors','macroData'].every(k=>equal(a[k],b[k]));
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
      requireThat((b[0]===0x20&&(b[2]===0||(b[2]>=4&&b[2]<224)))||b[0]===0x30||(b[0]===0x70&&b[2]===0),'不支持此键位记录。');
      if(b[0]===0x70)requireThat(b[1]<decodeBank(wanted.macroData).length,'宏绑定超出宏库。');
    }
    if(!equal(wanted.colors.slice(i*3,i*3+3),before.colors.slice(i*3,i*3+3)))requireThat(visible.has(i),'隐藏灯光位置不能改写。');
  }
  if(!equal(wanted.macroData,before.macroData)){decodeBank(wanted.macroData);macroDuration(before,slots(before));macroDuration(wanted,slots(wanted));}
}
export function makeKeymapPlan(draft,before){validateSnapshot(draft,true);requireThat(equal(draft.deviceInfo,before.deviceInfo),'配置来自不同固件，请使用当前读取配置编辑。');return new KeymapWriteAuthorization(before,draft.keymap).expected;}
export async function applyConfiguration(hid,wanted,before,{gate,backup,progress=()=>{}}={}){
  validateSnapshot(wanted,true);validateSnapshot(before,true);
  requireThat(['deviceInfo','parameters','colors','macroData'].every(k=>equal(wanted[k],before[k])),'仅允许键位写入；灯效、颜色与宏必须保留原始值。');
  const authorization=new KeymapWriteAuthorization(before,wanted.keymap);
  requireThat(gate&&typeof gate.check==='function'&&typeof backup==='function','缺少按键释放检查或可靠备份，停止写入。');
  if(!authorization.changedSlots.length)return clone(before);
  const id=crypto.randomUUID(),previousOperationId=hid.operationId;hid.operationId=id;
  try{
  const phase=async(name,extra={})=>{hid.record({id:crypto.randomUUID(),operationId:id,kind:'phase',at:new Date().toISOString(),phase:name,...extra});await hid.flushLogs();progress(name);};
  await phase('核对写入前配置');const current=await hid.snapshot();
  requireThat(sameSnapshot(current,before),'键盘配置已经变化，请重新读取后写入。');
  await backup(current);await phase('写入前备份已保存',{changedSlots:authorization.changedSlots,baseline:current,targetKeymap:wanted.keymap});await gate.check();
  return await hid.withKeymapAuthorization(authorization,gate,async()=>{
    const startingWrites=hid.keyWritesSent;
    const send=async map=>{for(let offset=0;offset<378;offset+=54)await hid.exchange(authorization.packet(map,offset));};
    try{
      await phase('正在写入键位');await send(wanted.keymap);
      await phase('正在完整读回核对');const after=await hid.snapshot();
      requireThat(sameSnapshot(after,wanted),'键位写后读取不一致，或其他配置发生变化。');
      await phase('键位写入完成');return after;
    }catch(error){
      const reason=error.message;
      if(hid.keyWritesSent===startingWrites)throw new Error(`${reason} 未发送键位写包，原配置没有修改。`);
      if(hid.dead)throw new Error(`${reason} 已停止发送；命令可能已执行。备份已保存，请重新连接并读取，再按需要恢复按键。`);
      try{
        await gate.check();await phase('正在核对可恢复范围');authorization.validateRecovery(await hid.snapshot());
        await phase('正在恢复原键位');await send(before.keymap);
        requireThat(sameSnapshot(await hid.snapshot(),before),'恢复读回不一致。');await phase('原键位已恢复');
      }catch(recovery){throw new Error(`${reason} 自动恢复未完成：${recovery.message}。备份已保存；请松开全部按键，重新连接读取后核对恢复。`);}
      throw new Error(`${reason} 已恢复写入前的键位，备份和日志已保存。`);
    }
  });
  }finally{hid.operationId=previousOperationId;}
}
