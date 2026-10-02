// Offline only: execute the archived implementation against an in-memory device.
// No device picker, OS HID API, native helper, or network connection is used.
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {mkdtemp,writeFile,readFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {fileURLToPath,pathToFileURL} from 'node:url';
import {createHash} from 'node:crypto';
import {PageReleaseGate as PatchedGate} from '../assets/hid.js';
import {validatePlan as patchedPreflight,applyConfiguration as quarantinedEntry} from '../assets/writer.js';

const root=fileURLToPath(new URL('../../',import.meta.url));
const revision='7c7f31f7c82f737ea8acc75700afff9736c58c67';
const temp=await mkdtemp(join(tmpdir(),'cherrymac-offline-'));
try{
  await writeFile(join(temp,'package.json'),'{"type":"module"}');
  const hashes={};
  for(const name of ['writer','hid','model','layout','tables']){
    const source=execFileSync('git',['show',`${revision}:Web/assets/${name}.js`],{cwd:root});
    hashes[name]=createHash('sha256').update(source).digest('hex');
    await writeFile(join(temp,`${name}.js`),source);
  }
  const legacy=await import(pathToFileURL(join(temp,'writer.js')));
  const {CherryHID,PageReleaseGate}=await import(pathToFileURL(join(temp,'hid.js')));
  const {clone,importWindows}=await import(pathToFileURL(join(temp,'model.js')));
  const {demoSnapshot}=await import(pathToFileURL(join(temp,'layout.js')));
  class MemoryDevice extends EventTarget{
    constructor(snapshot,fault=null){super();this.state=clone(snapshot);this.fault=fault;this.opened=false;
      this.vendorId=1130;this.productId=462;this.writes=[];this.reads=0;
      const reports=[{reportId:4,items:[{reportSize:8,reportCount:63}]}];
      this.collections=[{usagePage:0xff1c,usage:0x92,inputReports:reports,outputReports:reports}];
    }
    async open(){this.opened=true;}async close(){this.opened=false;}
    async sendReport(id,data){
      assert.equal(id,4);assert.equal(data.length,63);
      const request=Uint8Array.from([id,...data]),reply=request.slice();
      const command=request[3],offset=request[5]|request[6]<<8,length=request[4];
      const field=({3:'deviceInfo',5:'parameters',8:'keymap',10:'colors',20:'macroData'})[command];
      if(field){this.reads++;reply.set(this.state[field].slice(offset,offset+length),8);}
      else{
        const target=({6:'parameters',9:'keymap',11:'colors',21:'macroData'})[command];
        assert.ok(target,`Unexpected command ${command}`);
        this.state[target].splice(offset,length,...request.slice(8,8+length));
        this.writes.push({command,offset,length,flag:request[7],colorOption:command===6?request[13]:null,at:performance.now()});
        // Fault injection models an uncertain acknowledgement AFTER execution.
        // This is not a model of the keyboard firmware or evidence it did so.
        if(this.writes.length===1){
          if(this.fault==='lost-first-write-reply')return;
          if(this.fault==='corrupt-first-write-reply')reply[1]^=1;
        }
      }
      const event=new Event('inputreport');Object.assign(event,{reportId:4,data:new DataView(reply.buffer,1,63),device:this});
      queueMicrotask(()=>this.dispatchEvent(event));
    }
  }
  const gate=(Gate=PageReleaseGate)=>{
    const win=new EventTarget(),doc=new EventTarget();doc.hasFocus=()=>true;doc.visibilityState='visible';
    const g=new Gate(win,doc);g.acknowledge({detail:1});return g;
  };
  const run=async(before,wanted,fault=null,Gate=PageReleaseGate)=>{
    const device=new MemoryDevice(before,fault),hid=new CherryHID(device,{timeout:30});await hid.open();
    let error=null,backups=0;
    try{await legacy.applyConfiguration(hid,wanted,before,{gate:gate(Gate),backup:async s=>{assert.ok(legacy.sameSnapshot(s,before));backups++;}});}
    catch(e){error=e.message;}
    const result={fault,backups,error,transportClosed:hid.dead,writes:device.writes.map(({at,...p})=>p),
      gapsMs:device.writes.slice(1).map((p,i)=>Number((p.at-device.writes[i].at).toFixed(3))),
      changedFields:['keymap','parameters','colors','macroData'].filter(k=>JSON.stringify(device.state[k])!==JSON.stringify(before[k])),
      matchesTarget:legacy.sameSnapshot(device.state,wanted),matchesBaseline:legacy.sameSnapshot(device.state,before)};
    await hid.close();return result;
  };
  const scenarios=[];
  if(process.argv[2]){
    const diagnostics=JSON.parse(await readFile(process.argv[2],'utf8'));
    assert.equal(diagnostics.format,'CherryMacWebDiagnostics');
    const backups=[...diagnostics.backups].sort((a,b)=>Date.parse(a.date)-Date.parse(b.date));
    for(let i=1;i<backups.length;i++)if(!legacy.sameSnapshot(backups[i-1].snapshot,backups[i].snapshot))
      scenarios.push({name:`Observed snapshot transition ${i-1} -> ${i} (operation history unknown)`,before:backups[i-1].snapshot,wanted:backups[i].snapshot});
    if(process.argv[3]){
      const before=backups.at(-1).snapshot,windows=JSON.parse(await readFile(process.argv[3],'utf8'));
      scenarios.push({name:'Last snapshot -> supplied Windows recovery target',before,wanted:importWindows(windows,before).snapshot});
    }
  }else{
    const before=demoSnapshot();before.parameters[1]=23;before.parameters[5]=255;
    const wanted=clone(before);wanted.parameters[1]=8;wanted.colors.splice(42,3,231,193,193);
    scenarios.push({name:'Synthetic mode change carrying unknown color option',before,wanted});
  }
  assert.ok(scenarios.length,'No changed snapshots to replay');
  const results=[];
  for(const {name,before,wanted} of scenarios){
    const success=await run(before,wanted);assert.equal(success.error,null);assert.equal(success.matchesTarget,true);
    const failures=[];
    for(const fault of ['corrupt-first-write-reply','lost-first-write-reply']){
      const failure=await run(before,wanted,fault);assert.match(failure.error,/自动恢复未完成/);
      assert.equal(failure.transportClosed,true);assert.equal(failure.writes.length,1);
      // A whole-keymap transfer may start with an unchanged chunk. Report the
      // actual state instead of assuming every failed transfer leaves changes.
      failures.push(failure);
    }
    let patched;
    try{patchedPreflight(wanted,before);}catch(error){patched={preflight:'blocked',reason:error.message,writes:0};}
    if(!patched){
      const simulated=await run(before,wanted,null,PatchedGate);
      assert.equal(simulated.error,null);assert.equal(simulated.matchesTarget,true);
      assert.ok(simulated.gapsMs.every(ms=>ms>=200));
      patched={preflight:'accepted',legacyWriterWithPatchedGateInMemory:simulated};
    }
    let ioCalls=0;const unexpected=async()=>{ioCalls++;throw new Error('UNEXPECTED IO');};
    await assert.rejects(quarantinedEntry({snapshot:unexpected,exchange:unexpected},wanted,before,{gate:{check:unexpected},backup:unexpected}),/写入已停用/);
    assert.equal(ioCalls,0);
    results.push({name,success,injectedFailures:failures,patched,currentWriteEntryIOCalls:ioCalls});
  }
  console.log(JSON.stringify({format:'CherryMacOfflineReproduction',revision,sourceSHA256:hashes,
    physicalDeviceAccess:false,physicalMalfunctionReproduced:false,
    limits:'Snapshots do not identify the failing operation. Memory emulation does not model firmware, USB timing tolerance, lights, or OS enumeration. Injected faults are hypothetical.',results},null,2));
}finally{await rm(temp,{recursive:true,force:true});}
