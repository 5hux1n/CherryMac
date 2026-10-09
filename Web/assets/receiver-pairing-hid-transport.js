import {ReceiverPairingDevices} from './receiver-pairing-devices.js';
import {checkedReceiverPairingSelection,sameReceiverPairingSelection} from './receiver-pairing-selection.js';
import {receiverPairingFrame} from './receiver-pairing-frames.js';
import {loadPairingJournal} from './receiver-pairing-journal.js';
import {loadPairingRawLog} from './receiver-pairing-raw-log.js';

// Development transport; not imported by the product runtime. No automatic
// open, selector default, backup substitute, pairing retry or UI write grant.
// Reply binding is one report on the pinned endpoint after a single send;
// command/checksum echoes and cross-process exclusivity remain unproved.
export class ReceiverPairingHIDTransport {
  #devices;#selection;#keyboard;#receiver;#hid;
  #state='new';#pending=null;#busy=false;#operationID=null;#consumed=new Set();
  #opens=[];#owned=new Set();#closeTask=null;#cleanupErrors=[];
  constructor(devices,selection){
    if(!(devices instanceof ReceiverPairingDevices))throw new Error('配对传输需要当前真实设备选择器。');
    this.#devices=devices;this.#selection=checkedReceiverPairingSelection(selection);
    this.#hid=globalThis.navigator?.hid;
    if(!this.#hid)throw new Error('浏览器没有提供 WebHID。');
    const bound=this.#resolve();this.#keyboard=bound.keyboard;this.#receiver=bound.receiver;
    if(this.#keyboard===this.#receiver)throw new Error('键盘与接收器不能是同一个接口。');
  }
  #resolve(){
    const bound=this.#devices.resolve({keyboardToken:this.#selection.keyboard.token,receiverToken:this.#selection.receiver.token});
    if(!sameReceiverPairingSelection(bound.selection,this.#selection)||!bound.keyboard||!bound.receiver)throw new Error('配对端点选择发生变化。');
    if(this.#keyboard&&(bound.keyboard!==this.#keyboard||bound.receiver!==this.#receiver))throw new Error('配对端点对象已更换。');
    return bound;
  }
  currentSelection(){
    if(this.#state==='closed')throw new Error('配对传输已经关闭。');
    this.#resolve();return this.#selection;
  }
  #disconnect=event=>{if(event.device===this.#keyboard||event.device===this.#receiver)this.#poison(new Error('配对端点已断开；本次传输停止。'));};
  #input=event=>{
    if(this.#state==='closed'||event.reportId!==4)return;
    if(event.device!==this.#keyboard&&event.device!==this.#receiver)return;
    const pending=this.#pending;
    if(!pending||!pending.sent||event.device!==pending.device){this.#poison(new Error('收到本次请求之外的配置回复；停止而不重试。'));return;}
    if(pending.reply!==null){this.#poison(new Error('同一配对请求收到多个配置回复。'));return;}
    try{
      this.currentSelection();
      if(!(event.data instanceof DataView)||event.data.byteLength>65535)throw new Error('配对回复没有有效原始数据。');
      // Preserve the actual length. The wire adapter logs the bounded sample
      // before applying the 64-byte frame/status checks.
      const bytes=[4,...new Uint8Array(event.data.buffer,event.data.byteOffset,event.data.byteLength)];
      if(bytes.length>65536)throw new Error('配对回复超过传输范围。');
      pending.reply=bytes;this.#finishIfReady();
    }catch(error){this.#poison(error);}
  };
  #finishIfReady(){
    const pending=this.#pending;
    if(pending?.sendCompleted&&pending.reply!==null){this.#pending=null;pending.resolve(pending.reply);}
  }
  #poison(error){
    if(this.#state==='closed')return;
    this.#state='closed';const pending=this.#pending;this.#pending=null;pending?.reject(error);
    this.#keyboard.removeEventListener('inputreport',this.#input);
    this.#receiver.removeEventListener('inputreport',this.#input);
    this.#hid.removeEventListener('disconnect',this.#disconnect);
    void this.close().catch(()=>{});
  }
  async open({signal}={}){
    if(this.#state!=='new')throw new Error('配对传输不能重复打开。');
    this.currentSelection();cancel(signal);
    if(this.#keyboard.opened||this.#receiver.opened)throw new Error('配置接口已打开，请先关闭其他配置会话。');
    this.#state='opening';
    this.#keyboard.addEventListener('inputreport',this.#input);
    this.#receiver.addEventListener('inputreport',this.#input);
    this.#hid.addEventListener('disconnect',this.#disconnect);
    try{
      for(const device of [this.#keyboard,this.#receiver]){
        this.currentSelection();cancel(signal);
        const task=Promise.resolve().then(()=>{
          if(this.#state==='closed')throw new Error('打开设备前配对传输已停止。');
          return device.open();
        }).then(async()=>{
          this.#owned.add(device);
          if(this.#state==='closed'){
            try{await device.close();this.#owned.delete(device);}
            catch(error){this.#cleanupErrors.push(error);throw error;}
          }
        });
        // Retain the real open promise: a deadline is not OS cancellation.
        this.#opens.push(task);task.catch(()=>{});
        await bounded(task,5000,signal,'配对接口打开超时。');
        this.currentSelection();cancel(signal);
        if(!device.opened)throw new Error('配对接口未保持打开。');
      }
      this.#state='open';
    }catch(error){this.#poison(error);throw error;}
  }
  async exchange(endpoint,request,{signal,id,intent,phase,selector}={}){
    if(this.#state!=='open'||this.#busy)throw new Error('配对传输尚未打开、已失效或正在交换报告。');
    const plan=receiverPairingFrame(phase,selector);
    if(plan.endpoint!==endpoint||!Array.isArray(request)||JSON.stringify(request)!==JSON.stringify(plan.request))throw new Error('配对传输只接受本阶段固定请求。');
    this.currentSelection();cancel(signal);this.#busy=true;
    // No arbitrary authorization callback. Require the actual durable pending
    // checkpoint and the actual prepared raw record before one physical send.
    try{
      const checkpoints=await bounded(loadPairingJournal(id),5000,signal,'配对检查点读取超时。'),state=checkpoints.at(-1)?.state;
      this.currentSelection();cancel(signal);
      const raw=await bounded(loadPairingRawLog(id),5000,signal,'配对原始日志读取超时。'),last=raw.at(-1)?.entry;
      this.currentSelection();cancel(signal);
      if(this.#state!=='open'||this.#pending||!state?.pending||state.operationID!==intent||state.phase!==phase||!state.backupReference||!sameReceiverPairingSelection(state.selection,this.#selection)||last?.intent!==intent||last.stage!=='prepared'||last.phase!==phase||last.endpoint!==endpoint||last.selector!==plan.selector||!sameReceiverPairingSelection(last.selection,this.#selection)||JSON.stringify(last.request)!==JSON.stringify(plan.request))throw new Error('配对发送缺少本次已保存的意图和准备记录。');
      if((this.#operationID!==null&&this.#operationID!==id)||this.#consumed.has(intent))throw new Error('配对传输操作编号已变化或意图已使用。');
      this.#operationID=id;this.#consumed.add(intent);
      const device=endpoint==='keyboard'?this.#keyboard:this.#receiver;
      if(!device.opened)throw new Error('所选配置接口已经关闭。');
      const response=new Promise((resolve,reject)=>{
        const pending={device,reply:null,sent:false,sendCompleted:false,resolve,reject};this.#pending=pending;
        Promise.resolve().then(()=>{
          this.currentSelection();cancel(signal);
          if(this.#state!=='open'||this.#pending!==pending)throw new Error('发送前配对传输已停止。');
          pending.sent=true;
          return device.sendReport(4,Uint8Array.from(plan.request.slice(1)));
        }).then(()=>{
          if(this.#state==='closed'||this.#pending!==pending)return;
          pending.sendCompleted=true;this.#finishIfReady();
        }).catch(error=>this.#poison(error));
      });
      const reply=await bounded(response,endpoint==='keyboard'?1000:5000,signal,'配对报告交换超时；没有重试。');
      this.currentSelection();cancel(signal);return reply;
    }catch(error){this.#poison(error);throw error;}finally{this.#busy=false;}
  }
  async close(){
    if(this.#closeTask)return this.#closeTask;
    if(this.#state!=='closed')this.#poison(new Error('配对传输已关闭。'));
    if(this.#closeTask)return this.#closeTask;
    this.#closeTask=(async()=>{
      // Start closing already owned endpoints immediately. Waiting for a
      // hung second open must not leave the first endpoint open indefinitely.
      const closing=Promise.allSettled([...this.#owned].map(async device=>{
        try{await device.close();this.#owned.delete(device);}
        catch(error){this.#cleanupErrors.push(error);throw error;}
      }));
      await bounded(Promise.allSettled([...this.#opens,closing]),5000,null,'配对接口打开或关闭尚未结束，清理未确认完成。');
      if(this.#cleanupErrors.length)throw this.#cleanupErrors[0];
      if(this.#owned.size)throw new Error('配对接口清理未确认完成。');
    })();
    return this.#closeTask;
  }
}
function cancel(signal){if(signal?.aborted)throw new DOMException('配对已取消。','AbortError');}
function bounded(task,milliseconds,signal,message){
  return new Promise((resolve,reject)=>{
    let done=false;
    const finish=(error,value)=>{
      if(done)return;done=true;clearTimeout(timer);signal?.removeEventListener('abort',abort);
      if(error)reject(error);else resolve(value);
    };
    const abort=()=>finish(new DOMException('配对已取消。','AbortError'));
    const timer=setTimeout(()=>finish(new Error(message)),milliseconds);
    signal?.addEventListener('abort',abort,{once:true});
    if(signal?.aborted)abort();
    Promise.resolve(task).then(value=>finish(null,value),error=>finish(error));
  });
}
