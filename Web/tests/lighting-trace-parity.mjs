// Synthetic file-only checks; never opens a browser or a HID device.
import assert from 'node:assert/strict';
import {mkdtemp,writeFile,readFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {execFileSync} from 'node:child_process';
import {officialLightingReports,reviewOfficialLightingTrace,clone} from '../assets/model.js';
const binary=process.argv[2];assert.ok(binary,'Supply a native pure-model binary');
const dir=await mkdtemp(join(tmpdir(),'cherrymac-lighting-trace-'));
let checks=0;
try{
  for(const selector of [0,1])for(const beginRequired of [false,true]){
    const flag=selector?0:85,plan={format:'CherryMacOfficialLightingPlan',version:2,hardwareReady:false,bank:0,transportSelector:selector,chunkCapacity:56,stages:[{name:'parameters',beginRequired,beginCommand:selector?129:1,finishCommand:selector?130:2,finishDelayMilliseconds:10,writes:[{command:6,offset:0,flag,data:[0,1,2,3,1,0,7,123,249]},{command:6,offset:21,flag,data:[1]},{command:6,offset:24,flag,data:[1]}]}]};
    const reports=officialLightingReports(plan);let clock=0;
    const trace={format:'CherryMacLightingTrace',version:1,source:'simulation',entries:reports.map(r=>{clock+=r.delayMilliseconds;const entry={request:clone(r.request),reply:clone(r.request),sentMilliseconds:clock,endedMilliseconds:clock+1};clock++;return entry;})};
    const valid=[trace,{...clone(trace),source:'usbTrace'},{...clone(trace),entries:[]},{...clone(trace),entries:trace.entries.slice(0,-1)}];
    const pending=clone(trace);delete pending.entries.at(-1).reply;delete pending.entries.at(-1).endedMilliseconds;valid.push(pending);
    const failed=clone(trace);delete failed.entries.at(-1).reply;failed.entries.at(-1).error='timeout';valid.push(failed);
    const rejected=clone(trace);rejected.entries.at(-1).reply[7]=255;valid.push(rejected);
    const invalid=[];
    for(const mutate of [t=>t.entries[0].request[5]^=1,t=>t.entries.at(-1).sentMilliseconds-=10,t=>t.entries[0].reply[7]=255,t=>delete t.entries[0].reply,t=>t.entries[0].error='timeout',t=>t.entries[1].sentMilliseconds=-1,t=>t.entries.push(clone(t.entries.at(-1))),t=>t.source='hardwareProven']){const bad=clone(trace);mutate(bad);invalid.push(bad);}
    const planPath=join(dir,'plan.json'),tracePath=join(dir,'trace.json'),output=join(dir,'review.json');await writeFile(planPath,JSON.stringify(plan));
    for(const item of valid){await writeFile(tracePath,JSON.stringify(item));execFileSync(binary,['--review-official-lighting-trace',planPath,tracePath,output],{stdio:'pipe'});assert.deepEqual(JSON.parse(await readFile(output,'utf8')),reviewOfficialLightingTrace(plan,item));checks++;}
    for(const item of invalid){await writeFile(tracePath,JSON.stringify(item));assert.throws(()=>reviewOfficialLightingTrace(plan,item));assert.throws(()=>execFileSync(binary,['--review-official-lighting-trace',planPath,tracePath,output],{stdio:'pipe'}));checks++;}
    assert.equal(reviewOfficialLightingTrace(plan,trace).status,'complete');assert.equal(reviewOfficialLightingTrace(plan,pending).status,'incomplete');assert.equal(reviewOfficialLightingTrace(plan,failed).status,'failed');
  }
  console.log(`PASS: ${checks} native/Web lighting trace comparisons (synthetic; no device I/O)`);
}finally{await rm(dir,{recursive:true,force:true});}
