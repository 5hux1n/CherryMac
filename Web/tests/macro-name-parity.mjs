// Pure file conversion only; never construct a USB transport or start an App.
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {mkdtemp,writeFile,readFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import {WINDOWS_DEFAULTS} from '../assets/tables.js';
import {demoSnapshot} from '../assets/layout.js';
import {importWindows,duplicateMacro,validateMacro,validateProfile,parseProfile,resolveMacros,exportWindowsKeysAndMacros} from '../assets/model.js';

const binary=resolve(process.argv[2]),folder=await mkdtemp(join(tmpdir(),'CherryMacMacroNames-'));
try{
  const baseline=demoSnapshot();baseline.deviceInfo[6]=24;
  const base=join(folder,'baseline.json'),input=join(folder,'windows.json'),output=join(folder,'native.json');
  await writeFile(base,JSON.stringify(baseline));
  for(const names of [['e\u0301'.repeat(70)],['👩‍💻'.repeat(30)],['e\u0301','é']]){
    const root={'//':'47',KeyList:WINDOWS_DEFAULTS.map(value=>({DefaultAssignment:value,Assignment:value,ActionLink:0})),ActionInfo:names.map(name=>({ActionType:2,ActionName:name,ActionContent:{ActionMacroType:0,ActionMacroLoopValue:1,ActionMacroEvents:[{Type:10,Button:4,Action:'down',Delay:50},{Type:10,Button:4,Action:'up',Delay:0}]}}))};
    await writeFile(input,JSON.stringify(root));execFileSync(binary,['--convert-windows-profile',output,'--profile',input,'--baseline',base],{stdio:'pipe'});
    const native=JSON.parse(await readFile(output,'utf8')),web=importWindows(root,baseline);
    assert.deepEqual(native.macros,web.macros);assert.deepEqual(native.snapshot.macroData,web.snapshot.macroData);
    assert.deepEqual(JSON.parse(native.windowsTemplateJSON).ActionInfo,root.ActionInfo);
    assert.deepEqual(JSON.parse(web.windowsTemplateJSON).ActionInfo,root.ActionInfo);
  }
  const steps=[{usage:4,pressed:true,delayMilliseconds:50},{usage:4,pressed:false,delayMilliseconds:0}];
  validateMacro({name:'e\u0301'.repeat(80),steps});assert.throws(()=>validateMacro({name:'é'.repeat(81),steps}));
  const profile={format:'CherryMacProfile',version:1,snapshot:baseline,macros:[{name:'e\u0301',steps}],macroBindings:{102:'é'},macroModes:{102:{mode:'count',count:1}}};
  profile.snapshot=resolveMacros(profile);const parsed=parseProfile(JSON.stringify(profile));assert.equal(parsed.macroBindings['102'],'e\u0301');
  const copy=duplicateMacro(parsed,'é');assert.equal(copy.name,'é 副本');assert.deepEqual(copy.profile.macroBindings,parsed.macroBindings);
  const template={'//':'47',KeyList:WINDOWS_DEFAULTS.map(value=>({DefaultAssignment:value,Assignment:value,ActionLink:0})),ActionInfo:[{ActionType:2,ActionName:'é',VendorField:'preserved',ActionContent:{ActionMacroType:0,ActionMacroLoopValue:1,ActionMacroEvents:[{Type:10,Button:4,Action:'down',Delay:50},{Type:10,Button:4,Action:'up',Delay:0}]}}]};
  await writeFile(input,JSON.stringify(template));const own=join(folder,'profile.json');await writeFile(own,JSON.stringify(profile));
  execFileSync(binary,['--export-windows-keys-macros',output,'--profile',own,'--template',input],{stdio:'pipe'});
  const nativeExport=JSON.parse(await readFile(output,'utf8')),webExport=exportWindowsKeysAndMacros(profile,template);
  assert.deepEqual(nativeExport.ActionInfo,webExport.ActionInfo);assert.equal(webExport.ActionInfo[0].VendorField,'preserved');
  const previousOutput=await readFile(output);const invalid=structuredClone(profile);invalid.macros[0].name='é'.repeat(81);await writeFile(own,JSON.stringify(invalid));
  assert.throws(()=>execFileSync(binary,['--export-windows-keys-macros',output,'--profile',own,'--template',input],{stdio:'pipe'}));assert.deepEqual(await readFile(output),previousOutput);
  const repeated=structuredClone(profile);repeated.macros.push({name:'é',steps});assert.throws(()=>validateProfile(repeated));
  console.log('Unicode names match native/Web conversion; aliases resolve; duplicate equivalence rejected; original official names preserved.');
}finally{await rm(folder,{recursive:true,force:true});}
