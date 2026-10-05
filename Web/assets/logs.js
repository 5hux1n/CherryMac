// Separate database preserves the existing 0.1.0 backup schema and records.
import {databaseOpener} from './database.js?v=0.6.0';
const db=databaseOpener('CherryMacWebLogs',1,value=>value.createObjectStore('logs',{keyPath:'id'}),'日志数据库被其他页面占用。');
export async function saveLog(entry){const database=await db();await new Promise((resolve,reject)=>{const t=database.transaction('logs','readwrite');t.objectStore('logs').put(entry);t.oncomplete=resolve;t.onerror=()=>reject(t.error);t.onabort=()=>reject(t.error??new Error('日志存储失败。'));});}
export async function listLogs(){const database=await db();return new Promise((resolve,reject)=>{const t=database.transaction('logs','readonly'),r=t.objectStore('logs').getAll();let logs=[];r.onsuccess=()=>logs=r.result;t.oncomplete=()=>resolve(logs.sort((a,b)=>a.at.localeCompare(b.at)));t.onerror=()=>reject(t.error);t.onabort=()=>reject(t.error??new Error('日志读取已中止。'));});}
