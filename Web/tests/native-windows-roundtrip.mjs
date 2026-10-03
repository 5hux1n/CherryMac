// Runs only offline CLI branches. Fixtures are synthetic; no USB access.
import assert from 'node:assert/strict';
import {mkdtempSync,writeFileSync,readFileSync,existsSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import {spawnSync} from 'node:child_process';
import {demoSnapshot} from '../assets/layout.js';
import {fromHardware,resolveMacros,officialMacroAction,exportWindowsKeysAndMacros,importWindows,clone} from '../assets/model.js';
import {WINDOWS_DEFAULTS} from '../assets/tables.js';
const binary=process.argv[2];
assert.ok(binary,'Usage: node Web/tests/native-windows-roundtrip.mjs /absolute/path/CherryMac');
const directory=mkdtempSync(join(tmpdir(),'cherrymac-offline-'));
const save=(name,value)=>{const path=join(directory,name);writeFileSync(path,JSON.stringify(value));return path;};
const invoke=(args,success=true)=>{const r=spawnSync(resolve(binary),args,{encoding:'utf8',timeout:30000});assert.equal(r.error,undefined);assert.equal(r.status===0,success,r.stderr||r.stdout);};
try{
 const baseline=demoSnapshot(),profile=fromHardware(baseline);
 const macro={name:'Mixed',recordingDelay:{fixed:true,milliseconds:77},preferredPlayback:{mode:'held',count:1},steps:[
  {usage:231,pressed:true,delayMilliseconds:0},{usage:4,kind:'mouse',pressed:true,delayMilliseconds:12},
  {usage:4,kind:'mouse',pressed:false,delayMilliseconds:24},{usage:231,pressed:false,delayMilliseconds:36},
  {usage:4,pressed:true,delayMilliseconds:48},{usage:4,pressed:false,delayMilliseconds:60}]};
 profile.macros=[macro];profile.macroBindings={102:'Mixed',108:'Mixed',114:'Mixed'};
 profile.macroModes={102:{mode:'count',count:2},108:{mode:'held',count:1},114:{mode:'toggle',count:1}};
 profile.snapshot=resolveMacros(profile);profile.snapshot.keymap.splice(0,3,0x20,13,6);
 const action=officialMacroAction(macro);action.opaque={id:42};action.ActionContent.opaque='keep';action.ActionContent.ActionMacroEvents[0].opaque='event';
 const template={'//':'47',KeyList:WINDOWS_DEFAULTS.map(v=>({DefaultAssignment:v,Assignment:v,ActionLink:0})),ActionInfo:[action],unknown:{keep:true},SystemStages:{Repeat:16,RepeatDelay:0,Key6Flag:1,ReportSelectItem:3,RFReportSelectItem:3,WFlag:0,WinFlag:0,opaque:99}};
 const p=save('profile.json',profile),t=save('template.json',template),b=save('baseline.json',fromHardware(baseline));
 const out=join(directory,'export.json');invoke(['--export-windows-keys-macros',out,'--profile',p,'--template',t]);
 const exported=JSON.parse(readFileSync(out,'utf8'));
 assert.deepEqual(exported,exportWindowsKeysAndMacros(profile,template));
 const converted=join(directory,'converted.json');invoke(['--convert-windows-profile',converted,'--profile',out,'--baseline',b]);
 const native=JSON.parse(readFileSync(converted,'utf8')),web=importWindows(exported,baseline);
 for(const field of ['deviceInfo','parameters','keymap','colors','macroData'])assert.deepEqual(native.snapshot[field],web.snapshot[field],field);
 assert.deepEqual(native.macros,web.macros);assert.deepEqual(native.macroBindings,web.macroBindings);assert.deepEqual(native.macroModes,web.macroModes);
 assert.deepEqual(JSON.parse(native.windowsTemplateJSON),JSON.parse(web.windowsTemplateJSON));
 for(const source of [p,t]){
  const before=readFileSync(source);invoke(['--export-windows-keys-macros',source,'--profile',p,'--template',t],false);assert.deepEqual(readFileSync(source),before);
 }
 const invalid=clone(profile);invalid.macros[0].steps[0].usage=230;invalid.macros[0].steps[3].usage=230;
 const bad=save('changed-event.json',invalid),rejected=join(directory,'rejected.json');
 invoke(['--export-windows-keys-macros',rejected,'--profile',bad,'--template',t],false);assert.equal(existsSync(rejected),false);
 assert.throws(()=>exportWindowsKeysAndMacros(invalid,template));
 // Differing metadata on same-name official actions must never be silently
 // assigned to one current macro. Both implementations reject that ambiguity.
 const ambiguous=clone(template);ambiguous.ActionInfo.push({...clone(action),opaque:{id:43}});
 const ambiguousPath=save('ambiguous-template.json',ambiguous);
 invoke(['--export-windows-keys-macros',rejected,'--profile',p,'--template',ambiguousPath],false);
 assert.equal(existsSync(rejected),false);assert.throws(()=>exportWindowsKeysAndMacros(profile,ambiguous));
 // A library with unbound items must survive export/import; repeated bindings
 // to one mode must share an action rather than consume duplicate bank slots.
 const library=clone(profile),libraryTemplate=clone(template);
 library.macros.push({...clone(macro),name:'Unbound',preferredPlayback:{mode:'count',count:3}});
 library.macroBindings[120]='Mixed';library.macroModes[120]={mode:'count',count:2};library.snapshot=resolveMacros(library);
 libraryTemplate.ActionInfo.push({ActionType:3,ActionName:'Untouched text',ActionContent:{ActionText:'preserve'}});
 libraryTemplate.KeyList[79].ActionLink=1;libraryTemplate.KeyList[79].ActionLinkIndex=1;
 const lp=save('library.json',library),lt=save('library-template.json',libraryTemplate),lo=join(directory,'library-export.json');
 invoke(['--export-windows-keys-macros',lo,'--profile',lp,'--template',lt]);
 const libraryOut=JSON.parse(readFileSync(lo,'utf8'));assert.deepEqual(libraryOut,exportWindowsKeysAndMacros(library,libraryTemplate));
 assert.deepEqual(libraryOut.ActionInfo[0],libraryTemplate.ActionInfo[1]);assert.equal(libraryOut.KeyList[79].ActionLinkIndex,0);
 assert.equal(libraryOut.ActionInfo.filter(a=>a.ActionType===2&&a.ActionName==='Mixed'&&a.ActionContent.ActionMacroLoopValue===2).length,1);
 invoke(['--convert-windows-profile',converted,'--profile',lo,'--baseline',b]);
 const importedLibrary=JSON.parse(readFileSync(converted,'utf8')),webLibrary=importWindows(libraryOut,baseline);
 for(const field of ['deviceInfo','parameters','keymap','colors','macroData'])assert.deepEqual(importedLibrary.snapshot[field],webLibrary.snapshot[field],field);
 assert.deepEqual(importedLibrary.macros,webLibrary.macros);assert.ok(importedLibrary.macros.some(m=>m.name==='Unbound'&&m.preferredPlayback.count===3));
 assert.deepEqual(importedLibrary.macroBindings,webLibrary.macroBindings);
 // Imported same-name actions retain distinct provenance even after renaming.
 const duplicate=clone(template);duplicate.ActionInfo.push({...clone(action),opaque:{id:43}});
 duplicate.KeyList[17].ActionLink=1;duplicate.KeyList[17].ActionLinkIndex=0;
 duplicate.KeyList[18].ActionLink=1;duplicate.KeyList[18].ActionLinkIndex=1;
 const dp=save('duplicate.json',duplicate);invoke(['--convert-windows-profile',converted,'--profile',dp,'--baseline',b]);
 const distinct=JSON.parse(readFileSync(converted,'utf8')),webDistinct=importWindows(duplicate,baseline);
 assert.deepEqual(distinct.macros,webDistinct.macros);
 distinct.macros[0].name='Renamed';distinct.macroBindings[102]='Renamed';
 const distinctPath=save('distinct.json',distinct),distinctOut=join(directory,'distinct-out.json');
 invoke(['--export-windows-keys-macros',distinctOut,'--profile',distinctPath,'--template',dp]);
 const distinctExport=JSON.parse(readFileSync(distinctOut,'utf8'));
 assert.deepEqual(distinctExport,exportWindowsKeysAndMacros(distinct,duplicate));
 assert.deepEqual(distinctExport.ActionInfo.map(a=>a.opaque.id),[42,43]);
 const broken=clone(distinct);broken.macros[0].windowsActionIndex=999;
 const brokenPath=save('broken-source.json',broken);
 invoke(['--export-windows-keys-macros',rejected,'--profile',brokenPath,'--template',dp],false);
 assert.equal(existsSync(rejected),false);assert.throws(()=>exportWindowsKeysAndMacros(broken,duplicate));
 console.log('PASS: native/Web official export equality, five-bank import equality, unbound libraries, shared bindings, hidden text references, metadata, playback variants, source protection and ambiguity rejection');
}finally{rmSync(directory,{recursive:true,force:true});}
