// Raw restore reports and interrupted restore prefixes; file/memory only.
import assert from 'node:assert/strict';
import {mkdtemp,writeFile,readFile,rm} from 'node:fs/promises';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import {execFileSync} from 'node:child_process';
import {demoSnapshot} from '../assets/layout.js';
import {LightingCandidateAuthorization} from '../assets/safety.js';
import {clone,officialLightingReadbackTarget,lightingRestoreReports,reviewLightingRestoreProgress} from '../assets/model.js';
const binary=process.argv[2];assert.ok(binary);
const original=demoSnapshot();original.colors=Array.from({length:378},(_,i)=>i%256);original.parameters[24]=0;
const colors=Array(378).fill(3),flag=85;
const plan={format:'CherryMacOfficialLightingPlan',version:2,hardwareReady:false,bank:0,transportSelector:0,chunkCapacity:56,stages:[{name:'parameters',beginRequired:true,beginCommand:1,finishCommand:2,finishDelayMilliseconds:10,writes:[{command:6,offset:0,flag,data:[0,8,2,3,1,0,7,123,249]},{command:6,offset:21,flag,data:[1]},{command:6,offset:24,flag,data:[1]}]},{name:'customColors',beginRequired:true,beginCommand:1,finishCommand:2,finishDelayMilliseconds:10,writes:Array.from({length:7},(_,i)=>({command:11,offset:i*56,flag:0,data:colors.slice(i*56,(i+1)*56)}))}]};
const before=officialLightingReadbackTarget(plan,original),sourceRecord={format:'CherryMacLightingRecoveryRecord',version:1,hardwareReady:false,operationID:'restore-test',plan,original,trace:{format:'CherryMacLightingTrace',version:1,source:'simulation',entries:[]},current:null,failure:'interrupted'};
const recovery={format:'CherryMacLightingRestorePlan',version:1,hardwareReady:false,sourceRecord,before},reports=lightingRestoreReports(recovery),scope=LightingCandidateAuthorization.recovery(recovery);
assert.equal(reports.length,14);assert.deepEqual(reports.find(r=>r.request[3]===6&&r.request[5]===24).request.slice(8,9),[0]);
let state=clone(before);const states=[clone(state)];
for(const report of reports){scope.validate(report.request);scope.accept(report.request,report.request);if(report.kind==='data'){const b=report.request;state[b[3]===6?'parameters':'colors'].splice(b[5]+b[6]*256,b[4],...b.slice(8,8+b[4]));states.push(clone(state));}}
assert.equal(scope.complete,true);assert.deepEqual(state,original);
const dir=await mkdtemp(join(tmpdir(),'cherrymac-lighting-restore-')),input=join(dir,'restore.json'),current=join(dir,'current.json'),output=join(dir,'review.json');
try{
  await writeFile(input,JSON.stringify(recovery));
  for(const [index,snapshot] of states.entries()){
    await writeFile(current,JSON.stringify(snapshot));execFileSync(binary,['--review-lighting-restore',input,current,output],{stdio:'pipe'});
    const progress=reviewLightingRestoreProgress(recovery,snapshot);assert.ok(progress.matchedWritePrefixes.includes(index));assert.deepEqual(JSON.parse(await readFile(output,'utf8')),{reports,progress});
  }
  const unknown=clone(before);unknown.keymap[0]^=1;assert.throws(()=>reviewLightingRestoreProgress(recovery,unknown));await writeFile(current,JSON.stringify(unknown));assert.throws(()=>execFileSync(binary,['--review-lighting-restore',input,current,output],{stdio:'pipe'}));
  const bad=clone(recovery);bad.before.colors=null;assert.throws(()=>lightingRestoreReports(bad));await writeFile(input,JSON.stringify(bad));assert.throws(()=>execFileSync(binary,['--review-lighting-restore',input,current,output],{stdio:'pipe'}));
  const unchanged={...clone(recovery),before:clone(original)};assert.deepEqual(lightingRestoreReports(unchanged),[]);assert.equal(reviewLightingRestoreProgress(unchanged,original).configurationMatchesOriginal,true);
  console.log(`PASS: ${states.length} raw restore-prefix parity cases, unchanged no-send, unknown/incomplete rejection, raw RGB/marker preservation and ordered scope; no HID`);
}finally{await rm(dir,{recursive:true,force:true});}
