import {chromium} from 'playwright';
import assert from 'node:assert/strict';
import {mkdtemp} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
const artifacts=process.env.CHERRY_TEST_ARTIFACTS??await mkdtemp(join(tmpdir(),'CherryMacMacroStopUI-'));
const url=process.env.CHERRY_TEST_URL??'http://127.0.0.1:8768/';
const browser=await chromium.launch({executablePath:process.env.CHERRY_CHROME??(process.platform==='darwin'?'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome':undefined),headless:true});
const errors=[];
async function start(mode='toggle',options={}){
  const page=await browser.newPage({viewport:{width:980,height:800}});page.on('pageerror',e=>errors.push(e.message));await page.goto(url);
  await page.evaluate(async({mode,options})=>{
    const {confirmMacroStopped}=await import('./assets/macro-stop.js'),{PageReleaseGate}=await import('./assets/hid.js');
    const {demoSnapshot}=await import('./assets/layout.js'),{encodeBank,macroBinding}=await import('./assets/model.js'),{MacroWriteAuthorization}=await import('./assets/safety.js');
    const {saveLog,listLogs}=await import('./assets/logs.js');
    const macro={name:'stop UI',steps:[{usage:4,pressed:true,delayMilliseconds:0},{usage:4,pressed:false,delayMilliseconds:30}]};
    if(options.leftMacro)macro.steps=[{kind:'mouse',usage:1,pressed:true,delayMilliseconds:0},{kind:'mouse',usage:1,pressed:false,delayMilliseconds:30}];
    const before=demoSnapshot(),looping=structuredClone(before);looping.macroData=encodeBank([macro]);looping.keymap.splice(306,3,...macroBinding(0,{mode,count:1}));
    const plan=new MacroWriteAuthorization(looping,before,{allowUnbounded:true});
    const request={phase:'beforeWrite',configurations:[plan.before],requirements:[plan.beforeCompletion]};
    window.stopHID={dead:false,operationId:crypto.randomUUID()};window.stopRows=[];window.stopOutcome=null;window.stopLogs=listLogs;
    window.stopGate=new PageReleaseGate();window.stopAbort=new AbortController();
    window.stopPromise=confirmMacroStopped(request,{hid:window.stopHID,gate:window.stopGate,signal:window.stopAbort.signal,log:async row=>{
      if(options.failLog)throw new Error('simulated disk failure');window.stopRows.push(structuredClone(row));await saveLog(row);
    }}).then(receipt=>window.stopOutcome={ok:true,receipt},error=>window.stopOutcome={ok:false,error:error.message});
  },{mode,options});
  return page;
}
try{
  for(const mode of ['held','toggle']){
    const page=await start(mode);await page.locator('.macro-stop-area').waitFor();
    assert.match(await page.locator('.macro-stop-bindings').textContent(),mode==='held'?/松开触发键/:/用原触发键停止/);
    await page.keyboard.down('a');assert.equal(await page.locator('.macro-stop-accept').isDisabled(),true);
    await page.keyboard.up('a');await page.mouse.move(450,400);await page.mouse.down({button:'right'});assert.equal(await page.locator('.macro-stop-accept').isDisabled(),true);await page.mouse.up({button:'right'});
    await page.waitForFunction(()=>!document.querySelector('.macro-stop-accept').disabled);
    // Programmatic clicking is not a physical acknowledgement.
    await page.evaluate(()=>document.querySelector('.macro-stop-accept').click());assert.equal(await page.evaluate(()=>window.stopOutcome),null);
    await page.screenshot({path:join(artifacts,`stop-${mode}.png`)});
    await page.locator('.macro-stop-accept').click();await page.waitForFunction(()=>window.stopOutcome!=null);
    const result=await page.evaluate(()=>window.stopOutcome);assert.equal(result.ok,true);assert.equal(result.receipt.source,'focusedBrowser');assert.equal(result.receipt.result,'complete');assert.ok(result.receipt.postAcknowledgementQuietMilliseconds>=250);
    const assessment=await page.evaluate(async()=>{const {replayMacroStopRecord}=await import('./assets/macro-stop.js');const records=await window.stopLogs();return replayMacroStopRecord(records.find(row=>row.operationId===window.stopHID.operationId));});assert.equal(assessment.status,'acknowledged');
    const rows=await page.evaluate(async()=>{const records=await window.stopLogs();return records.filter(row=>row.operationId===window.stopHID.operationId);});
    assert.equal(rows.length,1);assert.equal(rows[0].result,'complete');assert.equal(rows[0].events.length,4);assert.equal(rows[0].failure,null);assert.match(rows[0].scope,/no device identity/);
    await page.close();
  }
  // Mouse-only macros must not hide their clicks behind a disabled button.
  const selfClick=await start('toggle',{leftMacro:true}),selfBox=await selfClick.locator('.macro-stop-accept').boundingBox();
  for(let i=0;i<8;i++){await selfClick.mouse.click(selfBox.x+selfBox.width/2,selfBox.y+selfBox.height/2);await selfClick.waitForTimeout(70);}
  assert.equal(await selfClick.evaluate(()=>window.stopOutcome),null);assert.equal(await selfClick.locator('.macro-stop-accept').isDisabled(),true);
  assert.ok(await selfClick.evaluate(()=>window.stopRows.at(-1).events.length>=16));
  await selfClick.waitForFunction(()=>!document.querySelector('.macro-stop-accept').disabled);await selfClick.locator('.macro-stop-accept').click();
  await selfClick.mouse.click(selfBox.x+selfBox.width/2,selfBox.y+selfBox.height/2);await selfClick.waitForFunction(()=>window.stopOutcome!=null);
  assert.equal((await selfClick.evaluate(()=>window.stopOutcome)).ok,false);assert.equal(await selfClick.evaluate(()=>window.stopGate.armed),false);await selfClick.close();
  // New input after the explicit confirmation must revoke it before resolution.
  const late=await start();await late.waitForFunction(()=>!document.querySelector('.macro-stop-accept').disabled);await late.locator('.macro-stop-accept').click();await late.keyboard.press('b');await late.waitForFunction(()=>window.stopOutcome!=null);
  const lateResult=await late.evaluate(()=>window.stopOutcome);assert.equal(lateResult.ok,false);assert.match(lateResult.error,/确认后|确认期间/);await late.close();
  for(const fault of ['cancel','blur','hidden','disconnect','failLog','abort']){
    const page=await start('toggle',{failLog:fault==='failLog'});
    if(fault!=='failLog')await page.locator('.macro-stop-area').waitFor();
    if(fault==='cancel')await page.locator('.macro-stop-cancel').click();
    if(fault==='blur')await page.evaluate(()=>window.dispatchEvent(new Event('blur')));
    if(fault==='hidden')await page.evaluate(()=>{Object.defineProperty(document,'visibilityState',{value:'hidden'});document.dispatchEvent(new Event('visibilitychange'));});
    if(fault==='abort')await page.evaluate(()=>window.stopAbort.abort());
    if(fault==='disconnect')await page.evaluate(()=>window.stopHID.dead=true);
    await page.waitForFunction(()=>window.stopOutcome!=null);assert.equal((await page.evaluate(()=>window.stopOutcome)).ok,false);assert.equal(await page.locator('.macro-stop-dialog').count(),0);await page.close();
  }
  const mobile=await start();await mobile.setViewportSize({width:390,height:844});assert.ok(await mobile.evaluate(()=>document.documentElement.scrollWidth<=innerWidth));await mobile.screenshot({path:join(artifacts,'stop-mobile.png')});await mobile.emulateMedia({colorScheme:'dark'});await mobile.screenshot({path:join(artifacts,'stop-dark.png')});await mobile.locator('.macro-stop-cancel').click();await mobile.close();
  assert.deepEqual(errors,[]);
  console.log(JSON.stringify({passed:true,scope:'headless browser trusted automation, real local IndexedDB; no keyboard connection or HID writes',cases:['held','toggle','held-key/mouse','untrusted-click','late-output','cancel','blur','hidden','disconnect','logging-failure','abort','mouse-self-click','mobile','dark'],artifacts}));
}finally{await browser.close();}
