import {requireThat,validateSnapshot} from './model.js?v=0.1.1';
import {assertReadOnlyRequest} from './safety.js?v=0.1.1';
export const sleep=ms=>new Promise(r=>setTimeout(r,ms));
const READ_COMMANDS=new Set([3,5,7,8,0x0a,0x14,0x1b]);
export function packet(command,offset,length,data=[],flag=0){
  requireThat(Number.isInteger(offset)&&offset>=0&&offset<=65535&&Number.isInteger(length)&&length>0&&length<=56&&(data.length===0||data.length===length),'USB 分块参数无效。');
  const b=new Uint8Array(64);b[0]=4;b[3]=command;b[4]=length;b[5]=offset&255;b[6]=offset>>8;b[7]=flag;b.set(data,8);
  const sum=b.slice(3).reduce((n,v)=>n+v,0);b[1]=sum&255;b[2]=sum>>8;return b;
}
export function validateReply(reply,request){
  requireThat(reply.length===64&&reply[0]===4&&reply[3]===request[3],'USB 回复命令或报告长度不匹配。');
  requireThat(reply[7]!==255&&reply[7]!==254,'键盘拒绝了此命令。');
  requireThat([4,5,6,7].every(i=>reply[i]===request[i]),'USB 回复偏移或状态不匹配。');
  const checksum=Array.from(request.slice(3,READ_COMMANDS.has(request[3])?8:64)).reduce((n,v)=>n+v,0);
  requireThat((reply[1]|reply[2]<<8)===checksum,'USB 回复校验失败。');
}
function descendants(c){return [c,...(c.children??[]).flatMap(descendants)];}
export function supportsDevice(device){
  if(device.vendorId!==1130||device.productId!==462)return false;
  return (device.collections??[]).some(c=>c.usagePage===0xff1c&&c.usage===0x92&&['inputReports','outputReports'].every(kind=>
    descendants(c).some(d=>(d[kind]??[]).some(r=>r.reportId===4&&(r.items??[]).reduce((n,i)=>n+i.reportSize*i.reportCount,0)===504))));
}
export class CherryHID{
  constructor(device,{timeout=2000,onDisconnect=()=>{},progress=()=>{},log=()=>{}}={}){
    requireThat(supportsDevice(device),'浏览器没有提供这把键盘的 63 字节厂商配置接口。请确认 USB 有线模式。');
    this.device=device;this.timeout=timeout;this.progress=progress;this.onDisconnect=onDisconnect;this.tail=Promise.resolve();this.dead=false;this.pending=null;
    this.history=[];this.log=log;this.logTasks=Promise.resolve();this.loggingError=null;
    this.input=e=>{if(e.reportId!==4||!this.pending)return;const p=this.pending;
      try{const bytes=new Uint8Array(1+e.data.byteLength);bytes[0]=4;bytes.set(new Uint8Array(e.data.buffer,e.data.byteOffset,e.data.byteLength),1);p.entry.reply=Array.from(bytes);validateReply(bytes,p.request);this.finish(null,bytes);}
      catch(error){this.poison(error);}
    };
    this.disconnected=e=>{if(e.device===device)this.poison(new Error('键盘已经断开。重新连接后请先读取配置。'));};
  }
  async open(){await this.device.open();this.device.addEventListener('inputreport',this.input);globalThis.navigator?.hid?.addEventListener('disconnect',this.disconnected);}
  record(entry){const copy=structuredClone(entry);this.logTasks=this.logTasks.then(()=>this.log(copy)).catch(error=>{this.loggingError=error.message;});}
  finish(error,result){const p=this.pending;if(!p)return;this.pending=null;clearTimeout(p.timer);p.entry.durationMs=performance.now()-p.start;p.entry.status=error?'error':'ok';p.entry.error=error?.message??null;this.record(p.entry);if(error)p.reject(error);else p.resolve(result);}
  poison(error){if(this.dead)return;this.dead=true;this.finish(error);this.device.removeEventListener('inputreport',this.input);globalThis.navigator?.hid?.removeEventListener('disconnect',this.disconnected);void this.device.close().catch(()=>{});this.onDisconnect(error);}
  async close(){this.poison(new Error('USB 会话已关闭。'));await this.tail.catch(()=>{});}
  exchange(request){
    const task=this.tail.then(()=>{
      assertReadOnlyRequest(request);
      requireThat(!this.dead&&this.device.opened,'USB 连接已失效，请重新连接。');
      const entry={id:crypto.randomUUID(),at:new Date().toISOString(),command:request[3],offset:request[5]|request[6]<<8,length:request[4],request:Array.from(request),reply:null,status:'pending',durationMs:null,error:null};
      this.history.push(entry);this.record(entry);
      if(this.history.length>300)this.history.shift();
      return new Promise((resolve,reject)=>{
        this.pending={request,resolve,reject,entry,start:performance.now(),timer:setTimeout(()=>this.poison(new Error('USB 回复超时；命令可能已执行。已停止发送，请重新连接并读取。')),this.timeout)};
        // WebHID receives the ID separately: 4 + 63 bytes, never a duplicated ID.
        this.device.sendReport(4,request.slice(1)).catch(error=>this.poison(error));
      });
    });this.tail=task.catch(()=>{});return task;
  }
  async read(command,count){const result=[];
    for(let offset=0;offset<count;offset+=54){const length=Math.min(54,count-offset),b=await this.exchange(packet(command,offset,length));result.push(...b.slice(8,8+length));}
    return result;
  }
  async snapshot(){
    this.progress('读取设备信息');const deviceInfo=await this.read(3,34);
    requireThat(deviceInfo[6]===24,'宏存储容量与已验证固件不符，停止读取。');
    this.progress('读取键位');const keymap=await this.read(8,378);
    this.progress('读取灯光参数');const parameters=await this.read(5,56);
    this.progress('读取逐键颜色');const colors=await this.read(0x0a,378);
    this.progress('读取宏存储');const macroData=await this.read(0x14,3071);
    const s={format:'CherryMacHardware',version:1,vendorID:1130,productID:462,deviceInfo,keymap,parameters,colors,macroData,createdAt:Date.now()/1000-978307200};validateSnapshot(s,true);return s;
  }
}
// Browser events only cover this focused page. They cannot prove system-wide
// keyboard idleness. The explicit physical-release acknowledgement is required.
export class PageReleaseGate{
  constructor(win=window,doc=document){this.win=win;this.doc=doc;this.held=new Set();this.armed=false;this.lastKey=0;
    this.down=e=>{this.held.add(e.code);this.lastKey=performance.now();};
    this.up=e=>{this.held.delete(e.code);this.lastKey=performance.now();};
    this.blur=()=>{this.armed=false;};win.addEventListener('keydown',this.down,true);win.addEventListener('keyup',this.up,true);win.addEventListener('blur',this.blur);doc.addEventListener('visibilitychange',this.blur);
  }
  acknowledge(event){requireThat(event.detail>0,'请松开全部键，用鼠标点击确认。');requireThat(this.doc.hasFocus()&&this.doc.visibilityState==='visible','请保持页面在前台。');
    requireThat(!(event.ctrlKey||event.altKey||event.metaKey||event.shiftKey),'请松开 Ctrl、Alt、Win 和 Shift。');
    // A deliberate physical acknowledgement resets events missed while unfocused.
    this.held.clear();this.armed=true;this.lastKey=performance.now();
  }
  async check(){requireThat(this.armed&&this.doc.hasFocus()&&this.doc.visibilityState==='visible','页面离开了前台，已停止写入。请松开全部键后重新确认。');
    requireThat(this.held.size===0,'检测到按键仍按住，已停止写入。');const elapsed=performance.now()-this.lastKey;if(elapsed<200)await sleep(200-elapsed);
    requireThat(this.armed&&this.doc.hasFocus()&&this.doc.visibilityState==='visible'&&this.held.size===0,'写入期间请保持页面在前台，并松开全部按键。');
  }
}
