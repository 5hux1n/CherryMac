// Official file edits only; no device, browser or permission access.
import assert from 'node:assert/strict';
import {mkdtemp,writeFile,readFile,rm} from 'node:fs/promises';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import {execFileSync} from 'node:child_process';
import {WINDOWS_DEFAULTS} from '../assets/tables.js';
import {clone,officialPollingDraft} from '../assets/model.js';
const binary=process.argv[2];assert.ok(binary);
const root={'//':'47',KeyList:WINDOWS_DEFAULTS.map(v=>({DefaultAssignment:v,Assignment:v,ActionLink:0})),ActionInfo:[],SystemStages:{Repeat:'31',RepeatDelay:2,Key6Flag:1,ReportSelectItem:65535,RFReportSelectItem:3,WFlag:1,WinFlag:1,unknown:{keep:true}},unknown:{opaque:[1,2,3]}};
const original=clone(root),dir=await mkdtemp(join(tmpdir(),'cherry-polling-draft-')),input=join(dir,'official.json'),output=join(dir,'output.json');
try{
  for(let index=0;index<4;index++){
    const expected=clone(root);expected.SystemStages.ReportSelectItem=index;
    assert.deepEqual(officialPollingDraft(root,index),expected);assert.deepEqual(root,original);
    await writeFile(input,JSON.stringify(root));execFileSync(binary,['--edit-official-polling-draft',input,String(index),output],{stdio:'pipe'});assert.deepEqual(JSON.parse(await readFile(output,'utf8')),expected);
  }
  for(const index of [-1,4,6,65535,1.5]){
    assert.throws(()=>officialPollingDraft(root,index));assert.throws(()=>execFileSync(binary,['--edit-official-polling-draft',input,String(index),output],{stdio:'pipe'}));
  }
  for(const bad of [(()=>{const p=clone(root);delete p.SystemStages;return p;})(),{...clone(root),SystemStages:{...root.SystemStages,WinFlag:-1}},{...clone(root),'//':'46'}]){
    assert.throws(()=>officialPollingDraft(bad,0));await writeFile(input,JSON.stringify(bad));assert.throws(()=>execFileSync(binary,['--edit-official-polling-draft',input,'0',output],{stdio:'pipe'}));
  }
  await writeFile(input,JSON.stringify(root));const before=await readFile(input);assert.throws(()=>execFileSync(binary,['--edit-official-polling-draft',input,'0',input],{stdio:'pipe'}));assert.deepEqual(await readFile(input),before);
  console.log('PASS: native/Web polling draft parity, only ReportSelectItem changes, unknown fields and other setting values preserved, invalid choices and input overwrite rejected; no HID');
}finally{await rm(dir,{recursive:true,force:true});}
