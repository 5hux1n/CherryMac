import {clone,requireThat,validateSnapshot,decodeBank,macroCompletionRequirements} from './model.js?v=0.6.0';
import {keys} from './layout.js?v=0.6.0';
const canonical=x=>JSON.stringify(x,(_,v)=>v&&typeof v==='object'&&!Array.isArray(v)?Object.fromEntries(Object.keys(v).sort().map(k=>[k,v[k]])):v);

// Quiet/release observation is distinct from execution evidence. The explicit
// user stop acknowledgement is required; this never measures firmware state.
export class MacroStopObservation{
  constructor(request,startedMilliseconds){
    requireThat(request&&['beforeWrite','recovery'].includes(request.phase)&&Array.isArray(request.configurations)&&Array.isArray(request.requirements),'停止请求无效。');
    requireThat(request.configurations.length===(request.phase==='beforeWrite'?1:2)&&request.requirements.length===request.configurations.length,'停止请求配置数量无效。');
    const requirements=request.configurations.map(s=>{validateSnapshot(s,true);return macroCompletionRequirements(s.keymap,decodeBank(s.macroData));});
    requireThat(canonical(requirements)===canonical(request.requirements),'停止请求与实际配置不一致。');
    const bindings=requirements.flatMap(r=>r.repeatingBindings);requireThat(bindings.length>0,'没有需要确认停止的持续宏。');
    requireThat(Number.isInteger(startedMilliseconds)&&startedMilliseconds>=0,'停止观察时钟无效。');
    this.request=clone(request);this.quietMilliseconds=Math.max(200,...bindings.map(b=>b.quietMilliseconds));
    this.startedMilliseconds=startedMilliseconds;this.lastMilliseconds=startedMilliseconds;this.lastActivity=startedMilliseconds;
    this.held=new Set();this.events=[];this.failure=null;this.acknowledged=null;
  }
  interrupt(reason){this.failure??=String(reason);}
  clock(milliseconds){
    if(!Number.isInteger(milliseconds)||milliseconds<this.lastMilliseconds){this.interrupt('停止观察时钟无效或倒退。');throw new Error(this.failure);}
    this.lastMilliseconds=milliseconds;
  }
  observe({kind,code,pressed,milliseconds}){
    this.clock(milliseconds);
    requireThat(!this.failure,'停止观察已经失败。');
    if(!['key','mouse','motion'].includes(kind)||typeof code!=='string'||!code||code.length>80||typeof pressed!=='boolean'||(kind==='motion'&&(code!=='pointer'||pressed))){
      this.interrupt('停止观察事件无法识别。');throw new Error(this.failure);
    }
    if(this.events.length>=65536){this.interrupt('停止观察容量已满。');throw new Error(this.failure);}
    const identity=`${kind}:${code}`;
    if(kind!=='motion'){if(pressed)this.held.add(identity);else this.held.delete(identity);}
    this.lastActivity=milliseconds;this.events.push({kind,code,pressed,milliseconds});
    // Output after acknowledgement revokes it, including an already-held key.
    if(this.acknowledged!=null){this.interrupt('确认后仍检测到输入，不能继续写入。');throw new Error(this.failure);}
  }
  assess(milliseconds){
    this.clock(milliseconds);
    const remaining=Math.max(0,this.quietMilliseconds-(milliseconds-this.lastActivity));
    return {canAcknowledge:!this.failure&&this.acknowledged==null&&this.held.size===0&&remaining===0,remainingMilliseconds:remaining,heldCount:this.held.size,failure:this.failure};
  }
  acknowledge(milliseconds){
    requireThat(this.assess(milliseconds).canAcknowledge,'请先停止宏、完全松开并等候观察结束。');this.acknowledged=milliseconds;
  }
  record(){return {format:'CherryMacPhysicalMacroStop',version:1,source:'focusedBrowser',scope:'explicit user stop acknowledgement and focused page input only; no device identity, system-wide idle, firmware stop command or power-off proof',request:clone(this.request),startedMilliseconds:this.startedMilliseconds,quietMilliseconds:this.quietMilliseconds,lastActivityMilliseconds:this.lastActivity,assessedMilliseconds:this.lastMilliseconds,events:clone(this.events),failure:this.failure,userConfirmedStopped:this.acknowledged!=null&&this.failure==null,acknowledgedMilliseconds:this.acknowledged};}
}

