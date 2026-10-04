import {clone,equal,requireThat,validateSnapshot,decodeBank} from './model.js?v=0.6.0';
import {editableSlots,modes} from './layout.js?v=0.6.0';
import {KeymapWriteAuthorization,MacroWriteAuthorization,HostTextWriteAuthorization} from './safety.js?v=0.6.0';
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
  return applyAuthorizedKeymap(hid,authorization,{gate,backup,progress},'withKeymapAuthorization');
}
export async function applyHostTextInstallation(hid,root,before,{gate,backup,saveTextConfiguration,progress=()=>{}}={}){
  requireThat(typeof hid?.withHostTextAuthorization==='function','文本安装尚未开放，未读取或写入键盘。');
  requireThat(gate&&typeof gate.check==='function'&&typeof backup==='function'&&typeof saveTextConfiguration==='function','缺少松键检查、键盘备份或主机文本配置保存，停止安装。');
  hid.stopHostTextObservation();
  const plan=await hid.readHostTextInstallation(root,before);
  const authorization=new HostTextWriteAuthorization(plan.officialJSON,plan.factoryKeymap,plan.before);
  // Even an already installed marker needs a persistent host text definition.
  if(!authorization.changedSlots.length){await saveTextConfiguration(clone(plan.officialJSON),clone(plan));return clone(plan.before);}
  return applyAuthorizedKeymap(hid,authorization,{gate,progress,backup:async current=>{await backup(current);await saveTextConfiguration(clone(plan.officialJSON),clone(plan));}},'withHostTextAuthorization');
}
export async function restoreHostTextInstallation(hid,root,factoryKeymap,before,{gate,backup,progress=()=>{}}={}){
  requireThat(typeof hid?.withHostTextAuthorization==='function','文本恢复尚未开放，未读取或写入键盘。');
  requireThat(gate&&typeof gate.check==='function'&&typeof backup==='function','缺少按键释放检查或可靠备份，停止恢复。');
  hid.stopHostTextObservation();
  factoryKeymap=clone(factoryKeymap);
  const original=new HostTextWriteAuthorization(root,factoryKeymap,before);
  requireThat(equal(await hid.read(7,378),factoryKeymap),'恢复时固件默认表不同，停止发送。');
  const recovery=original.recovery(await hid.snapshot());
  return applyAuthorizedKeymap(hid,recovery,{gate,backup,progress},'withHostTextAuthorization');
}
async function applyAuthorizedKeymap(hid,authorization,{gate,backup,progress},entry){
  const before=authorization.before,wanted=authorization.expected;
  requireThat(gate&&typeof gate.check==='function'&&typeof backup==='function','缺少按键释放检查或可靠备份，停止写入。');
  if(!authorization.changedSlots.length)return clone(before);
  const id=crypto.randomUUID(),previousOperationId=hid.operationId;hid.operationId=id;
  try{
  const phase=async(name,extra={})=>{hid.record({id:crypto.randomUUID(),operationId:id,kind:'phase',at:new Date().toISOString(),phase:name,...extra});await hid.flushLogs();progress(name);};
  await phase('核对写入前配置');const current=await hid.snapshot();
  requireThat(sameSnapshot(current,before),'键盘配置已经变化，请重新读取后写入。');
  await backup(current);await phase('写入前备份已保存',{changedSlots:authorization.changedSlots,baseline:current,targetKeymap:wanted.keymap});await gate.check();
  return await hid[entry](authorization,gate,async()=>{
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

// This generic transaction is exercised with a scoped simulated transport.
// Normal CherryHID construction exposes no macro permission. The explicit
// research transport exercises framing and recovery before product acceptance.
export async function applyMacroConfiguration(hid,target,before,{gate,backup,waitForCompletion,confirmStopped,progress=()=>{}}={}){
  requireThat(typeof hid?.withMacroAuthorization==='function','宏传输尚未开放，未读取或写入键盘。');
  const authorization=new MacroWriteAuthorization(before,target,{allowUnbounded:typeof confirmStopped==='function'}),wanted=authorization.expected,original=authorization.before,disabled=authorization.disabled;
  requireThat(gate&&typeof gate.check==='function'&&typeof backup==='function'&&typeof waitForCompletion==='function','缺少松键、备份或宏结束检查，停止写入。');
  if(sameSnapshot(original,wanted))return clone(original);
  const id=crypto.randomUUID(),previousOperationId=hid.operationId;hid.operationId=id;
  const phase=async(name,extra={})=>{hid.record({id:crypto.randomUUID(),operationId:id,kind:'phase',at:new Date().toISOString(),phase:name,...extra});await hid.flushLogs();progress(name);};
  try{
    await phase('核对宏写入前配置');requireThat(sameSnapshot(await hid.snapshot(),original),'键盘配置已经变化，请重新读取后写入。');
    await backup(clone(original));await phase('宏写入前备份已保存',{baseline:original,target:wanted,beforeDurationMilliseconds:authorization.beforeDurationMilliseconds,targetDurationMilliseconds:authorization.targetDurationMilliseconds});await gate.check();
    if(authorization.beforeCompletion.repeatingBindings.length){
      await phase('等待实体宏停止');
      await confirmStopped({phase:'beforeWrite',configurations:[clone(original)],requirements:[authorization.beforeCompletion]});
      await gate.check();await hid.flushLogs();
      requireThat(sameSnapshot(await hid.snapshot(),original),'停止期间配置发生变化，未发送写包。');
    }
    return await hid.withMacroAuthorization(authorization,gate,async()=>{
      let attempted=false;
      const send=async packet=>{authorization.validate(packet);await gate.check();await hid.flushLogs();attempted=true;await hid.exchange(packet);};
      const keys=async map=>{for(let offset=0;offset<378;offset+=54)await send(authorization.packet(9,map,offset));};
      const bank=async data=>{for(const offset of authorization.changedOffsets.slice().reverse())await send(authorization.packet(0x15,data,offset));};
      const drain=async milliseconds=>{await phase('等待有限宏结束',{durationMilliseconds:milliseconds});await waitForCompletion(milliseconds);await gate.check();};
      try{
        if(slots(original).length){await phase('临时禁用原宏绑定');await keys(disabled.keymap);await drain(authorization.beforeDurationMilliseconds);}
        await phase('写入宏事件与头部');await bank(wanted.macroData);
        requireThat(equal(await hid.read(0x14,3071),wanted.macroData),'宏区写后读取不一致。');
        if(!equal(original.keymap,wanted.keymap)||slots(original).length){await phase('写入宏绑定');await keys(wanted.keymap);}
        await phase('完整读回宏与其他配置');const after=await hid.snapshot();requireThat(sameSnapshot(after,wanted),'宏写后读取不一致，或其他配置发生变化。');
        await phase('宏写入完成');return after;
      }catch(error){
        const reason=error.message;
        if(!attempted)throw new Error(`${reason} 未发送宏或键位写包，原配置没有修改。`);
        if(hid.dead)throw new Error(`${reason} 已停止发送；命令可能已执行。备份已保存，请重新连接并读取后恢复。`);
        try{
          await gate.check();await phase('核对宏可恢复范围');authorization.validateRecovery(await hid.snapshot());
          if(authorization.beforeCompletion.repeatingBindings.length||authorization.targetCompletion.repeatingBindings.length){
            requireThat(typeof confirmStopped==='function','缺少持续宏停止流程，保留备份并停止恢复。');
            await phase('等待实体宏停止后恢复');
            await confirmStopped({phase:'recovery',configurations:[clone(original),clone(wanted)],requirements:[authorization.beforeCompletion,authorization.targetCompletion]});
            await gate.check();await hid.flushLogs();authorization.validateRecovery(await hid.snapshot());
          }
          await phase('禁用新旧宏触发键');await keys(disabled.keymap);
          await drain(Math.max(authorization.beforeDurationMilliseconds,authorization.targetDurationMilliseconds));
          await phase('恢复原宏区与绑定');await bank(original.macroData);await keys(original.keymap);
          requireThat(sameSnapshot(await hid.snapshot(),original),'宏恢复后读取不一致。');await phase('原宏与绑定已恢复');
        }catch(recovery){throw new Error(`${reason} 自动恢复未完成：${recovery.message}。备份已保存，请停止使用测试宏，重新连接并读取配置。`);}
        throw new Error(`${reason} 已恢复原宏与绑定，备份和日志已保存。`);
      }
    });
  }finally{hid.operationId=previousOperationId;}
}

// Resume recovery on a NEW connection with the original immutable transaction
// scope. A mixed/undecodable bank is never used as a new write authorization.
export async function restoreMacroTransaction(hid,before,target,{gate,backup,waitForCompletion,confirmStopped,progress=()=>{}}={}){
  requireThat(typeof hid?.withMacroAuthorization==='function','宏传输尚未开放，未读取或写入键盘。');
  const auth=new MacroWriteAuthorization(before,target,{allowUnbounded:typeof confirmStopped==='function'});
  requireThat(gate&&typeof gate.check==='function'&&typeof backup==='function'&&typeof waitForCompletion==='function','缺少恢复释放、备份或宏结束检查。');
  const previous=hid.operationId;hid.operationId=crypto.randomUUID();
  const phase=async(name,extra={})=>{hid.record({id:crypto.randomUUID(),operationId:hid.operationId,kind:'phase',at:new Date().toISOString(),phase:name,...extra});await hid.flushLogs();progress(name);};
  try{
    await phase('重连恢复完整读取',{baseline:auth.before,target:auth.expected});
    const current=await hid.snapshot();auth.validateRecovery(current);
    if(sameSnapshot(current,auth.before)){await phase('原宏配置已在设备中，无需写入');return current;}
    await backup(clone(current));await phase('恢复前中间状态备份已保存');await gate.check();
    if(auth.beforeCompletion.repeatingBindings.length||auth.targetCompletion.repeatingBindings.length){
      await confirmStopped({phase:'recovery',configurations:[auth.before,auth.expected],requirements:[auth.beforeCompletion,auth.targetCompletion]});
      await gate.check();await hid.flushLogs();
    }
    // Recheck even after a finite wait/user action; outside changes are never overwritten.
    auth.validateRecovery(await hid.snapshot());
    return await hid.withMacroAuthorization(auth,gate,async()=>{
      const send=async packet=>{auth.validate(packet);await gate.check();await hid.flushLogs();await hid.exchange(packet);};
      const keys=async map=>{for(let o=0;o<378;o+=54)await send(auth.packet(9,map,o));};
      await phase('恢复前禁用新旧宏绑定');await keys(auth.disabled.keymap);
      await waitForCompletion(Math.max(auth.beforeDurationMilliseconds,auth.targetDurationMilliseconds));await gate.check();
      // No blind retry on this recovery attempt. Any failure retains the backup.
      await phase('恢复原宏事件与头部');for(const o of auth.changedOffsets.slice().reverse())await send(auth.packet(0x15,auth.before.macroData,o));
      requireThat(equal(await hid.read(0x14,3071),auth.before.macroData),'重连恢复宏区读回不一致，停止发送。');
      await phase('恢复原宏绑定');await keys(auth.before.keymap);
      const restored=await hid.snapshot();requireThat(sameSnapshot(restored,auth.before),'重连恢复完整读回不一致。');await phase('重连恢复完成');return restored;
    });
  }finally{hid.operationId=previous;}
}
