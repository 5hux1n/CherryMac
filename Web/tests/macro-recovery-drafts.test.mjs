import assert from 'node:assert/strict';
import {demoSnapshot} from '../assets/layout.js';
import {WINDOWS_DEFAULTS,FIRMWARE_LOGICAL_DEFAULTS} from '../assets/tables.js';
import {clone,resolveMacros,validateProfile,officialMacroSource,exportWindowsKeysAndMacros} from '../assets/model.js';
import {mergeMacroRecoveryDraft} from '../assets/product-macros.js';
const action={ActionType:2,ActionName:'A',VendorExtra:{keep:17},ActionContent:{ActionMacroType:0,ActionMacroLoopValue:1,ActionMacroFixTimeIsSelected:false,ActionMacroFixTimeValue:0,ActionMacroEvents:[]}};
const root={'//':'47',KeyList:WINDOWS_DEFAULTS.map(DefaultAssignment=>({DefaultAssignment,Assignment:DefaultAssignment,ActionLink:0})),ActionInfo:[action]};
const snapshot=demoSnapshot();snapshot.keymap=Array.from({length:126},()=>[0x20,0,0]).flat();
const restored={format:'CherryMacProfile',version:1,snapshot,macros:[{name:'A',steps:[{usage:4,pressed:true,delayMilliseconds:0},{usage:4,pressed:false,delayMilliseconds:0}],windowsActionIndex:0}],macroBindings:{},windowsTemplateJSON:JSON.stringify(root)};
restored.snapshot=resolveMacros(restored);validateProfile(restored);
const previous=clone(restored),draftRoot=clone(root);draftRoot.ActionInfo=[];draftRoot.VendorDraft={keep:'current'};
draftRoot.SystemStages={Repeat:0,RepeatDelay:0,Key6Flag:0,ReportSelectItem:3,RFReportSelectItem:0,WFlag:0,WinFlag:0};
previous.windowsTemplateJSON=JSON.stringify(draftRoot);delete previous.macros[0].windowsActionIndex;
previous.hostTextJSON=previous.windowsTemplateJSON;
previous.lightingMapping={deviceInfo:clone(snapshot.deviceInfo),factoryKeymap:FIRMWARE_LOGICAL_DEFAULTS.flatMap(v=>[v>>16,(v>>8)&255,v&255]),ledIndices:Array.from({length:126},(_,i)=>i)};
const original=clone(previous),merged=mergeMacroRecoveryDraft(restored,previous,restored.snapshot,restored.snapshot);
assert.equal(merged.hostTextJSON,previous.hostTextJSON);assert.deepEqual(merged.lightingMapping,previous.lightingMapping);
assert.equal(JSON.parse(merged.windowsTemplateJSON).SystemStages.ReportSelectItem,3);
assert.deepEqual(JSON.parse(merged.windowsTemplateJSON).VendorDraft,{keep:'current'});
assert.deepEqual(officialMacroSource(merged,merged.macros[0]),action);assert.deepEqual(previous,original);
const repeated=mergeMacroRecoveryDraft(restored,merged,restored.snapshot,restored.snapshot);
assert.equal(JSON.parse(repeated.windowsTemplateJSON).ActionInfo.length,1);
const reordered=clone(previous);const withText=clone(draftRoot);withText.ActionInfo=[{ActionType:3,ActionTextFlag:1,ActionContent:{ActionText:'new'}}];reordered.windowsTemplateJSON=JSON.stringify(withText);
const remapped=mergeMacroRecoveryDraft(restored,reordered,restored.snapshot,restored.snapshot);
assert.equal(remapped.macros[0].windowsActionIndex,1);assert.deepEqual(officialMacroSource(remapped,remapped.macros[0]),action);
const cleared=clone(previous);delete cleared.hostTextJSON;delete cleared.lightingMapping;
const clean=mergeMacroRecoveryDraft(merged,cleared,restored.snapshot,restored.snapshot);
assert.equal(clean.hostTextJSON,undefined);assert.equal(clean.lightingMapping,undefined);
const malformed=clone(previous);const malformedRoot=clone(draftRoot);malformedRoot.ActionInfo='invalid';malformed.windowsTemplateJSON=JSON.stringify(malformedRoot);assert.throws(()=>mergeMacroRecoveryDraft(restored,malformed,restored.snapshot,restored.snapshot),/动作列表无效/);
const reverseKeys=value=>Array.isArray(value)?value.map(reverseKeys):value&&typeof value==='object'?Object.fromEntries(Object.entries(value).reverse().map(([key,item])=>[key,reverseKeys(item)])):value;
const reorderedObject=clone(previous),equivalentRoot=clone(draftRoot);equivalentRoot.ActionInfo=[reverseKeys(action)];reorderedObject.windowsTemplateJSON=JSON.stringify(equivalentRoot);
const reused=mergeMacroRecoveryDraft(restored,reorderedObject,restored.snapshot,restored.snapshot);
assert.equal(JSON.parse(reused.windowsTemplateJSON).ActionInfo.length,1,'equivalent source with reordered object fields should be reused');
for(const candidate of [merged,remapped,reused]){
  const exported=exportWindowsKeysAndMacros(candidate,JSON.parse(candidate.windowsTemplateJSON));
  assert.deepEqual(exported.VendorDraft,{keep:'current'});assert.equal(exported.SystemStages.ReportSelectItem,3);
  assert.deepEqual(exported.ActionInfo.find(a=>a.ActionType===2).VendorExtra,{keep:17});
  assert.equal(exported.ActionInfo.find(a=>a.ActionType===2).ActionContent.ActionMacroEvents.length,2);
}
console.log('PASS: current template/settings/LED/text retained, original macro extras remapped after action reorder, no duplicate growth or input mutation; memory only');

// Optional final App conversion checks run before its GUI/HID entry point.
if(process.argv[2]){
  const {mkdtemp,writeFile,readFile,rm}=await import('node:fs/promises');
  const {join}=await import('node:path'),{tmpdir}=await import('node:os'),{execFileSync}=await import('node:child_process');
  const directory=await mkdtemp(join(tmpdir(),'cherry-recovery-export-'));
  try{
    for(const [index,candidate] of [merged,remapped,reused].entries()){
      const profilePath=join(directory,`profile-${index}.json`),templatePath=join(directory,`template-${index}.json`),output=join(directory,`out-${index}.json`);
      const template=JSON.parse(candidate.windowsTemplateJSON);
      await writeFile(profilePath,JSON.stringify(candidate));await writeFile(templatePath,JSON.stringify(template));
      execFileSync(process.argv[2],['--export-windows-keys-macros',output,'--profile',profilePath,'--template',templatePath],{stdio:'pipe'});
      assert.deepEqual(JSON.parse(await readFile(output,'utf8')),exportWindowsKeysAndMacros(candidate,template));
    }
    console.log('PASS: recovered draft official export matches final Mac App for appended/reordered/reused source actions; files only');
  }finally{await rm(directory,{recursive:true,force:true});}
}
