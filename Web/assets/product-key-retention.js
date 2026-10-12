import {clone,requireThat,lightingConfigurationEqual} from './model.js?v=0.6.0';
import {KeymapWriteAuthorization} from './safety.js?v=0.6.0';
import {LightingPowerCycle} from './lighting-test-plan.js?v=0.6.0';
import {supportsDevice} from './hid.js?v=0.6.0';
import {saveVerifiedLog} from './logs.js?v=0.6.0';
import {download} from './storage.js?v=0.6.0';

// Records the current page's confirmed key write. No transport is opened here;
// verification uses only the already selected main-page USB session.
export function installKeyRetention(operation,{getHID,isBusy}){
  const $=id=>document.getElementById(id),tokens=new WeakMap();
  const token=device=>{if(!tokens.has(device))tokens.set(device,crypto.randomUUID());return tokens.get(device);};
  let target=null,cycle=null,record=null,storageTail=Promise.resolve(),pending=0,storageFailure=null;
  let message='按键写入成功后可开始本轮断电检查。刷新页面会结束本轮，已保存记录可在排查资料中导出。';
  function render(){
    const busy=isBusy(),online=getHID();
    $('key-retention-start').disabled=busy||pending>0||!target||!online||online.dead||token(online.device)!==target.deviceToken;
    $('key-retention-off').disabled=busy||pending>0||!!storageFailure||!cycle||cycle.disconnectedAt==null||cycle.returnedAt!=null;
    $('key-retention-check').disabled=busy||pending>0||!!storageFailure||!cycle||cycle.powerOffAt==null||cycle.returnedAt==null||!online||online.dead;
    $('key-retention-export').disabled=busy||pending>0||!record;
    $('key-retention-status').textContent=storageFailure?`本轮记录保存失败，不能通过：${storageFailure}。可导出现有资料，重新开始检查。`:message;
  }
  function persist(){
    const source=record,copy=clone(source);pending++;render();
    const task=storageTail.then(()=>saveVerifiedLog(copy));
    storageTail=task.catch(error=>{if(record===source)storageFailure=String(error?.message??error);});
    return task.finally(()=>{pending--;render();});
  }
  function event(kind){
    record.events.push({kind,at:new Date().toISOString(),clockMilliseconds:performance.now()});
    record.powerCycle=clone({disconnectedAt:cycle.disconnectedAt,powerOffAt:cycle.powerOffAt,returnedAt:cycle.returnedAt,returnedToken:cycle.returnedToken});
    void persist().catch(()=>{});
  }
  const disconnected=eventInfo=>{
    if(!cycle||!record||!cycle.disconnect(token(eventInfo.device),performance.now()))return;
    delete record.current;delete record.evidence;delete record.configurationMatches;
    record.status='disconnected';message='已记录 USB 拔出。请关闭键盘电源，再点击“已关电”；仅拔 USB 不算关闭电池供电。';event('usbDisconnected');render();
  };
  const connected=eventInfo=>{
    if(!cycle||!record||!supportsDevice(eventInfo.device)||!cycle.reconnect(token(eventInfo.device),performance.now()))return;
    record.status='reconnected';message='已记录兼容键盘重连。请连接主页面 USB，再点击只读核对；过早接回需重新拔线、关电并等待。';event('usbReconnected');render();
  };
  navigator.hid?.addEventListener('disconnect',disconnected);
  navigator.hid?.addEventListener('connect',connected);
  window.addEventListener('pagehide',()=>{cycle=null;navigator.hid?.removeEventListener('disconnect',disconnected);navigator.hid?.removeEventListener('connect',connected);});
  $('key-retention-start').onclick=()=>operation(async()=>{
    const hid=getHID();requireThat(target&&hid&&!hid.dead&&token(hid.device)===target.deviceToken,'请先在本页面完成按键写入，保持该 USB 会话。');
    requireThat(pending===0,'断电事件尚未完成保存。');
    cycle=new LightingPowerCycle(target.deviceToken);storageFailure=null;
    record={format:'CherryMacKeyRetentionSession',version:1,id:crypto.randomUUID(),at:new Date().toISOString(),status:'waitingDisconnect',before:clone(target.before),target:clone(target.snapshot),events:[],powerCycle:null,evidenceScope:'USB events and user power-off confirmation; no proof of battery disconnection, physical serial identity or key output'};
    message='记录已开始。请拔 USB、关闭键盘电源，再点击“已关电”；之后等待至少 15 秒再开电并接 USB。';
    await persist();
  },{localOnly:true});
  $('key-retention-off').onclick=()=>operation(async()=>{
    requireThat(cycle&&record&&!storageFailure&&pending===0,'缺少完整拔插记录或保存未完成。');
    cycle.confirmPowerOff(performance.now());record.status='powerOffConfirmed';
    record.events.push({kind:'userConfirmedPowerOff',at:new Date().toISOString(),clockMilliseconds:cycle.powerOffAt});
    record.powerCycle=clone({disconnectedAt:cycle.disconnectedAt,powerOffAt:cycle.powerOffAt,returnedAt:cycle.returnedAt,returnedToken:cycle.returnedToken});
    message='已记录关电确认。至少等待 15 秒后开电并接 USB，切回有线，再连接主页面 USB。';await persist();
  },{localOnly:true});
  $('key-retention-check').onclick=()=>operation(async()=>{
    const hid=getHID(),source=record,selectedCycle=cycle;
    requireThat(hid&&!hid.dead&&source&&selectedCycle&&pending===0&&!storageFailure,'请先完成关电、重连和记录保存。');
    const evidence=selectedCycle.evidence(token(hid.device));
    source.status='reading';message='只读核对当前配置，不发送写包，也不替换编辑草稿。';await persist();
    try{
      const current=await hid.snapshot();await hid.flushLogs();
      requireThat(record===source&&cycle===selectedCycle&&getHID()===hid&&!hid.dead&&pending===0&&!storageFailure,'读取期间会话或断电记录改变，请重新完成本轮。');
      selectedCycle.evidence(token(hid.device));
      source.current=clone(current);source.evidence=evidence;
      source.configurationMatches=lightingConfigurationEqual(current,source.target);
      source.status=source.configurationMatches?'readbackMatched':'readbackMismatch';
      await persist();
      requireThat(record===source&&cycle===selectedCycle&&!hid.dead&&pending===0&&!storageFailure,'结果保存期间会话改变，记录不是完整本轮结果。');
      message=source.configurationMatches?'关电确认至少 15 秒后，重新连接的完整可见配置与写入目标一致。实体键输出、实际电池断电与物理身份未由此证明。':'重连读回与写入目标不同。请保留记录和备份；本入口没有恢复或再次写入键盘。';
    }catch(error){
      if(record===source){source.status='failed';source.failure=String(error?.message??error);message=source.failure;if(!storageFailure)try{await persist();}catch{}}
      throw error;
    }
  });
  $('key-retention-export').onclick=()=>operation(()=>{requireThat(record,'尚无本轮记录。');download(record,`CherryMac-key-retention-${record.id}.json`);},{localOnly:true});
  return {render,setTarget(before,snapshot,device){
    const auth=new KeymapWriteAuthorization(before,snapshot.keymap);
    requireThat(auth.changedSlots.length>0&&lightingConfigurationEqual(auth.expected,snapshot),'断电检查仅接受本页面已确认的按键写入结果。');
    target={before:clone(before),snapshot:clone(snapshot),deviceToken:token(device)};cycle=null;record=null;storageFailure=null;
    message='本轮按键已写入并即时读回一致。需要检查断电保留时，点击“开始记录拔插”；此检查不会再写入。';render();
  }};
}
