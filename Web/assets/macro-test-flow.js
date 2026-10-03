import {clone,equal,requireThat,validateSnapshot,decodeBank,encodeBank,macroBinding,MacroExecutionEvidence} from './model.js?v=0.6.0';
import {CherryHID,PageReleaseGate,supportsDevice} from './hid.js?v=0.6.0';
import {MacroWriteAuthorization} from './safety.js?v=0.6.0';
import {applyMacroWithStop,recoverMacroWithStop} from './macro-session.js?v=0.6.0';
import {sameSnapshot} from './writer.js?v=0.6.0';
import {saveBackup,download,listBackups} from './storage.js?v=0.6.0';
import {saveLog,listLogs} from './logs.js?v=0.6.0';
export const testMacro={name:'CherryMac 实体测试 AB',steps:[{usage:4,pressed:true,delayMilliseconds:0},{usage:4,pressed:false,delayMilliseconds:80},{usage:5,pressed:true,delayMilliseconds:80},{usage:5,pressed:false,delayMilliseconds:80}]};
export const testPlayback={mode:'count',count:2};
export function macroTestScenario(id='ab-twice'){
  const definitions={
    'ab-twice':{label:'AB 两次',macro:testMacro,playback:testPlayback},
    'ab-once':{label:'AB 一次',macro:testMacro,playback:{mode:'count',count:1}},
    'ab-three':{label:'AB 三次',macro:testMacro,playback:{mode:'count',count:3}},
    modifier:{label:'Shift+A 一次（全部释放）',macro:{name:'CherryMac 修饰键测试',steps:[{usage:225,pressed:true,delayMilliseconds:0},{usage:4,pressed:true,delayMilliseconds:80},{usage:4,pressed:false,delayMilliseconds:80},{usage:225,pressed:false,delayMilliseconds:80}]},playback:{mode:'count',count:1}},
    mouse:{label:'鼠标中键一次（按下并释放）',macro:{name:'CherryMac 鼠标中键测试',steps:[{usage:4,pressed:true,delayMilliseconds:0,kind:'mouse'},{usage:4,pressed:false,delayMilliseconds:80,kind:'mouse'}]},playback:{mode:'count',count:1}}
  };
  requireThat(Object.hasOwn(definitions,id),'未知宏测试场景；未连接或写入键盘。');return {id,...clone(definitions[id])};
}
export function macroTestPlan(before,scenarioId='ab-twice'){
  const scenario=macroTestScenario(scenarioId);
  validateSnapshot(before,true);requireThat(equal(before.keymap.slice(306,309),[0x30,0x92,1]),'本轮需要原始计算器媒体键，不覆盖现有计算器映射。');
  const library=decodeBank(before.macroData);requireThat(library.length<32,'宏库已满，测试不会覆盖现有宏。');const index=library.length;
  const target=clone(before);target.macroData=encodeBank([...library,scenario.macro]);target.keymap.splice(306,3,...macroBinding(index,scenario.playback));return new MacroWriteAuthorization(before,target,{allowUnbounded:true});
}

