import test from 'node:test';
import assert from 'node:assert/strict';
import {keys,demoSnapshot} from '../assets/layout.js';
import {clone,equal,encodeBank,decodeBank,validateMacro,MacroRecorder,fromHardware,resolveMacros,macroBinding,decodeMacroBinding,parseProfile,paint,importWindows} from '../assets/model.js';
import {packet,validateReply,supportsDevice,CherryHID,PageReleaseGate} from '../assets/hid.js';
import {validatePlan,applyConfiguration,sameSnapshot,makeKeymapPlan} from '../assets/writer.js';
import {KeymapWriteAuthorization} from '../assets/safety.js?v=0.5.0';
import {WINDOWS_DEFAULTS} from '../assets/tables.js';
const macro={name:'AB',steps:[{usage:4,pressed:true,delayMilliseconds:0},{usage:4,pressed:false,delayMilliseconds:30},{usage:5,pressed:true,delayMilliseconds:10},{usage:5,pressed:false,delayMilliseconds:30}]};
class FakeDevice extends EventTarget{
  constructor(snapshot=demoSnapshot()){super();this.s=clone(snapshot);this.vendorId=1130;this.productId=462;this.opened=false;this.collections=[{usagePage:0xff1c,usage:0x92,inputReports:[{reportId:4,items:[{reportSize:8,reportCount:63}]}],outputReports:[{reportId:4,items:[{reportSize:8,reportCount:63}]}]}];this.requests=[];this.writeCount=0;}
  async open(){this.opened=true;}async close(){this.opened=false;}
  async sendReport(id,data){
    assert.equal(id,4);assert.equal(data.byteLength,63);const b=new Uint8Array([id,...data]);this.requests.push(b);const cmd=b[3],o=b[5]|b[6]<<8,n=b[4],r=b.slice();
    const field=({3:'deviceInfo',5:'parameters',8:'keymap',10:'colors',20:'macroData'})[cmd];
    if(field){r.set(this.s[field].slice(o,o+n),8);if(this.wrongReadback&&this.writeCount>=7&&cmd===8){r[8]^=1;this.wrongReadback=false;}}
    else{
      this.writeCount++;const target=({9:'keymap',11:'colors',21:'macroData',6:'parameters'})[cmd];assert.ok(target,`Unexpected command ${cmd}`);
      if(cmd===6)assert.equal(b[7],0x55);this.s[target].splice(o,n,...b.slice(8,8+n));
      if(this.failWrite===this.writeCount){r[7]=255;this.failWrite=null;}
    }
    if(this.drop||(this.dropAfterWrite&&cmd===9))return;
    if(this.corrupt)r[1]^=1;
    // DataView includes a nonzero byteOffset, as a browser is allowed to supply.
    const buf=new Uint8Array(100);buf.set(r.slice(1),13);const e=new Event('inputreport');Object.assign(e,{reportId:4,data:new DataView(buf.buffer,13,63),device:this});queueMicrotask(()=>this.dispatchEvent(e));
  }
}
const transport=async(s=demoSnapshot(),options={})=>{const device=new FakeDevice(s),hid=new CherryHID(device,options);await hid.open();return {hid,device};};
const gate={async check(){}};
test('109 unique physical slots, square normal keys and dedicated media row',()=>{
  assert.equal(keys.length,109);assert.equal(new Set(keys.map(k=>k.slot)).size,109);assert.ok(keys.every(k=>Number.isInteger(k.slot)&&k.slot>=0&&k.slot<126));
  assert.ok(keys.filter(k=>k.w===32).filter(k=>!['numPlus','numEnter'].includes(k.id)).every(k=>k.h===32));
  for(const [a,b] of [['calculator','numLock'],['mediaPrevious','numDivide'],['mediaPlay','numMultiply'],['mediaNext','numMinus']]){assert.equal(keys.find(k=>k.id===a).x,keys.find(k=>k.id===b).x);assert.ok(keys.find(k=>k.id===a).y<keys.find(k=>k.id===b).y);}
});
test('macro codec balances modifiers and preserves event timing',()=>{
  const m=clone(macro);m.steps.unshift({usage:227,pressed:true,delayMilliseconds:100});m.steps.push({usage:227,pressed:false,delayMilliseconds:50});
  const bank=encodeBank([m]);assert.equal(bank.length,3071);assert.deepEqual(decodeBank(bank)[0].steps,m.steps);assert.equal(bank[0],0xaa);assert.equal(bank[1],0x55);
  assert.throws(()=>validateMacro({name:'bad',steps:[{usage:224,pressed:true,delayMilliseconds:0}]}));
  assert.throws(()=>validateMacro({name:'bad',steps:[{usage:4,pressed:false,delayMilliseconds:0}]}));
  const wrong=bank.slice();wrong[16]=0;assert.throws(()=>decodeBank(wrong));
  assert.throws(()=>encodeBank(Array(33).fill(macro)));
});
test('native profile export/import and unknown banks remain raw',()=>{
  const p=fromHardware(demoSnapshot());p.macros=[macro];p.macroBindings={102:'AB'};p.snapshot=resolveMacros(p);assert.deepEqual(parseProfile(JSON.stringify(p)),p);
  const raw=demoSnapshot();raw.macroData[0]=123;const parsed=parseProfile(JSON.stringify(raw));assert.deepEqual(parsed.snapshot.macroData,raw.macroData);assert.equal(parsed.macroBindings,undefined);
  assert.throws(()=>parseProfile(JSON.stringify({...p,snapshot:{...p.snapshot,keymap:Array(378).fill(256)}})));
});
test('lighting paint changes only selected physical slots',()=>{
  const s=demoSnapshot(),old=clone(s);paint(s,new Set(['calculator','key26']),'horizontal',[255,0,0],[0,0,255]);assert.equal(s.parameters[1],8);assert.deepEqual(s.colors.slice(102*3,102*3+3),[0,0,255]);
  for(let i=0;i<126;i++)if(![102,14].includes(i))assert.deepEqual(s.colors.slice(i*3,i*3+3),old.colors.slice(i*3,i*3+3));assert.deepEqual(s.keymap,old.keymap);
});
function windowsFixture(){return {'//':'47',KeyList:WINDOWS_DEFAULTS.map(v=>({DefaultAssignment:v,Assignment:v,ActionLink:0})),ActionInfo:[],LightInfo:{SelectItem:8,Light:4,Speed:2,Fx:0,MultiColor:0,Red:255,Green:214,Blue:0}};}
test('Windows logical order converts to matrix, rejects unsupported bound actions atomically',()=>{
  const root=windowsFixture(),s=demoSnapshot(),before=clone(s);const p=importWindows(root,s);assert.equal(p.snapshot.parameters[1],10);assert.deepEqual(p.snapshot.macroData,s.macroData);assert.deepEqual(s,before);
  root.KeyList[17].ActionLink=1;root.KeyList[17].ActionLinkIndex=0;root.ActionInfo=[{ActionType:4,ActionContent:{ActionMedia:16}}];assert.deepEqual(importWindows(root,s).snapshot.keymap.slice(306,309),[48,146,1]);
  root.ActionInfo=[{ActionType:3,ActionContent:{}}];assert.throws(()=>importWindows(root,s));assert.deepEqual(s,before);
  root.KeyList[0].DefaultAssignment=0;assert.throws(()=>importWindows(root,s));
});
test('WebHID framing sends 63 payload bytes and reads full snapshot',async()=>{
  const {hid,device}=await transport();assert.ok(supportsDevice(device));assert.ok(sameSnapshot(await hid.snapshot(),device.s));assert.equal(device.writeCount,0);assert.ok(device.requests.every(b=>b.length===64&&b[0]===4));await hid.close();
  device.collections[0].outputReports[0].items[0].reportCount=64;assert.equal(supportsDevice(device),false);
});
test('reply checksum uses query header; length, status, offset are strict',()=>{
  const req=packet(8,54,54),reply=req.slice();reply.fill(255,8);validateReply(reply,req);reply[5]++;assert.throws(()=>validateReply(reply,req));
  const w=packet(9,0,3,[32,0,4]);validateReply(w,w);w[7]=255;assert.throws(()=>validateReply(w,packet(9,0,3,[32,0,4])));
});
test('timeout closes session with no automatic retry or later command',async()=>{
  const {hid,device}=await transport(undefined,{timeout:20});device.drop=true;await assert.rejects(hid.read(8,378),/超时/);assert.equal(hid.dead,true);assert.equal(device.opened,false);const count=device.requests.length;await assert.rejects(hid.read(8,378));assert.equal(device.requests.length,count);
});
test('malformed reply and disconnect abort active request',async()=>{
  const {hid,device}=await transport();device.corrupt=true;await assert.rejects(hid.read(8,378),/校验/);assert.equal(hid.dead,true);
  const next=await transport();next.device.drop=true;const pending=next.hid.read(8,378);queueMicrotask(()=>next.hid.disconnected({device:next.device}));await assert.rejects(pending,/断开/);
});
test('non-key high-level entry never reads, saves or writes',async()=>{
  const base=demoSnapshot(),wanted=clone(base);wanted.colors.splice(42,3,22,33,44);wanted.parameters[1]=8;
  const unexpected=async()=>{throw new Error('UNEXPECTED IO');};
  await assert.rejects(applyConfiguration({snapshot:unexpected,exchange:unexpected},wanted,base,{gate:{check:unexpected},backup:unexpected}),/仅允许键位写入/);
});
test('unscoped device mutations and unknown commands are blocked before sendReport',async()=>{
  const {hid,device}=await transport();
  for(const cmd of [1,2,6,7,9,11,13,21,0xff])await assert.rejects(hid.exchange(packet(cmd,0,3,[32,0,4])),/写入暂缓/);
  assert.equal(device.requests.length,0);assert.equal(device.writeCount,0);assert.equal(hid.dead,false);
  assert.ok(sameSnapshot(await hid.snapshot(),device.s));assert.equal(device.writeCount,0);await hid.close();
});
test('malformed or out-of-range queries never reach sendReport',async()=>{
  const {hid,device}=await transport();
  for(const request of [packet(8,377,3),packet(5,0,1,[1]),packet(5,0,1,[],0x55),packet(8,0,55)])await assert.rejects(hid.exchange(request));
  const bad=packet(5,0,1);bad[1]++;await assert.rejects(hid.exchange(bad));
  assert.equal(device.requests.length,0);await hid.close();
});
test('internal keys, hidden colors and unknown system parameters cannot be changed',()=>{
  const base=demoSnapshot();for(const mutate of [s=>s.keymap[18]=32,s=>s.colors[125*3]=1,s=>s.parameters[9]=1]){const target=clone(base);mutate(target);assert.throws(()=>validatePlan(target,base));}
});
test('new lighting parameters cannot resend an unknown option from the old mode',()=>{
  const base=demoSnapshot();base.parameters[1]=23;base.parameters[5]=255;
  const target=clone(base);target.parameters[1]=8;target.colors.splice(42,3,231,193,193);
  assert.throws(()=>validatePlan(target,base),/选项未知/);
  target.parameters[5]=0;assert.doesNotThrow(()=>validatePlan(target,base));
  const colorsOnly=clone(base);colorsOnly.colors.splice(42,3,231,193,193);
  assert.doesNotThrow(()=>validatePlan(colorsOnly,base)); // No parameter resend.
  base.parameters[4]=255;target.parameters[4]=255;assert.throws(()=>validatePlan(target,base),/选项未知/);
});
test('page gate observes a fresh 200ms for every packet and rejects a tap during the wait',async()=>{
  const win=new EventTarget(),doc=new EventTarget();doc.hasFocus=()=>true;doc.visibilityState='visible';const g=new PageReleaseGate(win,doc);
  g.acknowledge({detail:1});
  for(let i=0;i<3;i++){const start=performance.now();await g.check();assert.ok(performance.now()-start>=200);}
  const checking=g.check();
  setTimeout(()=>{for(const type of ['keydown','keyup']){const e=new Event(type);Object.assign(e,{code:'KeyA'});win.dispatchEvent(e);}},20);
  await assert.rejects(checking,/状态变化/);
  await assert.rejects(g.check(),/重新确认/);
});
test('page gate requires mouse acknowledgement, waits for key release, disarms on blur',async()=>{
  const win=new EventTarget(),doc=new EventTarget();doc.hasFocus=()=>true;doc.visibilityState='visible';const g=new PageReleaseGate(win,doc);
  await assert.rejects(g.check());assert.throws(()=>g.acknowledge({detail:0}));assert.throws(()=>g.acknowledge({detail:1,ctrlKey:true}));g.acknowledge({detail:1});
  const down=new Event('keydown');Object.assign(down,{code:'ControlLeft'});win.dispatchEvent(down);await assert.rejects(g.check(),/按住/);
  const up=new Event('keyup');Object.assign(up,{code:'ControlLeft'});win.dispatchEvent(up);await g.check();win.dispatchEvent(new Event('blur'));await assert.rejects(g.check(),/前台/);
});
test('local log records request, reply, duration and timeout without retries',async()=>{
  const stored=new Map(),{hid,device}=await transport(undefined,{log:async entry=>stored.set(entry.id,entry)});
  await hid.read(3,34);await hid.logTasks;const entry=[...stored.values()][0];assert.equal(entry.request.length,64);assert.equal(entry.reply.length,64);assert.equal(entry.status,'ok');assert.ok(entry.durationMs>=0);assert.equal(device.writeCount,0);await hid.close();
  const timed=await transport(undefined,{timeout:15,log:async entry=>stored.set(entry.id,entry)});timed.device.drop=true;await assert.rejects(timed.hid.read(5,56));await timed.hid.logTasks;const failed=[...stored.values()].find(e=>e.status==='error');assert.match(failed.error,/超时/);assert.equal(failed.reply,null);assert.ok(failed.durationMs>0);assert.equal(timed.device.requests.length,1);
});
test('malformed raw reply remains in the diagnostic log',async()=>{
  const stored=new Map(),{hid,device}=await transport(undefined,{log:async entry=>stored.set(entry.id,entry)});device.corrupt=true;await assert.rejects(hid.read(3,34));await hid.logTasks;const entry=[...stored.values()][0];assert.equal(entry.status,'error');assert.match(entry.error,/校验/);assert.equal(entry.reply.length,64);assert.notDeepEqual(entry.reply.slice(1,3),entry.request.slice(1,3));
});

