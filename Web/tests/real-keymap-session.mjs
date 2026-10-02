// Explicit real-device test driver. No HID mocks, intercepted reports or synthetic key presses.
import {chromium} from 'playwright';
import {mkdir,readFile,writeFile} from 'node:fs/promises';
import {join,dirname,isAbsolute} from 'node:path';
import assert from 'node:assert/strict';
if(process.argv[2]!=='--real-keyboard')throw Error('Explicit --real-keyboard required');
const folder=process.argv[3],baselineFile=process.argv[4];
if(!folder||!baselineFile||!isAbsolute(folder)||!isAbsolute(baselineFile))throw Error('Absolute, new output directory and baseline JSON paths required');
const reference=JSON.parse(await readFile(baselineFile,'utf8')).snapshot;
await mkdir(dirname(folder),{recursive:true});await mkdir(folder); // Never overwrite a previous capture.
const state={format:'CherryMacRealWebKeyTest',startedAt:new Date().toISOString(),phase:'starting',scope:'calculator slot 102 only; no macro or lighting writes',physicalEvents:[]};
const save=()=>writeFile(join(folder,'test-log.json'),JSON.stringify(state,null,2));
const fields=['deviceInfo','keymap','parameters','colors','macroData'];
const same=(a,b)=>fields.every(k=>JSON.stringify(a[k])===JSON.stringify(b[k]));
const context=await chromium.launchPersistentContext(join(folder,'chrome-profile'),{executablePath:'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',headless:false,viewport:{width:1440,height:1050},acceptDownloads:true,args:['--no-first-run','--no-default-browser-check']});
const page=context.pages()[0]??await context.newPage();page.setDefaultTimeout(15000);
let before=null,target=null,wrote=false,restored=false;
async function phase(value,message){state.phase=value;state.updatedAt=new Date().toISOString();await save();if(message)await page.evaluate(text=>{let e=document.getElementById('physical-test-note');if(!e){e=document.createElement('p');e.id='physical-test-note';e.className='notice';e.setAttribute('role','alert');document.querySelector('main').prepend(e);}e.textContent=text;e.scrollIntoView({block:'start'});},message);console.log(value);}
async function download(selector,name){const wait=page.waitForEvent('download');await page.locator(selector).click();const file=await wait;await file.saveAs(join(folder,name));return JSON.parse(await readFile(join(folder,name),'utf8'));}
async function exportProfile(name){await page.locator('#tab-profiles').click();return await download('#export',name);}
async function readCurrent(name){await page.locator('#read').click();await page.waitForFunction(()=>!document.querySelector('#read').disabled && document.querySelector('#connection').classList.contains('connected'),{},{timeout:60000});assert.match(await page.locator('#status').textContent(),/已读取完整配置并保存本地备份/);return (await exportProfile(name)).snapshot;}
async function diagnostics(name){await page.locator('#tab-device').click();return await download('#diagnostics',name);}
async function writeKey(){
 await page.bringToFront();await page.locator('#tab-keys').click();await page.locator('#write').click();
 assert.match(await page.locator('#confirm-summary').textContent(),/将修改 1 个按键/);
 await page.locator('#confirm-write').click();
 await page.waitForFunction(()=>!document.querySelector('#read').disabled,{},{timeout:60000});
 const message=await page.locator('#status').textContent();assert.match(message,/按键写入完成，完整读回一致/);
}
async function restore(){
 await phase('checking-restoration','正在核对当前配置并恢复原计算器键，请松开所有按键。');
 const current=await readCurrent('before-restore.json');
 assert.ok(same(current,before)||same(current,target),'Unexpected configuration change; no blind restore');
 if(!same(current,before)){
  await page.locator('#tab-keys').click();await page.locator('[data-id="calculator"]').click();
  await page.locator('[data-record="48,146,1"]').click();await writeKey();
 }
 const after=(await exportProfile('restored.json')).snapshot;assert.ok(same(after,before));
 restored=true;state.fullConfigurationRestored=true;
 const independent=await readCurrent('independent-final.json');assert.ok(same(independent,before));state.newReadMatchesOriginal=true;
}
try{
 await page.goto('http://127.0.0.1:8768/');await page.locator('.key').last().waitFor();
 await phase('select-device','网页版实机测试：请在设备选择框选中 CHERRY 键盘并连接。此时只读取配置。');
 await page.locator('#connect').click();
 await page.locator('#connection.connected').waitFor({timeout:180000});
 const original=await exportProfile('before.json');before=original.snapshot;
 assert.ok(same(before,reference),'Baseline differs from approved restored configuration');assert.deepEqual(before.keymap.slice(306,309),[48,146,1]);
 target=structuredClone(before);target.keymap.splice(306,3,32,0,5);
 await page.evaluate(()=>{window.cherryPhysicalEvidence={armed:false,events:[],held:false};for(const type of ['keydown','keyup'])window.addEventListener(type,e=>{const s=window.cherryPhysicalEvidence;if(!s.armed||e.code!=='KeyB'||!e.isTrusted)return;s.events.push({type,code:e.code,key:e.key,repeat:e.repeat,ctrl:e.ctrlKey,alt:e.altKey,meta:e.metaKey,shift:e.shiftKey,at:new Date().toISOString()});s.held=type==='keydown';});});
 await phase('writing','正在通过网页版写入计算器键 → B。请松开所有按键，等待下一条提示。');
 await page.locator('#tab-keys').click();await page.locator('[data-id="calculator"]').click();
 await page.locator('#shortcut-key').selectOption('5');for(const m of await page.locator('.modifier').all())await m.uncheck();await page.locator('#stage-shortcut').click();
 const draft=(await exportProfile('draft.json')).snapshot;assert.ok(same(draft,target));
 wrote=true;await writeKey();const mapped=(await exportProfile('mapped.json')).snapshot;assert.ok(same(mapped,target));state.mappedReadbackMatches=true;
 await page.locator('#tab-keys').click();await page.bringToFront();await page.evaluate(()=>{window.cherryPhysicalEvidence.armed=true;document.activeElement?.blur();});
 await phase('waiting-physical','写入与完整读回通过。现在请按一次右上角计算器键并完全松开，随后将自动恢复。');
 await page.waitForFunction(()=>{const s=window.cherryPhysicalEvidence;return !s.held&&s.events.some(e=>e.type==='keydown'&&!e.repeat&&!e.ctrl&&!e.alt&&!e.meta&&!e.shift)&&s.events.some(e=>e.type==='keyup');},{},{timeout:180000});
 state.physicalEvents=await page.evaluate(()=>{window.cherryPhysicalEvidence.armed=false;return window.cherryPhysicalEvidence.events;});state.physicalBPressAndReleaseObserved=true;await save();
 await restore();await diagnostics('diagnostics.json');await page.locator('#disconnect').click();
 await phase('complete','网页版按键测试完成：B 的按下和松开已记录，原配置已恢复，重新读取一致。日志已自动保存。');
 state.finishedAt=new Date().toISOString();await save();
}catch(error){
 state.error=String(error);console.error(error);
 if(wrote&&before&&!restored){try{await restore();}catch(recovery){state.restoreError=String(recovery);}}
 try{state.physicalEvents=await page.evaluate(()=>window.cherryPhysicalEvidence?.events??[]);await diagnostics('failure-diagnostics.json');}catch{}
 await phase('stopped',restored?'测试已停止，原配置已恢复。日志已自动保存。':'测试已停止，请保留此页面以便检查；不要继续修改配置。').catch(()=>save());
}finally{await save();}
// Leave the visible result available. No further device actions after completion.
if(context.pages().length)await new Promise(resolve=>context.on('close',resolve));
