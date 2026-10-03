import {mergeMacroRecoveryDraft} from '../assets/product-macros.js';
import {macroTestPlan,testMacro,testPlayback} from '../assets/macro-test-flow.js';
import {waitForFiniteMacroCompletion,applyMacroWithStop} from '../assets/macro-session.js';
import {MacroStopObservation,replayMacroStopRecord} from '../assets/macro-stop.js';
import test from 'node:test';
import assert from 'node:assert/strict';
import {keys,demoSnapshot} from '../assets/layout.js';
import {clone,equal,duplicateMacro,clearMacros,removeMacro,unassignMacro,macroWriteReview,encodeBank,decodeBank,validateMacro,MacroRecorder,MacroExecutionEvidence,replayMacroExecutionLog,finiteMacroDurationMilliseconds,fromHardware,resolveMacros,macroBinding,decodeMacroBinding,parseProfile,paint,importWindows,officialMacroAction,exportWindowsKeysAndMacros,officialSystemStageWords,officialHostTextPlan,officialTextTriggerIndex,resolveHostTextTrigger} from '../assets/model.js';
import {packet,validateReply,supportsDevice,CherryHID,PageReleaseGate} from '../assets/hid.js';
import {validatePlan,applyConfiguration,sameSnapshot,makeKeymapPlan,applyMacroConfiguration,restoreMacroTransaction} from '../assets/writer.js';
import {KeymapWriteAuthorization,MacroWriteAuthorization} from '../assets/safety.js?v=0.6.0';
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

test('official system stages use seven words while imports preserve USB parameters and unknown fields',()=>{
  const root=windowsFixture(),base=demoSnapshot(),before=clone(base);delete root.LightInfo;
  root.SystemStages={Repeat:16,RepeatDelay:'257',Key6Flag:1,ReportSelectItem:3,RFReportSelectItem:2,WFlag:0,WinFlag:65535,opaque:'preserve'};
  assert.deepEqual(officialSystemStageWords(root),[16,257,1,3,2,0,65535]);assert.equal(officialSystemStageWords({}),null);
  const p=importWindows(root,base);assert.deepEqual(p.snapshot.parameters,base.parameters);assert.deepEqual(JSON.parse(p.windowsTemplateJSON).SystemStages,root.SystemStages);
  assert.deepEqual(exportWindowsKeysAndMacros(p,root).SystemStages,root.SystemStages);
  for(const value of [-1,65536,1.5,true,null]){const bad=clone(root);bad.SystemStages.RepeatDelay=value;assert.throws(()=>importWindows(bad,base));}
  for(const value of [[],42,{}])assert.throws(()=>officialSystemStageWords({SystemStages:value}));
  assert.deepEqual(base,before);
});

test('official source template survives profile save/reload, validates layout and allows escaped files',()=>{
  const root=windowsFixture(),base=demoSnapshot();root.unknown={text:'"'.repeat(420000)};
  const p=importWindows(root,base),serialized=JSON.stringify(p);assert.ok(new TextEncoder().encode(serialized).length>1_000_000);
  const loaded=parseProfile(serialized);assert.deepEqual(JSON.parse(loaded.windowsTemplateJSON),root);
  assert.deepEqual(exportWindowsKeysAndMacros(loaded,JSON.parse(loaded.windowsTemplateJSON)).unknown,root.unknown);
  const legacy=clone(p);delete legacy.macroBindings;delete legacy.macroModes;assert.equal(parseProfile(JSON.stringify(legacy)).windowsTemplateJSON,p.windowsTemplateJSON);
  const bad=clone(p);bad.windowsTemplateJSON='{}';assert.throws(()=>parseProfile(JSON.stringify(bad)));
  bad.windowsTemplateJSON=JSON.stringify({...root,'//':'46'});assert.throws(()=>parseProfile(JSON.stringify(bad)));
  bad.windowsTemplateJSON=42;assert.throws(()=>parseProfile(JSON.stringify(bad)));
  bad.windowsTemplateJSON=JSON.stringify({...root,unknown:'x'.repeat(1000000)});assert.throws(()=>parseProfile(JSON.stringify(bad)));
  assert.throws(()=>parseProfile(' '.repeat(3000001)));assert.equal(fromHardware(base).windowsTemplateJSON,undefined);
});

test('official macro export preserves attached unknown fields and refuses ambiguous or unmatched metadata',()=>{
  const root=windowsFixture(),base=demoSnapshot(),p=fromHardware(base);p.macros=[macro];p.snapshot=resolveMacros(p);
  const source=officialMacroAction(macro);source.opaque={id:42};source.ActionContent.opaque='keep';source.ActionContent.ActionMacroEvents[0].opaque='first';root.ActionInfo=[source];
  const before=clone(p),template=clone(root),out=exportWindowsKeysAndMacros(p,root),a=out.ActionInfo[0];
  assert.deepEqual(a.opaque,source.opaque);assert.equal(a.ActionContent.opaque,'keep');assert.equal(a.ActionContent.ActionMacroEvents[0].opaque,'first');
  p.macros[0]=clone(macro);p.macros[0].steps[0].delayMilliseconds=99;const changed=exportWindowsKeysAndMacros(p,root);assert.equal(changed.ActionInfo[0].ActionContent.ActionMacroEvents[0].Delay,99);
  p.macros[0].steps[0].usage=6;p.macros[0].steps[1].usage=6;assert.throws(()=>exportWindowsKeysAndMacros(p,root));
  p.macros=[macro];root.ActionInfo.push(Object.fromEntries(Object.entries(clone(source)).reverse()));assert.equal(exportWindowsKeysAndMacros(p,root).ActionInfo.length,1);root.ActionInfo.pop();
  p.macros=[macro];root.ActionInfo.push({...clone(source),opaque:{id:43}});assert.throws(()=>exportWindowsKeysAndMacros(p,root));
  root.ActionInfo=[{...clone(source),ActionName:'Unknown old macro'}];assert.throws(()=>exportWindowsKeysAndMacros(p,root));
  assert.deepEqual(p,before);assert.deepEqual(template.ActionInfo[0],source);
});

