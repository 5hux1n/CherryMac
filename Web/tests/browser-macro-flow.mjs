import {chromium} from 'playwright';
import assert from 'node:assert/strict';
import {mkdtemp,writeFile} from 'node:fs/promises';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import {spawnSync} from 'node:child_process';
const artifacts=await mkdtemp(join(tmpdir(),'CherryMacWebMacroFlow-'));
const browser=await chromium.launch({executablePath:'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',headless:true});
const page=await browser.newPage({viewport:{width:1100,height:850}});page.setDefaultTimeout(120000);const errors=[];page.on('pageerror',e=>errors.push(e.message));
try{
  await page.goto('http://127.0.0.1:8768/');await page.evaluate(async()=>{
    const {MacroTestFlow}=await import('./assets/macro-test-flow.js'),{demoSnapshot}=await import('./assets/layout.js'),{listLogs}=await import('./assets/logs.js'),{listBackups}=await import('./assets/storage.js');
    class MemoryDevice extends EventTarget{
      constructor(){super();this.s=demoSnapshot();this.vendorId=1130;this.productId=462;this.opened=false;this.requests=[];this.collections=[{usagePage:0xff1c,usage:0x92,inputReports:[{reportId:4,items:[{reportSize:8,reportCount:63}]}],outputReports:[{reportId:4,items:[{reportSize:8,reportCount:63}]}]}];}
      async open(){this.opened=true;}async close(){this.opened=false;}
      async sendReport(id,data){const p=new Uint8Array([id,...data]);if(id!==4||p.length!==64)throw new Error('framing');this.requests.push(Array.from(p));const r=p.slice(),o=p[5]|p[6]<<8,n=p[4],field=({3:'deviceInfo',5:'parameters',8:'keymap',10:'colors',20:'macroData'})[p[3]];
        if(field)r.set(this.s[field].slice(o,o+n),8);else{const f=({9:'keymap',21:'macroData'})[p[3]];if(!f)throw new Error('unexpected write');this.s[f].splice(o,n,...p.slice(8,8+n));}
        const e=new Event('inputreport');Object.assign(e,{reportId:4,data:new DataView(r.slice(1).buffer),device:this});queueMicrotask(()=>this.dispatchEvent(e));}
    }
    document.querySelector('.app-shell').remove();const root=document.createElement('main');document.body.append(root);window.fakeDevice=new MemoryDevice();window.fakeEvents=new EventTarget();window.clockOffset=0;window.flow=new MacroTestFlow(root,{selectDevice:async()=>[fakeDevice],hidEvents:fakeEvents,now:()=>Math.floor(performance.now())+clockOffset});window.flowLogs=listLogs;window.flowBackups=listBackups;
  });
  await page.locator('#macro-test-next').click();await page.waitForFunction(()=>flow.phase==='ready');
  await page.locator('#macro-test-next').click();await page.waitForFunction(()=>flow.phase==='observeReady'||flow.phase==='failed');assert.equal(await page.evaluate(()=>flow.phase),'observeReady');
  await page.screenshot({path:join(artifacts,'flow-desktop.png')});
  for(const afterPower of [false,true]){
    await page.locator('#macro-test-next').click();await page.waitForFunction(()=>flow.phase==='observing');
    for(let i=0;i<2;i++){await page.keyboard.press('a');await page.keyboard.press('b');}
    await page.waitForFunction(()=>flow.phase==='disconnect'||flow.phase==='restoreReady'||flow.phase==='failed');
    assert.equal(await page.evaluate(()=>flow.phase),afterPower?'restoreReady':'disconnect');
    if(!afterPower){
      await page.evaluate(()=>flow.hid.close());await page.waitForFunction(()=>flow.phase==='reconnect');await page.locator('#macro-test-off').check();
      await page.evaluate(()=>{clockOffset+=16000;const e=new Event('connect');Object.assign(e,{device:fakeDevice});fakeEvents.dispatchEvent(e);});await page.waitForFunction(()=>flow.phase==='observeReady'||flow.phase==='failed');assert.equal(await page.evaluate(()=>flow.phase),'observeReady');
    }
  }
  await page.locator('#macro-test-next').click();await page.waitForFunction(()=>flow.phase==='complete'||flow.phase==='failed');assert.equal(await page.evaluate(()=>flow.phase),'complete');
  const state=await page.evaluate(()=>({restored:flow.restored,power:flow.powerVerified,first:flow.firstPassed,second:flow.secondPassed,errors:flow.errors}));assert.deepEqual(state,{restored:true,power:true,first:true,second:true,errors:[]});
  await page.setViewportSize({width:390,height:844});await page.screenshot({path:join(artifacts,'flow-mobile.png')});assert.ok(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth));
  const evidence=await page.evaluate(async()=>{await flow.flush();await flow.hid.flushLogs();return {format:'CherryMacWebDiagnostics',version:1,usbLogs:await flowLogs(),sessionLogs:[],backups:await flowBackups()};});
  const filename=join(artifacts,'memory-flow-diagnostics.json');await writeFile(filename,JSON.stringify(evidence,null,2));const result=spawnSync(process.execPath,['Web/tests/replay-diagnostics.mjs',filename],{encoding:'utf8'});assert.equal(result.status,0,result.stderr);const report=JSON.parse(result.stdout);assert.deepEqual(report.issues,[]);assert.equal(report.missingReplies,0);assert.equal(report.macroExecutionRecords.length,2);assert.ok(report.macroExecutionRecords.every(r=>r.passed&&r.authorizationLinked&&r.source==='focusedBrowser'));
  const forged=structuredClone(evidence),entry=forged.usbLogs.find(r=>r.kind==='macroExecution');entry.macro.steps[1].delayMilliseconds=0;
  const forgedPath=join(artifacts,'mismatched-execution-diagnostics.json');await writeFile(forgedPath,JSON.stringify(forged));const bad=spawnSync(process.execPath,['Web/tests/replay-diagnostics.mjs',forgedPath],{encoding:'utf8'});assert.equal(bad.status,0,bad.stderr);assert.ok(JSON.parse(bad.stdout).issues.some(r=>r.error.includes('目标绑定不一致')));
  // An early reconnect cannot become a passing 15-second interval later.
  await page.evaluate(()=>{flow.phase='reconnect';flow.offAt=flow.now();flow.reconnected(fakeDevice);});await page.waitForFunction(()=>flow.phase==='failed');assert.equal(await page.evaluate(()=>flow.errors.length),1);
  // Reload the saved transaction scope in a new controller; never regenerate a target.
  await page.evaluate(async()=>{
    const before=flow.plan.before,target=flow.plan.expected;flow.dispose();await flow.hid.close();fakeDevice.s=structuredClone(target);
    const {saveLog}=await import('./assets/logs.js'),{MacroTestFlow}=await import('./assets/macro-test-flow.js');
    const id=crypto.randomUUID();await saveLog({id,operationId:id,at:new Date().toISOString(),kind:'phase',format:'CherryMacWebMacroHardwareFlow',version:1,phase:'failed',baseline:before,target,originalRestored:false});
    const root=document.querySelector('main');flow=new MacroTestFlow(root,{selectDevice:async()=>[fakeDevice],hidEvents:fakeEvents});
  });
  await page.locator('#macro-test-resume').click();await page.waitForFunction(()=>flow.phase==='complete'||flow.phase==='failed');assert.equal(await page.evaluate(()=>flow.phase),'complete');
  assert.equal(await page.evaluate(()=>flow.restored),true);assert.equal(await page.evaluate(()=>flow.firstPassed===true),false);assert.match(await page.locator('#macro-test-status').textContent(),/不计作通过/);
  await page.evaluate(()=>flow.dispose());assert.deepEqual(errors,[]);console.log(JSON.stringify({passed:true,scope:'browser UI, synthetic memory reports, trusted browser automation and simulated off clock; no physical HID or power-off proof',validReplies:report.validReplies,artifacts}));
}finally{await browser.close();}
