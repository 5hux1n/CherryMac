// Focused IDB/page check. No device enumeration, selection or input observation.
import {chromium} from 'playwright';
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createServer} from 'node:net';
import {fileURLToPath} from 'node:url';
import {readFile} from 'node:fs/promises';
const web=fileURLToPath(new URL('../',import.meta.url));
const socket=createServer();await new Promise(resolve=>socket.listen(0,'127.0.0.1',resolve));const port=socket.address().port;await new Promise(resolve=>socket.close(resolve));
const server=spawn('php',['-S',`127.0.0.1:${port}`,'-t',web],{env:{...process.env,CHERRY_TEXT_PRODUCT:'1'},stdio:'ignore'});
let browser;
try{
  const url=`http://127.0.0.1:${port}/`;
  for(let attempt=0;;attempt++){try{await fetch(url);break;}catch(error){if(attempt>50)throw error;await new Promise(resolve=>setTimeout(resolve,50));}}
  browser=await chromium.launch({headless:true,executablePath:process.env.CHERRY_CHROME??'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'});
  const page=await browser.newPage(),errors=[];page.on('pageerror',e=>errors.push(e.message));
  await page.addInitScript(()=>{
    window.hidRequests=0;
    Object.defineProperty(navigator,'hid',{value:{requestDevice(){window.hidRequests++;throw new Error('USB disabled');},getDevices(){window.hidRequests++;throw new Error('USB disabled');},addEventListener(){},removeEventListener(){}}});
  });
  await page.goto(url);await page.locator('#tab-text').click();
  assert.equal(await page.locator('#board-card').isVisible(),false);assert.equal(await page.locator('#review-card').isVisible(),false);
  assert.equal(await page.locator('#text-install').isDisabled(),true);
  const fixture=await page.evaluate(async()=>{
    const {HostTextStore,mergeHostTextDraft}=await import('/assets/product-text.js'),{prepareHostTextInstallation,fromHardware}=await import('/assets/model.js'),{demoSnapshot}=await import('/assets/layout.js'),{WINDOWS_DEFAULTS}=await import('/assets/tables.js');
    const root={'//':'47',KeyList:WINDOWS_DEFAULTS.map(DefaultAssignment=>({DefaultAssignment,ActionLink:0,ActionLinkIndex:-1})),ActionInfo:[{ActionType:3,ActionTextFlag:1,ActionContent:{ActionText:'中😀'}}]};root.KeyList[17].ActionLink=1;root.KeyList[17].ActionLinkIndex=0;
    const before=demoSnapshot(),factory=Array(378).fill(0);factory.splice(306,3,48,146,1);
    const plan=prepareHostTextInstallation(root,factory,before),store=new HostTextStore();
    const require=(ok,message)=>{if(!ok)throw new Error(message);};
    require(await store.active()===null,'initial state');const failed=await store.prepare(plan);require(await store.active()===null,'prepare changed active');await store.failed(failed);
    let refused=false;try{await store.commit(failed);}catch{refused=true;}require(refused,'failed stage committed');
    const first=await store.prepare(plan),second=await store.prepare(plan);
    await store.commit(first);refused=false;try{await new HostTextStore().commit(second);}catch{refused=true;}require(refused,'stale tab replaced host definition');
    refused=false;try{await store.validateRestoration(second);}catch{refused=true;}require(refused,'an uncommitted identical definition claimed another installation');
    require(JSON.stringify(await store.active())===JSON.stringify(root),'committed definition missing');
    const replacement=structuredClone(root);replacement.ActionInfo[0].ActionContent.ActionText='替换文本';
    const newer=await store.prepare(prepareHostTextInstallation(replacement,factory,plan.expected));await store.commit(newer);
    refused=false;try{await store.validateRestoration(first);}catch{refused=true;}require(refused,'old recovery overwrote newer definition');
    await store.restored(newer);require(JSON.stringify(await store.active())===JSON.stringify(root),'definition rollback failed');
    const pending=fromHardware(before);pending.snapshot.colors[0]=42;pending.snapshot.keymap.splice(27,3,32,0,5);
    const merged=mergeHostTextDraft(pending,plan.expected,plan);require(merged.snapshot.colors[0]===42&&merged.snapshot.keymap[29]===5&&merged.snapshot.keymap[306]===161,'draft merge');
    return root;
  });
  await page.locator('#text-load').click();await page.waitForFunction(()=>document.querySelector('#text-summary').textContent.includes('已保存文本配置'));
  assert.equal(await page.locator('#text-install').isDisabled(),true);
  await page.locator('#text-file').setInputFiles({name:'official-text.json',mimeType:'application/json',buffer:Buffer.from(JSON.stringify(fixture))});
  await page.waitForFunction(()=>document.querySelector('#text-summary').textContent.includes('official-text.json'));
  if(process.env.CHERRY_TEXT_PAGE_PREVIEW)await page.screenshot({path:process.env.CHERRY_TEXT_PAGE_PREVIEW,fullPage:true});
  await page.locator('#text-file').setInputFiles({name:'bad.json',mimeType:'application/json',buffer:Buffer.from('{}')});
  await page.waitForFunction(()=>document.querySelector('#status').classList.contains('error'));
  assert.match(await page.locator('#text-summary').textContent(),/official-text.json/);
  assert.equal(await page.evaluate(()=>window.hidRequests),0);assert.deepEqual(errors,[]);
  const editing=await browser.newPage();
  await editing.addInitScript(()=>{
    window.fakeWrites=0;
    class Device extends EventTarget{
      constructor(){super();this.vendorId=1130;this.productId=462;this.collections=[{usagePage:0xff1c,usage:0x92,inputReports:[{reportId:4,items:[{reportSize:8,reportCount:63}]}],outputReports:[{reportId:4,items:[{reportSize:8,reportCount:63}]}]}];}
      async open(){this.opened=true;}async close(){this.opened=false;}
      async sendReport(id,data){
        const request=new Uint8Array([id,...data]),command=request[3];
        if(![3,5,7,8,10,20].includes(command)){window.fakeWrites++;throw new Error('write disabled for editor check');}
        const n=({3:34,5:56,7:378,8:378,10:378,20:3071})[command],value=Array(n).fill(0);
        if(command===3)value[6]=24;if(command===7||command===8)value.splice(306,3,48,146,1);
        const offset=request[5]|request[6]<<8,reply=request.slice();reply.set(value.slice(offset,offset+request[4]),8);
        const event=new Event('inputreport');Object.assign(event,{device:this,reportId:4,data:new DataView(reply.slice(1).buffer)});queueMicrotask(()=>this.dispatchEvent(event));
      }
    }
    Object.defineProperty(navigator,'hid',{value:{requestDevice:async()=>[new Device()],getDevices:async()=>[],addEventListener(){},removeEventListener(){}}});
  });
  await editing.goto(url);await editing.locator('#connect').click();await editing.waitForFunction(()=>document.querySelector('#connection').textContent.includes('USB 已连接'));
  await editing.locator('#tab-text').click();await editing.locator('#text-file').setInputFiles({name:'official-text.json',mimeType:'application/json',buffer:Buffer.from(JSON.stringify(fixture))});
  await editing.waitForFunction(()=>!document.querySelector('#text-edit-open').disabled);await editing.locator('#text-edit-open').click();await editing.waitForFunction(()=>!document.querySelector('#text-editor').hidden&&!document.querySelector('#text-edit-save').disabled);
  await editing.locator('#text-edit-name').fill('编辑文本');await editing.locator('#text-edit-value').fill('甲\n乙');await editing.locator('#text-edit-save').click();
  const downloading=editing.waitForEvent('download');await editing.locator('#text-export').click();const exported=JSON.parse(await readFile(await (await downloading).path(),'utf8'));
  assert.equal(exported.ActionInfo[exported.KeyList[17].ActionLinkIndex].ActionContent.ActionText,'甲\r\n乙');
  await editing.locator('#text-edit-open').click();await editing.waitForFunction(()=>!document.querySelector('#text-editor').hidden&&!document.querySelector('#text-edit-remove').disabled);await editing.locator('#text-edit-remove').click();
  const removing=editing.waitForEvent('download');await editing.locator('#text-export').click();const cleared=JSON.parse(await readFile(await (await removing).path(),'utf8'));
  assert.equal(cleared.KeyList[17].ActionLink,0);assert.equal(cleared.KeyList[17].Assignment,cleared.KeyList[17].DefaultAssignment);
  assert.equal(await editing.evaluate(()=>window.fakeWrites),0);
  console.log('PASS: text page, real IndexedDB staging/commit/rollback, stale-tab rejection and draft preservation; zero real HID requests; editor uses read-only fake transport');
}finally{if(browser)await browser.close();server.kill('SIGTERM');}
