// File validation and fresh-read preparation only. No transport or browser APIs.
import {clone,equal,requireThat,lightingMappingSlots,officialLightingReports,officialLightingReadbackTarget,assessLightingRecoveryRecord,assessLightingRestoreAttempt,lightingRestorePlanFromRecord} from './model.js?v=0.6.0';
export function lightingAcceptanceInput(value){
  const input=clone(value);
  if(input?.format==='CherryMacLightingDraftReview'){
    requireThat(input.version===1&&input.hardwareReady===false,'灯效核对文件版本无效。');
    officialLightingReports(input.plan);
    const target=officialLightingReadbackTarget(input.plan,input.original);
    requireThat(equal(target,input.target),'灯效计划与预计读回不一致。');
    requireThat((target.parameters[1]!==8&&input.plan.defaultColorData==null)||input.lightingMapping!=null,'逐键计划缺少 LED 映射，请从主编辑器重新准备计划。旧恢复记录仍可载入。');
    if(input.lightingMapping!=null)lightingMappingSlots(input.lightingMapping,input.original);
    return {kind:'write',value:input,target};
  }
  if(input?.format==='CherryMacLightingRecoveryRecord'){assessLightingRecoveryRecord(input);return {kind:'restore',value:input,target:clone(input.original)};}
  if(input?.format==='CherryMacLightingRestoreAttempt'){assessLightingRestoreAttempt(input);return {kind:'restore',value:input,target:clone(input.recovery.sourceRecord.original)};}
  throw new Error('请选择灯效写入核对文件、写入记录或恢复记录。');
}
export function lightingRecoveryForFreshRead(record,current){
  const prepared=clone(record);prepared.current=clone(current);
  // The current device state replaces a historical readback only for review.
  // Attempt input retains its original restore plan and interrupted prefixes.
  return lightingRestorePlanFromRecord(prepared);
}

// Device tokens are assigned by the UI to actual HIDDevice objects. They are
// session evidence, not proof that two connections are the same physical unit.
export class LightingPowerCycle {
  constructor(originalToken){requireThat(typeof originalToken==='string'&&originalToken.length>0,'缺少本轮 USB 会话标识。');this.originalToken=originalToken;this.disconnectedAt=null;this.powerOffAt=null;this.returnedAt=null;this.returnedToken=null;}
  disconnect(token,now){
    if(token!==this.originalToken&&token!==this.returnedToken)return false;
    requireThat(Number.isFinite(now)&&now>=0,'USB 事件时钟无效。');
    this.originalToken=token;this.disconnectedAt=now;this.powerOffAt=null;this.returnedAt=null;this.returnedToken=null;return true;
  }
  confirmPowerOff(now){requireThat(this.disconnectedAt!=null&&this.returnedAt==null&&Number.isFinite(now)&&now>=this.disconnectedAt,'需先检测到 USB 拔出，并保持断开。');if(this.powerOffAt==null)this.powerOffAt=now;}
  reconnect(token,now){
    if(this.disconnectedAt==null||this.returnedAt!=null)return false;
    requireThat(typeof token==='string'&&token.length>0&&Number.isFinite(now)&&now>=this.disconnectedAt,'USB 重连记录无效。');
    this.returnedToken=token;this.returnedAt=now;return true;
  }
  evidence(selectedToken){
    requireThat(this.powerOffAt!=null&&this.returnedAt!=null&&this.returnedAt-this.powerOffAt>=15_000,'需检测到关电确认至少 15 秒后的 USB 重连；过早接回请再次拔出、关电并确认。');
    requireThat(selectedToken===this.returnedToken,'当前读取设备与本轮记录的重连设备不同，请重新完成拔插确认。');
    return {userConfirmedPowerOff:true,elapsedMilliseconds:Math.floor(this.returnedAt-this.powerOffAt),originalDeviceToken:this.originalToken,reconnectedDeviceToken:this.returnedToken};
  }
}

// Records failures before the first USB report as well as terminal results.
// Persistence must succeed before operational callbacks; downloading existing
// diagnostics remains available when storage itself is the failure.
export async function recordLightingOperation(session,kind,body,{persist,now=()=>new Date().toISOString(),cancelled=()=>false}={}){
  requireThat(session&&typeof kind==='string'&&typeof body==='function'&&typeof persist==='function','灯效操作记录接口无效。');
  const offlineExport=['download','download-record'].includes(kind);
  session.operations??=[];
  const record={index:session.operations.length,kind,startedAt:now(),status:'started'};
  session.operations.push(record);
  let value,failure;
  try{if(!offlineExport)await persist();value=await body();record.status=cancelled()?'cancelled':'complete';}
  catch(error){failure=error;record.status=cancelled()?'cancelled':'failed';record.error=String(error?.message??error).slice(0,4096);}
  record.endedAt=now();
  if(!offlineExport){
    try{await persist();}catch(error){record.persistenceError=String(error?.message??error).slice(0,4096);record.status='failed';failure??=error;}
  }
  if(failure)throw failure;return value;
}

// Invoke the permission picker in the original click task. Selecting a device
// opens no transport; the logged operation still gates all device access.
// Capture rejection immediately, even if logging fails before consuming it.
export function selectLightingDevice(operation,requestDevice,body){
  let selection;
  try{selection=Promise.resolve(requestDevice()).then(devices=>({devices}),error=>({error}));}
  catch(error){selection=Promise.resolve({error});}
  return operation('connect-read',async()=>{
    const result=await selection;
    if(result.error)throw result.error;
    requireThat(result.devices?.length===1,'未选择键盘。');
    return body(result.devices[0]);
  });
}
