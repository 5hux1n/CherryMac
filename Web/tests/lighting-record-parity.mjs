// File-only native/Web recovery review; no transport or product startup.
import assert from 'node:assert/strict';
import {mkdtemp,writeFile,readFile,rm} from 'node:fs/promises';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import {execFileSync} from 'node:child_process';
import {demoSnapshot} from '../assets/layout.js';
import {clone,officialLightingReports,officialLightingReadbackTarget,assessLightingRecoveryRecord} from '../assets/model.js';
const binary=process.argv[2];assert.ok(binary);
const plan={format:'CherryMacOfficialLightingPlan',version:2,hardwareReady:false,bank:0,transportSelector:0,chunkCapacity:56,stages:[{name:'parameters',beginRequired:true,beginCommand:1,finishCommand:2,finishDelayMilliseconds:10,writes:[{command:6,offset:0,flag:85,data:[0,1,2,3,1,0,7,123,249]},{command:6,offset:21,flag:85,data:[1]},{command:6,offset:24,flag:85,data:[1]}]}]};
const original=demoSnapshot();let clock=0;
const trace={format:'CherryMacLightingTrace',version:1,source:'simulation',entries:officialLightingReports(plan).map(r=>{clock+=r.delayMilliseconds;const sentMilliseconds=clock;clock++;return {request:r.request,reply:r.request,sentMilliseconds,endedMilliseconds:clock};})};
const base={format:'CherryMacLightingRecoveryRecord',version:1,hardwareReady:false,operationID:'record-test',plan,original,trace,current:officialLightingReadbackTarget(plan,original),failure:''};
const cases=[base];
for(const mutate of [r=>r.current=null,r=>r.current=clone(original),r=>r.current.keymap[0]^=1,r=>{r.trace.entries=r.trace.entries.slice(0,2);r.failure='timeout';delete r.trace.entries[1].reply;r.trace.entries[1].error='timeout';r.current=clone(original);r.current.parameters.splice(0,9,...plan.stages[0].writes[0].data);}]){const record=clone(base);mutate(record);cases.push(record);}
const invalid=[];for(const mutate of [r=>r.hardwareReady=true,r=>r.operationID='../test',r=>r.plan.stages[0].writes[0].offset++,r=>r.current.colors=null]){const record=clone(base);mutate(record);invalid.push(record);}
const dir=await mkdtemp(join(tmpdir(),'cherrymac-lighting-record-')),input=join(dir,'record.json'),output=join(dir,'assessment.json');
try{
  for(const record of cases){await writeFile(input,JSON.stringify(record));execFileSync(binary,['--review-lighting-recovery-record',input,output],{stdio:'pipe'});assert.deepEqual(JSON.parse(await readFile(output,'utf8')),assessLightingRecoveryRecord(record));}
  assert.deepEqual(cases.map(r=>assessLightingRecoveryRecord(r).recoveryStatus),['available','unavailable','unchanged','unrecognized','available']);
  for(const record of invalid){await writeFile(input,JSON.stringify(record));assert.throws(()=>assessLightingRecoveryRecord(record));assert.throws(()=>execFileSync(binary,['--review-lighting-recovery-record',input,output],{stdio:'pipe'}));}
  const before=await readFile(input);assert.throws(()=>execFileSync(binary,['--review-lighting-recovery-record',input,input],{stdio:'pipe'}));assert.deepEqual(await readFile(input),before);
  console.log('PASS: 5 recovery-record parity cases, 4 invalid records and original-file protection; synthetic files only');
}finally{await rm(dir,{recursive:true,force:true});}
