// In-memory EventTarget only. No navigator.hid, browser or USB device access.
import test from 'node:test';
import assert from 'node:assert/strict';
import {CherryHID} from '../assets/hid.js';
import {LightingCandidateAuthorization} from '../assets/safety.js';
import {clone,officialLightingReports} from '../assets/model.js';
import {demoSnapshot} from '../assets/layout.js';
const plan=()=>({format:'CherryMacOfficialLightingPlan',version:2,hardwareReady:false,bank:0,transportSelector:0,chunkCapacity:56,stages:[{name:'parameters',beginRequired:true,beginCommand:1,finishCommand:2,finishDelayMilliseconds:10,writes:[{command:6,offset:0,flag:85,data:[0,1,2,3,1,0,7,123,249]},{command:6,offset:21,flag:85,data:[1]},{command:6,offset:24,flag:85,data:[1]}]}]});
class MemoryDevice extends EventTarget{
  constructor(mode){super();this.mode=mode;this.vendorId=1130;this.productId=462;this.s=demoSnapshot();this.requests=[];this.opened=false;this.collections=[{usagePage:0xff1c,usage:0x92,inputReports:[{reportId:4,items:[{reportSize:8,reportCount:63}]}],outputReports:[{reportId:4,items:[{reportSize:8,reportCount:63}]}]}];}
  async open(){this.opened=true;}async close(){this.opened=false;}
  async sendReport(id,data){
    assert.equal(id,4);assert.equal(data.length,63);const request=[id,...data],reply=clone(request),command=request[3],offset=request[5]+request[6]*256,length=request[4];this.requests.push(request);
    const field={3:'deviceInfo',5:'parameters',8:'keymap',10:'colors',20:'macroData'}[command];
    if(field)reply.splice(8,length,...this.s[field].slice(offset,offset+length));
    else if(command===6){this.s.parameters.splice(offset,length,...request.slice(8,8+length));if(this.mode==='timeout')return;if(this.mode==='badReply')reply[7]=255;}
    else assert.ok([1,2].includes(command));
    const event=new Event('inputreport');Object.assign(event,{device:this,reportId:4,data:new DataView(Uint8Array.from(reply.slice(1)).buffer)});queueMicrotask(()=>this.dispatchEvent(event));
  }
}
test('lighting research adapter is closed by default and stops permanently on uncertain replies',async()=>{
  const ordinaryDevice=new MemoryDevice('success'),ordinary=new CherryHID(ordinaryDevice);await ordinary.open();
  assert.equal(ordinary.applyLightingCandidate,undefined);await assert.rejects(()=>ordinary.exchange(officialLightingReports(plan())[0].request));assert.equal(ordinaryDevice.requests.length,0);await ordinary.close();
  for(const mode of ['success','timeout','badReply']){
    const device=new MemoryDevice(mode),hid=new CherryHID(device,{lightingResearch:true,timeout:30});await hid.open();const baseline=clone(device.s),records=[];let backupSaved=false,checks=0;
    const result=await hid.applyLightingCandidate(plan(),baseline,{gate:{check:()=>{checks++;}},cancelled:()=>false,backup:()=>{backupSaved=true;},persist:record=>{assert.ok(backupSaved);records.push(clone(record));}});
    const writes=device.requests.filter(r=>[1,2,6,11].includes(r[3]));
    if(mode==='success'){assert.equal(result.readbackMatches,true);assert.equal(writes.length,5);assert.ok(checks>=10);assert.ok(result.record.current);}
    else{assert.equal(result.readbackMatches,false);assert.equal(writes.length,2);assert.equal(hid.dead,true);assert.equal(result.record.current,null);const count=device.requests.length;await assert.rejects(()=>hid.exchange(writes.at(-1)));assert.equal(device.requests.length,count);}
    assert.ok(records.at(-1).trace.entries.length);await hid.close();
  }
});
test('lighting report scope rejects altered, reordered, repeated and failed-session packets',()=>{
  const p=plan(),reports=officialLightingReports(p),scope=new LightingCandidateAuthorization(p,demoSnapshot());p.stages[0].writes[0].data[1]^=1;
  assert.throws(()=>scope.validate(reports[1].request));
  for(const report of reports){scope.validate(report.request);scope.accept(report.request,report.request);assert.throws(()=>scope.validate(report.request));}
  assert.equal(scope.complete,true);
  const poisoned=new LightingCandidateAuthorization(plan(),demoSnapshot()),bad=clone(reports[0].request);bad[7]=255;assert.throws(()=>poisoned.accept(bad,reports[0].request));assert.throws(()=>poisoned.validate(reports[0].request));
});
