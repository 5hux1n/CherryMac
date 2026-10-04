// Deferred promises model browser handle release; no navigator.hid or device.
import test from 'node:test';
import assert from 'node:assert/strict';
import {CherryHID} from '../assets/hid.js';
const deferred=()=>{let resolve,reject;const promise=new Promise((a,b)=>{resolve=a;reject=b;});return {promise,resolve,reject};};
class Device extends EventTarget{
  vendorId=1130;productId=462;opened=false;closes=0;
  collections=[{usagePage:0xff1c,usage:0x92,inputReports:[{reportId:4,items:[{reportSize:8,reportCount:63}]}],outputReports:[{reportId:4,items:[{reportSize:8,reportCount:63}]}]}];
  closing=deferred();opening=null;
  async open(){if(this.opening)await this.opening.promise;this.opened=true;}
  async close(){this.closes++;await this.closing.promise;this.opened=false;}
}
test('handoff waits for actual browser close, including poisoned sessions and repeated close',async()=>{
  const d=new Device(),h=new CherryHID(d);await h.open();h.poison(new Error('lost reply'));
  let released=false;const first=h.close().then(()=>{released=true;}),second=h.close();
  await new Promise(resolve=>setImmediate(resolve));assert.equal(released,false);assert.equal(d.opened,true);assert.equal(d.closes,1);
  d.closing.resolve();await Promise.all([first,second]);assert.equal(released,true);assert.equal(d.opened,false);assert.equal(d.closes,1);
  await assert.rejects(h.open(),/失效/);assert.equal(d.opened,false);
});
test('browser close failure prevents handoff and remains visible after the session is dead',async()=>{
  const d=new Device(),records=[],h=new CherryHID(d,{log:e=>records.push(e)});await h.open();
  const first=h.close();d.closing.reject(new Error('browser refused close'));await assert.rejects(first,/browser refused close/);
  await h.flushLogs();assert.equal(records.at(-1).phase,'usb-close-failed');assert.equal(d.opened,true);assert.equal(h.dead,true);
  await assert.rejects(h.close(),/未交接/);assert.equal(d.closes,1);
});
test('close during pending open waits and releases the late-opened handle',async()=>{
  const d=new Device();d.opening=deferred();const h=new CherryHID(d),opened=assert.rejects(h.open(),/已停止/),closed=h.close();
  await new Promise(resolve=>setImmediate(resolve));assert.equal(d.closes,0);
  d.opening.resolve();await opened;d.closing.resolve();await closed;assert.equal(d.opened,false);assert.equal(d.closes,1);
});