test('official template export preserves unknown fields and shared or differing macro modes',()=>{
  const base=demoSnapshot(),p=fromHardware(base),template=windowsFixture();
  template.DeviceBasicInfo={opaque:'unchanged'};template.ActionInfo=[officialMacroAction(macro),{ActionType:3,ActionName:'Text',ActionContent:{ActionText:'untouched'}}];
  template.KeyList[79].ActionLink=1;template.KeyList[79].ActionLinkIndex=1;template.KeyList[17].opaque=42;
  p.macros=[{...macro,preferredPlayback:{mode:'count',count:1}}];
  p.macroBindings={102:'AB',108:'AB',114:'AB'};p.macroModes={102:{mode:'count',count:1},108:{mode:'count',count:1},114:{mode:'toggle',count:1}};
  p.snapshot=resolveMacros(p);p.snapshot.keymap.splice(0,3,0x20,13,6);
  const before=clone(p),old=clone(template),out=exportWindowsKeysAndMacros(p,template);
  assert.deepEqual(p,before);assert.deepEqual(template,old);assert.deepEqual(out.DeviceBasicInfo,template.DeviceBasicInfo);assert.deepEqual(out.LightInfo,template.LightInfo);
  assert.equal(out.KeyList[79].ActionLinkIndex,0);assert.equal(out.KeyList[17].opaque,42);
  assert.equal(out.KeyList[17].ActionLinkIndex,out.KeyList[18].ActionLinkIndex);assert.notEqual(out.KeyList[17].ActionLinkIndex,out.KeyList[19].ActionLinkIndex);
  assert.deepEqual(exportWindowsKeysAndMacros(p,out),out);
  const imported=importWindows(out,base);
  for(const slot of [102,108,114]){assert.deepEqual(imported.macros.find(m=>m.name===imported.macroBindings[slot]).steps,macro.steps);assert.deepEqual(imported.macroModes[slot],p.macroModes[slot]);}
  assert.deepEqual(imported.snapshot.keymap.slice(0,3),[0x20,13,6]);
  template.KeyList[79].ActionLinkIndex=0;assert.throws(()=>exportWindowsKeysAndMacros(p,template));
  p.snapshot.keymap[0]=0xa1;assert.throws(()=>exportWindowsKeysAndMacros(p,old));
  const full=fromHardware(base);full.macros=Array.from({length:32},(_,i)=>({...macro,name:`M${i}`}));full.macroBindings={102:'M0'};full.macroModes={102:{mode:'count',count:2}};full.snapshot=resolveMacros(full);assert.throws(()=>exportWindowsKeysAndMacros(full,old));
});

test('official macro actions roundtrip modifier masks, mouse identity, timing and per-binding playback',()=>{
  const original={name:'Mixed',recordingDelay:{fixed:true,milliseconds:77},preferredPlayback:{mode:'held',count:1},steps:[
    {usage:231,pressed:true,delayMilliseconds:0},{kind:'mouse',usage:4,pressed:true,delayMilliseconds:25},
    {kind:'mouse',usage:4,pressed:false,delayMilliseconds:50},{usage:231,pressed:false,delayMilliseconds:60000}]};
  for(const playback of [{mode:'count',count:255},{mode:'held',count:1},{mode:'toggle',count:1}]){
    const root=windowsFixture(),a=officialMacroAction(original,playback);root.ActionInfo=[a];
    assert.equal(a.ActionContent.ActionMacroEvents[0].Button,128);assert.equal(a.ActionContent.ActionMacroEvents[1].Type,1);
    const p=importWindows(root,demoSnapshot());assert.deepEqual(p.macros[0],{...original,preferredPlayback:playback,windowsActionIndex:0});
    assert.deepEqual(officialMacroAction(p.macros[0]),a);
  }
  assert.equal(officialMacroAction(original).ActionContent.ActionMacroType,1);
  assert.throws(()=>officialMacroAction(original,{mode:'count',count:0}));
  assert.equal(original.preferredPlayback.mode,'held');
});

