import {replayMacroExecutionLog} from '../assets/model.js';
import {sameSnapshot} from '../assets/writer.js';
import {replayMacroStopRecord} from '../assets/macro-stop.js';
// Offline only. This script never opens a device or invokes a HID API.
import {readFileSync} from 'node:fs';
import {validateReply} from '../assets/hid.js';
import {assertReadOnlyRequest,KeymapWriteAuthorization,MacroWriteAuthorization} from '../assets/safety.js?v=0.6.0';
import {bytes,validateSnapshot,decodeBank,decodeMacroBinding,equal} from '../assets/model.js';
const filename=process.argv[2];
if(!filename){console.error('用法：node tests/replay-diagnostics.mjs CherryMac-diagnostics.json');process.exit(1);}
const raw=readFileSync(filename);if(raw.length>50_000_000)throw new Error('排查文件超过 50 MB。');
const data=JSON.parse(raw);if(data.format!=='CherryMacWebDiagnostics'||data.version!==1)throw new Error('排查文件格式无效。');
const logs=new Map();for(const entry of [...(data.usbLogs??[]),...(data.sessionLogs??[])])logs.set(entry.id,entry);
const report={mode:'offline; no USB access',logs:logs.size,phases:0,blockedRequests:0,validReplies:0,missingReplies:0,issues:[],snapshotChanges:[],macroStopRecords:[],macroExecutionRecords:[]};
const pageFailures=new Map();
for(const entry of [...logs.values(),...(data.pageFailures??[])])if(entry.kind==='phase'&&entry.phase==='page-failed')pageFailures.set(entry.id,entry);
report.pageFailures=[...pageFailures.values()];
const authorizations=new Map();
for(const e of logs.values())if(e.kind==='phase'){
  report.phases++;
  if(e.baseline&&e.target)try{authorizations.set(e.operationId,new MacroWriteAuthorization(e.baseline,e.target,{allowUnbounded:true}));}
  catch(error){report.issues.push({at:e.at,operationId:e.operationId,error:error.message});}
  if(e.baseline&&e.targetKeymap)try{authorizations.set(e.operationId,new KeymapWriteAuthorization(e.baseline,e.targetKeymap));}
  catch(error){report.issues.push({at:e.at,operationId:e.operationId,error:error.message});}
}
for(const e of logs.values()){
  if(e.kind==='phase')continue;
  if(e.kind==='macroExecution'){try{
    const assessment=replayMacroExecutionLog(e),auth=authorizations.get(e.operationId);
    if(auth){if(!(auth instanceof MacroWriteAuthorization))throw new Error('执行日志与事务类型不符');
      if(!Number.isInteger(e.bindingSlot)||e.bindingSlot<0||e.bindingSlot>=126)throw new Error('缺少明确的输出观察槽位');
      const target=auth.expected,library=decodeBank(target.macroData),binding=target.keymap.slice(e.bindingSlot*3,e.bindingSlot*3+3),playback=decodeMacroBinding(binding,library.length);
      if(!equal(playback,e.playback)||!equal(library[binding[1]].steps,e.macro.steps))throw new Error('执行观察宏与本次目标绑定不一致');
    }
    report.macroExecutionRecords.push({id:e.id,operationId:e.operationId,authorizationLinked:!!auth,...assessment});
  }catch(error){report.issues.push({at:e.at,operationId:e.operationId,error:error.message});}continue;}
  if(e.kind==='macroStop'){try{
    const assessment=replayMacroStopRecord(e),auth=authorizations.get(e.operationId);
    if(auth){if(!(auth instanceof MacroWriteAuthorization))throw new Error('停止记录与写入范围类型不一致');
      const expected=e.request.phase==='beforeWrite'?[auth.before]:[auth.before,auth.expected];
      if(!e.request.configurations.every((s,i)=>sameSnapshot(s,expected[i])))throw new Error('停止记录与本次宏原表／目标不一致');
    }
    report.macroStopRecords.push({id:e.id,operationId:e.operationId,authorizationLinked:!!auth,...assessment});
  }catch(error){report.issues.push({at:e.at,operationId:e.operationId,error:error.message});}continue;}
  try{if(!bytes(e.request,64))throw new Error('请求长度或字节无效');
    if([9,0x15].includes(e.request[3])){const auth=authorizations.get(e.operationId);if(!auth)throw new Error('缺少该键位／宏操作的原表和目标授权证据');auth.validate(e.request);}
    else assertReadOnlyRequest(Uint8Array.from(e.request));
    if(e.status==='blocked'){report.blockedRequests++;continue;}
    if(e.reply==null){report.missingReplies++;continue;}
    if(!bytes(e.reply,64))throw new Error('回复长度或字节无效');validateReply(Uint8Array.from(e.reply),Uint8Array.from(e.request));report.validReplies++;
  }catch(error){report.issues.push({at:e.at,command:e.command,offset:e.offset,error:error.message});}
}
const snapshots=(data.backups??[]).filter(r=>r.snapshot).sort((a,b)=>a.date.localeCompare(b.date));
for(const r of snapshots)validateSnapshot(r.snapshot,true);
for(let i=1;i<snapshots.length;i++){
  const a=snapshots[i-1],b=snapshots[i],changes={from:a.id,to:b.id,parameters:[],colorSlots:[],keySlots:[],macroByteChanges:0};
  for(let j=0;j<56;j++)if(a.snapshot.parameters[j]!==b.snapshot.parameters[j])changes.parameters.push({index:j,before:a.snapshot.parameters[j],after:b.snapshot.parameters[j]});
  for(let j=0;j<126;j++)for(const [key,field] of [['colors','colorSlots'],['keymap','keySlots']])if(a.snapshot[key].slice(j*3,j*3+3).some((v,k)=>v!==b.snapshot[key][j*3+k]))changes[field].push(j);
  changes.macroByteChanges=a.snapshot.macroData.filter((v,j)=>v!==b.snapshot.macroData[j]).length;report.snapshotChanges.push(changes);
}
report.warning='只能校验已有记录和快照差异，不能复原未记录的 0.1.0 写包时序或证明物理故障根因。';
console.log(JSON.stringify(report,null,2));
