import {chromium} from 'playwright';
import assert from 'node:assert/strict';
import {mkdtemp,readFile} from 'node:fs/promises';
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
await page.locator('#tab-macros').click();await page.locator('[data-id="calculator"]').click();await page.locator('#macro-name').fill('测试宏');await page.locator('#add-pair').click();await page.locator('#save-macro').click();await page.locator('#assign-macro').click();assert.match(await page.locator('#status').textContent(),/已将/);
// Verify the visible playback controls and exported wire mapping, with no HID.
for(const [mode,count,record] of [['count',3,[0x71,0,3]],['held',1,[0x70,0,1]],['toggle',1,[0x70,0,2]]]){
  await page.locator('#macro-playback').selectOption(mode);
  assert.equal(await page.locator('#macro-repeat').isDisabled(),mode!=='count');
  if(mode==='count')await page.locator('#macro-repeat').fill(String(count));
  await page.locator('#assign-macro').click();assert.match(await page.locator('#status').textContent(),/已将/);
  await page.locator('[data-id="key4"]').click();await page.locator('[data-id="calculator"]').click();
  assert.equal(await page.locator('#macro-playback').inputValue(),mode);assert.equal(await page.locator('#macro-repeat').inputValue(),String(count));
  assert.equal(await page.locator('#macro-list').inputValue(),'测试宏');
  await page.locator('#tab-profiles').click();const waiting=page.waitForEvent('download');await page.locator('#export').click();
  const exported=await waiting,filename=join(artifacts,`playback-${mode}.json`);await exported.saveAs(filename);
  const profile=JSON.parse(await readFile(filename,'utf8'));assert.deepEqual(profile.snapshot.keymap.slice(306,309),record);assert.deepEqual(profile.macroModes['102'],{mode,count});
  await page.locator('#tab-macros').click();
}
await page.screenshot({path:join(artifacts,'macro-playback.png'),fullPage:true});
// Import a fixed-interval preference, edit/rename through the real form, and export.
// This part runs before installing Fake: it has no keyboard connection.
const fixedProfile=JSON.parse(await readFile(join(artifacts,'playback-toggle.json'),'utf8'));
fixedProfile.macros[0].recordingDelay={fixed:true,milliseconds:777};
await page.locator('#tab-profiles').click();
await page.locator('#file').setInputFiles({name:'fixed-profile.json',mimeType:'application/json',buffer:Buffer.from(JSON.stringify(fixedProfile))});
await page.waitForFunction(()=>document.querySelector('#status').textContent.includes('导入'));
await page.locator('#tab-macros').click();await page.locator('#macro-list').selectOption('测试宏');
await page.locator('#macro-name').fill('固定选项保留');await page.locator('#save-macro').click();
await page.locator('#tab-profiles').click();const fixedDownload=page.waitForEvent('download');await page.locator('#export').click();
await (await fixedDownload).saveAs(join(artifacts,'fixed-edited.json'));
const edited=JSON.parse(await readFile(join(artifacts,'fixed-edited.json'),'utf8'));
assert.deepEqual(edited.macros[0].recordingDelay,fixedProfile.macros[0].recordingDelay);
assert.deepEqual(edited.macros[0].steps,fixedProfile.macros[0].steps);
assert.deepEqual(edited.snapshot.macroData,fixedProfile.snapshot.macroData);
assert.equal(edited.macroBindings['102'],'固定选项保留');
// Create and edit a mouse event through the visible macro form, without HID.
await page.locator('#tab-macros').click();await page.locator('#macro-list').selectOption('');
await page.locator('#macro-name').fill('鼠标中键测试');await page.locator('#macro-key').selectOption('mouse:4');await page.locator('#add-pair').click();await page.locator('#save-macro').click();
await page.locator('#tab-profiles').click();const mouseDownload=page.waitForEvent('download');await page.locator('#export').click();
await (await mouseDownload).saveAs(join(artifacts,'mouse-edited.json'));
const mouseProfile=JSON.parse(await readFile(join(artifacts,'mouse-edited.json'),'utf8'));
assert.deepEqual(mouseProfile.macros.find(m=>m.name==='鼠标中键测试').steps,[{kind:'mouse',usage:4,pressed:true,delayMilliseconds:0},{kind:'mouse',usage:4,pressed:false,delayMilliseconds:30}]);
// Focused recorder: trusted browser automation events, no real keyboard/HID.
await page.locator('#tab-macros').click();await page.locator('#macro-list').selectOption('');await page.locator('#macro-name').fill('录制测试');
await page.locator('#macro-recording summary').click();await page.locator('#record-timing').selectOption('fixed');await page.locator('#record-delay').fill('777');
await page.keyboard.down('Shift');await page.locator('#record-start').click();assert.match(await page.locator('#record-status').textContent(),/松开修饰键/);assert.equal(await page.locator('#record-stop').isDisabled(),true);await page.keyboard.up('Shift');
await page.locator('#record-start').click();await page.keyboard.down('a');await page.locator('#record-stop').click();
assert.match(await page.locator('#record-status').textContent(),/松开/);await page.keyboard.up('a');await page.locator('#record-stop').click();await page.locator('#save-macro').click();
await page.locator('#tab-profiles').click();const recordedDownload=page.waitForEvent('download');await page.locator('#export').click();await (await recordedDownload).saveAs(join(artifacts,'recorded.json'));
const recorded=JSON.parse(await readFile(join(artifacts,'recorded.json'),'utf8')).macros.find(m=>m.name==='录制测试');
assert.deepEqual(recorded.steps,[{usage:4,pressed:true,delayMilliseconds:777},{usage:4,pressed:false,delayMilliseconds:777}]);assert.deepEqual(recorded.recordingDelay,{fixed:true,milliseconds:777});
await page.locator('#tab-macros').click();await page.locator('#record-start').click();await page.keyboard.down('b');await page.locator('#tab-profiles').click();await page.keyboard.up('b');await page.locator('#tab-macros').click();
assert.equal(await page.locator('#record-stop').isDisabled(),true);assert.equal(await page.locator('.macro-step').count(),2);assert.match(await page.locator('#record-status').textContent(),/取消/);
await page.locator('#macro-name').fill('录制鼠标');await page.locator('#record-mouse').check();await page.locator('#record-start').click();await page.locator('#record-area').click();await page.locator('#record-stop').click();await page.locator('#save-macro').click();
await page.locator('#tab-profiles').click();const mouseRecordDownload=page.waitForEvent('download');await page.locator('#export').click();await (await mouseRecordDownload).saveAs(join(artifacts,'recorded-mouse.json'));
const recordedMouse=JSON.parse(await readFile(join(artifacts,'recorded-mouse.json'),'utf8')).macros.find(m=>m.name==='录制鼠标');
assert.deepEqual(recordedMouse.steps,[{usage:1,pressed:true,delayMilliseconds:777,kind:'mouse'},{usage:1,pressed:false,delayMilliseconds:777,kind:'mouse'}]);
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
await page.locator('#tab-device').click();const downloadPromise=page.waitForEvent('download');await page.locator('#diagnostics').click();const diagnostic=await downloadPromise;await diagnostic.saveAs(join(artifacts,'diagnostics.json'));const logs=await page.evaluate(async()=>{const m=await import('/assets/logs.js?v=0.5.0');return await m.listLogs();});assert.ok(logs.length>0);assert.ok(logs.filter(e=>e.kind!=='phase').every(e=>e.status==='ok'&&e.reply.length===64&&e.request.length===64&&e.durationMs>=0));assert.equal(await page.evaluate(()=>fakeDevice.writes),7);assert.deepEqual(errors,[]);
await page.locator('#tab-macros').click();await page.locator('#macro-list').selectOption('');await page.locator('#macro-name').fill('复制检查');await page.locator('#add-pair').click();await page.locator('#save-macro').click();await page.locator('#copy-macro').click();assert.match(await page.locator('#macro-name').inputValue(),/副本/);await page.locator('#clear-macros').click();assert.equal(await page.locator('#macro-list option').count(),1);assert.equal(await page.evaluate(()=>fakeDevice.writes),7);assert.deepEqual(errors,[]);
console.log(JSON.stringify({artifacts,ui:'pass',keys:109,squareKeys:true,mobileOverflow:false,macroPlayback:'count/held/toggle exports verified; no macro HID writes',simulatedKeyWrite:'pass; seven key packets only',backups,errors}));
}finally{await browser.close();}
