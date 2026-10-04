import assert from 'node:assert/strict';
import {demoSnapshot} from '../assets/layout.js';
import {clone,officialLightingReadbackTarget,lightingRestoreReports} from '../assets/model.js';
import {lightingAcceptanceInput,lightingRecoveryForFreshRead} from '../assets/lighting-test-plan.js';
const original=demoSnapshot();original.parameters[24]=0;
const plan={format:'CherryMacOfficialLightingPlan',version:2,hardwareReady:false,bank:0,transportSelector:0,chunkCapacity:56,stages:[{name:'parameters',beginRequired:true,beginCommand:1,finishCommand:2,finishDelayMilliseconds:10,writes:[{command:6,offset:0,flag:85,data:[0,1,2,3,1,0,7,123,249]},{command:6,offset:21,flag:85,data:[1]},{command:6,offset:24,flag:85,data:[1]}]}]};
const target=officialLightingReadbackTarget(plan,original),review={format:'CherryMacLightingDraftReview',version:1,hardwareReady:false,plan,original,target};
assert.equal(lightingAcceptanceInput(review).kind,'write');
const tampered=clone(review);tampered.target.keymap[0]^=1;assert.throws(()=>lightingAcceptanceInput(tampered));
assert.throws(()=>lightingAcceptanceInput({...review,hardwareReady:true}));
const record={format:'CherryMacLightingRecoveryRecord',version:1,hardwareReady:false,operationID:'fresh-recovery',plan,original,trace:{format:'CherryMacLightingTrace',version:1,source:'simulation',entries:[]},current:null,failure:'disconnected'};
assert.equal(lightingAcceptanceInput(record).kind,'restore');
const before=JSON.stringify(record),recovery=lightingRecoveryForFreshRead(record,target);
assert.deepEqual(recovery.before,target);assert.equal(JSON.stringify(record),before);
const reports=lightingRestoreReports(recovery),partial=clone(target),first=reports.find(r=>r.kind==='data').request;
partial.parameters.splice(first[5]+first[6]*256,first[4],...first.slice(8,8+first[4]));
const attempt={format:'CherryMacLightingRestoreAttempt',version:1,hardwareReady:false,operationID:'interrupted',recovery,started:clone(target),trace:{format:'CherryMacLightingTrace',version:1,source:'simulation',entries:[]},current:null,failure:'lost reply'};
assert.deepEqual(lightingRecoveryForFreshRead(attempt,partial),recovery);
assert.deepEqual(lightingRestoreReports(lightingRecoveryForFreshRead(record,original)),[]);
const unknown=clone(target);unknown.keymap[0]^=1;assert.throws(()=>lightingRecoveryForFreshRead(record,unknown));
assert.throws(()=>lightingRecoveryForFreshRead(attempt,unknown));
console.log('PASS: research input target verification, reconnect recovery without historical readback, raw/interrupted plan preservation, unknown scope rejection; memory only');
// Optional native file command parity. Never enters AppKit or opens a device.
if(process.argv[2]){
  const {mkdtemp,writeFile,readFile,rm}=await import('node:fs/promises');
  const {join}=await import('node:path'),{tmpdir}=await import('node:os'),{execFileSync}=await import('node:child_process');
  const dir=await mkdtemp(join(tmpdir(),'cherry-fresh-lighting-')),recordPath=join(dir,'record.json'),currentPath=join(dir,'current.json'),out=join(dir,'plan.json');
  try{
    for(const [source,current] of [[record,target],[record,original],[attempt,partial]]){
      await writeFile(recordPath,JSON.stringify(source));await writeFile(currentPath,JSON.stringify(current));
      execFileSync(process.argv[2],['--prepare-lighting-recovery',recordPath,currentPath,out],{stdio:'pipe'});
      assert.deepEqual(JSON.parse(await readFile(out,'utf8')),lightingRecoveryForFreshRead(source,current));
    }
    await writeFile(currentPath,JSON.stringify(unknown));
    assert.throws(()=>execFileSync(process.argv[2],['--prepare-lighting-recovery',recordPath,currentPath,out],{stdio:'pipe'}));
    for(const path of [recordPath,currentPath]){
      const before=await readFile(path);assert.throws(()=>execFileSync(process.argv[2],['--prepare-lighting-recovery',recordPath,currentPath,path],{stdio:'pipe'}));assert.deepEqual(await readFile(path),before);
    }
    console.log('PASS: native/Web fresh recovery plan parity, interrupted prefix and input overwrite rejection; files only');
  }finally{await rm(dir,{recursive:true,force:true});}
}
const {LightingPowerCycle}=await import('../assets/lighting-test-plan.js');
const cycle=new LightingPowerCycle('original');assert.equal(cycle.disconnect('other',10),false);
assert.throws(()=>cycle.confirmPowerOff(10));cycle.disconnect('original',100);cycle.confirmPowerOff(200);cycle.reconnect('returned',15_200);
assert.equal(cycle.reconnect('other',30_000),false);assert.throws(()=>cycle.evidence('other'));
assert.equal(cycle.evidence('returned').elapsedMilliseconds,15_000);
cycle.disconnect('returned',40_000);assert.throws(()=>cycle.evidence('returned'));cycle.confirmPowerOff(41_000);cycle.reconnect('returned',55_999);assert.throws(()=>cycle.evidence('returned'));
const reused=new LightingPowerCycle('same');reused.disconnect('same',0);reused.confirmPowerOff(1);reused.reconnect('same',15_001);assert.equal(reused.evidence('same').elapsedMilliseconds,15_000);
console.log('PASS: first reconnect time preserved, selected device binding, repeated power-cycle invalidation, early reconnect rejection and reused HID object; memory only');
// The research tab handoff is one-use and untrusted; replay, expiry, quota
// failure and a modified keymap must not become transport authorization.
const {saveLightingHandoff,takeLightingHandoff}=await import('../assets/storage.js');
const handoffID='aabbccdd-0000-4000-8000-000000000001',memory=new Map();
const storage={getItem:k=>memory.get(k)??null,setItem:(k,v)=>memory.set(k,v),removeItem:k=>memory.delete(k)};
saveLightingHandoff(storage,handoffID,review,100);
assert.deepEqual(lightingAcceptanceInput(takeLightingHandoff(storage,handoffID,200)).value,review);
assert.throws(()=>takeLightingHandoff(storage,handoffID,201));
for(const now of [99,600_101]){saveLightingHandoff(storage,handoffID,review,100);assert.throws(()=>takeLightingHandoff(storage,handoffID,now));assert.equal(memory.size,0);}
saveLightingHandoff(storage,handoffID,tampered,100);
assert.throws(()=>lightingAcceptanceInput(takeLightingHandoff(storage,handoffID,200)));
assert.throws(()=>saveLightingHandoff({...storage,setItem:()=>{}},handoffID,review,100));
assert.throws(()=>saveLightingHandoff(storage,'../../config',review));
assert.throws(()=>saveLightingHandoff(storage,handoffID,{text:'界'.repeat(1_000_001)},100));
assert.equal(memory.size,0);
console.log('PASS: single-use lighting handoff, expiry, scope revalidation, quota and UTF-8 size failure; memory only');