test('key plan isolates drafts and exact packet scope preserves internal and hidden slots',()=>{
  const base=demoSnapshot(),draft=clone(base);draft.keymap.splice(306,3,32,13,6);draft.parameters[1]=8;draft.colors[0]=22;draft.macroData[0]=123;
  const wanted=makeKeymapPlan(draft,base);assert.deepEqual(wanted.keymap,draft.keymap);
  for(const k of ['parameters','colors','macroData'])assert.deepEqual(wanted[k],base[k]);
  const auth=new KeymapWriteAuthorization(base,wanted.keymap);assert.deepEqual(auth.changedSlots,[102]);
  for(const map of [base.keymap,wanted.keymap])for(let o=0;o<378;o+=54)assert.doesNotThrow(()=>auth.validate(packet(9,o,54,map.slice(o,o+54))));
  const forged=packet(9,270,54,wanted.keymap.slice(270,324));forged[38]^=1;assert.throws(()=>auth.validate(forged));
  assert.throws(()=>auth.validate(packet(9,306,3,[32,13,6])));assert.throws(()=>auth.validate(packet(11,0,54,base.colors.slice(0,54))));
  for(const slot of [6,71,125]){const b=clone(base);b.keymap.splice(slot*3,3,32,0,4);assert.throws(()=>makeKeymapPlan(b,base));}
  const macro=clone(base);macro.keymap.splice(306,3,0x70,0,0);assert.throws(()=>makeKeymapPlan(macro,base),/宏绑定/);
  const oldMacro=clone(base);oldMacro.keymap.splice(306,3,0x70,0,0);assert.throws(()=>new KeymapWriteAuthorization(oldMacro,base.keymap),/宏绑定/);
  for(const usage of [1,2,3,224,255]){const bad=clone(base);bad.keymap.splice(306,3,32,0,usage);assert.throws(()=>makeKeymapPlan(bad,base));}
  const exposed=auth.expected;exposed.keymap[306]=0;assert.deepEqual(auth.expected.keymap,wanted.keymap);
  const otherFW=clone(draft);otherFW.deviceInfo[6]=25;assert.throws(()=>makeKeymapPlan(otherFW,base));
});
test('authorized key transaction writes only 09, verifies full readback and revokes permission',async()=>{
  const base=demoSnapshot(),wanted=clone(base);wanted.keymap.splice(306,3,32,13,6);
  const {hid,device}=await transport(base);let backed=null,checks=0;
  const after=await applyConfiguration(hid,wanted,base,{gate:{async check(){checks++;}},backup:async s=>{backed=clone(s);}});
  assert.ok(sameSnapshot(after,wanted));assert.ok(sameSnapshot(backed,base));assert.equal(device.writeCount,7);assert.ok(checks>=15);
  assert.ok(device.requests.filter(b=>![3,5,8,10,20].includes(b[3])).every(b=>b[3]===9));
  await assert.rejects(hid.exchange(packet(9,0,54,base.keymap.slice(0,54))),/写入暂缓/);await hid.close();
});
test('stale baseline, failed backup and missing release gate prevent all key writes',async()=>{
  const base=demoSnapshot(),wanted=clone(base);wanted.keymap.splice(306,3,32,13,6);
  const {hid,device}=await transport(base),stale=clone(base);stale.keymap[0]^=1;
  await assert.rejects(applyConfiguration(hid,wanted,stale,{gate,backup:async()=>{}}),/已经变化/);assert.equal(device.writeCount,0);
  await assert.rejects(applyConfiguration(hid,wanted,base,{gate,backup:async()=>{throw new Error('backup failed');}}),/backup failed/);assert.equal(device.writeCount,0);
  await assert.rejects(applyConfiguration(hid,wanted,base,{backup:async()=>{}}),/释放检查/);assert.equal(device.writeCount,0);await hid.close();
});
test('key write timeout preserves backup and stops without blind retries or rollback',async()=>{
  const base=demoSnapshot(),wanted=clone(base);wanted.keymap.splice(306,3,32,13,6);const {hid,device}=await transport(base,{timeout:25});device.dropAfterWrite=true;let backups=0;
  await assert.rejects(applyConfiguration(hid,wanted,base,{gate,backup:async()=>{backups++;}}),/重新连接并读取/);
  assert.equal(backups,1);assert.equal(device.writeCount,1);assert.equal(hid.dead,true);
});
test('readback failure on a live session checks scope, restores original and verifies',async()=>{
  const base=demoSnapshot(),wanted=clone(base);wanted.keymap.splice(306,3,32,13,6);const {hid,device}=await transport(base);device.wrongReadback=true;
  await assert.rejects(applyConfiguration(hid,wanted,base,{gate,backup:async()=>{}}),/已恢复写入前/);
  assert.equal(device.writeCount,14);assert.ok(sameSnapshot(device.s,base));assert.equal(hid.dead,false);await hid.close();
});
test('pressed keys and log persistence failure block a pending key packet before send',async()=>{
  const base=demoSnapshot(),wanted=clone(base);wanted.keymap.splice(306,3,32,13,6);const {hid,device}=await transport(base);let checks=0;
  await assert.rejects(applyConfiguration(hid,wanted,base,{gate:{async check(){if(++checks===3)throw new Error('held key');}},backup:async()=>{}}),/未发送键位写包/);
  assert.equal(device.writeCount,0);await hid.close();
  const next=await transport(base,{log:async entry=>{if(entry.command===9)throw new Error('disk failed');}});
  await assert.rejects(applyConfiguration(next.hid,wanted,base,{gate,backup:async()=>{}}),/日志保存失败/);assert.equal(next.device.writeCount,0);await next.hid.close();
});

