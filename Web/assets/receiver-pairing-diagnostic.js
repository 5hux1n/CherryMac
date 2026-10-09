import {loadPairingJournal} from './receiver-pairing-journal.js';
import {loadPairingRawLog} from './receiver-pairing-raw-log.js';
import {sameReceiverPairingSelection} from './receiver-pairing-selection.js';

// Read existing evidence only. A successful history check is not current
// hardware verification, complete recovery, power retention or write consent.
export async function inspectPairingDiagnostic(id){
  if(typeof id!=='string'||!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(id))throw new Error('配对诊断编号无效。');
  const readRaw=async()=>{
    try{return {records:await loadPairingRawLog(id),error:null};}
    catch(error){return {records:[],error:String(error?.message??error)};}
  };
  const [checkpoints,raw]=await Promise.all([loadPairingJournal(id),readRaw()]);
  const latest=checkpoints.at(-1);if(!latest)throw new Error('没有可检查的配对检查点。');
  const [secondCheckpoints,secondRaw]=await Promise.all([loadPairingJournal(id),readRaw()]);
  const stableAcrossReads=JSON.stringify(checkpoints)===JSON.stringify(secondCheckpoints)&&JSON.stringify(raw)===JSON.stringify(secondRaw);
  const state=latest.state,begins=state.events.filter(event=>event.action==='begin'&&['keyboardStart','receiverPrepare','receiverStart','polling'].includes(event.phase));
  const groups=new Map(),issues=[],uncertainIntents=[];
  if(!stableAcrossReads)issues.push('读取期间日志变化；本次结果不能作为稳定证据。');
  if(raw.error!==null)issues.push('原始报告日志未能校验：'+raw.error);
  for(const record of raw.records){
    const entry=record.entry,begin=begins.find(event=>event.sequence===entry.intent);
    if(!sameReceiverPairingSelection(entry.selection,state.selection)||!begin||begin.phase!==entry.phase){
      issues.push(`原始报告${record.sequence}没有对应的已读取端点与阶段意图。`);continue;
    }
    const rows=groups.get(entry.intent)??[];rows.push(entry);groups.set(entry.intent,rows);
  }
  const exchanges=begins.map(begin=>{
    const rows=groups.get(begin.sequence)??[],last=rows.at(-1),accepted=rows.find(row=>row.stage==='accepted');
    const next=state.events.find(event=>event.sequence>begin.sequence);
    const controllerConfirmed=next?.phase===begin.phase&&next?.action===(begin.phase==='polling'?'status':'accepted');
    const pairedSignal=begin.phase==='polling'&&accepted?.reply?.length===64?accepted.reply[8]===0xff:null;
    if(controllerConfirmed&&last?.stage!=='accepted')issues.push(`意图${begin.sequence}已有流程确认，但缺少对应的最终接受报告。`);
    if(controllerConfirmed&&begin.phase==='polling'&&pairedSignal!==(next.detail==='设备报告配对完成，继续核对原配置。'))issues.push(`意图${begin.sequence}的流程状态与原始查询回复不一致。`);
    if(!controllerConfirmed||last?.stage!=='accepted')uncertainIntents.push(begin.sequence);
    return {intent:begin.sequence,phase:begin.phase,rawStage:last?.stage??'not-recorded',controllerConfirmed,rawAccepted:accepted!==undefined,pairedSignal};
  });
  return {format:'CherryMacPairingDiagnostic',version:1,id,historicalOnly:true,
    checkpointRevision:latest.revision,phase:state.phase,pending:state.pending,pendingOperationID:state.operationID,mayHaveChanged:state.mayHaveChanged,selection:structuredClone(state.selection),backupReference:state.backupReference,
    restoreAttempted:state.restoreAttempted,recoveryRequired:state.recoveryRequired,stableAcrossReads,
    rawRecordCount:raw.records.length,rawLoadError:raw.error,exchanges,uncertainIntents,issues,
    controlAcknowledgementsCorroborated:stableAcrossReads&&begins.length>0&&issues.length===0&&uncertainIntents.length===0,
    configurationDataIncluded:false,powerCycleVerified:false};
}
