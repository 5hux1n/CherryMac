import {CherryHID,PageReleaseGate,supportsDevice} from './hid.js?v=0.6.0';
import {clone,equal,requireThat,assessLightingRecoveryRecord,assessLightingRestoreAttempt} from './model.js?v=0.6.0';
import {LightingCandidateAuthorization} from './safety.js?v=0.6.0';
import {selectLightingDevice,recordLightingOperation,lightingAcceptanceInput,lightingRecoveryForFreshRead,LightingPowerCycle} from './lighting-test-plan.js?v=0.6.0';
import {saveRawLightingMetadata,lightingResultChannelName,reviewLightingEditorResult,takeLightingHandoff,saveBackup,download} from './storage.js?v=0.6.0';
import {saveLog,saveVerifiedLog,latestLightingRecoveryLog} from './logs.js?v=0.6.0';
const $=id=>document.getElementById(id),gate=new PageReleaseGate(),runID=crypto.randomUUID();
const artifacts={format:'CherryMacLightingAcceptanceSession',version:1,hardwareReady:false,runID,startedAt:new Date().toISOString(),backups:[],records:[],usb:[],observations:[]};
let editorRecord=null,pendingEditorRecord=null,pendingWriteTarget=null,editorReview=null,connectionRevision=0,returnChannel=null;
let input=null,hid=null,busy=false,abort=null,latestRecord=null,writeAttempted=false,writtenTarget=null,powerCycle=null;
const powerStorage=new WeakMap();
function powerStorageReady(){const saved=powerCycle&&powerStorage.get(powerCycle);return saved!=null&&saved.pending===0&&saved.failure===null;}
function persistPowerObservation(observation,cycle){
  const saved=powerStorage.get(cycle);if(!saved)return;
  artifacts.observations.push(observation);saved.pending++;render();
  void persistSession().catch(error=>{
    saved.failure=String(error?.message??error);observation.persistenceError=saved.failure;
    if(powerCycle===cycle){editorRecord=null;status(`断电事件保存失败：${saved.failure}。本轮不能通过断电验收；可导出资料并恢复原配置。`,true);}
  }).finally(()=>{saved.pending--;render();});
}
const deviceTokens=new WeakMap();
function token(device){if(!deviceTokens.has(device))deviceTokens.set(device,crypto.randomUUID());return deviceTokens.get(device);}
const same=(a,b)=>['deviceInfo','keymap','parameters','colors','macroData'].every(k=>equal(a[k],b[k]));
function status(text,error=false){$('lighting-state').textContent=text;$('lighting-state').classList.toggle('error',error);}
function recoveryDetails(){
  if(!latestRecord)return '尚无恢复记录；备份和恢复记录保存完成后才进入发送。';
  try{
    const assessment=latestRecord.format==='CherryMacLightingRestoreAttempt'?assessLightingRestoreAttempt(latestRecord):assessLightingRecoveryRecord(latestRecord);
    const state=({alreadyMatched:'记录起始配置与原始备份一致',readbackMatched:'记录读回符合本轮目标',readbackMismatch:'记录读回与目标不同',incomplete:'记录尚未完成',failed:'记录中的操作未通过'})[assessment.status]??assessment.status;
    const advice=({available:'记录内的变化属于已识别范围，恢复前仍需重新读取。',unchanged:'记录中的配置与原始备份一致。',unavailable:'记录缺少完整读回，重连读取后才能判断恢复范围。',unrecognized:'记录有范围外变化，请保留资料，不要继续覆盖。'})[assessment.recoveryStatus]??'请保留原始记录并重新核对。';
    const trace=assessment.traceReview;
    return `恢复记录：${state}；已核对回复 ${trace.acceptedReports}/${trace.expectedReports}。${advice} 记录中的读回不代表现在的键盘状态。${busy?'':'操作中断后：重新选择并读取键盘 → 重新核对并恢复原始数据。可下载独立恢复记录后换会话载入。'}`;
  }catch(error){return `恢复记录无法核对：${error.message}。请下载并保留原始资料。`;}
}
function render(){
  $('lighting-recovery-state').textContent=recoveryDetails();
  const online=hid&&!hid.dead;
  for(const id of ['lighting-resume','lighting-file','lighting-connect','lighting-close','lighting-write','lighting-restore','lighting-power-off','lighting-retention','lighting-download','lighting-download-record','lighting-return'])$(id).disabled=busy;
  $('lighting-return').disabled=busy||!returnChannel||!editorRecord||!online;
  $('lighting-connect').disabled=busy||!isSecureContext||!('hid' in navigator);
  $('lighting-close').disabled=busy||!online;
  $('lighting-write').disabled=busy||!online||input?.kind!=='write'||writeAttempted;
  $('lighting-restore').disabled=busy||!online||!latestRecord;
  $('lighting-stop').disabled=!abort||abort.signal.aborted;
  $('lighting-download-record').disabled=busy||!latestRecord;
  $('lighting-power-off').disabled=busy||!powerStorageReady()||!writtenTarget||powerCycle?.disconnectedAt==null||online||powerCycle?.returnedAt!=null;
  $('lighting-retention').disabled=busy||!powerStorageReady()||!online||!writtenTarget||powerCycle?.powerOffAt==null;
}
async function persistSession(){await saveVerifiedLog({id:`lighting-session-${runID}`,at:artifacts.startedAt,kind:'lightingAcceptance',session:clone(artifacts)});}
async function backup(snapshot){const record=await saveBackup(snapshot,null,{strict:true});artifacts.backups.push(clone(record));await persistSession();}
async function persist(record){
  // Store completed transaction before exposing it as the latest recovery source.
  await saveVerifiedLog({id:`lighting-record-${record.operationID}`,at:new Date().toISOString(),kind:'lightingRecovery',record:clone(record)});
  latestRecord=clone(record);
  const index=artifacts.records.findIndex(r=>r.operationID===record.operationID);
  if(index<0)artifacts.records.push(clone(record));else artifacts.records[index]=clone(record);
  await persistSession();
}
async function operation(kind,body){
  if(busy)return;const revision=connectionRevision,cycleAtStart=powerCycle;
  // Returning performs only fresh reads and delivery. Preserve its receipt on
  // failure so reconnection can retry the fresh read without another write.
  const retainedEditorRecord=kind==='return-editor'?clone(editorRecord):null;
  if(['load-file','load-editor-plan','connect','write','restore','retention','confirm-power-off'].includes(kind))editorRecord=null;
  pendingEditorRecord=null;pendingWriteTarget=null;busy=true;render();
  try{
    await recordLightingOperation(artifacts,kind,body,{persist:persistSession,cancelled:()=>abort?.signal.aborted===true});
    if(kind==='write'&&pendingWriteTarget){
      requireThat(revision===connectionRevision&&!abort?.signal.aborted&&hid&&!hid.dead,'写入结束后会话已改变或收到停止请求；记录已保留，请重新读取后核对恢复。');
      writtenTarget=clone(pendingWriteTarget);powerCycle=new LightingPowerCycle(token(hid.device));powerStorage.set(powerCycle,{pending:0,failure:null});
      status('写入、完整读回及会话保存一致。请观察灯光，再按提示断电重连。尚未验证外观或断电保留。');
    }
    if(kind==='retention')requireThat(powerStorageReady(),'断电事件尚未完成保存或保存失败；本轮结果不能返回编辑器。');
    if(pendingEditorRecord&&revision===connectionRevision&&!abort?.signal.aborted&&hid&&!hid.dead){
      reviewLightingEditorResult(pendingEditorRecord,editorReview);editorRecord=clone(pendingEditorRecord);
    }
  }catch(error){
    editorRecord=revision===connectionRevision?retainedEditorRecord:null;
    if(kind==='write'){writtenTarget=null;powerCycle=null;}
    if(kind==='confirm-power-off'&&cycleAtStart){const saved=powerStorage.get(cycleAtStart);if(saved)saved.failure=String(error?.message??error);}
    status(error.message,true);
  }finally{pendingEditorRecord=null;pendingWriteTarget=null;abort=null;busy=false;render();}
}
async function loadInput(value,name){
  editorRecord=null;input=null;latestRecord=null;writeAttempted=false;writtenTarget=null;powerCycle=null;
  $('lighting-plan').textContent='正在核对新计划；此前选择已清除。';
  const prepared=lightingAcceptanceInput(value);
  if(prepared.kind==='write')new LightingCandidateAuthorization(prepared.value.plan,prepared.value.original);
  // Persist the selected source before enabling either operation button.
  artifacts.observations.push({kind:'loaded',at:new Date().toISOString(),name,input:clone(prepared.value)});await persistSession();
  input=prepared;latestRecord=prepared.kind==='restore'?clone(prepared.value):null;
  $('lighting-plan').textContent=prepared.kind==='write'?`已载入${prepared.value.plan.defaultColorData!=null?'默认配色→参数计划':'写入核对'}：模式 ${prepared.target.parameters[1]}，亮度 ${prepared.target.parameters[2]}/4。按键与宏保持备份。尚未写入。`:'已载入恢复记录；恢复前将重新读取完整配置。尚未发送。';
  if(prepared.kind==='write'&&prepared.target.parameters[1]===8&&prepared.value.rawLightingMetadata==null)$('lighting-plan').textContent+=' 旧计划未含原始 RGB；可恢复硬件数据，但不能从编码颜色还原原色。';
  status('计划已核对；请单独选择并读取 USB 键盘。');
}
$('lighting-resume').onclick=()=>{
  if(busy)return;
  // Invalidate before reading, so an unavailable/corrupt new source cannot
  // leave an older plan eligible for writing.
  editorRecord=null;input=null;latestRecord=null;writeAttempted=false;writtenTarget=null;powerCycle=null;
  $('lighting-plan').textContent='正在读取本机恢复记录；此前选择已清除。';
  return operation('load-file',async()=>{const saved=await latestLightingRecoveryLog();requireThat(saved.record&&saved.id===`lighting-record-${saved.record.operationID}`,'本机恢复记录身份无效，请使用原始文件。');
  requireThat(new TextEncoder().encode(JSON.stringify(saved.record)).length<=3_000_000,'本机恢复记录超过 3 MB，请选择原始备份文件。');
  await loadInput(saved.record,`本机最近恢复记录 · ${saved.at}`);});
};
$('lighting-file').onchange=()=>{
  if(busy)return;const file=$('lighting-file').files[0];if(!file)return;
  // Invalidate the previous selection even if recording this new attempt fails.
  editorRecord=null;input=null;latestRecord=null;writeAttempted=false;writtenTarget=null;powerCycle=null;
  $('lighting-plan').textContent='正在核对新文件；此前选择已清除。';
  void operation('load-file',async()=>{
    requireThat(file.size<=3_000_000,'文件超过 3 MB。');
    await loadInput(JSON.parse(await file.text()),file.name);
  });
};
const handoffID=new URL(location.href).searchParams.get('plan');
if(handoffID!==null){
  history.replaceState(null,'',location.pathname);
  void operation('load-editor-plan',async()=>{
    const review=takeLightingHandoff(sessionStorage,handoffID);
    await loadInput(review,'编辑区计划');editorReview=clone(review);
    if(typeof BroadcastChannel==='function')returnChannel=new BroadcastChannel(lightingResultChannelName(handoffID));
  });
}
$('lighting-connect').onclick=()=>{
  if(busy)return;
  return selectLightingDevice(operation,()=>navigator.hid.requestDevice({filters:[{vendorId:1130,productId:462,usagePage:0xff1c,usage:0x92}]}),async device=>{
  if(hid)await hid.close();
  const session=new CherryHID(device,{lightingResearch:true,log:async entry=>{
    await saveLog(entry);artifacts.usb.push(clone(entry));
  },progress:message=>status(message),onDisconnect:error=>{connectionRevision++;editorRecord=null;gate.invalidate();status(error.message,true);render();}});
  hid=session;await session.open();const snapshot=await session.snapshot();
  artifacts.observations.push({kind:'connectedRead',at:new Date().toISOString(),snapshot:clone(snapshot)});await persistSession();
  // A reconnect may resume a failed return without rewriting the keyboard.
  // The saved completed trace and this fresh read must both match the plan.
  if(editorReview&&latestRecord){
    try{const expected=reviewLightingEditorResult(latestRecord,editorReview);if(same(snapshot,expected))pendingEditorRecord=clone(latestRecord);}catch{}
  }
  status('完整配置已读取。连接与读取没有写入；请核对计划后用鼠标选择操作。');
  });
};
$('lighting-close').onclick=()=>operation('close-session',async()=>{await hid.close();status('会话已关闭。此操作不代表 USB 已拔出或键盘已断电。');});
navigator.hid?.addEventListener('disconnect',event=>{
  if(event.device!==hid?.device)return;
  editorRecord=null;connectionRevision++;
  if(!powerCycle?.disconnect(token(event.device),performance.now()))return;
  persistPowerObservation({kind:'usbDisconnected',at:new Date().toISOString(),deviceToken:token(event.device)},powerCycle);render();
});
navigator.hid?.addEventListener('connect',event=>{
  if(!supportsDevice(event.device)||!powerCycle?.reconnect(token(event.device),performance.now()))return;
  persistPowerObservation({kind:'usbReconnected',at:new Date().toISOString(),deviceToken:token(event.device)},powerCycle);render();
});
$('lighting-write').onclick=event=>operation('write',async()=>{
  requireThat(input?.kind==='write'&&!writeAttempted,'请先载入新的写入核对文件。');
  requireThat(confirm('本研究入口将实际写入灯效。请确认已保存恢复资料、松开全部按键，并保持页面前台。是否继续？'),'已取消，未写入。');
  gate.acknowledge(event);abort=new AbortController();writeAttempted=true;powerCycle=null;writtenTarget=null;render();
  if(input.value.rawLightingMetadata!=null){try{await saveRawLightingMetadata(input.value.rawLightingMetadata);}catch(error){throw new Error(`原始配色资料未保存，本次尚未进入灯效发送：${error.message} 请修复本机存储后重新载入计划并读取键盘。`);}}
  const result=await hid.applyLightingCandidate(input.value.plan,input.value.original,{lightingMapping:input.value.lightingMapping,gate,cancelled:()=>abort.signal.aborted,backup,persist});
  if(result.readbackMatches){if(editorReview)pendingEditorRecord=clone(result.record);pendingWriteTarget=clone(input.target);}
  else throw new Error(`本次写入未通过：${result.failure}。请保留记录，重新连接后核对恢复。`);
});
$('lighting-restore').onclick=event=>operation('restore',async()=>{
  requireThat(latestRecord,'尚无恢复记录。');
  requireThat(confirm('将从原始备份恢复灯效数据，颜色不再缩放。恢复前会重新读取并检查范围；请松开全部键。是否继续？'),'已取消，未恢复。');
  gate.acknowledge(event);abort=new AbortController();writtenTarget=null;powerCycle=null;render();
  const current=await hid.snapshot(),recovery=lightingRecoveryForFreshRead(latestRecord,current);
  const attempt=await hid.restoreLightingCandidate(recovery,{gate,cancelled:()=>abort.signal.aborted,backup,persist});
  const review=assessLightingRestoreAttempt(attempt);
  writtenTarget=null;powerCycle=null;
  requireThat(['readbackMatched','alreadyMatched'].includes(review.status),`恢复未通过：${attempt.failure||review.status}。保留记录并重新连接，不自动重试。`);
  if(editorReview)pendingEditorRecord=clone(attempt);
  status('原始备份与完整读回一致。请确认键盘操作与灯光外观，再下载资料。');
});
$('lighting-stop').onclick=()=>{abort?.abort();gate.invalidate();status('已请求停止后续发送；正在发出的报告不能撤回，恢复记录会保留。');render();};
$('lighting-power-off').onclick=()=>operation('confirm-power-off',async()=>{
  requireThat(powerStorageReady()&&writtenTarget&&powerCycle&&hid?.dead,'需先完成 USB 拔出记录保存，再关闭键盘电源。');
  const cycle=powerCycle;cycle.confirmPowerOff(performance.now());artifacts.observations.push({kind:'userConfirmedPowerOff',at:new Date().toISOString()});
  try{await persistSession();}catch(error){powerStorage.get(cycle).failure=String(error?.message??error);throw error;}status('已记录你的关电确认。请等待至少 15 秒，再开电、接回 USB 并重新选择键盘。');
});
$('lighting-retention').onclick=()=>operation('retention',async()=>{
  requireThat(powerStorageReady()&&writtenTarget&&powerCycle,'本轮断电记录尚未保存完成或保存失败；可导出资料并核对恢复。');
  const session=hid,selectedToken=token(session.device),evidence=powerCycle.evidence(selectedToken);
  const current=await session.snapshot();requireThat(hid===session&&!session.dead&&powerStorageReady(),'重连读回期间 USB 会话或断电记录保存状态改变。');powerCycle.evidence(selectedToken);
  const matches=same(current,writtenTarget);
  artifacts.observations.push({kind:'powerCycleReadback',at:new Date().toISOString(),...evidence,matches,current:clone(current)});await persistSession();
  requireThat(matches,'重连后的配置与目标不同。请保留资料，核对原始数据恢复。');
  if(editorReview&&latestRecord?.format==='CherryMacLightingRecoveryRecord'){pendingEditorRecord=clone(latestRecord);pendingEditorRecord.current=clone(current);}
  status('关电确认后的完整读回符合写入目标。灯光外观仍需观察；接下来可以恢复原始数据。');
});
$('lighting-return').onclick=()=>operation('return-editor',async()=>{
  requireThat(returnChannel&&editorRecord&&hid&&!hid.dead,'尚无可以返回的有效结果，请先完成写入或恢复。');
  const record=clone(editorRecord),session=hid,expected=reviewLightingEditorResult(record,editorReview);
  const current=await session.snapshot();
  requireThat(hid===session&&!session.dead&&same(current,expected),'返回前配置已改变；请重新核对，未更新编辑器。');
  await session.flushLogs();await session.close();gate.invalidate();
  artifacts.observations.push({kind:'editorReturnReadback',at:new Date().toISOString(),current:clone(current)});await persistSession();
  await new Promise((resolve,reject)=>{
    const channel=returnChannel;let timer;
    function finish(error){clearTimeout(timer);channel.onmessage=null;if(error)reject(error);else resolve();}
    channel.onmessage=event=>{const value=event.data;if(value?.kind!=='lighting-editor-result-ack'||value.id!==handoffID)return;finish(value.accepted?null:new Error(value.error||'编辑器拒绝此结果。'));};
    timer=setTimeout(()=>finish(new Error('编辑器未确认接收；资料仍保留，请返回原标签页核对。')),10_000);
    try{channel.postMessage({kind:'lighting-editor-result',id:handoffID,record});}catch(error){finish(error);}
  });
  returnChannel.close();returnChannel=null;editorRecord=null;
  status('结果已送回原编辑器，USB 会话已关闭。请切回原标签页，重新连接并读取；草稿保留。');
});
$('lighting-download').onclick=()=>operation('download',async()=>{let logFailure=null;try{await hid?.flushLogs();}catch(error){logFailure=error.message;}const saved=clone(artifacts);if(logFailure)saved.exportWarning=logFailure;download(saved,`CherryMac-灯效验收-${runID}.json`);status(logFailure?`已下载现有资料；日志未完整保存：${logFailure}`:'资料已下载；不会自动恢复或修改键盘。',!!logFailure);});
$('lighting-download-record').onclick=()=>operation('download-record',async()=>{requireThat(latestRecord,'尚无恢复记录。');download(latestRecord,`CherryMac-灯效恢复记录-${latestRecord.operationID}.json`);status('已下载独立恢复记录，可在新会话载入。');});
window.addEventListener('beforeunload',event=>{if(!busy)returnChannel?.close();abort?.abort();gate.invalidate();if(busy){event.preventDefault();event.returnValue='';}});
render();