test('official macro playback preserves count/held/toggle through banks and legacy profiles',()=>{
  const modes=[{mode:'count',count:1},{mode:'count',count:2},{mode:'count',count:255},{mode:'held',count:1},{mode:'toggle',count:1}];
  const records=[[0x70,0,0],[0x71,0,2],[0x71,0,255],[0x70,0,1],[0x70,0,2]];
  for(let i=0;i<modes.length;i++){
    assert.deepEqual(macroBinding(0,modes[i]),records[i]);assert.deepEqual(decodeMacroBinding(records[i],1),modes[i]);
    const p=fromHardware(demoSnapshot());p.macros=[macro];p.macroBindings[102]=macro.name;p.macroModes[102]=modes[i];p.snapshot=resolveMacros(p);
    const decoded=fromHardware(p.snapshot);assert.deepEqual(decoded.macroModes[102],modes[i]);assert.deepEqual(resolveMacros(decoded).keymap,p.snapshot.keymap);assert.deepEqual(parseProfile(JSON.stringify(p)),p);
    assert.throws(()=>makeKeymapPlan(p.snapshot,demoSnapshot()),/宏绑定/);
  }
  for(const b of [[0x70,0,3],[0x71,0,0],[0x71,0,1],[0x70,1,0]])assert.throws(()=>decodeMacroBinding(b,1));
  for(const value of [0,256])assert.throws(()=>macroBinding(0,{mode:'count',count:value}));
  assert.throws(()=>macroBinding(0,{mode:'held',count:2}));
  const legacy=fromHardware(demoSnapshot());legacy.macros=[macro];legacy.macroBindings[102]=macro.name;delete legacy.macroModes;legacy.snapshot=resolveMacros(legacy);assert.deepEqual(legacy.snapshot.keymap.slice(306,309),[0x70,0,0]);
});
test('Windows macro playback imports all supported bindings without changing the baseline',()=>{
  for(const [mode,count,record] of [[0,1,[0x70,0,0]],[0,3,[0x71,0,3]],[1,0,[0x70,0,1]],[2,0,[0x70,0,2]]]){
    const root=windowsFixture(),base=demoSnapshot(),old=clone(base);root.KeyList[17].ActionLink=1;root.KeyList[17].ActionLinkIndex=0;
    root.ActionInfo=[{ActionType:2,ActionName:'A',ActionContent:{ActionMacroType:mode,ActionMacroLoopValue:count,ActionMacroEvents:[{Type:10,Button:4,Action:'down',Delay:0},{Type:10,Button:4,Action:'up',Delay:50}]}}];
    const p=importWindows(root,base);assert.deepEqual(p.snapshot.keymap.slice(306,309),record);assert.deepEqual(base,old);
    root.ActionInfo[0].ActionContent.ActionMacroType=3;assert.throws(()=>importWindows(root,base));assert.deepEqual(base,old);
  }
});

