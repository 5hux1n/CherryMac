import {databaseOpener,strictWriteTransaction} from './database.js?v=0.6.0';
import {validatePairingConfigurationRegions} from './receiver-pairing-configuration-regions.js';

// Independent full-region schema; no prefix promotion or pairing authority.
// No database access until save/load, no HID calls or uploads.
const open=databaseOpener('CherryMacFullConfigurationRegionRecords',1,database=>database.createObjectStore('backups',{keyPath:'id'}),'完整配置区记录数据库被其他页面占用。');
function validateID(id){if(typeof id!=='string'||!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(id))throw new Error('完整配置区记录标识无效。');}
function checkedRecord(record,id){
  if(!record||record.id!==id||Object.keys(record).length!==2||!Object.hasOwn(record,'snapshot'))throw new Error('完整配置区记录记录无效。');
  validatePairingConfigurationRegions(record.snapshot);
  return record.snapshot;
}
export async function savePairingConfigurationRegions(input){
  const text=JSON.stringify(input);
  if(typeof text!=='string'||new TextEncoder().encode(text).length>128_000)throw new Error('完整配置区记录超过大小限制。');
  const snapshot=JSON.parse(text);validatePairingConfigurationRegions(snapshot);
  const id=crypto.randomUUID(),record={id,snapshot},database=await open();
  return new Promise((resolve,reject)=>{
    const tx=strictWriteTransaction(database,'backups'),store=tx.objectStore('backups');let failure=null;
    const added=store.add(record);
    added.onsuccess=()=>{
      const read=store.get(id);
      read.onsuccess=()=>{
        try{
          const restored=checkedRecord(read.result,id);
          if(JSON.stringify(restored)!==JSON.stringify(snapshot))throw new Error('完整配置区记录读回不一致，停止后续操作。');
        }catch(error){failure=error;tx.abort();}
      };
    };
    tx.oncomplete=()=>resolve('configuration-regions:'+id);
    tx.onerror=()=>reject(failure??tx.error??new Error('完整配置区记录保存失败。'));
    tx.onabort=()=>reject(failure??tx.error??new Error('完整配置区记录保存中止。'));
  });
}
export async function loadPairingConfigurationRegions(reference){
  if(typeof reference!=='string'||!reference.startsWith('configuration-regions:'))throw new Error('完整配置区记录标识类型无效。');
  const id=reference.slice('configuration-regions:'.length);validateID(id);const database=await open();
  return new Promise((resolve,reject)=>{
    const tx=database.transaction('backups','readonly');let snapshot,failure=null;
    const request=tx.objectStore('backups').get(id);
    request.onsuccess=()=>{
      try{snapshot=checkedRecord(request.result,id);}catch(error){failure=error;tx.abort();}
    };
    tx.oncomplete=()=>resolve(snapshot);
    tx.onerror=()=>reject(failure??tx.error??new Error('完整配置区记录读取失败。'));
    tx.onabort=()=>reject(failure??tx.error??new Error('完整配置区记录读取中止。'));
  });
}

export async function listPairingConfigurationRegionReferences(){
  const database=await open();return new Promise((resolve,reject)=>{
    const tx=database.transaction('backups','readonly');let ids,failure=null;
    const request=tx.objectStore('backups').getAllKeys();
    request.onsuccess=()=>{try{ids=request.result;ids.forEach(validateID);}catch(error){failure=error;tx.abort();}};
    tx.oncomplete=()=>resolve(ids.map(id=>'configuration-regions:'+id));tx.onerror=()=>reject(failure??tx.error??new Error('完整配置区记录列表读取失败。'));tx.onabort=()=>reject(failure??tx.error??new Error('完整配置区记录列表读取中止。'));
  });
}
