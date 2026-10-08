// Separate database preserves the existing 0.1.0 backup schema and records.
import {databaseOpener} from './database.js?v=0.6.0';
const db=databaseOpener('CherryMacWebLogs',1,value=>value.createObjectStore('logs',{keyPath:'id'}),'日志数据库被其他页面占用。');
export async function saveLog(entry){const database=await db();await new Promise((resolve,reject)=>{const t=database.transaction('logs','readwrite');t.objectStore('logs').put(entry);t.oncomplete=resolve;t.onerror=()=>reject(t.error);t.onabort=()=>reject(t.error??new Error('日志存储失败。'));});}
export async function listLogs(){const database=await db();return new Promise((resolve,reject)=>{const t=database.transaction('logs','readonly'),r=t.objectStore('logs').getAll();let logs=[];r.onsuccess=()=>logs=r.result;t.oncomplete=()=>resolve(logs.sort((a,b)=>a.at.localeCompare(b.at)));t.onerror=()=>reject(t.error);t.onabort=()=>reject(t.error??new Error('日志读取已中止。'));});}

// Recovery sources must be read back in the same write transaction before
// authorizing the next report. Snapshot before awaiting the database opener.
export async function saveVerifiedLog(entry){
  const expected=structuredClone(entry),database=await db();
  await new Promise((resolve,reject)=>{
    const transaction=database.transaction('logs','readwrite'),store=transaction.objectStore('logs');let verified=false,failure=null;
    const write=store.put(expected);
    write.onsuccess=()=>{
      const read=store.get(expected.id);
      read.onsuccess=()=>{
        if(JSON.stringify(read.result)!==JSON.stringify(expected)){failure=new Error('恢复资料读回不一致，停止后续发送。');transaction.abort();return;}
        verified=true;
      };
    };
    transaction.oncomplete=()=>verified?resolve():reject(new Error('恢复资料未完成读回核对，停止后续发送。'));
    transaction.onerror=()=>reject(failure??transaction.error??new Error('恢复资料保存失败。'));
    transaction.onabort=()=>reject(failure??transaction.error??new Error('恢复资料保存已中止。'));
  });
}
