import {chromium} from 'playwright';
import assert from 'node:assert/strict';
const browser=await chromium.launch({executablePath:'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',headless:true});
try{
  for(const mode of ['held','toggle']){
    const page=await browser.newPage();page.setDefaultTimeout(120000);const errors=[];page.on('pageerror',e=>errors.push(e.message));
    await page.goto('http://127.0.0.1:8768/');
    await page.evaluate(async mode=>{
      const {MacroTestFlow}=await import('./assets/macro-test-flow.js'),{demoSnapshot}=await import('./assets/layout.js');
      class MemoryDevice extends EventTarget{
        constructor(){super();this.s=demoSnapshot();this.vendorId=1130;this.productId=462;this.opened=false;this.collections=[{usagePage:0xff1c,usage:0x92,inputReports:[{reportId:4,items:[{reportSize:8,reportCount:63}]}],outputReports:[{reportId:4,items:[{reportSize:8,reportCount:63}]}]}];}
        async open(){this.opened=true;}async close(){this.opened=false;}
        async sendReport(id,data){const p=new Uint8Array([id,...data]);if(id!==4||p.length!==64)throw new Error('framing');const r=p.slice(),o=p[5]|p[6]<<8,n=p[4],field=({3:'deviceInfo',5:'parameters',8:'keymap',10:'colors',20:'macroData'})[p[3]];
          if(field)r.set(this.s[field].slice(o,o+n),8);else{const f=({9:'keymap',21:'macroData'})[p[3]];if(!f)throw new Error('unexpected write');this.s[f].splice(o,n,...p.slice(8,8+n));}
          const e=new Event('inputreport');Object.assign(e,{reportId:4,data:new DataView(r.slice(1).buffer),device:this});queueMicrotask(()=>this.dispatchEvent(e));}
      }
      document.querySelector('.app-shell').remove();const root=document.createElement('main');document.body.append(root);window.fakeDevice=new MemoryDevice();window.flow=new MacroTestFlow(root,{scenarioId:mode,selectDevice:async()=>[fakeDevice],hidEvents:new EventTarget()});
    },mode);
    assert.equal(await page.locator('#macro-test-power').isChecked(),false);
    await page.locator('#macro-test-next').click();await page.waitForFunction(()=>flow.phase==='ready'||flow.phase==='failed');assert.equal(await page.evaluate(()=>flow.phase),'ready');
    assert.equal(await page.locator('#macro-test-scenario').isDisabled(),true);
    await page.locator('#macro-test-next').click();await page.waitForFunction(()=>flow.phase==='observeReady'||flow.phase==='failed');assert.equal(await page.evaluate(()=>flow.phase),'observeReady');
    assert.deepEqual(await page.evaluate(()=>fakeDevice.s.keymap.slice(306,309)),[0x70,0,mode==='held'?1:2]);
    await page.locator('#macro-test-next').click();await page.waitForFunction(()=>flow.phase==='observing');assert.equal(await page.locator('#macro-test-stop').isDisabled(),true);
    for(let i=0;i<2;i++){await page.keyboard.press('a');await page.keyboard.press('b');}
    await page.waitForFunction(()=>!document.querySelector('#macro-test-stop').disabled);
    await page.locator('#macro-test-stop').click();await page.waitForFunction(()=>flow.phase==='restoreReady'||flow.phase==='failed');assert.equal(await page.evaluate(()=>flow.phase),'restoreReady');
    assert.equal(await page.evaluate(()=>flow.stopMarker.source),'userAcknowledged');
    await page.locator('#macro-test-next').click();
    await page.locator('.macro-stop-accept').waitFor();await page.waitForFunction(()=>!document.querySelector('.macro-stop-accept').disabled);await page.locator('.macro-stop-accept').click();
    await page.waitForFunction(()=>flow.phase==='complete'||flow.phase==='failed');assert.equal(await page.evaluate(()=>flow.phase),'complete');
    assert.deepEqual(await page.evaluate(()=>({first:flow.firstPassed,power:!!flow.powerVerified,restored:flow.restored,errors:flow.errors})),{first:true,power:false,restored:true,errors:[]});
    assert.match(await page.locator('#macro-test-status').textContent(),/未测试断电保留/);
    const record=await page.evaluate(async()=>{await flow.flush();const {listLogs}=await import('./assets/logs.js');return (await listLogs()).find(r=>r.id===flow.id);});
    assert.equal(record.passed,true);assert.equal(record.powerTestRequested,false);assert.equal(record.powerRetentionVerified,false);
    assert.deepEqual(errors,[]);await page.evaluate(()=>flow.dispose());await page.close();
  }
  console.log('PASS: held/toggle browser stop confirmation, target bindings, scoped no-power result and recovery dialog; memory device and browser automation only, no physical HID.');
}finally{await browser.close();}