test('Windows imports unbound macro library once, preserves preferences and rejects invalid libraries atomically',()=>{
  const root=windowsFixture(),base=demoSnapshot(),before=clone(base);
  const action=mode=>({ActionType:'02',ActionName:'Library',ActionContent:{ActionMacroType:mode,ActionMacroLoopValue:3,ActionMacroFixTimeIsSelected:1,ActionMacroFixTimeValue:77,ActionMacroEvents:[{Type:10,Button:4,Action:'down',Delay:0},{Type:10,Button:4,Action:'up',Delay:50}]}});
  root.ActionInfo=[action(1),action(2),action(0)];
  for(const index of [17,18])Object.assign(root.KeyList[index],{ActionLink:1,ActionLinkIndex:1});
  const p=importWindows(root,base);
  assert.deepEqual(p.macros.map(m=>m.name),['Library','Library (1)','Library (2)']);
  assert.deepEqual(p.macros.map(m=>m.preferredPlayback),[{mode:'held',count:1},{mode:'toggle',count:1},{mode:'count',count:3}]);
  assert.equal(p.macroBindings[102],'Library (1)');assert.equal(Object.values(p.macroBindings).filter(n=>n==='Library (1)').length,2);
  assert.deepEqual(parseProfile(JSON.stringify(p)),p);assert.deepEqual(base,before);
  root.ActionInfo[0].ActionContent.ActionMacroEvents.pop();assert.throws(()=>importWindows(root,base));assert.deepEqual(base,before);
  root.ActionInfo=Array.from({length:33},()=>action(0));assert.throws(()=>importWindows(root,base));assert.deepEqual(base,before);
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
  for(const [timing,expected] of [['actual',[20,40,10,0]],['fixed',[777,777,777,0]],['ignore',[0,0,0,0]]]){
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
  r.observe({usage:4,pressed:false,milliseconds:100000});assert.equal(r.steps[0].delayMilliseconds,60000);
  r.cancel();assert.equal(r.steps.length,0);assert.throws(()=>r.finish('test'));
  const limit=new MacroRecorder({startedMilliseconds:0});for(let i=0;i<256;i++)limit.observe({usage:4,pressed:i%2===0,milliseconds:i});
  assert.throws(()=>limit.observe({usage:4,pressed:true,milliseconds:257}));assert.equal(limit.steps.length,256);assert.equal(limit.held.size,0);
});

test('macro transaction plan isolates blocks, freezes inputs and refuses unrelated recovery',()=>{
  const before=demoSnapshot(),target=clone(before);target.macroData=encodeBank([macro]);target.keymap.splice(306,3,0x70,0,0);
  const plan=new MacroWriteAuthorization(before,target),saved=clone(target);target.keymap[306]=0;before.parameters[0]^=1;
  assert.deepEqual(plan.expected,saved);const leaked=plan.expected;leaked.macroData[0]=0;assert.deepEqual(plan.expected,saved);
  for(const s of [plan.before,plan.expected,plan.disabled])for(let offset=0;offset<378;offset+=54)plan.validate(plan.packet(9,s.keymap,offset));
  for(const s of [plan.before,plan.expected])for(const offset of plan.changedOffsets)plan.validate(plan.packet(0x15,s.macroData,offset));
  const partial=plan.before;const o=plan.changedOffsets.at(-1);partial.macroData.splice(o,Math.min(54,3071-o),...saved.macroData.slice(o,o+54));plan.validateRecovery(partial);plan.validateRecovery(plan.disabled);
  for(const field of ['deviceInfo','parameters','colors','keymap','macroData']){const foreign=plan.expected;foreign[field][field==='macroData'?3000:0]^=1;assert.throws(()=>plan.validateRecovery(foreign));}
  const corrupt=plan.packet(9,saved.keymap,270);corrupt[1]^=1;assert.throws(()=>plan.validate(corrupt));
  assert.throws(()=>plan.validate(packet(0x15,54,3024,new Uint8Array(54))));
  assert.throws(()=>plan.validate(plan.packet(0x15,saved.macroData,3024))); // unchanged block not authorized
  for(const field of ['parameters','colors','deviceInfo']){const foreign=plan.expected;foreign[field][0]^=1;assert.throws(()=>new MacroWriteAuthorization(plan.before,foreign));}
  const unrelated=plan.expected;unrelated.keymap.splice(0,3,0x20,0,5);assert.throws(()=>new MacroWriteAuthorization(plan.before,unrelated));
  for(const record of [[0x70,0,1],[0x70,0,2],[0x71,0,1],[0x70,31,0]]){const invalid=plan.expected;invalid.keymap.splice(306,3,...record);assert.throws(()=>new MacroWriteAuthorization(plan.before,invalid));}
  const hidden=plan.expected;hidden.keymap.splice(6*3,3,0x70,0,0);assert.throws(()=>new MacroWriteAuthorization(plan.before,hidden));
  const restore=plan.before;restore.keymap.splice(306,3,0x30,0x92,1);const restorePlan=new MacroWriteAuthorization(plan.expected,restore);restorePlan.validateRecovery(plan.expected);assert.deepEqual(restorePlan.expected,restore);
});

test('finite macro wait accounts for per-binding repeats and ignores unbound macros',()=>{
  const before=demoSnapshot(),once=clone(before);once.macroData=encodeBank([macro]);once.keymap.splice(306,3,...macroBinding(0,{mode:'count',count:1}));
  const cycle=macro.steps.reduce((n,s)=>n+s.delayMilliseconds,0);
  for(const count of [1,2,3,255]){
    const repeated=clone(once);repeated.keymap.splice(306,3,...macroBinding(0,{mode:'count',count}));const plan=new MacroWriteAuthorization(once,repeated);
    assert.equal(plan.beforeDurationMilliseconds,cycle);assert.equal(plan.targetDurationMilliseconds,cycle*count);
    const shared=clone(repeated);shared.keymap.splice(324,3,...macroBinding(0,{mode:'count',count:255}));assert.equal(new MacroWriteAuthorization(before,shared).targetDurationMilliseconds,cycle*255);
  }
  const unbound=[...decodeBank(once.macroData),{name:'unused',steps:[{usage:6,pressed:true,delayMilliseconds:60000},{usage:6,pressed:false,delayMilliseconds:60000}]}];
  assert.equal(finiteMacroDurationMilliseconds(once.keymap,unbound),cycle);assert.equal(finiteMacroDurationMilliseconds(before.keymap,unbound),0);
  for(const mode of ['held','toggle']){const unsupported=clone(once);unsupported.keymap.splice(306,3,...macroBinding(0,{mode,count:1}));assert.throws(()=>new MacroWriteAuthorization(once,unsupported));assert.throws(()=>new MacroWriteAuthorization(unsupported,once));}
});

class SimulatedMacroSession {
  constructor(snapshot){this.state=clone(snapshot);this.packets=[];this.saved=[];this.drains=[];this.history=[];this.dead=false;this.reads=0;this.checks=0;this.failAt=0;this.externalChange=false;this.disconnect=false;this.operationId='previous';}
  record(row){this.history.push(clone(row));}
  async flushLogs(){if(this.logFailure)throw new Error('simulated log failure');}
  async snapshot(){this.reads++;return clone(this.state);}
  async read(cmd,count){assert.equal(cmd,0x14);assert.equal(count,3071);return [...this.state.macroData];}
  async withMacroAuthorization(authorization,gate,body){assert.equal(this.authorization,undefined);this.authorization=authorization;try{return await body();}finally{delete this.authorization;}}
  async exchange(packet){
    this.authorization.validate(packet);assert.ok(this.checks>this.packets.length,'every packet must pass release gate');this.packets.push([...packet]);
    const offset=packet[5]|packet[6]<<8,target=packet[3]===9?'keymap':'macroData';this.state[target].splice(offset,packet[4],...packet.slice(8,8+packet[4]));
    if(this.failAt===this.packets.length){if(this.externalChange)this.state.parameters[9]^=1;if(this.disconnect)this.dead=true;throw new Error('simulated lost acknowledgement');}
    return packet;
  }
  options(){return {gate:{check:async()=>{this.checks++;if(this.heldAt&&this.checks>=this.heldAt)throw new Error('simulated held key');}},backup:async value=>{if(this.backupFailure)throw new Error('simulated backup failure');this.saved.push(clone(value));},waitForCompletion:async ms=>this.drains.push(ms)};}
}
test('Web macro transaction writes header last, drains finite repeats and restores original media binding',async()=>{
  const before=demoSnapshot(),target=clone(before);target.macroData=encodeBank([{...macro,steps:Array.from({length:3},()=>macro.steps).flat()}]);target.keymap.splice(306,3,...macroBinding(0,{mode:'count',count:3}));
  const first=new SimulatedMacroSession(before);assert.ok(sameSnapshot(await applyMacroConfiguration(first,target,before,first.options()),target));
  assert.deepEqual(first.saved,[before]);assert.deepEqual(first.drains,[]);assert.equal(first.operationId,'previous');assert.equal(first.authorization,undefined);
  const macroPackets=first.packets.filter(p=>p[3]===0x15);assert.ok(macroPackets.length>1);assert.equal(macroPackets.at(-1)[5]|macroPackets.at(-1)[6]<<8,0);
  assert.ok(macroPackets.every(p=>(p[5]|p[6]<<8)+p[4]<=3071));const firstKey=first.packets.findIndex(p=>p[3]===9);assert.ok(first.packets.slice(0,firstKey).every(p=>p[3]===0x15));
  const repeatOnly=clone(target);repeatOnly.keymap.splice(306,3,...macroBinding(0,{mode:'count',count:2}));const second=new SimulatedMacroSession(target);
  await applyMacroConfiguration(second,repeatOnly,target,second.options());assert.deepEqual(second.drains,[630]);assert.equal(second.packets.length,14);assert.ok(second.packets.every(p=>p[3]===9));
  assert.deepEqual(second.packets.slice(0,7).flatMap(p=>p.slice(8,62)).slice(306,309),[0x20,0,0]);
  const restore=new SimulatedMacroSession(repeatOnly);await applyMacroConfiguration(restore,before,repeatOnly,restore.options());assert.ok(sameSnapshot(restore.state,before));assert.deepEqual(restore.drains,[420]);
  assert.deepEqual(restore.state.keymap.slice(306,309),[0x30,0x92,1]);
});
test('Web macro lost acknowledgements recover only transaction blocks; disconnect and unrelated changes stop',async()=>{
  const before=demoSnapshot(),target=clone(before);target.macroData=encodeBank([macro]);target.keymap.splice(306,3,...macroBinding(0,{mode:'count',count:3}));
  const full=new SimulatedMacroSession(before);await applyMacroConfiguration(full,target,before,full.options());
  for(const index of [1,full.packets.filter(p=>p[3]===0x15).length,full.packets.length]){
    const failing=new SimulatedMacroSession(before);failing.failAt=index;
    await assert.rejects(applyMacroConfiguration(failing,target,before,failing.options()),/已恢复原宏与绑定/);assert.ok(sameSnapshot(failing.state,before));assert.deepEqual(failing.drains,[210]);assert.equal(failing.authorization,undefined);
  }
  for(const kind of ['disconnect','externalChange']){
    const failing=new SimulatedMacroSession(before);failing.failAt=1;failing[kind]=true;
    await assert.rejects(applyMacroConfiguration(failing,target,before,failing.options()),kind==='disconnect'?/已停止发送/:/自动恢复未完成/);assert.equal(failing.packets.length,1);assert.equal(failing.authorization,undefined);
  }
});
test('Web macro preflight blocks real closed transport, stale baseline, failed backup, held keys and logging failure',async()=>{
  const before=demoSnapshot(),target=clone(before);target.macroData=encodeBank([macro]);target.keymap.splice(306,3,0x70,0,0);
  const {hid,device}=await transport(before);await assert.rejects(applyMacroConfiguration(hid,target,before,{gate,backup:async()=>{},waitForCompletion:async()=>{}}),/宏传输尚未开放/);assert.equal(device.requests.length,0);await hid.close();
  for(const kind of ['stale','backupFailure','held','logFailure']){
    const session=new SimulatedMacroSession(before);if(kind==='stale')session.state.parameters[0]^=1;else if(kind==='held')session.heldAt=2;else session[kind]=true;
    await assert.rejects(applyMacroConfiguration(session,target,before,session.options()));assert.equal(session.packets.length,0);assert.equal(session.operationId,'previous');assert.equal(session.authorization,undefined);
  }
});

test('macro execution evidence needs exact observed output, release and a subsequent quiet window',()=>{
  const m={name:'keyboard + mouse',steps:[{usage:4,pressed:true,delayMilliseconds:0},{usage:4,kind:'mouse',pressed:true,delayMilliseconds:20},{usage:4,kind:'mouse',pressed:false,delayMilliseconds:50},{usage:4,pressed:false,delayMilliseconds:0}]};
  const cycle=(e,start)=>m.steps.forEach((step,i)=>e.observe({usage:step.usage,pressed:step.pressed,milliseconds:start+i*10,...(step.kind?{kind:step.kind}:{})}));
  for(const count of [1,2,3,255]){
    const e=new MacroExecutionEvidence({macro:m,playback:{mode:'count',count},source:'simulation',startedMilliseconds:0});
    assert.equal(e.assessment(100000).status,'waitingOutput');for(let i=0;i<count;i++)cycle(e,i*100);
    const last=(count-1)*100+30;assert.equal(e.assessment(last+269).status,'waitingQuiet');
    const passed=e.assessment(last+270);assert.equal(passed.passed,true);assert.equal(passed.completedCycles,count);assert.equal(passed.observedEvents,4*count);assert.deepEqual(passed.held,[]);
    const copy=e.observations;copy[0].usage=100;assert.equal(e.observations[0].usage,4);
    e.observe({usage:4,pressed:true,milliseconds:last+300});assert.equal(e.assessment(last+1000).failure,'extraEvent');
  }
  for(const mode of ['held','toggle']){
    const input=clone(m),e=new MacroExecutionEvidence({macro:input,playback:{mode,count:1},source:'hid',startedMilliseconds:0});input.steps[0].usage=5;
    cycle(e,0);cycle(e,100);assert.equal(e.assessment(1000).status,'waitingStop');
    e.observe({usage:4,pressed:true,milliseconds:200});e.requestStop({milliseconds:210,source:'userAcknowledged'});
    assert.equal(e.assessment(1000).status,'waitingRelease');e.observe({usage:4,pressed:false,milliseconds:220});
    const result=e.assessment(490);assert.equal(result.passed,true);assert.equal(result.completedCycles,2);assert.equal(result.eventsAfterStop,1);assert.equal(result.stopSource,'userAcknowledged');
    e.observe({usage:4,pressed:true,milliseconds:500});assert.equal(e.assessment(1000).failure,'pressAfterStop');
  }
});
test('macro execution failures stay latched and stop cleanup cannot hide unrelated releases',()=>{
  const make=(mode='count')=>new MacroExecutionEvidence({macro,playback:{mode,count:1},source:'focusedBrowser',startedMilliseconds:100});
  const invalid=make();assert.throws(()=>invalid.observe({usage:4,pressed:true,milliseconds:99}));macro.steps.forEach((s,i)=>invalid.observe({...s,milliseconds:100+i*10}));assert.equal(invalid.assessment(10000).failure,'invalidObservation');
  const repeated=make();repeated.observe({usage:4,pressed:true,milliseconds:100});repeated.observe({usage:4,pressed:true,milliseconds:101});assert.equal(repeated.assessment(10000).failure,'unbalancedObservation');
  const incorrect=make();incorrect.observe({usage:6,pressed:true,milliseconds:100});assert.equal(incorrect.assessment(10000).failure,'unexpectedEvent');
  const orphan=make('toggle');orphan.requestStop({milliseconds:100,source:'simulation'});orphan.observe({usage:4,pressed:false,milliseconds:110});assert.equal(orphan.assessment(1000).failure,'unbalancedObservation');
  const stop=make();assert.throws(()=>stop.requestStop({milliseconds:100,source:'simulation'}));assert.equal(stop.assessment(10000).failure,'invalidStopMarker');
  assert.throws(()=>make().assessment(99));assert.throws(()=>new MacroExecutionEvidence({macro,source:'simulation',startedMilliseconds:0}));
  assert.throws(()=>replayMacroExecutionLog({format:'wrong',version:1,events:[]}));
  for(const reason of ['observerDisconnected','focusLost','loggingFailed','cancelled','reportRejected']){const e=make();macro.steps.forEach((s,i)=>e.observe({...s,milliseconds:100+i*10}));assert.equal(e.assessment(1000).passed,true);e.invalidate(reason);assert.equal(e.assessment(10000).failure,reason);}
  const invalidReason=make();assert.throws(()=>invalidReason.invalidate('unknown'));assert.equal(invalidReason.assessment(1000).status,'failed');
});

test('execution capture capacity refuses to report success after dropping observations',()=>{
  const e=new MacroExecutionEvidence({macro,playback:{mode:'toggle',count:1},source:'simulation',startedMilliseconds:0});
  for(let i=0;i<65537;i++)e.observe({...macro.steps[i%macro.steps.length],milliseconds:i});
  e.requestStop({milliseconds:70000,source:'simulation'});const result=e.assessment(71000);
  assert.equal(e.observations.length,65536);assert.equal(result.observedEvents,65537);assert.equal(result.failure,'captureOverflow');assert.equal(result.passed,false);
});


test('research macro transport uses real framing, rejects unrelated writes and revokes scope',async()=>{
  const before=demoSnapshot(),target=clone(before);target.macroData=encodeBank([macro]);target.keymap.splice(306,3,...macroBinding(0));
  const authorization=new MacroWriteAuthorization(before,target),{hid,device}=await transport(before,{macroResearch:true});
  let checks=0;
  await hid.withMacroAuthorization(authorization,{async check(){checks++;}},async()=>{
    const chunk=authorization.packet(0x15,target.macroData,0);
    await assert.rejects(hid.exchange(packet(0x0b,0,54,target.colors.slice(0,54))));
    await assert.rejects(hid.withKeymapAuthorization(new KeymapWriteAuthorization(before,before.keymap),gate,async()=>{}));
    assert.equal(device.requests.length,0);
    await hid.exchange(chunk);
    assert.deepEqual(Array.from(device.requests[0]),Array.from(chunk));
    assert.deepEqual(device.s.macroData.slice(0,54),target.macroData.slice(0,54));
  });
  assert.ok(checks>=2);assert.equal(device.writeCount,1);
  await assert.rejects(hid.exchange(authorization.packet(0x15,target.macroData,0)));
  assert.equal(device.writeCount,1);await hid.close();
});
test('research macro logging failure blocks send and reply loss poisons recovery',async()=>{
  const before=demoSnapshot(),target=clone(before);target.macroData=encodeBank([macro]);target.keymap.splice(306,3,...macroBinding(0));
  const authorization=new MacroWriteAuthorization(before,target);
  for(const fault of ['logging','timeout']){
    const {hid,device}=await transport(before,{macroResearch:true,timeout:20,log:async()=>{if(fault==='logging')throw new Error('disk failed');}});
    if(fault==='timeout')device.drop=true;
    await assert.rejects(hid.withMacroAuthorization(authorization,gate,async()=>hid.exchange(authorization.packet(0x15,target.macroData,0))));
    assert.equal(device.writeCount,fault==='logging'?0:1);
    await assert.rejects(hid.exchange(authorization.packet(0x15,target.macroData,0)));assert.equal(device.writeCount,fault==='logging'?0:1);
    await hid.close();
  }
});

test('macro writer runs through framed research HID with header last and full-bank readback',async()=>{
  const before=demoSnapshot(),target=clone(before),longMacro={name:'AB twice',steps:[...clone(macro.steps),...clone(macro.steps),...clone(macro.steps)]};
  target.macroData=encodeBank([longMacro]);target.keymap.splice(306,3,...macroBinding(0));
  const {hid,device}=await transport(before,{macroResearch:true});let saved,drains=[];
  const result=await applyMacroConfiguration(hid,target,before,{gate,backup:async s=>{saved=clone(s);},waitForCompletion:async ms=>drains.push(ms)});
  assert.ok(sameSnapshot(saved,before));assert.ok(sameSnapshot(result,target));assert.ok(sameSnapshot(device.s,target));
  const writes=device.requests.filter(p=>[9,0x15].includes(p[3]));assert.equal(writes.length,9);
  assert.deepEqual(writes.filter(p=>p[3]===0x15).map(p=>p[5]|p[6]<<8),[54,0]);
  assert.ok(device.requests.every(p=>[3,5,8,10,20,9,21].includes(p[3])));assert.deepEqual(drains,[]);
  const outgoing=hid.history.filter(e=>[9,0x15].includes(e.command));
  for(let i=1;i<outgoing.length;i++)assert.ok(new Date(outgoing[i].at)-new Date(outgoing[i-1].at)>=1400,'packets must be throttled');
  await assert.rejects(hid.exchange(writes[0]));assert.equal(device.writeCount,9);await hid.close();
});

test('held/toggle transaction stops before disabling and refuses missing or failed stop providers',async()=>{
  const original=demoSnapshot(),finite=clone(original);finite.macroData=encodeBank([macro]);finite.keymap.splice(306,3,...macroBinding(0));
  for(const mode of ['held','toggle']){
    const looping=clone(finite);looping.keymap.splice(306,3,...macroBinding(0,{mode,count:1}));
    const missing=new SimulatedMacroSession(looping);
    await assert.rejects(applyMacroConfiguration(missing,finite,looping,missing.options()),/明确停止流程/);assert.equal(missing.packets.length,0);assert.equal(missing.saved.length,0);
    const session=new SimulatedMacroSession(looping),stops=[];
    await applyMacroConfiguration(session,finite,looping,{...session.options(),confirmStopped:async request=>{
      assert.equal(session.packets.length,0,'original toggle trigger must stay available until stopped');assert.equal(request.phase,'beforeWrite');
      assert.equal(request.requirements[0].repeatingBindings[0].playback.mode,mode);stops.push(request.phase);
      request.configurations[0].keymap.fill(255);request.requirements[0].repeatingBindings.length=0;
    }});
    assert.deepEqual(stops,['beforeWrite']);assert.ok(sameSnapshot(session.state,finite));
    const refused=new SimulatedMacroSession(looping);
    await assert.rejects(applyMacroConfiguration(refused,finite,looping,{...refused.options(),confirmStopped:async()=>{throw new Error('stop not confirmed');}}),/stop not confirmed/);assert.equal(refused.packets.length,0);
    const changed=new SimulatedMacroSession(looping);
    await assert.rejects(applyMacroConfiguration(changed,finite,looping,{...changed.options(),confirmStopped:async()=>{changed.state.parameters[9]^=1;}}),/停止期间配置发生变化/);assert.equal(changed.packets.length,0);
  }
});
test('held/toggle failure requires stopping new and old candidates before any recovery writes',async()=>{
  const original=demoSnapshot();
  for(const mode of ['held','toggle'])for(const refuse of [false,true]){
    const looping=clone(original);looping.macroData=encodeBank([macro]);looping.keymap.splice(306,3,...macroBinding(0,{mode,count:1}));
    const session=new SimulatedMacroSession(original);session.failAt=1;let stops=0;
    await assert.rejects(applyMacroConfiguration(session,looping,original,{...session.options(),confirmStopped:async request=>{
      stops++;assert.equal(request.phase,'recovery');assert.equal(session.packets.length,1);assert.equal(request.configurations.length,2);assert.equal(request.requirements[1].repeatingBindings[0].playback.mode,mode);
      if(refuse)throw new Error('not stopped');
    }}),refuse?/自动恢复未完成/:/已恢复原宏与绑定/);
    assert.equal(stops,1);if(refuse)assert.equal(session.packets.length,1);else assert.ok(sameSnapshot(session.state,original));
    assert.equal(session.authorization,undefined);
  }
});

function stopRequest(mode='toggle'){
  const before=demoSnapshot(),looping=clone(before);looping.macroData=encodeBank([macro]);looping.keymap.splice(306,3,...macroBinding(0,{mode,count:1}));
  const plan=new MacroWriteAuthorization(looping,before,{allowUnbounded:true});
  return {phase:'beforeWrite',configurations:[plan.before],requirements:[plan.beforeCompletion]};
}
test('stop observation separates quiet from held state and never acknowledges on elapsed time alone',()=>{
  for(const mode of ['held','toggle']){
    const request=stopRequest(mode),stop=new MacroStopObservation(request,0);assert.equal(stop.quietMilliseconds,270);
    request.requirements[0].repeatingBindings.length=0;assert.equal(stop.record().request.requirements[0].repeatingBindings.length,1);
    stop.observe({kind:'key',code:'KeyA',pressed:true,milliseconds:10});assert.equal(stop.assess(1000).canAcknowledge,false);assert.throws(()=>stop.acknowledge(1000));
    stop.observe({kind:'key',code:'KeyA',pressed:false,milliseconds:1001});assert.equal(stop.assess(1270).canAcknowledge,false);assert.equal(stop.assess(1271).canAcknowledge,true);
    assert.equal(stop.record().userConfirmedStopped,false);stop.acknowledge(1271);assert.equal(stop.record().userConfirmedStopped,true);
    assert.throws(()=>stop.observe({kind:'mouse',code:'middle',pressed:true,milliseconds:1272}));assert.equal(stop.record().userConfirmedStopped,false);assert.equal(stop.assess(10000).canAcknowledge,false);
  }
});
test('stop request cannot shorten the observation budget or substitute another configuration',()=>{
  const shortened=stopRequest();shortened.requirements[0].repeatingBindings[0].quietMilliseconds=200;assert.throws(()=>new MacroStopObservation(shortened,0));
  const wrong=stopRequest();wrong.configurations[0].keymap.splice(306,3,0x70,0,1);assert.throws(()=>new MacroStopObservation(wrong,0));
  const extra=stopRequest();extra.configurations.push(clone(extra.configurations[0]));assert.throws(()=>new MacroStopObservation(extra,0));
  const stop=new MacroStopObservation(stopRequest(),0);stop.assess(100);assert.throws(()=>stop.assess(99));assert.equal(stop.assess(1000).canAcknowledge,false);
});
test('stop capacity and interruption never allow silent passing or reuse of a confirmation',()=>{
  const stop=new MacroStopObservation(stopRequest(),0);
  for(let i=0;i<65536;i++)stop.observe({kind:'key',code:'KeyA',pressed:i%2===0,milliseconds:i});
  assert.throws(()=>stop.observe({kind:'key',code:'KeyA',pressed:true,milliseconds:65536}));assert.equal(stop.assess(100000).canAcknowledge,false);
  const cancelled=new MacroStopObservation(stopRequest(),0);cancelled.interrupt('focus lost');assert.equal(cancelled.assess(1000).canAcknowledge,false);assert.throws(()=>cancelled.acknowledge(1000));
});

test('finite browser wait chunks maximum repeats, detects cancellation/connection loss and checks release after the budget',async()=>{
  let clock=0,pauses=[],checks=0;const doc={hasFocus:()=>true,visibilityState:'visible'},gate={armed:true,check:async()=>checks++};
  const maximum=256*60000*255;
  await waitForFiniteMacroCompletion(maximum,{doc,win:{},gate,now:()=>clock,pause:async ms=>{pauses.push(ms);clock=maximum;}});
  assert.deepEqual(pauses,[100]);assert.equal(checks,1);
  for(const fault of ['abort','disconnect','blur','gate','clock']){
    clock=0;checks=0;const controller=new AbortController(),hid={dead:false},focus={value:true},g={armed:true,check:async()=>checks++};
    await assert.rejects(waitForFiniteMacroCompletion(1000,{doc:{hasFocus:()=>focus.value,visibilityState:'visible'},win:{},gate:g,hid,signal:controller.signal,now:()=>clock,pause:async()=>{
      if(fault==='abort')controller.abort();if(fault==='disconnect')hid.dead=true;if(fault==='blur')focus.value=false;if(fault==='gate')g.armed=false;clock=fault==='clock'?-1:100;
    }}));assert.equal(checks,0);
  }
});
test('integrated macro writer does not expose normal transport permissions or read before closed/aborted rejection',async()=>{
  const before=demoSnapshot(),target=clone(before);target.macroData=encodeBank([macro]);target.keymap.splice(306,3,...macroBinding(0));
  const {hid,device}=await transport(before);const gate={acknowledge(){},invalidate(){},async check(){}};
  await assert.rejects(applyMacroWithStop(hid,target,before,{gate,backup:async()=>{},win:{},doc:{}}),/宏传输尚未开放/);assert.equal(device.requests.length,0);await hid.close();
  const research=await transport(before,{macroResearch:true}),controller=new AbortController();controller.abort();
  await assert.rejects(applyMacroWithStop(research.hid,target,before,{gate,backup:async()=>{},signal:controller.signal,win:{},doc:{}}),/取消/);assert.equal(research.device.requests.length,0);await research.hid.close();
});

test('stop replay verifies final quiet evidence and rejects forged budgets, clocks and contradictory failure status',()=>{
  const stop=new MacroStopObservation(stopRequest(),0);stop.observe({kind:'key',code:'KeyA',pressed:true,milliseconds:10});stop.observe({kind:'key',code:'KeyA',pressed:false,milliseconds:20});stop.acknowledge(290);stop.assess(600);
  const record={...stop.record(),result:'complete',postAcknowledgementQuietMilliseconds:310};assert.equal(replayMacroStopRecord(record).status,'acknowledged');
  for(const mutate of [r=>r.quietMilliseconds=200,r=>r.assessedMilliseconds=300,r=>r.postAcknowledgementQuietMilliseconds=100,r=>r.source='hid',r=>r.events[0].milliseconds=-1,r=>r.userConfirmedStopped=false]){const wrong=clone(record);mutate(wrong);assert.throws(()=>replayMacroStopRecord(wrong));}
  const late=new MacroStopObservation(stopRequest(),0);late.acknowledge(270);assert.throws(()=>late.observe({kind:'key',code:'KeyB',pressed:true,milliseconds:300}));
  const failed={...late.record(),result:'failed',postAcknowledgementQuietMilliseconds:null};assert.equal(replayMacroStopRecord(failed).status,'failed');
  const forged=clone(failed);forged.failure='unrelated';assert.throws(()=>replayMacroStopRecord(forged));
});


test('reconnected macro recovery retains original scope for undecodable mixed banks, refuses unrelated changes and never retries',async()=>{
  const before=demoSnapshot(),target=clone(before);target.macroData=encodeBank([{...macro,steps:Array.from({length:3},()=>macro.steps).flat()}]);target.keymap.splice(306,3,...macroBinding(0,{mode:'count',count:3}));
  const plan=new MacroWriteAuthorization(before,target),mixed=clone(plan.disabled);mixed.macroData=clone(target.macroData);mixed.macroData.splice(0,54,...before.macroData.slice(0,54));
  assert.throws(()=>decodeBank(mixed.macroData));
  for(const state of [before,target,mixed]){
    const session=new SimulatedMacroSession(state),result=await restoreMacroTransaction(session,before,target,session.options());
    assert.ok(sameSnapshot(result,before));assert.equal(session.operationId,'previous');assert.equal(session.authorization,undefined);
    if(state===before){assert.equal(session.packets.length,0);assert.equal(session.saved.length,0);}else{
      assert.deepEqual(session.saved,[state]);assert.deepEqual(session.drains,[630]);
      const bank=session.packets.filter(p=>p[3]===21);assert.equal(bank.at(-1)[5]|bank.at(-1)[6]<<8,0);session.packets.forEach(p=>plan.validate(p));
    }
  }
  for(const fault of ['outside','bank','backup','held','packet','logging']){
    const state=clone(mixed);if(fault==='outside')state.colors[0]^=1;if(fault==='bank')state.macroData[3000]^=1;
    const session=new SimulatedMacroSession(state);session.backupFailure=fault==='backup';session.heldAt=fault==='held'?1:0;session.failAt=fault==='packet'?1:0;session.logFailure=fault==='logging';
    await assert.rejects(restoreMacroTransaction(session,before,target,session.options()));assert.equal(session.packets.length,fault==='packet'?1:0);assert.equal(session.authorization,undefined);assert.equal(session.operationId,'previous');
  }
  const loop=clone(target);loop.keymap.splice(306,3,...macroBinding(0,{mode:'toggle',count:1}));
  const confirmed=new SimulatedMacroSession(loop);let sawStop=false;
  assert.ok(sameSnapshot(await restoreMacroTransaction(confirmed,before,loop,{...confirmed.options(),confirmStopped:async request=>{sawStop=true;assert.equal(request.phase,'recovery');assert.equal(confirmed.packets.length,0);}}),before));assert.equal(sawStop,true);
  for(const refuse of [true,false]){
    const session=new SimulatedMacroSession(loop);let called=false;
    const options={...session.options(),confirmStopped:async request=>{called=true;assert.equal(request.phase,'recovery');assert.equal(session.packets.length,0);if(refuse)throw new Error('stop refused');else session.state.parameters[9]^=1;}};
    await assert.rejects(restoreMacroTransaction(session,before,loop,options));assert.equal(called,true);assert.equal(session.packets.length,0);
  }
});


test('macro flow target appends without replacing existing macros or bindings and refuses full or non-original calculator states',()=>{
  const before=demoSnapshot();before.macroData=encodeBank([macro]);before.keymap.splice(324,3,...macroBinding(0,{mode:'count',count:3}));
  const plan=macroTestPlan(before),library=decodeBank(plan.expected.macroData);
  assert.equal(library.length,2);assert.deepEqual(library[0].steps,macro.steps);assert.deepEqual(library[1].steps,testMacro.steps);
  assert.deepEqual(decodeMacroBinding(plan.expected.keymap.slice(306,309),library.length),testPlayback);
  for(let slot=0;slot<126;slot++)if(slot!==102)assert.deepEqual(plan.expected.keymap.slice(slot*3,slot*3+3),before.keymap.slice(slot*3,slot*3+3));
  assert.deepEqual(plan.expected.colors,before.colors);assert.deepEqual(plan.expected.parameters,before.parameters);
  const full=clone(before);full.macroData=encodeBank(Array.from({length:32},(_,i)=>({...macro,name:String(i)})));assert.throws(()=>macroTestPlan(full));
  const changed=clone(before);changed.keymap[306]=32;assert.throws(()=>macroTestPlan(changed));
  const short=clone(before);short.keymap=[];assert.throws(()=>macroTestPlan(short));
});


test('macro duplicate is independent, keeps original binding and fails atomically at capacity; clear disables only bound keys',()=>{
  const s=demoSnapshot();s.macroData=encodeBank([macro]);s.keymap.splice(306,3,...macroBinding(0,{mode:'count',count:3}));const p=fromHardware(s),original=clone(p);
  p.macros[0].recordingDelay={fixed:true,milliseconds:555};const copy=duplicateMacro(p,p.macros[0].name);assert.equal(copy.profile.macros.length,2);assert.deepEqual(copy.profile.macroBindings,p.macroBindings);assert.deepEqual(copy.profile.snapshot.keymap,p.snapshot.keymap);assert.deepEqual(copy.profile.macros[1].recordingDelay,{fixed:true,milliseconds:555});
  copy.profile.macros[1].steps[0].delayMilliseconds=123;assert.notEqual(copy.profile.macros[1].steps[0].delayMilliseconds,p.macros[0].steps[0].delayMilliseconds);
  const twice=duplicateMacro(copy.profile,p.macros[0].name);assert.notEqual(twice.name,copy.name);
  const cleared=clearMacros(p);assert.equal(cleared.macros.length,0);assert.deepEqual(cleared.snapshot.keymap.slice(306,309),[32,0,0]);for(let slot=0;slot<126;slot++)if(slot!==102)assert.deepEqual(cleared.snapshot.keymap.slice(slot*3,slot*3+3),p.snapshot.keymap.slice(slot*3,slot*3+3));assert.deepEqual(cleared.snapshot.colors,p.snapshot.colors);assert.deepEqual(decodeBank(cleared.snapshot.macroData),[]);assert.equal(p.macros.length,1);
  const full=clone(original);full.macros=Array.from({length:32},(_,i)=>({...clone(macro),name:String(i)}));full.macroBindings={};full.macroModes={};full.snapshot.keymap.splice(306,3,32,0,0);full.snapshot=resolveMacros(full);const saved=clone(full);assert.throws(()=>duplicateMacro(full,'0'));assert.deepEqual(full,saved);
});


test('macro management unbinds independently, reindexes deletion and preserves failed drafts',()=>{
  const p=fromHardware(demoSnapshot());p.snapshot.keymap.fill(0);p.macros=[clone(macro),{...clone(macro),name:'second'}];p.macroBindings={102:'AB',9:'AB',10:'second'};p.macroModes={102:{mode:'count',count:1},9:{mode:'count',count:3},10:{mode:'count',count:1}};p.snapshot=resolveMacros(p);
  const before=clone(p),unbound=unassignMacro(p,102);
  assert.deepEqual(p,before);assert.deepEqual(unbound.macros,p.macros);assert.deepEqual(unbound.snapshot.macroData,p.snapshot.macroData);
  assert.equal(unbound.macroBindings[9],'AB');assert.deepEqual(unbound.macroModes[9],{mode:'count',count:3});assert.deepEqual(unbound.snapshot.keymap.slice(306,309),[0x20,0,0]);
  const removed=removeMacro(unbound,'AB');assert.equal(removed.macros.length,1);assert.equal(removed.macroBindings[9],undefined);assert.equal(removed.macroModes[9],undefined);assert.deepEqual(removed.snapshot.keymap.slice(30,33),[0x70,0,0]);
  const broken=clone(p);broken.snapshot.keymap.splice(33,3,0x70,0,0);const saved=clone(broken);
  assert.throws(()=>removeMacro(broken,'AB'));assert.deepEqual(broken,saved);assert.throws(()=>unassignMacro(broken,102));assert.deepEqual(broken,saved);
  assert.throws(()=>unassignMacro(p,11));assert.throws(()=>removeMacro(p,'missing'));assert.deepEqual(p,before);
});


test('macro editor preserves opaque header and per-record bytes across edits',()=>{
  const s=demoSnapshot();s.keymap.fill(0);s.macroData=encodeBank([macro]);s.macroData.splice(6,10,1,2,3,4,5,6,7,8,9,10);
  const offset=s.macroData[16]|s.macroData[17]<<8;s.macroData.splice(offset+2,2,0xa5,0xf1);
  const p=fromHardware(s);assert.deepEqual(resolveMacros(p).macroData,s.macroData);
  p.macros[0].steps[0].delayMilliseconds=45;p.snapshot=resolveMacros(p);
  assert.deepEqual(p.snapshot.macroData.slice(6,16),[1,2,3,4,5,6,7,8,9,10]);assert.deepEqual(p.snapshot.macroData.slice(offset+2,offset+4),[0xa5,0xf1]);
  const copy=duplicateMacro(p,p.macros[0].name);assert.deepEqual(copy.profile.macros[1].hardwareReserved,[0xa5,0xf1]);
  const saved=parseProfile(JSON.stringify(copy.profile));assert.deepEqual(resolveMacros(saved).macroData,copy.profile.snapshot.macroData);
  const removed=removeMacro(saved,copy.name);assert.deepEqual(removed.snapshot.macroData,p.snapshot.macroData);
  assert.throws(()=>validateMacro({...macro,hardwareReserved:[1]}));assert.throws(()=>encodeBank([macro],[1]));
});


test('macro recovery preserves ordinary and lighting drafts without retaining unsent macro bindings',()=>{
  const before=demoSnapshot();before.keymap.fill(0);before.macroData=encodeBank([macro]);before.keymap.splice(306,3,0x70,0,0);
  const restored=fromHardware(before),previous=clone(restored);previous.snapshot.parameters[2]=3;previous.snapshot.colors[45]=123;previous.snapshot.keymap.splice(60,3,0x20,8,21);
  previous.macroBindings[12]=previous.macros[0].name;previous.snapshot=resolveMacros(previous);const saved=clone(previous);
  const result=mergeMacroRecoveryDraft(restored,previous,before,before);
  assert.deepEqual(result.snapshot.parameters,previous.snapshot.parameters);assert.deepEqual(result.snapshot.colors,previous.snapshot.colors);assert.deepEqual(result.snapshot.keymap.slice(60,63),[0x20,8,21]);
  assert.deepEqual(result.snapshot.keymap.slice(36,39),before.keymap.slice(36,39));assert.deepEqual(result.macroBindings,restored.macroBindings);assert.deepEqual(result.macros,restored.macros);assert.deepEqual(previous,saved);
  const wrong=clone(restored);wrong.snapshot.macroData[20]=1;assert.throws(()=>mergeMacroRecoveryDraft(wrong,previous,before,before));
});


test('macro write review includes unchanged triggers when their library updates and explains clearing',()=>{
  const before=demoSnapshot();before.keymap.fill(0);before.macroData=encodeBank([macro]);before.keymap.splice(306,3,0x70,0,0);
  const p=fromHardware(before);p.macros[0].name='AB';p.macroBindings[102]='AB';p.macros[0].steps[0].delayMilliseconds=42;p.snapshot=resolveMacros(p);
  const summary=macroWriteReview(p,before,p.snapshot,{102:'计算器'});
  assert.match(summary,/宏库：1 → 1 个，将更新/);assert.match(summary,/准备写入：AB · 4 步/);assert.match(summary,/计算器 → AB · 执行 1 次/);
  const cleared=clearMacros(p),empty=macroWriteReview(cleared,before,cleared.snapshot,{102:'计算器'});assert.match(empty,/将清空宏库/);assert.match(empty,/计算器 → 禁用/);
});


test('recorded segments insert without changing original waits and failures keep recording reusable',()=>{
  const recorder=new MacroRecorder({timing:'fixed',fixedMilliseconds:17,startedMilliseconds:0});recorder.observe({usage:6,pressed:true,milliseconds:1});recorder.observe({usage:6,pressed:false,milliseconds:2});
  const original=clone(macro.steps);assert.throws(()=>recorder.finish('C',{originalSteps:original,insertionIndex:99}));assert.equal(recorder.active,true);
  const result=recorder.finish('merged',{originalSteps:original,insertionIndex:2});assert.deepEqual(result.steps.map(s=>s.usage),[4,4,6,6,5,5]);assert.deepEqual(result.steps.map(s=>s.delayMilliseconds),[0,30,17,0,10,30]);assert.deepEqual(original,macro.steps);
  const overflow=new MacroRecorder({timing:'ignore',startedMilliseconds:0});overflow.observe({usage:6,pressed:true,milliseconds:1});overflow.observe({usage:6,pressed:false,milliseconds:2});
  assert.throws(()=>overflow.finish('large',{originalSteps:Array.from({length:256},(_,i)=>({usage:4,pressed:i%2===0,delayMilliseconds:0})),insertionIndex:256}));assert.equal(overflow.active,true);
  assert.equal(overflow.finish('replace').steps.length,2);
});

test('official host text prepares UTF-16 without treating Unicode as onboard macro',()=>{
  const action=text=>({ActionType:3,ActionName:'中文文本',ActionTextFlag:1,ActionContent:{ActionText:text}});
  const raw='中😀\r\nA\0后文',p=officialHostTextPlan(action(raw));
  assert.deepEqual(p,{name:'中文文本',originalText:raw,windowsFlag:1,marker:[161,0,0],scalarUTF16:[[0x4e2d],[0xd83d,0xde00],[13],[65]]});
  assert.equal(officialHostTextPlan(action('')).marker,null);
  assert.equal(officialHostTextPlan(action('\0后文')).marker,null);
  assert.deepEqual(officialHostTextPlan(action('\n')).scalarUTF16,[]);
  assert.deepEqual(officialHostTextPlan(action('\n')).marker,[161,0,0]);
  assert.deepEqual([0x6ff,0x700,0x7ff,0x800,1792.5].map(officialTextTriggerIndex),[null,0,255,null,null]);
  assert.throws(()=>officialHostTextPlan({ActionType:3,ActionContent:{ActionText:7}}));
  const root=windowsFixture(),baseline=demoSnapshot(),before=clone(baseline);
  root.KeyList[17].ActionLink=1;root.KeyList[17].ActionLinkIndex=0;root.ActionInfo=[action(raw)];
  assert.throws(()=>importWindows(root,baseline),/需要主机执行服务/);assert.deepEqual(baseline,before);
});

test('host text dispatch uses factory matching table instead of JSON logical position',()=>{
  const factory=Array(378).fill(0);factory.splice(306,3,48,146,1);
  assert.deepEqual(resolveHostTextTrigger(0x766,factory),{logicalIndex:17,physicalSlot:102});
  factory.splice(360,3,240,0,2);assert.deepEqual(resolveHostTextTrigger(0x778,factory),{logicalIndex:120,physicalSlot:120});
  factory.splice(309,3,48,146,1);assert.equal(resolveHostTextTrigger(0x767,factory),null);
  assert.equal(resolveHostTextTrigger(0x7ff,factory),null);
  assert.throws(()=>resolveHostTextTrigger(0x766,factory.slice(0,377)));
});
