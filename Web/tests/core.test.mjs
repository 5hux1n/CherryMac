import test from 'node:test';
import assert from 'node:assert/strict';
import {keys,demoSnapshot} from '../assets/layout.js';
import {clone,equal,encodeBank,decodeBank,validateMacro,fromHardware,resolveMacros,parseProfile,paint,importWindows} from '../assets/model.js';
import {packet,validateReply,supportsDevice,CherryHID,PageReleaseGate} from '../assets/hid.js';
import {validatePlan,applyConfiguration,sameSnapshot} from '../assets/writer.js';
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
    if(this.drop)return;
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
test('backup failure and changed baseline never send writes',async()=>{
  for(const stale of [false,true]){const {hid,device}=await transport();const base=clone(device.s),target=clone(base);target.keymap.splice(306,3,32,8,21);if(stale)device.s.parameters[8]++;
    await assert.rejects(applyConfiguration(hid,target,base,{gate,backup:async()=>{throw new Error('disk full');}}));assert.equal(device.writeCount,0);await hid.close();}
});
test('internal keys, hidden colors and unknown system parameters cannot be changed',()=>{
  const base=demoSnapshot();for(const mutate of [s=>s.keymap[18]=32,s=>s.colors[125*3]=1,s=>s.parameters[9]=1]){const target=clone(base);mutate(target);assert.throws(()=>validatePlan(target,base));}
});
test('key and lighting transaction preserves macro bank and unknown parameters',async()=>{
  const {hid,device}=await transport(),base=clone(device.s),wanted=clone(base);wanted.keymap.splice(306,3,32,10,33);wanted.colors.splice(42,3,22,33,44);wanted.parameters[1]=3;let backup;
  const after=await applyConfiguration(hid,wanted,base,{gate,backup:async s=>backup=clone(s)});assert.ok(sameSnapshot(backup,base));assert.ok(sameSnapshot(after,wanted));assert.deepEqual(after.macroData,base.macroData);assert.deepEqual(after.parameters.slice(9),base.parameters.slice(9));assert.ok(!device.requests.some(b=>[1,2,13].includes(b[3])));await hid.close();
});
test('macro bank and binding are verified together, header block last',async()=>{
  const {hid,device}=await transport(),base=clone(device.s),p=fromHardware(base);p.macros=[macro];p.macroBindings={102:'AB'};p.snapshot=resolveMacros(p);
  const after=await applyConfiguration(hid,p.snapshot,base,{gate,backup:async()=>{}});assert.ok(sameSnapshot(after,p.snapshot));const offsets=device.requests.filter(b=>b[3]===21).map(b=>b[5]|b[6]<<8);assert.equal(offsets.at(-1),0);assert.ok(device.requests.findIndex(b=>b[3]===21)<device.requests.findIndex(b=>b[3]===9));await hid.close();
});
test('rejected partial write closes session; reconnect can restore backup',async()=>{
  const {hid,device}=await transport(),base=clone(device.s),wanted=clone(base);wanted.keymap.splice(306,3,32,8,21);device.failWrite=3;
  // A known rejection is not a transport framing error; reopen for recovery is
  // deliberately unnecessary here: the protocol driver closes on any bad reply.
  await assert.rejects(applyConfiguration(hid,wanted,base,{gate,backup:async()=>{}}),/自动恢复未完成/);assert.equal(hid.dead,true);
  const recovery=await transport(device.s);await applyConfiguration(recovery.hid,base,clone(recovery.device.s),{gate,backup:async()=>{}});assert.ok(sameSnapshot(recovery.device.s,base));await recovery.hid.close();
});
test('valid replies with mismatching readback automatically restore the original',async()=>{
  const {hid,device}=await transport(),base=clone(device.s),wanted=clone(base);wanted.keymap.splice(306,3,32,8,21);device.wrongReadback=true;
  await assert.rejects(applyConfiguration(hid,wanted,base,{gate,backup:async()=>{}}),/已恢复写入前/);assert.ok(sameSnapshot(device.s,base));assert.equal(device.writeCount,14);await hid.close();
});
test('losing release acknowledgement during a write stops all further mutation',async()=>{
  const {hid,device}=await transport(),base=clone(device.s),wanted=clone(base);wanted.keymap.splice(306,3,32,8,21);let checks=0;
  await assert.rejects(applyConfiguration(hid,wanted,base,{gate:{async check(){if(++checks>3)throw new Error('page lost focus');}},backup:async()=>{}}),/自动恢复未完成/);assert.equal(device.writeCount,2);await hid.close();
});
test('page gate requires mouse acknowledgement, waits for key release, disarms on blur',async()=>{
  const win=new EventTarget(),doc=new EventTarget();doc.hasFocus=()=>true;doc.visibilityState='visible';const g=new PageReleaseGate(win,doc);
  await assert.rejects(g.check());assert.throws(()=>g.acknowledge({detail:0}));assert.throws(()=>g.acknowledge({detail:1,ctrlKey:true}));g.acknowledge({detail:1});
  const down=new Event('keydown');Object.assign(down,{code:'ControlLeft'});win.dispatchEvent(down);await assert.rejects(g.check(),/按住/);
  const up=new Event('keyup');Object.assign(up,{code:'ControlLeft'});win.dispatchEvent(up);await g.check();win.dispatchEvent(new Event('blur'));await assert.rejects(g.check(),/前台/);
});
