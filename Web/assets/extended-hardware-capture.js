import {validateExtendedHardwareBackup,sameExtendedCapturedData} from './extended-hardware-backup.js?v=0.6.0';

// No default USB or persistence implementation. Identity comes from a live
// adapter's descriptor/session, never a user-entered revision or imported file.
export const extendedCaptureRegions=[['deviceInfo',3,34,56],['parameters',5,63,56],['keymap',8,511,56],['colors',10,511,56],['macroData',20,3071,54]];
export function checkedCaptureIdentity(value){
  if(!value||Object.keys(value).length!==5||typeof value.sessionToken!=='string'||!value.sessionToken||new TextEncoder().encode(value.sessionToken).length>128||value.vendorID!==0x046a||value.productID!==0x01ce||value.usbRevision!==0x0104||value.transport!=='USB')throw new Error('扩展捕获仅有 Pokémon USB 0104 的静态边界依据；当前设备身份／固件范围未匹配。');
  return structuredClone(value);
}
export async function captureExtendedHardware({identity,cancelled,nowMilliseconds,persist,read,save,load}){
  if(![identity,cancelled,nowMilliseconds,persist,read,save,load].every(fn=>typeof fn==='function'))throw new Error('扩展捕获缺少真实身份、取消、时钟、日志、读取或保存接口。');
  const selected=checkedCaptureIdentity(await identity());let sequence=0,completedReads=0,backupReference=null;
  const check=async()=>{
    if(cancelled())throw new Error('扩展捕获已取消；已有资料保留。');
    const current=checkedCaptureIdentity(await identity());
    if(Object.keys(selected).some(key=>current[key]!==selected[key]))throw new Error('扩展捕获 USB 会话已改变，停止读取。');
  };
  const event=async(phase,pass=0,region='',offset=0,length=0,detail='')=>{
    await persist({sequence:++sequence,phase,pass,region,offset,length,backupReference,detail});
  };
  const capturePass=async pass=>{
    const data={};
    for(const [region,command,count,capacity] of extendedCaptureRegions){
      const value=[];
      for(let offset=0;offset<count;offset+=capacity){
        const length=Math.min(capacity,count-offset);
        await check();await event('readPrepared',pass,region,offset,length);await check();
        const reply=await read(command,offset,length);
        if(!Array.isArray(reply)||reply.length!==length||!Array.from(reply).every(byte=>Number.isInteger(byte)&&byte>=0&&byte<=255))throw new Error('扩展捕获回复长度或字节无效。');
        const bytes=Array.from(reply);await check();value.push(...bytes);completedReads++;await event('readAccepted',pass,region,offset,length);
      }
      data[region]=value;
    }
    const snapshot={format:'CherryMacExtendedHardware',version:1,vendorID:0x046a,productID:0x01ce,boundaryModel:'pokemon-0104-static',createdAtMilliseconds:nowMilliseconds(),...data};
    validateExtendedHardwareBackup(snapshot);return snapshot;
  };
  try{
    await check();await event('started');
    const first=await capturePass(1),second=await capturePass(2);
    if(!sameExtendedCapturedData(first,second))throw new Error('扩展数据在两次捕获间发生变化，未作为一致备份保存。');
    await check();await event('saving');const reference=await save(structuredClone(second));
    if(typeof reference!=='string'||!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(reference))throw new Error('扩展备份保存标识无效。');
    backupReference=reference;await event('saved');const restored=await load(reference);validateExtendedHardwareBackup(restored);
    if(restored.createdAtMilliseconds!==second.createdAtMilliseconds||!sameExtendedCapturedData(restored,second))throw new Error('扩展备份本机读回不一致，保存结果不能用于后续流程。');
    await check();await event('complete');return {identity:selected,snapshot:second,backupReference:reference,completedReads};
  }catch(error){await event(cancelled()?'cancelled':'failed',0,'',0,0,String(error?.message??error).slice(0,1024));throw error;}
}