test('Windows fixed-interval preference preserves actual event delays and profile roundtrip',()=>{
  const root=windowsFixture(),baseline=demoSnapshot(),before=clone(baseline);
  root.KeyList[17].ActionLink=1;root.KeyList[17].ActionLinkIndex=0;
  const content={ActionMacroType:0,ActionMacroLoopValue:1,ActionMacroEvents:macro.steps.map(s=>({Type:10,Button:s.usage,Action:s.pressed?'down':'up',Delay:s.delayMilliseconds}))};
  root.ActionInfo=[{ActionType:2,ActionName:'AB',ActionContent:content}];
  const bank=importWindows(root,baseline).snapshot.macroData;
  for(const fixed of [0,1]){
    Object.assign(content,{ActionMacroFixTimeIsSelected:fixed,ActionMacroFixTimeValue:777});
    const p=importWindows(root,baseline);
    assert.deepEqual(p.macros[0].recordingDelay,{fixed:fixed===1,milliseconds:777});
    assert.deepEqual(p.macros[0].steps,macro.steps);assert.deepEqual(p.snapshot.macroData,bank);
    assert.deepEqual(parseProfile(JSON.stringify(p)),p);
  }
  for(const milliseconds of [-1,60001,1.5,true]){
    content.ActionMacroFixTimeValue=milliseconds;assert.throws(()=>importWindows(root,baseline));
  }
  assert.throws(()=>validateMacro({...macro,recordingDelay:{fixed:1,milliseconds:777}}));
  assert.deepEqual(baseline,before);
});

