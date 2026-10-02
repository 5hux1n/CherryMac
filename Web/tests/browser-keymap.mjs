import {chromium} from 'playwright';
import assert from 'node:assert/strict';
import {mkdtemp} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
const artifacts=process.env.CHERRY_TEST_ARTIFACTS??await mkdtemp(join(tmpdir(),'CherryMacWebUI-'));
const url=process.env.CHERRY_TEST_URL??'http://127.0.0.1:8768/';
const browser=await chromium.launch({executablePath:process.env.CHERRY_CHROME??(process.platform==='darwin'?'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome':undefined),headless:true});
const page=await browser.newPage({viewport:{width:1440,height:1120},deviceScaleFactor:1});
const errors=[];page.on('pageerror',e=>errors.push(e.message));
try{
await page.goto(url);
await page.locator('.key').last().waitFor();
assert.equal(await page.locator('.key').count(),109);
assert.equal(await page.locator('#write').isDisabled(),true);
const keyBox=await page.locator('[data-id="key4"]').boundingBox();assert.ok(Math.abs(keyBox.width-keyBox.height)<.2);
await page.locator('#tab-lights').click();await page.locator('#tab-light-perkey').click();await page.locator('[data-region="all"]').click();await page.locator('#pattern').selectOption('rainbow');await page.locator('#paint').click();
assert.match(await page.locator('#light-count').textContent(),/109/);
await page.screenshot({path:join(artifacts,'editor.png'),fullPage:true});
await page.setViewportSize({width:390,height:844});
assert.ok(await page.evaluate(()=>document.documentElement.scrollWidth<=window.innerWidth));
await page.screenshot({path:join(artifacts,'mobile.png'),fullPage:false});
await page.setViewportSize({width:1440,height:1120});
await page.emulateMedia({colorScheme:'dark'});await page.screenshot({path:join(artifacts,'dark.png'),fullPage:true});await page.emulateMedia({colorScheme:'light'});
await page.locator('#tab-macros').click();await page.locator('#macro-name').fill('测试宏');await page.locator('#add-pair').click();await page.locator('#save-macro').click();await page.locator('#assign-macro').click();assert.match(await page.locator('#status').textContent(),/已将/);
// Install a simulated WebHID device. This never requests actual hardware access.
await page.evaluate(()=>{
  class Fake extends EventTarget{
    constructor(s){super();this.s=s;this.vendorId=1130;this.productId=462;this.opened=false;this.writes=0;this.commands=[];this.before=structuredClone(s);this.collections=[{usagePage:0xff1c,usage:0x92,inputReports:[{reportId:4,items:[{reportSize:8,reportCount:63}]}],outputReports:[{reportId:4,items:[{reportSize:8,reportCount:63}]}]}];}
    async open(){this.opened=true;}async close(){this.opened=false;}
    async sendReport(id,payload){if(id!==4||payload.length!==63)throw new Error('bad framing');const b=new Uint8Array([4,...payload]),r=b.slice(),o=b[5]|b[6]<<8,n=b[4];let field=({3:'deviceInfo',5:'parameters',8:'keymap',10:'colors',20:'macroData'})[b[3]];
      this.commands.push(b[3]);if(field)r.set(this.s[field].slice(o,o+n),8);else{field=({9:'keymap',11:'colors',21:'macroData',6:'parameters'})[b[3]];if(!field)throw new Error('unexpected command');this.writes++;this.s[field].splice(o,n,...b.slice(8,8+n));}
      const e=new Event('inputreport');Object.assign(e,{reportId:4,data:new DataView(r.buffer,1,63),device:this});queueMicrotask(()=>this.dispatchEvent(e));
    }
  }
  Object.defineProperty(navigator.hid,'requestDevice',{value:async()=>{const {demoSnapshot}=await import('/assets/layout.js');window.fakeDevice=new Fake(demoSnapshot());return [window.fakeDevice];},configurable:true});
});
await page.locator('#connect').click();await page.locator('#connection.connected').waitFor();assert.equal(await page.evaluate(()=>fakeDevice.writes),0);
await page.locator('#tab-keys').click();await page.locator('[data-id="calculator"]').click();await page.locator('[data-record="32,10,33"]').click();
assert.equal(await page.locator('#write').isDisabled(),false);
// Stage a lighting change while connected, then write only the calculator key.
await page.locator('#tab-lights').click();await page.locator('#tab-light-builtins').click();await page.locator('#brightness').fill('2');await page.locator('#stage-lights').click();
await page.locator('#tab-keys').click();await page.screenshot({path:join(artifacts,'ready.png'),fullPage:true});await page.locator('#write').click();await page.locator('#confirm-write').click();
await page.waitForFunction(()=>document.querySelector('#status').textContent.includes('按键写入完成'),{},{timeout:30000});
assert.equal(await page.evaluate(()=>fakeDevice.writes),7);assert.deepEqual(await page.evaluate(()=>fakeDevice.s.keymap.slice(306,309)),[32,10,33]);
for(const k of ['parameters','colors','macroData'])assert.deepEqual(await page.evaluate(k=>fakeDevice.s[k],k),await page.evaluate(k=>fakeDevice.before[k],k));
assert.deepEqual(await page.evaluate(()=>fakeDevice.commands.filter(c=>![3,5,8,10,20].includes(c))),Array(7).fill(9));
assert.match(await page.locator('#changes').textContent(),/灯效参数已修改/);
await page.locator('#tab-lights').click();assert.equal(await page.locator('#write').isDisabled(),true);
await page.locator('#tab-keys').click();await page.screenshot({path:join(artifacts,'written.png'),fullPage:true});

const backups=await page.evaluate(async()=>{const m=await import('/assets/storage.js');return (await m.listBackups()).length;});assert.ok(backups>=1);
// Invalid import leaves draft unchanged and does not issue a hardware write.
await page.locator('#tab-profiles').click();await page.locator('#file').setInputFiles({name:'bad.json',mimeType:'application/json',buffer:Buffer.from('{"format":"other"}')});await page.waitForFunction(()=>document.querySelector('#status').classList.contains('error'));assert.equal(await page.evaluate(()=>fakeDevice.writes),7);
await page.locator('#show-backups').click();await page.locator('.backup-row').first().waitFor();assert.ok(await page.locator('.backup-row').count()>=1);
await page.locator('#tab-device').click();const downloadPromise=page.waitForEvent('download');await page.locator('#diagnostics').click();const diagnostic=await downloadPromise;await diagnostic.saveAs(join(artifacts,'diagnostics.json'));const logs=await page.evaluate(async()=>{const m=await import('/assets/logs.js?v=0.3.0');return await m.listLogs();});assert.ok(logs.length>0);assert.ok(logs.filter(e=>e.kind!=='phase').every(e=>e.status==='ok'&&e.reply.length===64&&e.request.length===64&&e.durationMs>=0));assert.equal(await page.evaluate(()=>fakeDevice.writes),7);assert.deepEqual(errors,[]);
console.log(JSON.stringify({artifacts,ui:'pass',keys:109,squareKeys:true,mobileOverflow:false,simulatedKeyWrite:'pass; seven key packets only',backups,errors}));
}finally{await browser.close();}
