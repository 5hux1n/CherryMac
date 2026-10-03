// Browser plumbing test only: memory reports, never navigator.hid.requestDevice.
import {chromium} from 'playwright';
import assert from 'node:assert/strict';
import {mkdtemp,writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {spawnSync} from 'node:child_process';
const artifacts=await mkdtemp(join(tmpdir(),'CherryMacMacroTransaction-'));
const browser=await chromium.launch({executablePath:process.env.CHERRY_CHROME??'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',headless:true});
const page=await browser.newPage(),errors=[];page.on('pageerror',e=>errors.push(e.message));page.setDefaultTimeout(120000);
try{
  await page.goto(process.env.CHERRY_TEST_URL??'http://127.0.0.1:8768/');
  await page.evaluate(async()=>{
    const {CherryHID,PageReleaseGate}=await import('./assets/hid.js'),{applyMacroWithStop}=await import('./assets/macro-session.js');
    const {demoSnapshot}=await import('./assets/layout.js'),{encodeBank,macroBinding}=await import('./assets/model.js');
    const {saveLog,listLogs}=await import('./assets/logs.js'),{sameSnapshot}=await import('./assets/writer.js');
    const before=demoSnapshot(),macro={name:'A',steps:[{usage:4,pressed:true,delayMilliseconds:0},{usage:4,pressed:false,delayMilliseconds:30}]};
    before.macroData=encodeBank([macro]);before.keymap.splice(306,3,...macroBinding(0,{mode:'toggle',count:1}));
    const target=structuredClone(before);target.macroData=encodeBank([{...macro,name:'B',steps:macro.steps.map(s=>({...s,usage:5}))}]);target.keymap.splice(306,3,...macroBinding(0,{mode:'count',count:3}));
    class MemoryDevice extends EventTarget{
      constructor(){super();this.s=structuredClone(before);this.vendorId=1130;this.productId=462;this.opened=false;this.requests=[];this.collections=[{usagePage:0xff1c,usage:0x92,inputReports:[{reportId:4,items:[{reportSize:8,reportCount:63}]}],outputReports:[{reportId:4,items:[{reportSize:8,reportCount:63}]}]}];}
      async open(){this.opened=true;}async close(){this.opened=false;}
      async sendReport(id,data){
        if(id!==4||data.byteLength!==63)throw new Error('Invalid report framing');
        const p=new Uint8Array([id,...data]);this.requests.push(Array.from(p));const r=p.slice(),command=p[3],offset=p[5]|p[6]<<8,length=p[4];
        const field=({3:'deviceInfo',5:'parameters',8:'keymap',10:'colors',20:'macroData'})[command];
        if(field)r.set(this.s[field].slice(offset,offset+length),8);
        else {const field=({9:'keymap',21:'macroData'})[command];if(!field)throw new Error('Unscoped command');this.s[field].splice(offset,length,...p.slice(8,8+length));}
        const buffer=new Uint8Array(90);buffer.set(r.slice(1),9);const event=new Event('inputreport');Object.assign(event,{reportId:4,data:new DataView(buffer.buffer,9,63),device:this});queueMicrotask(()=>this.dispatchEvent(event));
      }
    }
    window.tx={before,target,device:new MemoryDevice(),backups:[],phases:[],outcome:null,operationIds:[],sameSnapshot,listLogs};
    tx.hid=new CherryHID(tx.device,{macroResearch:true,log:saveLog});await tx.hid.open();tx.gate=new PageReleaseGate();
    const start=document.createElement('button');start.id='macro-transaction-start';start.textContent='Start memory macro transaction';document.body.append(start);
    start.addEventListener('click',event=>{
      tx.gate.acknowledge(event);
      const options={gate:tx.gate,backup:async s=>tx.backups.push(structuredClone(s)),progress:p=>tx.phases.push(p)};
      tx.promise=(async()=>{
        const after=await applyMacroWithStop(tx.hid,target,before,options);if(!sameSnapshot(after,target))throw new Error('Target mismatch');
        tx.targetVerified=true;
        const restored=await applyMacroWithStop(tx.hid,before,after,options);if(!sameSnapshot(restored,before))throw new Error('Restore mismatch');
        // Capability must be gone outside the transaction, even in research mode.
        const {MacroWriteAuthorization}=await import('./assets/safety.js'),auth=new MacroWriteAuthorization(before,target,{allowUnbounded:true});
        const count=tx.device.requests.length;let denied=false;try{await tx.hid.exchange(auth.packet(9,target.keymap,0));}catch{denied=true;}
        if(!denied||count!==tx.device.requests.length)throw new Error('Transaction permission leaked');
        await tx.hid.flushLogs();tx.outcome={ok:true,restored:true,permissionRevoked:denied};
      })().catch(error=>tx.outcome={ok:false,error:error.message});
    },{once:true});
  });
  await page.locator('#macro-transaction-start').click();await page.locator('.macro-stop-dialog').waitFor();
  assert.equal(await page.evaluate(()=>tx.device.requests.filter(p=>[9,21].includes(p[3])).length),0);
  await page.waitForFunction(()=>!document.querySelector('.macro-stop-accept').disabled);await page.locator('.macro-stop-accept').click();
  await page.waitForFunction(()=>tx.outcome!=null);const outcome=await page.evaluate(()=>tx.outcome);assert.deepEqual(outcome,{ok:true,restored:true,permissionRevoked:true});
  // A cancelled stop dialog must leave the old toggle trigger and all banks intact.
  await page.evaluate(async()=>{
    const {applyMacroWithStop}=await import('./assets/macro-session.js');tx.cancelOutcome=null;tx.requestsBeforeCancel=tx.device.requests.length;
    const button=document.createElement('button');button.id='macro-transaction-cancel';button.textContent='Start cancelled memory transaction';document.body.append(button);
    button.addEventListener('click',event=>{tx.gate.acknowledge(event);
      applyMacroWithStop(tx.hid,tx.target,tx.before,{gate:tx.gate,backup:async s=>tx.backups.push(structuredClone(s))})
        .then(()=>tx.cancelOutcome={ok:true},error=>tx.cancelOutcome={ok:false,error:error.message});
    },{once:true});
  });
  await page.locator('#macro-transaction-cancel').click();await page.locator('.macro-stop-dialog').waitFor();await page.locator('.macro-stop-cancel').click();await page.waitForFunction(()=>tx.cancelOutcome!=null);
  assert.equal((await page.evaluate(()=>tx.cancelOutcome)).ok,false);
  assert.equal(await page.evaluate(()=>tx.sameSnapshot(tx.device.s,tx.before)),true);
  assert.equal(await page.evaluate(()=>tx.device.requests.slice(tx.requestsBeforeCancel).filter(p=>[9,21].includes(p[3])).length),0);
  assert.equal(await page.evaluate(()=>tx.gate.armed),false);
  const evidence=await page.evaluate(async()=>{
    const logs=await tx.listLogs(),ids=new Set(logs.filter(r=>r.kind==='phase'&&r.baseline&&r.target&&tx.sameSnapshot(r.baseline,tx.before)).map(r=>r.operationId));
    for(const r of logs)if(r.kind==='phase'&&r.baseline&&r.target&&tx.sameSnapshot(r.target,tx.before)&&tx.sameSnapshot(r.baseline,tx.target))ids.add(r.operationId);
    return {format:'CherryMacWebDiagnostics',version:1,usbLogs:logs.filter(r=>ids.has(r.operationId)),sessionLogs:[],backups:tx.backups.map((snapshot,i)=>({id:String(i),date:new Date(i).toISOString(),snapshot})),summary:{phases:tx.phases,writeCommands:tx.device.requests.filter(p=>[9,21].includes(p[3])).map(p=>p[3]),targetVerified:tx.targetVerified}};
  });
  assert.equal(evidence.backups.length,3);assert.equal(evidence.summary.targetVerified,true);assert.ok(evidence.summary.writeCommands.includes(21));assert.ok(evidence.summary.writeCommands.every(c=>[9,21].includes(c)));
  const filename=join(artifacts,'memory-transaction-diagnostics.json');await writeFile(filename,JSON.stringify(evidence,null,2));
  const replay=spawnSync(process.execPath,['Web/tests/replay-diagnostics.mjs',filename],{encoding:'utf8'});assert.equal(replay.status,0,replay.stderr);const report=JSON.parse(replay.stdout);assert.deepEqual(report.issues,[]);assert.equal(report.missingReplies,0);assert.equal(report.macroStopRecords.length,2);assert.ok(report.macroStopRecords.every(r=>r.authorizationLinked));assert.deepEqual(report.macroStopRecords.map(r=>r.status).sort(),['acknowledged','failed']);assert.deepEqual(errors,[]);
  await writeFile(join(artifacts,'replay.json'),replay.stdout);console.log(JSON.stringify({passed:true,scope:'memory USB reports and headless browser; no physical HID access, macro execution or power-cycle proof',writePackets:evidence.summary.writeCommands.length,validReplies:report.validReplies,artifacts}));
}finally{await browser.close();}
