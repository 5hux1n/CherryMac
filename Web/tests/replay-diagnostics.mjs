// Offline only. This script never opens a device or invokes a HID API.
import {readFileSync} from 'node:fs';
import {validateReply} from '../assets/hid.js';
import {assertReadOnlyRequest,KeymapWriteAuthorization} from '../assets/safety.js?v=0.4.0';
import {bytes,validateSnapshot} from '../assets/model.js';
const filename=process.argv[2];
if(!filename){console.error('用法：node tests/replay-diagnostics.mjs CherryMac-diagnostics.json');process.exit(1);}
const raw=readFileSync(filename);if(raw.length>50_000_000)throw new Error('排查文件超过 50 MB。');
const data=JSON.parse(raw);if(data.format!=='CherryMacWebDiagnostics'||data.version!==1)throw new Error('排查文件格式无效。');
const logs=new Map();for(const entry of [...(data.usbLogs??[]),...(data.sessionLogs??[])])logs.set(entry.id,entry);
const report={mode:'offline; no USB access',logs:logs.size,phases:0,blockedRequests:0,validReplies:0,missingReplies:0,issues:[],snapshotChanges:[]};
const authorizations=new Map();
for(const e of logs.values())if(e.kind==='phase'){
  report.phases++;
  if(e.baseline&&e.targetKeymap)try{authorizations.set(e.operationId,new KeymapWriteAuthorization(e.baseline,e.targetKeymap));}
  catch(error){report.issues.push({at:e.at,operationId:e.operationId,error:error.message});}
}
for(const e of logs.values()){
  if(e.kind==='phase')continue;
  try{if(!bytes(e.request,64))throw new Error('请求长度或字节无效');
    if(e.request[3]===9){const auth=authorizations.get(e.operationId);if(!auth)throw new Error('缺少该键位操作的原表／目标授权证据');auth.validate(e.request);}
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
