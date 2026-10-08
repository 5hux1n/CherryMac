// Cache a successful connection, not a permanent failure. Opening a database
// never starts a configuration operation or retries a failed transaction.
export function databaseOpener(name,version,upgrade,blockedMessage){
  let cached=null;
  return function open(){
    if(cached)return cached;
    let attempt;
    attempt=Promise.resolve().then(()=>new Promise((resolve,reject)=>{
      const request=indexedDB.open(name,version);let abandoned=false;
      const fail=error=>{abandoned=true;reject(error);};
      request.onupgradeneeded=()=>{
        try{upgrade(request.result);}catch(error){request.transaction?.abort();fail(error);}
      };
      request.onsuccess=()=>{
        const database=request.result;
        if(abandoned){database.close();return;}
        const forget=()=>{if(cached===attempt)cached=null;};
        database.onversionchange=()=>{database.close();forget();};
        database.onclose=forget;
        resolve(database);
      };
      request.onerror=()=>fail(request.error??new Error('本地数据库无法打开。'));
      request.onblocked=()=>fail(new Error(blockedMessage));
    })).catch(error=>{if(cached===attempt)cached=null;throw error;});
    cached=attempt;return attempt;
  };
}

// Recovery-critical commits explicitly request strict durability. This is a
// browser hint, not proof against eviction, disk failure or system power loss.
export function strictWriteTransaction(database,stores){
  let transaction;
  try{transaction=database.transaction(stores,'readwrite',{durability:'strict'});}
  catch{throw new Error('浏览器无法创建严格保存事务；恢复资料未确认保存，停止后续发送。');}
  if(transaction.durability!=='strict'){
    transaction.abort();throw new Error('浏览器未采用严格保存事务；请使用支持此功能的浏览器后重新载入计划。');
  }
  return transaction;
}
