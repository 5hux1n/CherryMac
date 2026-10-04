// File validation and fresh-read preparation only. No transport or browser APIs.
import {clone,equal,requireThat,officialLightingReports,officialLightingReadbackTarget,assessLightingRecoveryRecord,assessLightingRestoreAttempt,lightingRestorePlanFromRecord} from './model.js?v=0.6.0';
export function lightingAcceptanceInput(value){
  const input=clone(value);
  if(input?.format==='CherryMacLightingDraftReview'){
    requireThat(input.version===1&&input.hardwareReady===false,'灯效核对文件版本无效。');
    officialLightingReports(input.plan);
    const target=officialLightingReadbackTarget(input.plan,input.original);
    requireThat(equal(target,input.target),'灯效计划与预计读回不一致。');
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
