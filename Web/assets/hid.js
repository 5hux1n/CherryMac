import {executeLightingRestore,executeOfficialLightingCandidate,captureLightingMapping,requireThat,validateSnapshot} from './model.js?v=0.6.0';
import {prepareHostTextBindings,prepareHostTextInstallation,officialHostTextEvent} from './model.js?v=0.6.0';
import {assertReadOnlyRequest,LightingCandidateAuthorization,KeymapWriteAuthorization,MacroWriteAuthorization,HostTextWriteAuthorization} from './safety.js?v=0.6.0';
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
  #keyAuthorization=null;#macroAuthorization=null;#lightingAuthorization=null;#writeGate=null;#lastKeyWriteAt=null;
  #configurationGeneration=0;
  #hostTextObservation=null;#hostTextObservationGeneration=0;
  constructor(device,{timeout=2000,onDisconnect=()=>{},progress=()=>{},log=()=>{},macroResearch=false,macroProduct=false,textProduct=false,lightingResearch=false}={}){
    requireThat(supportsDevice(device),'浏览器没有提供这把键盘的 63 字节厂商配置接口。请确认 USB 有线模式。');
    this.device=device;this.timeout=timeout;this.progress=progress;this.onDisconnect=onDisconnect;this.tail=Promise.resolve();this.dead=false;this.pending=null;
    // Both entries use the same immutable packet authorization. Product
    // preview is explicitly gated by the PHP deployment environment.
    if(lightingResearch===true){
      this.applyLightingCandidate=(plan,baseline,options)=>this.#applyLightingCandidate(plan,baseline,options);
      this.restoreLightingCandidate=(recovery,options)=>this.#restoreLightingCandidate(recovery,options);
    }
    if(textProduct===true)this.withHostTextAuthorization=(authorization,gate,body)=>this.#withHostTextAuthorization(authorization,gate,body);
    if(macroResearch===true||macroProduct===true)this.withMacroAuthorization=(authorization,gate,body)=>this.#withMacroAuthorization(authorization,gate,body);
    this.history=[];this.log=log;this.logTasks=Promise.resolve();this.loggingError=null;this.keyWritesSent=0;
    this.input=e=>{
      if(e.device!==this.device)return;
      if(e.reportId===5){
        const observation=this.#hostTextObservation;
        if(!observation||this.dead||!this.device.opened||e.data.byteLength!==8)return;
        const bytes=[5,...new Uint8Array(e.data.buffer,e.data.byteOffset,e.data.byteLength)],binding=observation.resolve(bytes);
        if(!binding)return;
        const isCurrent=()=>this.#hostTextObservation===observation&&!this.dead&&this.device.opened;
        const failed=error=>{if(isCurrent()){
          this.stopHostTextObservation();
          // Consumer failures must not escape into the configuration reader.
          try{Promise.resolve(observation.onError(error)).catch(()=>{});}catch{}
        }};
        try{Promise.resolve(observation.onBinding(binding,isCurrent)).catch(failed);}catch(error){failed(error);}
        return;
      }
      if(e.reportId!==4||!this.pending)return;const p=this.pending;
      try{const bytes=new Uint8Array(1+e.data.byteLength);bytes[0]=4;bytes.set(new Uint8Array(e.data.buffer,e.data.byteOffset,e.data.byteLength),1);p.entry.reply=Array.from(bytes);validateReply(bytes,p.request);this.finish(null,bytes);}
      catch(error){this.poison(error);}
    };
    this.disconnected=e=>{if(e.device===device)this.poison(new Error('键盘已经断开。重新连接后请先读取配置。'));};
  }
  async open(){await this.device.open();this.device.addEventListener('inputreport',this.input);globalThis.navigator?.hid?.addEventListener('disconnect',this.disconnected);}
  record(entry){const copy=structuredClone(entry);this.logTasks=this.logTasks.then(()=>this.log(copy)).catch(error=>{this.loggingError=error.message;});}
  finish(error,result){const p=this.pending;if(!p)return;this.pending=null;clearTimeout(p.timer);p.entry.durationMs=performance.now()-p.start;p.entry.status=error?'error':'ok';p.entry.error=error?.message??null;this.record(p.entry);if(error)p.reject(error);else p.resolve(result);}
  poison(error){if(this.dead)return;this.#lightingAuthorization?.invalidate();this.stopHostTextObservation();this.dead=true;this.finish(error);this.device.removeEventListener('inputreport',this.input);globalThis.navigator?.hid?.removeEventListener('disconnect',this.disconnected);void this.device.close().catch(()=>{});this.onDisconnect(error);}
  async close(){this.poison(new Error('USB 会话已关闭。'));await this.tail.catch(()=>{});}
  async flushLogs(){await this.logTasks;requireThat(!this.loggingError,`操作日志保存失败，停止写入：${this.loggingError}`);}
  async withKeymapAuthorization(authorization,gate,body){
    requireThat(authorization instanceof KeymapWriteAuthorization&&!this.#keyAuthorization&&!this.#macroAuthorization&&!this.#lightingAuthorization&&gate&&typeof gate.check==='function','键位写入授权或按键释放确认无效。');
    this.#keyAuthorization=authorization;this.#writeGate=gate;
    try{return await body();}finally{this.#keyAuthorization=null;this.#writeGate=null;}
  }
  async #withHostTextAuthorization(authorization,gate,body){
    requireThat(authorization instanceof HostTextWriteAuthorization&&!this.#keyAuthorization&&!this.#macroAuthorization&&!this.#lightingAuthorization&&gate&&typeof gate.check==='function'&&typeof body==='function','文本安装授权或按键释放确认无效。');
    this.#keyAuthorization=authorization;this.#writeGate=gate;
    try{return await body();}finally{this.#keyAuthorization=null;this.#writeGate=null;}
  }
  async #withMacroAuthorization(authorization,gate,body){
    requireThat(authorization instanceof MacroWriteAuthorization&&!this.#keyAuthorization&&!this.#macroAuthorization&&!this.#lightingAuthorization&&gate&&typeof gate.check==='function'&&typeof body==='function','宏事务授权或释放检查无效。');
    this.#macroAuthorization=authorization;this.#writeGate=gate;
    try{return await body();}finally{this.#macroAuthorization=null;this.#writeGate=null;}
  }
  async #restoreLightingCandidate(recovery,{gate,cancelled,backup,persist}){
    recovery=structuredClone(recovery);const authorization=LightingCandidateAuthorization.recovery(recovery),device=this.device;
    requireThat(gate&&typeof gate.check==='function'&&[cancelled,backup,persist].every(fn=>typeof fn==='function'),'恢复需要释放确认、取消、备份与日志接口。');
    await this.tail;
    requireThat(!this.dead&&device.opened&&this.device===device&&!this.#keyAuthorization&&!this.#macroAuthorization&&!this.#lightingAuthorization,'恢复需要可用的新 USB 会话。');
    this.stopHostTextObservation();this.#lightingAuthorization=authorization;this.#writeGate=gate;
    try{return await executeLightingRestore(recovery,{source:'usbTrace',cancelled,backup,persist,
      assertCurrent:()=>requireThat(!this.dead&&device.opened&&this.device===device&&this.#lightingAuthorization===authorization,'恢复 USB 会话已经改变。'),
      read:()=>this.snapshot(),clock:()=>Math.floor(performance.now()),wait:sleep,exchange:request=>this.exchange(request)});
    }finally{this.#lightingAuthorization=null;this.#writeGate=null;}
  }
  async #applyLightingCandidate(plan,baseline,{gate,cancelled,backup,persist}){
    plan=structuredClone(plan);baseline=structuredClone(baseline);
    const authorization=new LightingCandidateAuthorization(plan,baseline),device=this.device;
    requireThat(gate&&typeof gate.check==='function'&&[cancelled,backup,persist].every(fn=>typeof fn==='function'),'灯效研究需要释放确认、取消、备份与日志接口。');
    await this.tail;
    requireThat(!this.dead&&device.opened&&this.device===device&&!this.#keyAuthorization&&!this.#macroAuthorization&&!this.#lightingAuthorization,'USB 会话不可用或已有配置事务。');
    this.stopHostTextObservation();this.#lightingAuthorization=authorization;this.#writeGate=gate;
    try{return await executeOfficialLightingCandidate(plan,baseline,{source:'usbTrace',cancelled,backup,persist,
      assertCurrent:()=>requireThat(!this.dead&&device.opened&&this.device===device&&this.#lightingAuthorization===authorization,'灯效 USB 会话已经改变。'),
      read:()=>this.snapshot(),clock:()=>Math.floor(performance.now()),wait:sleep,exchange:request=>this.exchange(request)});
    }finally{this.#lightingAuthorization=null;this.#writeGate=null;}
  }
  exchange(request){
    // Copy before queueing: callers cannot alter a previously validated packet.
    request=Array.from(request);
    // Invalidate prepared text data when a mutation is queued, before it can
    // affect the keyboard. A failed/blocked mutation also requires rereading.
    if([6,9,11,0x15].includes(request[3])){this.#configurationGeneration++;this.stopHostTextObservation();}
    const task=this.tail.then(async()=>{
      requireThat(request.every(v=>Number.isInteger(v)&&v>=0&&v<=255),'USB 包包含无效字节。');
      const lighting=[1,2,6,11].includes(request[3])&&this.#lightingAuthorization;
      const authorization=lighting||(request[3]===9&&this.#keyAuthorization)||([9,0x15].includes(request[3])&&this.#macroAuthorization);
      const writing=Boolean(authorization);
      if(writing)authorization.validate(request);else assertReadOnlyRequest(request);
      requireThat(!this.dead&&this.device.opened,'USB 连接已失效，请重新连接。');
      if(writing){
        if(!lighting&&this.#lastKeyWriteAt!=null)await sleep(Math.max(0,1500-(performance.now()-this.#lastKeyWriteAt)));
        await this.#writeGate.check();await this.flushLogs();
      }
      const entry={id:crypto.randomUUID(),operationId:this.operationId??null,at:new Date().toISOString(),command:request[3],offset:request[5]|request[6]<<8,length:request[4],request:Array.from(request),reply:null,status:'pending',durationMs:null,error:null};
      this.history.push(entry);this.record(entry);
      if(this.history.length>300)this.history.shift();
      if(writing){try{await this.flushLogs();await this.#writeGate.check();requireThat(!this.dead&&this.device.opened,'键盘已经断开，停止写入。');}catch(error){entry.status='blocked';entry.error=error.message;this.record(entry);throw error;}}
      return new Promise((resolve,reject)=>{
        this.pending={request,resolve,reject,entry,start:performance.now(),timer:setTimeout(()=>this.poison(new Error('USB 回复超时；命令可能已执行。已停止发送，请重新连接并读取。')),this.timeout)};
        // WebHID receives the ID separately: 4 + 63 bytes, never a duplicated ID.
        if(writing&&!lighting){this.keyWritesSent++;this.#lastKeyWriteAt=performance.now();}
        this.device.sendReport(4,Uint8Array.from(request.slice(1))).catch(error=>this.poison(error));
      }).then(reply=>{if(lighting){try{lighting.accept(reply,request);}catch(error){this.poison(error);throw error;}}return reply;});
    });this.tail=task.catch(()=>{});return task;
  }
  async read(command,count){const result=[];
    for(let offset=0;offset<count;offset+=54){const length=Math.min(54,count-offset),b=await this.exchange(packet(command,offset,length));result.push(...b.slice(8,8+length));}
    return result;
  }
  async readHostTextBindings(root){
    requireThat(!this.dead&&this.device.opened,'USB 连接已失效，请重新连接。');
    const supported=(this.device.collections??[]).some(c=>c.usagePage===0xff1c&&c.usage===0x92&&descendants(c).some(d=>(d.inputReports??[]).some(r=>r.reportId===5&&(r.items??[]).reduce((n,i)=>n+i.reportSize*i.reportCount,0)===64)));
    requireThat(supported,'浏览器没有提供文本触发所需的 Report 5 输入接口。');
    // Freeze the official JSON before asynchronous reads; draft edits must not
    // change the prepared action references midway through this operation.
    root=structuredClone(root);
    const generation=this.#configurationGeneration;
    const before=await this.read(8,378),factory=await this.read(7,378),after=await this.read(8,378);
    requireThat(!this.dead&&this.device.opened&&generation===this.#configurationGeneration&&before.every((v,i)=>v===after[i]),'准备文本监听期间配置或 USB 会话发生变化，请重新读取。');
    const binding=prepareHostTextBindings(root,factory,after);
    // Caller supplies a complete report from this device's input event. This
    // is a resolver only: no listener or cross-application execution installed.
    return fullReport=>{
      if(this.dead||!this.device.opened||generation!==this.#configurationGeneration)return null;
      const value=officialHostTextEvent(fullReport);return value===null?null:binding(value);
    };
  }
  stopHostTextObservation(){this.#hostTextObservation=null;this.#hostTextObservationGeneration++;}
  async startHostTextObservation(root,{onBinding,onError}={}){
    requireThat(!this.#lightingAuthorization,'灯效事务期间不能启动文本服务。');
    requireThat(typeof onBinding==='function'&&typeof onError==='function','文本监听需要事件和错误处理器。');
    this.stopHostTextObservation();const generation=this.#hostTextObservationGeneration;
    const resolve=await this.readHostTextBindings(root);
    requireThat(!this.dead&&this.device.opened&&generation===this.#hostTextObservationGeneration,'文本监听准备已取消，请重新读取。');
    this.#hostTextObservation={resolve,onBinding,onError};
  }
  async readHostTextInstallation(root,baseline){
    requireThat(!this.dead&&this.device.opened,'USB 连接已失效，请重新连接。');
    root=structuredClone(root);baseline=structuredClone(baseline);
    validateSnapshot(baseline,true);
    const generation=this.#configurationGeneration;
    const before=await this.read(8,378),factory=await this.read(7,378),after=await this.read(8,378);
    requireThat(!this.dead&&this.device.opened&&generation===this.#configurationGeneration&&before.every((v,i)=>v===after[i]&&v===baseline.keymap[i]),'准备文本安装期间键位或读取基线发生变化，请重新读取。');
    return prepareHostTextInstallation(root,factory,baseline);
  }
  async readLightingMapping(snapshot){
    requireThat(!this.dead&&this.device.opened,'USB 连接已失效，请重新连接。');
    const device=this.device,generation=this.#configurationGeneration;
    const mapping=await captureLightingMapping(snapshot,(command,count)=>this.read(command,count));
    requireThat(!this.dead&&this.device===device&&device.opened&&generation===this.#configurationGeneration,'读取灯光映射期间 USB 会话或配置发生变化，请重新读取。');return mapping;
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
  constructor(win=window,doc=document){this.win=win;this.doc=doc;this.held=new Set();this.armed=false;this.lastKey=0;this.activity=0;
    this.down=e=>{this.held.add(e.code);this.lastKey=performance.now();this.activity++;};
    this.up=e=>{this.held.delete(e.code);this.lastKey=performance.now();this.activity++;};
    this.blur=()=>this.invalidate();win.addEventListener('keydown',this.down,true);win.addEventListener('keyup',this.up,true);win.addEventListener('blur',this.blur);doc.addEventListener('visibilitychange',this.blur);
  }
  invalidate(){this.armed=false;this.activity++;}
  acknowledge(event){requireThat(event.detail>0,'请松开全部键，用鼠标点击确认。');requireThat(this.doc.hasFocus()&&this.doc.visibilityState==='visible','请保持页面在前台。');
    requireThat(!(event.ctrlKey||event.altKey||event.metaKey||event.shiftKey),'请松开 Ctrl、Alt、Win 和 Shift。');
    // A deliberate physical acknowledgement resets events missed while unfocused.
    this.held.clear();this.armed=true;this.lastKey=performance.now();this.activity++;
  }
  async check(){requireThat(this.armed&&this.doc.hasFocus()&&this.doc.visibilityState==='visible','页面离开了前台，已停止写入。请松开全部键后重新确认。');
    requireThat(this.held.size===0,'检测到按键仍按住，已停止写入。');
    const activity=this.activity,start=performance.now();
    // A new continuous observation period for EVERY check. Never borrow the
    // wait before an earlier command; even a down/up tap invalidates this one.
    do{await sleep(Math.max(1,200-(performance.now()-start)));
      const valid=this.activity===activity&&this.armed&&this.doc.hasFocus()&&this.doc.visibilityState==='visible'&&this.held.size===0;
      if(!valid)this.armed=false;
      requireThat(valid,'等待期间检测到按键或页面状态变化，已停止写入，请重新确认。');
    }while(performance.now()-start<200);
  }
}
