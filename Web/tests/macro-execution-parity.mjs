// Replay synthetic observations in Swift and JavaScript. No HID is opened.
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {mkdtemp,readFile,writeFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {clone,replayMacroExecutionLog} from '../assets/model.js';
const binary=resolve(process.argv[2]??fileURLToPath(new URL('../../build/CherryMac',import.meta.url)));
const directory=await mkdtemp(join(tmpdir(),'CherryMacMacroEvidence-'));
const macro={name:'A + middle mouse',steps:[{usage:4,pressed:true,delayMilliseconds:0},{usage:4,kind:'mouse',pressed:true,delayMilliseconds:20},{usage:4,kind:'mouse',pressed:false,delayMilliseconds:50},{usage:4,pressed:false,delayMilliseconds:0}]};
const cycle=start=>macro.steps.map(({usage,kind,pressed},i)=>({usage,pressed,milliseconds:start+i*10,...(kind?{kind}:{})}));
const base={format:'CherryMacMacroExecution',version:1,macro,playback:{mode:'count',count:1},source:'simulation',startedMilliseconds:0,events:cycle(0),assessedMilliseconds:300};
const cases=[];
for(const count of [1,2,3,255])cases.push({name:`count-${count}`,log:{...base,playback:{mode:'count',count},events:Array.from({length:count},(_,i)=>cycle(i*100)).flat(),assessedMilliseconds:(count-1)*100+300},status:'passed'});
cases.push({name:'empty-is-not-finished',log:{...base,events:[],assessedMilliseconds:999999},status:'waitingOutput'});
cases.push({name:'missing-cycle',log:{...base,playback:{mode:'count',count:2}},status:'waitingOutput'});
cases.push({name:'quiet-not-yet-complete',log:{...base,assessedMilliseconds:299},status:'waitingQuiet'});
cases.push({name:'wrong-key',log:{...base,events:[{usage:5,pressed:true,milliseconds:0}]},status:'failed'});
cases.push({name:'extra-cycle',log:{...base,events:[...cycle(0),...cycle(100)]},status:'failed'});
cases.push({name:'duplicate-press',log:{...base,events:[{usage:4,pressed:true,milliseconds:0},{usage:4,pressed:true,milliseconds:1}]},status:'failed'});
for(const reason of ['observerDisconnected','focusLost','loggingFailed','cancelled','reportRejected'])cases.push({name:reason,log:{...base,interruptions:[reason]},status:'failed'});
for(const mode of ['held','toggle']){
  const active={...base,playback:{mode,count:1},events:[...cycle(0),...cycle(100)],assessedMilliseconds:1000};
  cases.push({name:`${mode}-needs-stop`,log:active,status:'waitingStop'});
  cases.push({name:`${mode}-stopped`,log:{...active,stop:{milliseconds:200,source:'userAcknowledged'}},status:'passed'});
  cases.push({name:`${mode}-needs-two-cycles`,log:{...active,events:cycle(0),stop:{milliseconds:200,source:'simulation'}},status:'waitingOutput'});
  const partial=[...active.events,{usage:4,pressed:true,milliseconds:200},{usage:4,kind:'mouse',pressed:true,milliseconds:201}];
  cases.push({name:`${mode}-stuck-key`,log:{...active,events:partial,stop:{milliseconds:210,source:'physicalTriggerObserved'}},status:'waitingRelease'});
  cases.push({name:`${mode}-abort-releases-reordered`,log:{...active,events:[...partial,{usage:4,pressed:false,milliseconds:220},{usage:4,kind:'mouse',pressed:false,milliseconds:221}],stop:{milliseconds:210,source:'userAcknowledged'}},status:'passed'});
  cases.push({name:`${mode}-late-output`,log:{...active,events:[...active.events,...cycle(300)],stop:{milliseconds:200,source:'userAcknowledged'}},status:'failed'});
  cases.push({name:`${mode}-orphan-release`,log:{...active,events:[...active.events,{usage:5,pressed:false,milliseconds:300}],stop:{milliseconds:200,source:'simulation'}},status:'failed'});
}
try{
  const input=join(directory,'execution.json'),output=join(directory,'assessment.json');
  for(const {name,log,status} of cases){
    await writeFile(input,JSON.stringify(log));execFileSync(binary,['--analyze-macro-execution',output,'--execution-log',input],{stdio:'pipe'});
    const native=JSON.parse(await readFile(output,'utf8')),web=replayMacroExecutionLog(log);
    assert.equal(native.format,'CherryMacMacroExecutionAssessment');assert.equal(native.version,1);
    assert.equal(native.inputSHA256,createHash('sha256').update(await readFile(input)).digest('hex'));
    assert.deepEqual(native.assessment,web,name);assert.equal(web.status,status,name);
  }
  const invalid=[{...base,format:'foreign'}, {...base,playback:{mode:'count',count:0}}, {...base,events:[{usage:4,pressed:true,milliseconds:2},{usage:4,pressed:false,milliseconds:1}]}, {...base,source:'unknown'}, {...base,stop:{milliseconds:200,source:'simulation'}},{...base,interruptions:['unknown']}];
  for(const log of invalid){
    await writeFile(input,JSON.stringify(log));assert.throws(()=>replayMacroExecutionLog(log));assert.throws(()=>execFileSync(binary,['--analyze-macro-execution',output,'--execution-log',input],{stdio:'pipe'}));
  }
  await writeFile(input,JSON.stringify(clone(base)));const original=await readFile(input);
  assert.throws(()=>execFileSync(binary,['--analyze-macro-execution',input,'--execution-log',input],{stdio:'pipe'}));assert.deepEqual(await readFile(input),original);
  console.log(`PASS: ${cases.length} native/Web execution-evidence cases, ${invalid.length} invalid logs, source distinction and original-log overwrite rejection (synthetic replay only)`);
}finally{await rm(directory,{recursive:true,force:true});}
