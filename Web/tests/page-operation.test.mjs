import test from 'node:test';
import assert from 'node:assert/strict';
import {fileURLToPath} from 'node:url';
import {runPageOperation} from '../assets/page-operation.js';
test('local diagnostics and recovery exports work while host service is unavailable',async()=>{
  const calls=[];
  const gates={localOnly:true,stopObservation:()=>calls.push('stop'),invalidateText:()=>calls.push('clear'),suspendHostText:async()=>{calls.push('network');throw new Error('Mac unavailable');}};
  const exported=await runPageOperation(async()=>{calls.push('export');return {logs:[{error:'Mac unavailable'}]};},gates);
  assert.deepEqual(calls,['export']);assert.equal(exported.logs[0].error,'Mac unavailable');
});
test('configuration keeps shutdown ordering and never reaches device callback on failure',async()=>{
  const calls=[];const gates={stopObservation:()=>calls.push('stop'),invalidateText:()=>calls.push('clear'),suspendHostText:async()=>{calls.push('suspend');throw new Error('Mac busy');}};
  await assert.rejects(runPageOperation(async()=>calls.push('device'),gates),/Mac busy/);
  assert.deepEqual(calls,['stop','clear','suspend']);
  gates.suspendHostText=async()=>calls.push('released');
  await runPageOperation(async()=>calls.push('device'),gates);
  assert.deepEqual(calls.slice(3),['stop','clear','released','device']);
});

test('offline replay retains pre-USB failures even when database persistence failed',async()=>{
  const {mkdtemp,writeFile,rm}=await import('node:fs/promises');
  const {tmpdir}=await import('node:os'),{join}=await import('node:path'),{execFileSync}=await import('node:child_process');
  const directory=await mkdtemp(join(tmpdir(),'cherry-page-failures-'));
  const first={id:'first',at:'2026-10-05T00:00:00Z',kind:'phase',phase:'page-failed',action:'connect',tab:'keys',error:'Mac unavailable'};
  const second={...first,id:'second',action:'read',error:'picker unavailable',persistenceError:'disk full'};
  try{
    const path=join(directory,'diagnostics.json');await writeFile(path,JSON.stringify({format:'CherryMacWebDiagnostics',version:1,usbLogs:[first],sessionLogs:[],pageFailures:[first,second],backups:[]}));
    const report=JSON.parse(execFileSync(process.execPath,[fileURLToPath(new URL('./replay-diagnostics.mjs',import.meta.url)),path],{encoding:'utf8'}));
    assert.deepEqual(report.issues,[]);assert.deepEqual(report.pageFailures,[first,second]);assert.equal(report.validReplies,0);
  }finally{await rm(directory,{recursive:true,force:true});}
});