// Supply this as the writer's confirmStopped callback. Normal product macro
// writes remain closed; opening this dialog sends no HID commands.
export function confirmMacroStopped(request,{hid,gate,log,signal,win=window,doc=document}={}){
  requireThat(gate&&typeof gate.acknowledge==='function'&&typeof gate.check==='function'&&typeof gate.invalidate==='function'&&typeof log==='function','缺少释放确认或可靠日志，不能确认停止。');
  requireThat(!signal?.aborted,'用户已取消宏停止确认。');
  const clock=()=>Math.floor(performance.now()),observation=new MacroStopObservation(request,clock());
  requireThat(doc.hasFocus()&&doc.visibilityState==='visible','请保持页面在前台。');
  const dialog=doc.createElement('dialog');dialog.className='macro-stop-dialog';dialog.setAttribute('aria-label','停止持续宏');
  const make=(tag,text,cls)=>{const e=doc.createElement(tag);e.textContent=text;if(cls)e.className=cls;return e;};
  const title=make('h2',request.phase==='recovery'?'恢复前，先停止正在运行的宏':'改配置前，先停止正在运行的宏');
  const description=make('p','仅停止正在运行的宏，不要为了确认而启动它。不确定时取消，关闭键盘电源，再重新连接读取。');
  const list=make('ul','');list.className='macro-stop-bindings';
  const names=new Set(request.requirements.flatMap(r=>r.repeatingBindings).map(b=>`${keys.find(k=>k.slot===b.slot)?.label??`槽位 ${b.slot}`}：${b.playback.mode==='held'?'松开触发键':'用原触发键停止'}`));
  for(const name of names)list.append(make('li',name));
  const area=make('div','请保持此页面在前台。这里观察输入，不发送停止命令。','macro-stop-area');area.tabIndex=0;area.setAttribute('role','region');area.setAttribute('aria-label','停止宏输入观察区');
  const status=make('p','','macro-stop-status');status.setAttribute('aria-live','polite');
  const limitation=make('p','网页只观察当前页面。请先在键盘上停止宏并松开全部键，再确认。','help');
  const accept=make('button','所有持续宏已停止，全部键已松开');accept.type='button';accept.className='primary macro-stop-accept';accept.disabled=true;
  const cancel=make('button','取消并停止发送');cancel.type='button';cancel.className='macro-stop-cancel';
  const controls=make('div','','form-row');controls.append(accept,cancel);dialog.append(title,description,list,area,status,limitation,controls);doc.body.append(dialog);
  const id=crypto.randomUUID(),at=new Date().toISOString();let saved=Promise.resolve(),failure=null,finished=false,pending=false,completed=false,completedAt=null,revision=0,timer;
  const listeners=[];const listen=(target,name,fn,opts)=>{target.addEventListener(name,fn,opts);listeners.push(()=>target.removeEventListener(name,fn,opts));};
  let resolve,reject;const result=new Promise((yes,no)=>{resolve=yes;reject=no;});
  const persist=()=>{const row={id,operationId:hid?.operationId??null,at,kind:'macroStop',...observation.record(),result:observation.failure?'failed':completed?'complete':pending?'pendingConfirmation':'waiting',postAcknowledgementQuietMilliseconds:completedAt==null?null:completedAt-observation.acknowledged};saved=saved.then(()=>log(row)).catch(error=>{failure=error;observation.interrupt(`停止日志保存失败：${error.message}`);});return saved;};
  const cleanup=()=>{clearInterval(timer);listeners.forEach(remove=>remove());dialog.close();dialog.remove();};
  const fail=async reason=>{if(finished)return;finished=true;accept.disabled=true;gate.invalidate();observation.interrupt(reason);await persist();cleanup();reject(new Error(failure?.message??reason));};
  const refresh=()=>{if(finished)return;try{
    if(hid?.dead){void fail('USB 会话已经断开，停止后续发送。');return;}
    const s=observation.assess(clock());accept.disabled=pending||!!failure||!s.canAcknowledge;
    const text=s.heldCount?'仍检测到按键或鼠标按钮按住，请停止宏并完全松开。':pending?'正在核对确认期间是否出现新输入…':`停止输出后还需观察 ${(s.remainingMilliseconds/1000).toFixed(1)} 秒，再用鼠标确认。`;
    if(status.textContent!==text)status.textContent=text;
    if(failure)void fail(`停止日志保存失败：${failure.message}`);
  }catch(error){void fail(error.message);}};
  const observed=(kind,code,pressed)=>{if(finished)return;try{revision++;observation.observe({kind,code,pressed,milliseconds:clock()});void persist();refresh();}catch(error){void fail(error.message);}};
  listen(win,'keydown',e=>{if(!e.isTrusted)return;if(e.key==='Escape'){e.preventDefault();void fail('用户取消停止确认。');return;}if(e.isComposing||!e.code||e.code==='Unidentified'){void fail('键盘或输入法事件无法可靠识别。');return;}if(e.key!=='Tab')e.preventDefault();observed('key',e.code,true);},true);
  listen(win,'keyup',e=>{if(e.isTrusted)observed('key',e.code,false);},true);
  const buttonCode=button=>({0:'left',1:'middle',2:'right',3:'back',4:'forward'})[button];
  listen(win,'mousedown',e=>{if(!e.isTrusted||accept.contains(e.target)||cancel.contains(e.target))return;const code=buttonCode(e.button);if(!code){void fail('鼠标按钮无法识别。');return;}e.preventDefault();observed('mouse',code,true);},true);
  listen(win,'mouseup',e=>{if(!e.isTrusted)return;const code=buttonCode(e.button);if(!code){void fail('鼠标按钮无法识别。');return;}if(observation.held.has(`mouse:${code}`)||(!accept.contains(e.target)&&!cancel.contains(e.target)))observed('mouse',code,false);},true);
  listen(win,'mousemove',e=>{if(e.isTrusted&&(e.movementX!==0||e.movementY!==0))observed('motion','pointer',false);},true);
  listen(dialog,'contextmenu',e=>e.preventDefault());
  listen(win,'wheel',e=>{if(e.isTrusted&&!list.contains(e.target))void fail('观察区出现滚动输出，停止确认已中止。');},true);
  if(signal)listen(signal,'abort',()=>void fail('用户已取消宏停止确认，停止后续发送。'));
  listen(win,'blur',()=>void fail('页面失去焦点，停止后续发送。'));
  listen(doc,'visibilitychange',()=>{if(doc.visibilityState!=='visible')void fail('页面已隐藏，停止后续发送。');});
  listen(dialog,'cancel',e=>{e.preventDefault();void fail('用户取消停止确认。');});
  listen(dialog,'close',()=>{if(!finished)void fail('停止窗口被关闭，停止后续发送。');});
  listen(cancel,'click',()=>void fail('用户取消停止确认。'));
  listen(accept,'click',async event=>{
    if(pending||finished||!event.isTrusted||event.detail<=0||event.button!==0||event.buttons!==0||event.ctrlKey||event.altKey||event.metaKey||event.shiftKey)return;
    try{
      requireThat(doc.hasFocus()&&doc.visibilityState==='visible','页面离开前台，不能确认停止。');observation.acknowledge(clock());pending=true;refresh();
      const expectedRevision=revision;await persist();requireThat(!failure,'停止日志保存失败。');
      requireThat(!finished&&!observation.failure&&revision===expectedRevision,'确认期间出现输入或停止确认已取消。');
      gate.acknowledge(event);await gate.check();
      // A fresh interval, rather than borrowing the quiet time before a click.
      await new Promise(r=>setTimeout(r,250));
      requireThat(!finished&&!failure&&revision===expectedRevision&&!observation.failure&&doc.hasFocus()&&doc.visibilityState==='visible'&&!hid?.dead,'确认期间出现输入或页面状态变化，停止后续发送。');
      completed=true;completedAt=clock();observation.assess(completedAt);await persist();requireThat(!failure,'停止日志保存失败。');finished=true;cleanup();resolve({...observation.record(),result:'complete',postAcknowledgementQuietMilliseconds:completedAt-observation.acknowledged});
    }catch(error){gate.invalidate();void fail(error.message);}
  });
  try{dialog.showModal();area.focus();timer=setInterval(refresh,50);void persist();refresh();}catch(error){void fail(error.message);}
  return result;
}


