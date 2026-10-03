import {requireThat} from './model.js?v=0.6.0';
import {applyMacroConfiguration,restoreMacroTransaction} from './writer.js?v=0.6.0';
import {confirmMacroStopped} from './macro-stop.js?v=0.6.0';

// A nominal finite delay is never evidence of firmware cancellation. Keep the
// UI responsive and never pass a potentially >2^31 delay to setTimeout.
export async function waitForFiniteMacroCompletion(milliseconds,{hid,gate,signal,win=window,doc=document,now=()=>performance.now(),pause=ms=>new Promise(r=>setTimeout(r,ms))}={}){
  requireThat(Number.isSafeInteger(milliseconds)&&milliseconds>=0&&gate&&typeof gate.check==='function','有限宏等待参数无效。');
  const start=now();requireThat(Number.isFinite(start),'等待时钟无效。');const deadline=start+milliseconds;let previous=start;
  const ready=()=>{
    requireThat(!signal?.aborted,'用户已取消宏写入，停止发送。');requireThat(!hid?.dead,'USB 会话已失效，停止发送。');
    requireThat(doc.hasFocus()&&doc.visibilityState==='visible'&&(!('armed' in gate)||gate.armed===true),'页面或释放确认失效，停止发送。');
  };
  while(true){
    ready();const current=now();requireThat(Number.isFinite(current)&&current>=previous,'等待时钟无效或倒退。');previous=current;
    const remaining=deadline-current;if(remaining<=0)break;await pause(Math.min(100,remaining));
  }
  ready();await gate.check();ready();
}

// Product/test integration: backup, logging, stop UI and nominal completion
// feed the same scoped writer. This grants no macro transport capability.
export async function applyMacroWithStop(hid,target,before,{gate,backup,progress=()=>{},signal,win=window,doc=document}={}){
  return macroSession(applyMacroConfiguration,hid,target,before,{gate,backup,progress,signal,win,doc});
}

export async function recoverMacroWithStop(hid,before,target,{gate,backup,progress=()=>{},signal,win=window,doc=document}={}){
  return macroSession(restoreMacroTransaction,hid,before,target,{gate,backup,progress,signal,win,doc});
}

async function macroSession(transaction,hid,first,second,{gate,backup,progress,signal,win,doc}){
  requireThat(gate&&typeof gate.check==='function'&&typeof gate.acknowledge==='function'&&typeof gate.invalidate==='function','缺少物理释放确认。');
  const ready=()=>requireThat(!signal?.aborted,'用户已取消宏写入，停止发送。');
  ready();
  const guardedGate={invalidate:()=>gate.invalidate(),acknowledge:event=>{ready();gate.acknowledge(event);},check:async()=>{ready();await gate.check();ready();}};
  return transaction(hid,first,second,{gate:guardedGate,backup,progress,
    waitForCompletion:ms=>waitForFiniteMacroCompletion(ms,{hid,gate,signal,win,doc}),
    confirmStopped:request=>confirmMacroStopped(request,{hid,gate:guardedGate,signal,win,doc,log:async row=>{hid.record(row);await hid.flushLogs();}})
  });
}
