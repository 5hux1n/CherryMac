// Targeted draft checks; file conversion only, no devices or permissions.
import assert from 'node:assert/strict';
import {mkdtemp,writeFile,readFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {execFileSync} from 'node:child_process';
import {demoSnapshot} from '../assets/layout.js';
import {WINDOWS_DEFAULTS,FIRMWARE_LOGICAL_DEFAULTS} from '../assets/tables.js';
import {clone,fromHardware,importWindows,parseProfile,lightingMappingSlots,reviewLightingDraft,exportProfileWindowsLightingDraft} from '../assets/model.js';
import {mergeMacroRecoveryDraft} from '../assets/product-macros.js';
const binary=process.argv[2];assert.ok(binary);
const baseline=demoSnapshot(),mapping={deviceInfo:clone(baseline.deviceInfo),factoryKeymap:FIRMWARE_LOGICAL_DEFAULTS.flatMap(v=>[v>>16,(v>>8)&255,v&255]),ledIndices:Array.from({length:126},(_,i)=>(i+7)%126)};
const root={'//':'47',KeyList:WINDOWS_DEFAULTS.map(v=>({DefaultAssignment:v,Assignment:v,ActionLink:0})),ActionInfo:[],LightInfo:{SelectItem:21,Light:2,Speed:1,Fx:1,MultiColor:0,Red:7,Green:123,Blue:249,LightOpenFlag:1},CustomLightMode:{LightColorInfo:[WINDOWS_DEFAULTS.map(()=>({Red:255,Green:128,Blue:1,Alpha:0}))]}};
const draft=importWindows(root,baseline,{lightingMapping:mapping});assert.equal(draft.lightingColorEncoding,'officialRGB');assert.equal(fromHardware(baseline).lightingColorEncoding,'hardwareRGB');
const saved=clone(draft);draft.snapshot.keymap[27]^=1;draft.snapshot.macroData[200]^=1;
const review=reviewLightingDraft(draft,baseline),slot=lightingMappingSlots(mapping,baseline)[0];
assert.deepEqual(review.target.colors.slice(slot*3,slot*3+3),[134,67,0]);assert.deepEqual(review.target.keymap,baseline.keymap);assert.deepEqual(review.target.macroData,baseline.macroData);assert.equal(review.hardwareReady,false);
assert.deepEqual(review.changedColorSlots,Array.from({length:126},(_,i)=>i).filter(i=>baseline.colors.slice(i*3,i*3+3).some((v,j)=>v!==review.target.colors[i*3+j])));
assert.deepEqual(parseProfile(JSON.stringify(saved)).lightingColorEncoding,'officialRGB');
const restored=fromHardware(baseline),merged=mergeMacroRecoveryDraft(restored,saved,baseline,baseline);assert.equal(merged.lightingColorEncoding,'officialRGB');
const builtin=clone(draft);builtin.snapshot.parameters[1]=3;const template=JSON.parse(builtin.windowsTemplateJSON);delete template.CustomLightMode;builtin.windowsTemplateJSON=JSON.stringify(template);delete builtin.lightingColorEncoding;
const builtinReview=reviewLightingDraft(builtin,baseline);assert.equal(builtinReview.plan.stages.length,1);assert.deepEqual(builtinReview.target.colors,baseline.colors);
const dir=await mkdtemp(join(tmpdir(),'cherrymac-draft-review-')),input=join(dir,'draft.json'),base=join(dir,'baseline.json'),output=join(dir,'review.json');
try{
  await writeFile(base,JSON.stringify(fromHardware(baseline)));
  for(const profile of [draft,builtin]){await writeFile(input,JSON.stringify(profile));execFileSync(binary,['--review-lighting-draft',input,base,output],{stdio:'pipe'});assert.deepEqual(JSON.parse(await readFile(output,'utf8')),reviewLightingDraft(profile,baseline));}
  for(const encoding of [undefined,'hardwareRGB','invalid']){
    const bad=clone(draft);if(encoding===undefined)delete bad.lightingColorEncoding;else bad.lightingColorEncoding=encoding;
    assert.throws(()=>reviewLightingDraft(bad,baseline));await writeFile(input,JSON.stringify(bad));assert.throws(()=>execFileSync(binary,['--review-lighting-draft',input,base,output],{stdio:'pipe'}));
  }
  const stored=clone(builtin);stored.windowsTemplateJSON=JSON.stringify(root);stored.lightingColorEncoding='hardwareRGB';stored.snapshot.colors.fill(64);
  for(const profile of [saved,builtin,stored]){
    const source=JSON.parse(profile.windowsTemplateJSON),templateFile=join(dir,'template.json');await writeFile(input,JSON.stringify(profile));await writeFile(templateFile,JSON.stringify(source));
    execFileSync(binary,['--export-lighting-draft',input,templateFile,output],{stdio:'pipe'});
    const expected=exportProfileWindowsLightingDraft(profile,source);assert.deepEqual(JSON.parse(await readFile(output,'utf8')),expected);
    if(profile===stored){assert.deepEqual(expected.CustomLightMode,root.CustomLightMode);assert.deepEqual(expected.CustomLightMode.LightColorInfo[0][0],{Red:255,Green:128,Blue:1,Alpha:0});}
  }
  for(const encoding of [undefined,'hardwareRGB']){
    const bad=clone(saved);if(encoding===undefined)delete bad.lightingColorEncoding;else bad.lightingColorEncoding=encoding;
    assert.throws(()=>exportProfileWindowsLightingDraft(bad,root));await writeFile(input,JSON.stringify(bad));const templateFile=join(dir,'template.json');await writeFile(templateFile,JSON.stringify(root));assert.throws(()=>execFileSync(binary,['--export-lighting-draft',input,templateFile,output],{stdio:'pipe'}));
  }
  const invalid=clone(builtin);invalid.snapshot.parameters[3]=5;assert.throws(()=>exportProfileWindowsLightingDraft(invalid,root));assert.throws(()=>reviewLightingDraft(invalid,baseline));
  await writeFile(input,JSON.stringify(saved));const roundtrip=join(dir,'roundtrip.json');execFileSync(binary,['--portable-profile-roundtrip',input,roundtrip],{stdio:'pipe'});assert.equal(JSON.parse(await readFile(roundtrip,'utf8')).lightingColorEncoding,'officialRGB');
  const before=await readFile(input);assert.throws(()=>execFileSync(binary,['--review-lighting-draft',input,base,input],{stdio:'pipe'}));assert.deepEqual(await readFile(input),before);
  console.log('PASS: native/Web draft parity, single brightness conversion, key/macro isolation, profile export parity, stored RGB template preservation, palette provenance, legacy rejection and input preservation; no HID');
}finally{await rm(dir,{recursive:true,force:true});}
