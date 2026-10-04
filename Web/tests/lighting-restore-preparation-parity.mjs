// Restore preparation only; saved files and memory, never a transport.
import assert from 'node:assert/strict';
import {mkdtemp,writeFile,readFile,rm} from 'node:fs/promises';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import {execFileSync} from 'node:child_process';
import {demoSnapshot} from '../assets/layout.js';
import {clone,officialLightingReadbackTarget,lightingRestoreReports,lightingRestorePlanFromRecord} from '../assets/model.js';
const binary=process.argv[2];assert.ok(binary);
const original=demoSnapshot();original.colors=Array.from({length:378},(_,i)=>i%256);original.parameters[24]=0;
const colors=Array(378).fill(3),flag=85;
const plan={format:'CherryMacOfficialLightingPlan',version:2,hardwareReady:false,bank:0,transportSelector:0,chunkCapacity:56,stages:[{name:'parameters',beginRequired:true,beginCommand:1,finishCommand:2,finishDelayMilliseconds:10,writes:[{command:6,offset:0,flag,data:[0,8,2,3,1,0,7,123,249]},{command:6,offset:21,flag,data:[1]},{command:6,offset:24,flag,data:[1]}]},{name:'customColors',beginRequired:true,beginCommand:1,finishCommand:2,finishDelayMilliseconds:10,writes:Array.from({length:7},(_,i)=>({command:11,offset:i*56,flag:0,data:colors.slice(i*56,(i+1)*56)}))}]};

const current=officialLightingReadbackTarget(plan,original),record={format:'CherryMacLightingRecoveryRecord',version:1,hardwareReady:false,operationID:'prepare-test',plan,original,trace:{format:'CherryMacLightingTrace',version:1,source:'simulation',entries:[]},current,failure:'stopped'};
const recovery=lightingRestorePlanFromRecord(record),rawBefore=JSON.stringify(record),reports=lightingRestoreReports(recovery);
assert.deepEqual(recovery.before,current);assert.equal(recovery.hardwareReady,false);assert.deepEqual(recovery.sourceRecord,record);
const intermediate=clone(current),first=reports.find(r=>r.kind==='data').request;intermediate.parameters.splice(first[5]+first[6]*256,first[4],...first.slice(8,8+first[4]));
const attempt={format:'CherryMacLightingRestoreAttempt',version:1,hardwareReady:false,operationID:'restore-stop',recovery,started:clone(current),trace:{format:'CherryMacLightingTrace',version:1,source:'simulation',entries:[]},current:intermediate,failure:'stopped'};
assert.deepEqual(lightingRestorePlanFromRecord(attempt),recovery);assert.equal(JSON.stringify(record),rawBefore);
const unchanged={...clone(record),current:clone(original)};assert.deepEqual(lightingRestoreReports(lightingRestorePlanFromRecord(unchanged)),[]);
const bad=clone(record);bad.current.keymap[27]^=1;const badAttempt=clone(attempt);badAttempt.current.colors[0]^=1;
const dir=await mkdtemp(join(tmpdir(),'cherry-restore-prepare-')),input=join(dir,'record.json'),output=join(dir,'plan.json');
try{
  for(const item of [record,attempt,unchanged]){await writeFile(input,JSON.stringify(item));execFileSync(binary,['--export-lighting-restore-plan',input,output],{stdio:'pipe'});assert.deepEqual(JSON.parse(await readFile(output,'utf8')),lightingRestorePlanFromRecord(item));}
  for(const item of [bad,badAttempt,{...clone(record),current:null},{...clone(attempt),current:null},{...clone(record),hardwareReady:true}]){assert.throws(()=>lightingRestorePlanFromRecord(item));await writeFile(input,JSON.stringify(item));assert.throws(()=>execFileSync(binary,['--export-lighting-restore-plan',input,output],{stdio:'pipe'}));}
  await writeFile(input,JSON.stringify(record));const before=await readFile(input);assert.throws(()=>execFileSync(binary,['--export-lighting-restore-plan',input,input],{stdio:'pipe'}));assert.deepEqual(await readFile(input),before);
  console.log('PASS: native/Web restore preparation parity, interrupted-restore continuation, unchanged no reports, missing/unknown readback rejection, raw source and input preservation; no HID');
}finally{await rm(dir,{recursive:true,force:true});}
