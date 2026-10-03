// Focused form regression: USB selection is replaced by a rejecting stub.
import {chromium} from 'playwright';
import assert from 'node:assert/strict';
import {readFile,mkdtemp} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';

const browser=await chromium.launch({headless:true,executablePath:process.env.CHERRY_CHROME??(process.platform==='darwin'?'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome':undefined)});
try{
  const page=await browser.newPage();const errors=[];page.on('pageerror',error=>errors.push(error.message));
  await page.addInitScript(()=>{
    window.hidRequests=0;
    Object.defineProperty(navigator,'hid',{value:{requestDevice(){window.hidRequests++;throw new Error('USB disabled for form check');},getDevices:async()=>[],addEventListener(){},removeEventListener(){}}});
  });
  await page.goto(process.env.CHERRY_TEST_URL??'http://127.0.0.1:8768/');await page.locator('#tab-macros').click();
  await page.locator('#macro-name').fill('默认五次');await page.locator('#add-pair').click();
  await page.locator('#macro-playback').selectOption('count');await page.locator('#macro-repeat').fill('5');await page.locator('#save-macro').click();
  assert.equal(await page.locator('#macro-repeat').inputValue(),'5');
  assert.match(await page.locator('#macro-summary').textContent(),/30\/3071 字节.*150 ms/);
  await page.locator('#assign-macro').click();
  await page.locator('#macro-repeat').fill('7');await page.locator('#save-macro').click();
  assert.equal(await page.locator('#macro-repeat').inputValue(),'7');
  await page.locator('[data-id="key4"]').click();assert.equal(await page.locator('#macro-repeat').inputValue(),'7');
  await page.locator('[data-id="calculator"]').click();assert.equal(await page.locator('#macro-repeat').inputValue(),'5');
  const folder=await mkdtemp(join(tmpdir(),'CherryMacMacroSave-'));
  await page.locator('#tab-profiles').click();const waiting=page.waitForEvent('download');await page.locator('#export').click();
  const download=await waiting;const path=join(folder,'profile.json');await download.saveAs(path);const profile=JSON.parse(await readFile(path,'utf8'));
  assert.deepEqual(profile.macros[0].preferredPlayback,{mode:'count',count:7});
  assert.deepEqual(profile.macroModes['102'],{mode:'count',count:5});
  assert.deepEqual(profile.snapshot.keymap.slice(306,309),[0x71,0,5]);
  assert.deepEqual(profile.macros[0].steps.map(step=>step.delayMilliseconds),[30,0]);
  await page.locator('#tab-macros').click();await page.locator('#macro-repeat').fill('0');await page.locator('#save-macro').click();
  assert.equal(await page.locator('#status').evaluate(node=>node.classList.contains('error')),true);
  assert.equal(await page.locator('#macro-summary').evaluate(node=>node.classList.contains('error')),true);
  await page.locator('#macro-repeat').fill('1');
  await page.locator('#macro-name').fill('👩‍💻'.repeat(25));await page.locator('#save-macro').click();
  assert.equal(await page.locator('#macro-name').inputValue(),'👩‍💻'.repeat(25));
  assert.match(await page.locator('#macro-summary').textContent(),/30\/3071 字节.*30 ms/);
  assert.equal(await page.evaluate(()=>window.hidRequests),0);assert.deepEqual(errors,[]);
  console.log('Macro form defaults preserved; existing trigger unchanged; invalid count rejected; no USB access.');
}finally{await browser.close();}
