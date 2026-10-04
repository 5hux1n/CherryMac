import {CherryHID,PageReleaseGate} from './hid.js?v=0.6.0';
import {clone,equal,requireThat,assessLightingRestoreAttempt} from './model.js?v=0.6.0';
import {LightingCandidateAuthorization} from './safety.js?v=0.6.0';
import {lightingAcceptanceInput,lightingRecoveryForFreshRead} from './lighting-test-plan.js?v=0.6.0';
import {saveBackup,download} from './storage.js?v=0.6.0';
import {saveLog} from './logs.js?v=0.6.0';
const $=id=>document.getElementById(id),gate=new PageReleaseGate(),runID=crypto.randomUUID();
const artifacts={format:'CherryMacLightingAcceptanceSession',version:1,hardwareReady:false,runID,startedAt:new Date().toISOString(),backups:[],records:[],usb:[],observations:[]};
let input=null,hid=null,busy=false,abort=null,latestRecord=null,writeAttempted=false,writtenTarget=null,unpluggedAt=null,powerOffAt=null,usbReturnAt=null;
const same=(a,b)=>['deviceInfo','keymap','parameters','colors','macroData'].every(k=>equal(a[k],b[k]));
function status(text,error=false){$('lighting-state').textContent=text;$('lighting-state').classList.toggle('error',error);}
function render(){
  const online=hid&&!hid.dead;
  for(const id of ['lighting-file','lighting-connect','lighting-close','lighting-write','lighting-restore','lighting-power-off','lighting-retention','lighting-download','lighting-download-record'])$(id).disabled=busy;
  $('lighting-connect').disabled=busy||!isSecureContext||!('hid' in navigator);
  $('lighting-close').disabled=busy||!online;
  $('lighting-write').disabled=busy||!online||input?.kind!=='write'||writeAttempted;
  $('lighting-restore').disabled=busy||!online||!latestRecord;
  $('lighting-stop').disabled=!abort||abort.signal.aborted;
  $('lighting-download-record').disabled=busy||!latestRecord;
  $('lighting-power-off').disabled=busy||!writtenTarget||unpluggedAt==null||online||usbReturnAt!=null;
  $('lighting-retention').disabled=busy||!online||!writtenTarget||powerOffAt==null;
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
async function operation(body){
  if(busy)return;busy=true;render();
  try{await body();}catch(error){status(error.message,true);}finally{abort=null;busy=false;render();}
}
$('lighting-file').onchange=()=>operation(async()=>{
  const file=$('lighting-file').files[0];if(!file)return;
  input=null;latestRecord=null;writeAttempted=false;writtenTarget=null;unpluggedAt=null;powerOffAt=null;usbReturnAt=null;
  $('lighting-plan').textContent='正在核对新文件；此前选择已清除。';
  requireThat(file.size<=3_000_000,'文件超过 3 MB。');
  const prepared=lightingAcceptanceInput(JSON.parse(await file.text()));
  // Validate the exact scope now; files cannot broaden the research sender.
  if(prepared.kind==='write')new LightingCandidateAuthorization(prepared.value.plan,prepared.value.original);
  input=prepared;latestRecord=prepared.kind==='restore'?clone(prepared.value):null;
  writeAttempted=false;writtenTarget=null;unpluggedAt=null;powerOffAt=null;usbReturnAt=null;
  $('lighting-plan').textContent=prepared.kind==='write'?`已载入写入核对：模式 ${prepared.target.parameters[1]}，亮度 ${prepared.target.parameters[2]}/4。按键与宏保持备份。尚未写入。`:'已载入恢复记录；恢复前将重新读取完整配置。尚未发送。';
  artifacts.observations.push({kind:'loaded',at:new Date().toISOString(),name:file.name,input:clone(prepared.value)});await persistSession();status('文件已核对；请单独选择并读取 USB 键盘。');
});
$('lighting-connect').onclick=()=>operation(async()=>{
  const devices=await navigator.hid.requestDevice({filters:[{vendorId:1130,productId:462,usagePage:0xff1c,usage:0x92}]});requireThat(devices.length===1,'未选择键盘。');
  if(hid)await hid.close();
  const session=new CherryHID(devices[0],{lightingResearch:true,log:async entry=>{
    await saveLog(entry);artifacts.usb.push(clone(entry));
  },progress:message=>status(message),onDisconnect:error=>{gate.invalidate();status(error.message,true);render();}});
  hid=session;await session.open();const snapshot=await session.snapshot();
  artifacts.observations.push({kind:'connectedRead',at:new Date().toISOString(),snapshot:clone(snapshot)});await persistSession();
  status('完整配置已读取。连接与读取没有写入；请核对计划后用鼠标选择操作。');
});
$('lighting-close').onclick=()=>operation(async()=>{await hid.close();status('会话已关闭。此操作不代表 USB 已拔出或键盘已断电。');});
navigator.hid?.addEventListener('disconnect',event=>{
  if(event.device!==hid?.device)return;
  unpluggedAt=performance.now();powerOffAt=null;usbReturnAt=null;artifacts.observations.push({kind:'usbDisconnected',at:new Date().toISOString()});
  void persistSession().catch(error=>status(`断开记录保存失败：${error.message}`,true));render();
});
navigator.hid?.addEventListener('connect',event=>{
  if(unpluggedAt==null||event.device.vendorId!==1130||event.device.productId!==462)return;
  usbReturnAt=performance.now();artifacts.observations.push({kind:'usbReconnected',at:new Date().toISOString()});
  void persistSession().catch(error=>status(`重连记录保存失败：${error.message}`,true));render();
});
$('lighting-write').onclick=event=>operation(async()=>{
  requireThat(input?.kind==='write'&&!writeAttempted,'请先载入新的写入核对文件。');
  requireThat(confirm('本研究入口将实际写入灯效。请确认已保存恢复资料、松开全部按键，并保持页面前台。是否继续？'),'已取消，未写入。');
  gate.acknowledge(event);abort=new AbortController();writeAttempted=true;unpluggedAt=null;powerOffAt=null;usbReturnAt=null;writtenTarget=null;render();
  const result=await hid.applyLightingCandidate(input.value.plan,input.value.original,{gate,cancelled:()=>abort.signal.aborted,backup,persist});
  if(result.readbackMatches){writtenTarget=clone(input.target);status('写入与完整读回一致。请观察灯光，再按下方提示断电重连。尚未验证外观或断电保留。');}
  else status(`本次写入未通过：${result.failure}。请保留记录，重新连接后核对恢复。`,true);
});
$('lighting-restore').onclick=event=>operation(async()=>{
  requireThat(latestRecord,'尚无恢复记录。');
  requireThat(confirm('将从原始备份恢复灯效数据，颜色不再缩放。恢复前会重新读取并检查范围；请松开全部键。是否继续？'),'已取消，未恢复。');
  gate.acknowledge(event);abort=new AbortController();render();
  const current=await hid.snapshot(),recovery=lightingRecoveryForFreshRead(latestRecord,current);
  const attempt=await hid.restoreLightingCandidate(recovery,{gate,cancelled:()=>abort.signal.aborted,backup,persist});
  const review=assessLightingRestoreAttempt(attempt);
  writtenTarget=null;powerOffAt=null;unpluggedAt=null;
  status(['readbackMatched','alreadyMatched'].includes(review.status)?'原始备份与完整读回一致。请确认键盘操作与灯光外观，再下载资料。':`恢复未通过：${attempt.failure||review.status}。保留记录并重新连接，不自动重试。`,!['readbackMatched','alreadyMatched'].includes(review.status));
});
$('lighting-stop').onclick=()=>{abort?.abort();gate.invalidate();status('已请求停止后续发送；正在发出的报告不能撤回，恢复记录会保留。');render();};
$('lighting-power-off').onclick=()=>operation(async()=>{
  requireThat(writtenTarget&&unpluggedAt!=null&&usbReturnAt==null&&hid?.dead,'需先检测到 USB 拔出，并关闭键盘电源。');
  powerOffAt=performance.now();artifacts.observations.push({kind:'userConfirmedPowerOff',at:new Date().toISOString()});await persistSession();status('已记录你的关电确认。请等待至少 15 秒，再开电、接回 USB 并重新选择键盘。');
});
$('lighting-retention').onclick=()=>operation(async()=>{
  requireThat(writtenTarget&&powerOffAt!=null&&usbReturnAt!=null&&usbReturnAt-powerOffAt>=15_000,'需检测到关电确认至少 15 秒后的 USB 重连；过早接回时请再次拔出、关电并确认。');
  const current=await hid.snapshot(),matches=same(current,writtenTarget);
  artifacts.observations.push({kind:'powerCycleReadback',at:new Date().toISOString(),userConfirmedPowerOff:true,elapsedMilliseconds:Math.floor(usbReturnAt-powerOffAt),matches,current:clone(current)});await persistSession();
  status(matches?'关电确认后的完整读回符合写入目标。灯光外观仍需观察；接下来可以恢复原始数据。':'重连后的配置与目标不同。请保留资料，核对原始数据恢复。',!matches);
});
$('lighting-download').onclick=()=>operation(async()=>{await hid?.flushLogs();download(artifacts,`CherryMac-灯效验收-${runID}.json`);status('资料已下载；不会自动恢复或修改键盘。');});
$('lighting-download-record').onclick=()=>operation(async()=>{requireThat(latestRecord,'尚无恢复记录。');download(latestRecord,`CherryMac-灯效恢复记录-${latestRecord.operationID}.json`);status('已下载独立恢复记录，可在新会话载入。');});
window.addEventListener('beforeunload',event=>{abort?.abort();gate.invalidate();if(busy){event.preventDefault();event.returnValue='';}});
render();