// File-only assessment; accepting a record never grants a HID permission.
export function replayMacroStopRecord(record){
  requireThat(record?.format==='CherryMacPhysicalMacroStop'&&record.version===1&&record.source==='focusedBrowser'&&Array.isArray(record.events)&&record.events.length<=65536,'停止日志格式或来源无效。');
  const stop=new MacroStopObservation(record.request,record.startedMilliseconds),ack=record.acknowledgedMilliseconds;
  requireThat(ack==null||Number.isInteger(ack)&&ack>=record.startedMilliseconds,'停止确认时钟无效。');let marked=false;
  for(const [index,event] of record.events.entries()){
    if(ack!=null&&!marked&&event.milliseconds>=ack){stop.acknowledge(ack);marked=true;}
    try{stop.observe(event);}catch(error){if(stop.failure!=='确认后仍检测到输入，不能继续写入。'||stop.events.length!==index+1)throw error;}
  }
  requireThat(stop.events.length===record.events.length,'停止日志包含终止后无法接受的事件。');
  if(ack!=null&&!marked)stop.acknowledge(ack);
  if(stop.failure)requireThat(record.failure===stop.failure,'停止日志错误状态不一致。');
  requireThat(record.result==null||['waiting','pendingConfirmation','complete','failed'].includes(record.result),'停止日志结果无效。');
  if(record.failure!=null){requireThat(typeof record.failure==='string'&&record.failure.length<=2000,'停止错误记录无效。');stop.interrupt(record.failure);}
  const assessed=stop.assess(record.assessedMilliseconds);
  requireThat(record.quietMilliseconds===stop.quietMilliseconds&&record.lastActivityMilliseconds===stop.lastActivity,'停止日志观察预算或活动时间不一致。');
  requireThat(record.userConfirmedStopped===(ack!=null&&!stop.failure),'停止日志确认状态不一致。');
  const complete=record.result==='complete';
  if(complete)requireThat(!stop.failure&&ack!=null&&record.assessedMilliseconds-ack>=250&&Number.isFinite(record.postAcknowledgementQuietMilliseconds)&&record.postAcknowledgementQuietMilliseconds>=250&&record.postAcknowledgementQuietMilliseconds<=record.assessedMilliseconds-ack,'停止日志没有完整的确认后静默观察。');
  return {status:stop.failure?'failed':complete?'acknowledged':'waiting',source:'focusedBrowser',scope:stop.record().scope,eventCount:record.events.length,quietMilliseconds:stop.quietMilliseconds,canAcknowledge:assessed.canAcknowledge,failure:stop.failure};
}
