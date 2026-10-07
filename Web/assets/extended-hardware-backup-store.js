import {databaseOpener} from './database.js?v=0.6.0';
import {validateExtendedHardwareBackup} from './extended-hardware-backup.js';

// Separate raw backups, never silently upgraded from ordinary editor snapshots.
// No database access until save/load, no HID calls or uploads.
const open=databaseOpener('CherryMacExtendedHardwareBackups',1,database=>database.createObjectStore('backups',{keyPath:'id'}),'扩展备份数据库被其他页面占用。');
function validateID(id){if(typeof id!=='string'||!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(id))throw new Error('扩展备份标识无效。');}
function checkedRecord(record,id){
  if(!record||record.id!==id||Object.keys(record).length!==2||!Object.hasOwn(record,'snapshot'))throw new Error('扩展备份记录无效。');
  validateExtendedHardwareBackup(record.snapshot);
  return record.snapshot;
}
export async function saveExtendedHardwareBackup(input){
  const text=JSON.stringify(input);
  if(typeof text!=='string'||new TextEncoder().encode(text).length>128_000)throw new Error('扩展备份超过大小限制。');
  const snapshot=JSON.parse(text);validateExtendedHardwareBackup(snapshot);
  const id=crypto.randomUUID(),record={id,snapshot},database=await open();
  return new Promise((resolve,reject)=>{
    const tx=database.transaction('backups','readwrite',{durability:'strict'}),store=tx.objectStore('backups');let failure=null;
    const added=store.add(record);
    added.onsuccess=()=>{
      const read=store.get(id);
      read.onsuccess=()=>{
        try{
          const restored=checkedRecord(read.result,id);
          if(JSON.stringify(restored)!==JSON.stringify(snapshot))throw new Error('扩展备份读回不一致，停止后续操作。');
        }catch(error){failure=error;tx.abort();}
      };
    };
    tx.oncomplete=()=>resolve(id);
    tx.onerror=()=>reject(failure??tx.error??new Error('扩展备份保存失败。'));
    tx.onabort=()=>reject(failure??tx.error??new Error('扩展备份保存中止。'));
  });
}
export async function loadExtendedHardwareBackup(id){
  validateID(id);const database=await open();
  return new Promise((resolve,reject)=>{
    const tx=database.transaction('backups','readonly');let snapshot,failure=null;
    const request=tx.objectStore('backups').get(id);
    request.onsuccess=()=>{
      try{snapshot=checkedRecord(request.result,id);}catch(error){failure=error;tx.abort();}
    };
    tx.oncomplete=()=>resolve(snapshot);
    tx.onerror=()=>reject(failure??tx.error??new Error('扩展备份读取失败。'));
    tx.onabort=()=>reject(failure??tx.error??new Error('扩展备份读取中止。'));
  });
}
