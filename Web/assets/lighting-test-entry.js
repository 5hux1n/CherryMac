import {CherryHID,PageReleaseGate,supportsDevice} from './hid.js?v=0.6.0';
import {clone,equal,requireThat,assessLightingRestoreAttempt} from './model.js?v=0.6.0';
import {LightingCandidateAuthorization} from './safety.js?v=0.6.0';
import {selectLightingDevice,recordLightingOperation,lightingAcceptanceInput,lightingRecoveryForFreshRead,LightingPowerCycle} from './lighting-test-plan.js?v=0.6.0';
import {lightingResultChannelName,reviewLightingEditorResult,takeLightingHandoff,saveBackup,download} from './storage.js?v=0.6.0';
import {saveLog} from './logs.js?v=0.6.0';
const $=id=>document.getElementById(id),gate=new PageReleaseGate(),runID=crypto.randomUUID();
const artifacts={format:'CherryMacLightingAcceptanceSession',version:1,hardwareReady:false,runID,startedAt:new Date().toISOString(),backups:[],records:[],usb:[],observations:[]};
let editorRecord=null,pendingEditorRecord=null,editorReview=null,connectionRevision=0,returnChannel=null;
let input=null,hid=null,busy=false,abort=null,latestRecord=null,writeAttempted=false,writtenTarget=null,powerCycle=null;
const deviceTokens=new WeakMap();
function token(device){if(!deviceTokens.has(device))deviceTokens.set(device,crypto.randomUUID());return deviceTokens.get(device);}
const same=(a,b)=>['deviceInfo','keymap','parameters','colors','macroData'].every(k=>equal(a[k],b[k]));
function status(text,error=false){$('lighting-state').textContent=text;$('lighting-state').classList.toggle('error',error);}
function render(){
  const online=hid&&!hid.dead;
  for(const id of ['lighting-file','lighting-connect','lighting-close','lighting-write','lighting-restore','lighting-power-off','lighting-retention','lighting-download','lighting-download-record','lighting-return'])$(id).disabled=busy;
  $('lighting-return').disabled=busy||!returnChannel||!editorRecord||!online;
  $('lighting-connect').disabled=busy||!isSecureContext||!('hid' in navigator);
  $('lighting-close').disabled=busy||!online;
  $('lighting-write').disabled=busy||!online||input?.kind!=='write'||writeAttempted;
  $('lighting-restore').disabled=busy||!online||!latestRecord;
  $('lighting-stop').disabled=!abort||abort.signal.aborted;
  $('lighting-download-record').disabled=busy||!latestRecord;
  $('lighting-power-off').disabled=busy||!writtenTarget||powerCycle?.disconnectedAt==null||online||powerCycle?.returnedAt!=null;
  $('lighting-retention').disabled=busy||!online||!writtenTarget||powerCycle?.powerOffAt==null;
}
async function persistSession(){await saveLog({id:`lighting-session-${runID}`,at:artifacts.startedAt,kind:'lightingAcceptance',session:clone(artifacts)});}
async function backup(snapshot){const record=await saveBackup(snapshot);artifacts.backups.push(clone(record));await persistSession();}
async function persist(record){
  // Store completed transaction before exposing it as the latest recovery source.
  await saveLog({id:`lighting-record-${record.operationID}`,at:new Date().toISOString(),kind:'lightingRecovery',record:clone(record)});
  latestRecord=clone(record);
  const index=artifacts.records.findIndex(r=>r.operationID===record.operationID);
  if(index<0)artifacts.records.push(clone(record));else artifacts.records[index]=clone(record);
  await persistSession();
}
async function operation(kind,body){
  if(busy)return;const revision=connectionRevision;
  if(['load-file','load-editor-plan','connect','write','restore','retention','confirm-power-off'].includes(kind))editorRecord=null;
  pendingEditorRecord=null;busy=true;render();
  try{
    await recordLightingOperation(artifacts,kind,body,{persist:persistSession,cancelled:()=>abort?.signal.aborted===true});
    if(pendingEditorRecord&&revision===connectionRevision&&!abort?.signal.aborted&&hid&&!hid.dead){
      reviewLightingEditorResult(pendingEditorRecord,editorReview);editorRecord=clone(pendingEditorRecord);
    }
  }catch(error){editorRecord=null;status(error.message,true);}finally{pendingEditorRecord=null;abort=null;busy=false;render();}
}
async function loadInput(value,name){
  editorRecord=null;input=null;latestRecord=null;writeAttempted=false;writtenTarget=null;powerCycle=null;
  $('lighting-plan').textContent='正在核对新计划；此前选择已清除。';
  const prepared=lightingAcceptanceInput(value);
  if(prepared.kind==='write')new LightingCandidateAuthorization(prepared.value.plan,prepared.value.original);
  // Persist the selected source before enabling either operation button.
  artifacts.observations.push({kind:'loaded',at:new Date().toISOString(),name,input:clone(prepared.value)});await persistSession();
  input=prepared;latestRecord=prepared.kind==='restore'?clone(prepared.value):null;
  $('lighting-plan').textContent=prepared.kind==='write'?`已载入写入核对：模式 ${prepared.target.parameters[1]}，亮度 ${prepared.target.parameters[2]}/4。按键与宏保持备份。尚未写入。`:'已载入恢复记录；恢复前将重新读取完整配置。尚未发送。';
  status('计划已核对；请单独选择并读取 USB 键盘。');
}
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
  artifacts.observations.push({kind:'usbDisconnected',at:new Date().toISOString(),deviceToken:token(event.device)});
  void persistSession().catch(error=>status(`断开记录保存失败：${error.message}`,true));render();
});
navigator.hid?.addEventListener('connect',event=>{
  if(!supportsDevice(event.device)||!powerCycle?.reconnect(token(event.device),performance.now()))return;
  artifacts.observations.push({kind:'usbReconnected',at:new Date().toISOString(),deviceToken:token(event.device)});
  void persistSession().catch(error=>status(`重连记录保存失败：${error.message}`,true));render();
});
$('lighting-write').onclick=event=>operation('write',async()=>{
  requireThat(input?.kind==='write'&&!writeAttempted,'请先载入新的写入核对文件。');
  requireThat(confirm('本研究入口将实际写入灯效。请确认已保存恢复资料、松开全部按键，并保持页面前台。是否继续？'),'已取消，未写入。');
  gate.acknowledge(event);abort=new AbortController();writeAttempted=true;powerCycle=null;writtenTarget=null;render();
  const result=await hid.applyLightingCandidate(input.value.plan,input.value.original,{gate,cancelled:()=>abort.signal.aborted,backup,persist});
  if(result.readbackMatches){if(editorReview)pendingEditorRecord=clone(result.record);writtenTarget=clone(input.target);powerCycle=new LightingPowerCycle(token(hid.device));status('写入与完整读回一致。请观察灯光，再按下方提示断电重连。尚未验证外观或断电保留。');}
  else throw new Error(`本次写入未通过：${result.failure}。请保留记录，重新连接后核对恢复。`);
});
$('lighting-restore').onclick=event=>operation('restore',async()=>{
  requireThat(latestRecord,'尚无恢复记录。');
  requireThat(confirm('将从原始备份恢复灯效数据，颜色不再缩放。恢复前会重新读取并检查范围；请松开全部键。是否继续？'),'已取消，未恢复。');
  gate.acknowledge(event);abort=new AbortController();render();
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
  requireThat(writtenTarget&&powerCycle&&hid?.dead,'需先检测到 USB 拔出，并关闭键盘电源。');
  powerCycle.confirmPowerOff(performance.now());artifacts.observations.push({kind:'userConfirmedPowerOff',at:new Date().toISOString()});await persistSession();status('已记录你的关电确认。请等待至少 15 秒，再开电、接回 USB 并重新选择键盘。');
});
$('lighting-retention').onclick=()=>operation('retention',async()=>{
  requireThat(writtenTarget&&powerCycle,'尚无本轮断电记录。');
  const session=hid,selectedToken=token(session.device),evidence=powerCycle.evidence(selectedToken);
  const current=await session.snapshot();requireThat(hid===session&&!session.dead,'重连读回期间 USB 会话改变。');powerCycle.evidence(selectedToken);
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