// Research-only UI. Page input is not a device-specific HID output observer.
// Its logs preserve that limitation. Default product construction stays closed.
export class MacroTestFlow {
  constructor(root,{scenarioId='ab-twice',selectDevice=()=>navigator.hid.requestDevice({filters:[{vendorId:1130,productId:462,usagePage:0xff1c,usage:0x92}]}),makeHID=(device,options)=>new CherryHID(device,options),hidEvents=navigator.hid,now=()=>Math.floor(performance.now())}={}){
    this.scenario=macroTestScenario(scenarioId);this.root=root;this.selectDevice=selectDevice;this.makeHID=makeHID;this.hidEvents=hidEvents;this.now=now;this.id=crypto.randomUUID();this.phase='prepared';this.busy=false;this.writeAttempted=false;this.errors=[];this.gate=new PageReleaseGate();this.logs=Promise.resolve();this.logError=null;this.operationIds=new Set([this.id]);this.interruptions=[];
    root.innerHTML='<h1>宏 · 写入与断电测试</h1><p class="help">仅测试计算器键的独立宏场景。电源关闭由你确认；网页只能观察此页面的输入。</p><label class="form-row">本轮测试<select id="macro-test-scenario"></select></label><p class="notice" id="macro-test-status" role="status">先连接 USB 有线键盘，保存完整备份。</p><div class="form-row"><button class="primary" id="macro-test-next">连接并读取</button><button id="macro-test-restore" disabled>停止测试并恢复</button><button id="macro-test-export">导出本轮日志</button><button id="macro-test-resume">恢复以前中断的测试</button></div><label><input type="checkbox" id="macro-test-off" disabled>已关闭键盘电源（不只是拔 USB）</label><p id="macro-test-area" tabindex="0" class="macro-stop-area">输出观察区 · 按提示开始后，再按计算器键。</p>';
    root.querySelector('.help').textContent=`本轮：${this.scenario.label}。电源关闭由你确认；网页只能观察此页面的输入。`;
    this.scenarioPicker=root.querySelector('#macro-test-scenario');
    for(const id of ['ab-once','ab-twice','ab-three','modifier','mouse']){const option=document.createElement('option');option.value=id;option.textContent=macroTestScenario(id).label;this.scenarioPicker.append(option);}
    this.scenarioPicker.value=this.scenario.id;
    this.status=root.querySelector('#macro-test-status');this.next=root.querySelector('#macro-test-next');this.restore=root.querySelector('#macro-test-restore');this.off=root.querySelector('#macro-test-off');this.area=root.querySelector('#macro-test-area');this.listeners=[];
    const listen=(target,type,fn,options)=>{target?.addEventListener(type,fn,options);this.listeners.push(()=>target?.removeEventListener(type,fn,options));};
    listen(this.scenarioPicker,'change',()=>{
      if(this.busy||this.phase!=='prepared'){this.scenarioPicker.value=this.scenario.id;return;}
      this.scenario=macroTestScenario(this.scenarioPicker.value);root.querySelector('.help').textContent=`本轮：${this.scenario.label}。电源关闭由你确认；网页只能观察此页面的输入。`;
    });
    listen(this.next,'click',e=>this.act(e,()=>this.advance()));listen(this.restore,'click',e=>this.act(e,()=>this.recover()));
    listen(root.querySelector('#macro-test-export'),'click',()=>this.export());
    listen(root.querySelector('#macro-test-resume'),'click',e=>this.act(e,()=>this.resume()));
    listen(this.off,'change',e=>{if(!e.isTrusted||this.phase!=='reconnect'||!this.off.checked)return;this.offAt=this.now();this.off.disabled=true;this.transition('reconnect','已确认关闭电源。至少等 15 秒，再开电并接回同一把 USB 键盘。');});
    listen(window,'keydown',e=>this.input(e,true),true);listen(window,'keyup',e=>this.input(e,false),true);
    listen(window,'mousedown',e=>this.mouseInput(e,true),true);listen(window,'mouseup',e=>this.mouseInput(e,false),true);
    listen(window,'blur',()=>{if(this.phase==='observing')this.fail('页面失去焦点，输出观察中止。','focusLost');});
    listen(document,'visibilitychange',()=>{if(this.phase==='observing'&&document.visibilityState!=='visible')this.fail('页面已隐藏，输出观察中止。','focusLost');});
    listen(hidEvents,'connect',e=>this.reconnected(e.device));
    this.timer=setInterval(()=>this.poll(),100);
    this.beforeUnload=e=>{if(this.plan&&this.writeAttempted&&!this.restored){e.preventDefault();e.returnValue='';}};listen(window,'beforeunload',this.beforeUnload);
  }
  record(extra={}){
    const row={id:this.id,operationId:this.id,kind:'phase',at:new Date().toISOString(),format:'CherryMacWebMacroHardwareFlow',version:1,scenario:this.scenario.id,writeAttempted:this.writeAttempted,phase:this.phase,source:'focusedBrowser',scope:'page events only; no device-specific output or firmware delay proof; power off user-confirmed',errors:clone(this.errors),firstExecutionPassed:!!this.firstPassed,secondExecutionPassed:!!this.secondPassed,powerRetentionVerified:!!this.powerVerified,originalRestored:!!this.restored,passed:!!(this.firstPassed&&this.secondPassed&&this.powerVerified&&this.restored&&!this.errors.length),disconnectedMilliseconds:this.disconnectedAt??null,powerOffConfirmedMilliseconds:this.offAt??null,reconnectedMilliseconds:this.reconnectedAt??null,...extra};
    if(this.plan){row.baseline=this.plan.before;row.target=this.plan.expected;}
    this.logs=this.logs.then(()=>saveLog(row)).catch(e=>{this.logError=e;this.fail('日志保存失败，停止后续操作。','loggingFailed',false);});return this.logs;
  }
  async flush(){await this.logs;requireThat(!this.logError,'日志无法保存，停止写入。');}
  transition(phase,text){this.phase=phase;this.status.textContent=text;this.render();void this.record();}
  render(){this.scenarioPicker.disabled=this.busy||this.phase!=='prepared';this.next.disabled=this.busy||!['prepared','ready','observeReady','restoreReady','complete'].includes(this.phase);this.restore.disabled=this.busy||!this.plan||this.restored||this.phase==='ready';this.off.disabled=this.phase!=='reconnect'||this.offAt!=null;
    this.root.querySelector('#macro-test-resume').disabled=this.busy||!!this.plan;
    this.next.textContent=({prepared:'连接并读取',ready:'备份并写入测试宏',observeReady:'开始输出观察',restoreReady:'恢复原配置',complete:'本轮已结束'})[this.phase]??'等候当前步骤';}
  fail(message,interruption='cancelled',persist=true){if(this.phase==='observing'){this.evidence?.invalidate(interruption);if(!this.interruptions.includes(interruption))this.interruptions.push(interruption);void this.saveExecution();}this.errors.push(message);this.gate.invalidate();this.phase='failed';this.status.textContent=message;this.render();if(persist)void this.record();}
  async act(event,work){if(this.busy||!event.isTrusted||event.detail<=0)return;this.busy=true;this.render();try{this.gate.acknowledge(event);await this.flush();await work();}catch(e){this.fail(e.message);}finally{this.busy=false;this.render();}}
  async connect(){const selected=await this.selectDevice();requireThat(selected.length===1&&supportsDevice(selected[0]),'请选择唯一的一把本型号 USB 键盘。');this.device=selected[0];this.hid=this.newHID();await this.hid.open();return this.hid.snapshot();}
  newHID(){const hid=this.makeHID(this.device,{macroResearch:true,log:saveLog,onDisconnect:()=>this.disconnected()});hid.operationId=this.id;return hid;}
  async advance(){
    if(this.phase==='prepared'){const before=await this.connect();this.plan=macroTestPlan(before,this.scenario.id);await saveBackup(before);await saveBackup(this.plan.expected);this.transition('ready',`原配置与测试目标已保存。点击写入，仅将计算器键绑定到 ${this.scenario.label}。`);}
    else if(this.phase==='ready'){
      this.writeAttempted=true;this.transition('writing','正在备份、写入并完整读回。请勿按键或拔线。');await this.flush();
      const after=await applyMacroWithStop(this.hid,this.plan.expected,this.plan.before,{gate:this.gate,backup:saveBackup});requireThat(sameSnapshot(after,this.plan.expected),'目标读回不一致。');
      requireThat(this.phase==='writing','写入期间流程中断，请恢复原配置。');this.transition('observeReady','写入读回一致。点击开始，再按下并完全松开计算器键一次。');
    }else if(this.phase==='observeReady'){
      requireThat(!this.hid.dead&&document.hasFocus()&&document.visibilityState==='visible','请连接键盘并保持页面前台。');this.started=this.now();this.interruptions=[];this.evidence=new MacroExecutionEvidence({macro:this.scenario.macro,playback:this.scenario.playback,source:'focusedBrowser',startedMilliseconds:this.started});this.transition('observing',`现在按计算器键一次。预期 ${this.scenario.label}，共 ${this.scenario.macro.steps.length*this.scenario.playback.count} 个按下／松开事件。`);this.area.focus();
    }else if(this.phase==='restoreReady')await this.recover();
  }
  input(event,pressed){if(this.phase!=='observing'||!event.isTrusted)return;event.preventDefault();try{
    const usage=({KeyA:4,KeyB:5,ShiftLeft:225})[event.code];
    requireThat(!event.isComposing&&usage!=null,'检测到测试场景之外的按键。');
    this.evidence.observe({usage,pressed,milliseconds:this.now()});void this.saveExecution();
  }catch(e){this.fail(e.message,'reportRejected');}}
  mouseInput(event,pressed){if(this.phase!=='observing'||!event.isTrusted)return;event.preventDefault();try{
    requireThat(this.scenario.id==='mouse'&&event.button===1,'检测到测试场景之外的鼠标按钮。');
    this.evidence.observe({usage:4,kind:'mouse',pressed,milliseconds:this.now()});void this.saveExecution();
  }catch(e){this.fail(e.message,'reportRejected');}}
  async saveExecution(){if(!this.evidence)return;const log={id:`${this.id}-${this.powerVerified?'after':'before'}`,operationId:this.id,kind:'macroExecution',bindingSlot:102,at:new Date().toISOString(),format:'CherryMacMacroExecution',version:1,macro:clone(this.scenario.macro),playback:clone(this.scenario.playback),source:'focusedBrowser',startedMilliseconds:this.started,events:this.evidence.observations,stop:null,assessedMilliseconds:this.now(),interruptions:clone(this.interruptions)};this.logs=this.logs.then(()=>saveLog(log)).catch(e=>{this.logError=e;this.fail('输出日志保存失败。','loggingFailed',false);});return this.logs;}
  poll(){if(this.phase!=='observing')return;try{const assessment=this.evidence.assessment(this.now());if(assessment.status==='failed'){this.fail(assessment.failure,'reportRejected');return;}if(assessment.passed){
      if(this.powerVerified){this.secondPassed=true;this.transition('restoreReady','断电后的输出检查通过。点击恢复原配置。');}else{this.firstPassed=true;this.transition('disconnect','输出检查通过。拔下 USB 并关闭键盘电源；断开后勾选确认。');}void this.saveExecution();
    }else if(this.now()-this.started>300000)this.fail('观察超时，请停止测试并恢复。');}catch(e){this.fail(e.message,'loggingFailed');}}
  disconnected(){if(this.phase==='disconnect'){this.disconnectedAt=this.now();this.transition('reconnect','USB 已断开。请关闭键盘电源，勾选确认并等待至少 15 秒。');}else if(!['reconnect','complete'].includes(this.phase))this.fail('键盘在预定步骤外断开；重连后恢复原配置。','observerDisconnected');}
  async reconnected(device){if(this.phase!=='reconnect'||!supportsDevice(device))return;this.reconnectedAt=this.now();try{
      requireThat(device===this.device,'浏览器无法确认原获准设备，停止测试；请通过恢复入口重新选择。');requireThat(this.offAt!=null&&this.reconnectedAt-this.offAt>=15000,'USB 在电源确认前或 15 秒内重连，本次断电测试未通过。');this.busy=true;this.transition('reading','正在新会话读取；不会先重写目标。');await this.flush();this.hid=this.newHID();await this.hid.open();const after=await this.hid.snapshot();await saveBackup(after);
      requireThat(this.phase==='reading'&&sameSnapshot(after,this.plan.expected),'断电后完整配置未保留或流程中断。');this.powerVerified=true;this.evidence=null;this.transition('observeReady','断电后宏、绑定与其他配置一致。点击开始，再按计算器键一次。');
    }catch(e){this.fail(e.message);}finally{this.busy=false;this.render();}}
  async resume(){
    requireThat(!this.plan,'请先恢复当前测试，再读取以前的测试。');
    const logs=await listLogs(),previous=logs.filter(r=>r.format==='CherryMacWebMacroHardwareFlow'&&r.phase!=='complete'&&r.originalRestored!==true&&r.baseline&&r.target&&r.id!==this.id).at(-1);
    requireThat(previous,'没有可恢复的中断宏测试。');this.writeAttempted=true;this.plan=new MacroWriteAuthorization(previous.baseline,previous.target,{allowUnbounded:true});this.errors.push('恢复以前中断的测试，不计作本轮验收通过。');await this.recover();
  }
  async recover(){requireThat(this.phase!=='ready','首次写入前无需恢复，请直接退出。');requireThat(this.plan,'缺少本轮原表和目标。');if(this.phase==='observing'){this.evidence.invalidate('cancelled');this.interruptions.push('cancelled');await this.saveExecution();this.errors.push('用户提前恢复，测试未完整通过。');}
    if(!this.hid||this.hid.dead){const selected=await this.selectDevice();requireThat(selected.length===1&&supportsDevice(selected[0]),'请选择本轮同一把 USB 键盘恢复。');this.device=selected[0];this.hid=this.newHID();await this.hid.open();}
    this.transition('restoring','按原事务范围读回并恢复原配置。请勿按键或拔线。');await this.flush();const restored=await recoverMacroWithStop(this.hid,this.plan.before,this.plan.expected,{gate:this.gate,backup:saveBackup});requireThat(sameSnapshot(restored,this.plan.before),'恢复读回不一致。');this.restored=true;this.transition('complete',this.firstPassed&&this.secondPassed&&this.powerVerified&&!this.errors.length?'本轮检查通过，原配置已恢复。':'原配置已恢复；本轮未完成全部验收，不计作通过。');await this.flush();}
  async export(){try{await this.flush();const logs=await listLogs(),ids=new Set([this.id]);for(const row of logs)if(row.kind==='phase'&&row.baseline&&this.plan&&sameSnapshot(row.baseline,this.plan.before)&&sameSnapshot(row.target,this.plan.expected))ids.add(row.operationId);download({format:'CherryMacWebDiagnostics',version:1,usbLogs:logs.filter(r=>ids.has(r.operationId)),sessionLogs:[],backups:await listBackups()},'CherryMac-宏测试日志.json');}catch(e){this.status.textContent=e.message;}}
  dispose(){clearInterval(this.timer);this.listeners.forEach(f=>f());}
}