test('official mouse macro bytes distinguish middle button from keyboard A',()=>{
  const mixed={name:'Middle + A',steps:[{usage:4,pressed:true,delayMilliseconds:0},{kind:'mouse',usage:4,pressed:true,delayMilliseconds:20},{kind:'mouse',usage:4,pressed:false,delayMilliseconds:50},{usage:4,pressed:false,delayMilliseconds:0}]};
  const bank=encodeBank([mixed]);assert.deepEqual(bank.slice(22,38),[0,0,138,4,20,0,129,4,50,0,1,4,0,0,10,4]);
  assert.deepEqual(decodeBank(bank)[0].steps,mixed.steps);
  for(const usage of [1,2,4,8,16]){const m={name:'mouse',steps:[{kind:'mouse',usage,pressed:true,delayMilliseconds:0},{kind:'mouse',usage,pressed:false,delayMilliseconds:50}]};assert.deepEqual(decodeBank(encodeBank([m]))[0].steps,m.steps);}
  assert.throws(()=>validateMacro({name:'cross',steps:[mixed.steps[0],mixed.steps[2]]}));
  assert.throws(()=>validateMacro({name:'bad',steps:[{kind:'mouse',usage:3,pressed:true,delayMilliseconds:0}]}));
});

test('recorder timing, repeat suppression, balanced finish, cancel and capacity',()=>{
  for(const [timing,expected] of [['actual',[10,20,40,10]],['fixed',[777,777,777,777]],['ignore',[0,0,0,0]]]){
    const r=new MacroRecorder({timing,fixedMilliseconds:777,startedMilliseconds:100});
    r.observe({usage:4,pressed:false,milliseconds:105});
    r.observe({usage:4,pressed:true,milliseconds:110});
    r.observe({usage:4,pressed:true,milliseconds:120,repeatEvent:true});
    assert.throws(()=>r.finish('test'));
    r.observe({usage:4,kind:'mouse',pressed:true,milliseconds:130});
    r.observe({usage:4,kind:'mouse',pressed:false,milliseconds:170});
    r.observe({usage:4,pressed:false,milliseconds:180});
    const m=r.finish('test');assert.deepEqual(m.steps.map(s=>s.delayMilliseconds),expected);
    assert.deepEqual(decodeBank(encodeBank([m]))[0].steps,m.steps);
    assert.throws(()=>r.observe({usage:4,pressed:true,milliseconds:200}));
  }
  const r=new MacroRecorder({startedMilliseconds:100});r.observe({usage:4,pressed:true,milliseconds:110});
  assert.throws(()=>r.observe({usage:5,pressed:true,milliseconds:109}));assert.equal(r.steps.length,1);
  r.observe({usage:4,pressed:false,milliseconds:100000});assert.equal(r.steps[1].delayMilliseconds,60000);
  r.cancel();assert.equal(r.steps.length,0);assert.throws(()=>r.finish('test'));
  const limit=new MacroRecorder({startedMilliseconds:0});for(let i=0;i<256;i++)limit.observe({usage:4,pressed:i%2===0,milliseconds:i});
  assert.throws(()=>limit.observe({usage:4,pressed:true,milliseconds:257}));assert.equal(limit.steps.length,256);assert.equal(limit.held.size,0);
});
