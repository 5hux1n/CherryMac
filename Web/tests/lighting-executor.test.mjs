import test from 'node:test';
import assert from 'node:assert/strict';
import {demoSnapshot} from '../assets/layout.js';
import {clone,executeOfficialLightingCandidate,officialLightingReadbackTarget} from '../assets/model.js';

test('lighting candidate execution backs up, stops on uncertainty and checks complete readback without HID',async()=>{
  const plan={format:'CherryMacOfficialLightingPlan',version:2,hardwareReady:false,bank:0,transportSelector:0,chunkCapacity:56,stages:[{name:'parameters',beginRequired:true,beginCommand:1,finishCommand:2,finishDelayMilliseconds:10,writes:[{command:6,offset:0,flag:85,data:[0,1,2,3,1,0,7,123,249]},{command:6,offset:21,flag:85,data:[1]},{command:6,offset:24,flag:85,data:[1]}]}]};
  for(const mode of ['success','backupFailure','pendingLogFailure','lostReply','badReply','cancel','stale','unrelatedChange']){
    const baseline=demoSnapshot();let state=clone(baseline),now=0,sends=0,reads=0,backedUp=false;const records=[];
    const adapter={source:'simulation',assertCurrent:()=>{},cancelled:()=>mode==='cancel'&&sends===1,clock:()=>now,wait:ms=>{now+=ms;},
      read:()=>{reads++;if(mode==='stale'&&reads===2)state.keymap[0]^=1;return clone(state);},
      backup:value=>{assert.deepEqual(value,baseline);if(mode==='backupFailure')throw Error('backup failed');backedUp=true;},
      persist:value=>{if(mode==='pendingLogFailure'&&value.entries.length===1)throw Error('log failed');records.push(clone(value));},
      exchange:request=>{assert.ok(backedUp);assert.deepEqual(records.at(-1).entries.at(-1).request,request);assert.equal(records.at(-1).entries.at(-1).reply,undefined);sends++;now++;
        if(request[3]===6)state.parameters.splice(request[5]+request[6]*256,request[4],...request.slice(8,8+request[4]));
        if(mode==='unrelatedChange')state.keymap[0]=baseline.keymap[0]^1;
        if(mode==='lostReply')throw Error('reply timeout');
        const reply=clone(request);if(mode==='badReply')reply[7]=255;return reply;}};
    if(['backupFailure','pendingLogFailure','stale'].includes(mode)){await assert.rejects(()=>executeOfficialLightingCandidate(plan,baseline,adapter));assert.equal(sends,0);continue;}
    const result=await executeOfficialLightingCandidate(plan,baseline,adapter);
    if(mode==='success'){assert.equal(result.readbackMatches,true);assert.equal(sends,5);assert.deepEqual(state,officialLightingReadbackTarget(plan,baseline));assert.equal(result.trace.entries.at(-1).sentMilliseconds-result.trace.entries.at(-2).endedMilliseconds,10);}
    else{assert.equal(result.readbackMatches,false);assert.ok(result.failure);assert.equal(sends,mode==='unrelatedChange'?5:1);}
    assert.ok(result.current);assert.ok(records.length>=3);
  }
});
