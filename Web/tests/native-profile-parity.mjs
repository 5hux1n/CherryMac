// Compare independent Swift and JavaScript conversion against synthetic official JSON.
// Only the native file-conversion CLI runs; no HID, system services or network access.
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {mkdtemp,readFile,writeFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {WINDOWS_DEFAULTS} from '../assets/tables.js';
import {demoSnapshot} from '../assets/layout.js';
import {importWindows} from '../assets/model.js';
const binary=resolve(process.argv[2]??fileURLToPath(new URL('../../build/CherryMac',import.meta.url)));
const folder=await mkdtemp(join(tmpdir(),'CherryMacParity-'));
try{
  const baseline=demoSnapshot(),input=join(folder,'windows.json'),base=join(folder,'baseline.json'),output=join(folder,'native.json');
  await writeFile(base,JSON.stringify(baseline));
  for(const [mode,count] of [[0,1],[0,3],[0,255],[1,0],[2,0]]){
    for(const preference of [{}, {ActionMacroFixTimeIsSelected:0,ActionMacroFixTimeValue:60000},{ActionMacroFixTimeIsSelected:1,ActionMacroFixTimeValue:777}]){
    const root={'//':'47',KeyList:WINDOWS_DEFAULTS.map(v=>({DefaultAssignment:v,Assignment:v,ActionLink:0})),ActionInfo:[{ActionType:2,ActionName:'Ctrl A',ActionContent:{...preference,ActionMacroType:mode,ActionMacroLoopValue:count,ActionMacroEvents:[{Type:9,Button:1,Action:'down',Delay:0},{Type:10,Button:4,Action:'down',Delay:25},{Type:10,Button:4,Action:'up',Delay:50},{Type:9,Button:1,Action:'up',Delay:0}]}}]};
    for(const i of [17,18]){root.KeyList[i].ActionLink=1;root.KeyList[i].ActionLinkIndex=0;}
    await writeFile(input,JSON.stringify(root));
    execFileSync(binary,['--convert-windows-profile',output,'--profile',input,'--baseline',base],{stdio:'pipe'});
    const native=JSON.parse(await readFile(output,'utf8')),web=importWindows(root,baseline);
    for(const field of ['deviceInfo','keymap','parameters','colors','macroData'])assert.deepEqual(native.snapshot[field],web.snapshot[field]);
    assert.deepEqual(native.macros,web.macros);assert.deepEqual(native.macroBindings,web.macroBindings);assert.deepEqual(native.macroModes,web.macroModes);
    }
  }
  console.log('PASS: native/Web parity for 15 playback/fixed-interval cases, two shared bindings, balanced modifier events and all preserved banks (offline only)');
}finally{await rm(folder,{recursive:true,force:true});}
