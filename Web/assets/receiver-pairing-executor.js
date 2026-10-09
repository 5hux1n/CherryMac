import {checkedReceiverPairingSelection,sameReceiverPairingSelection} from './receiver-pairing-selection.js';
import {ReceiverPairingTransaction} from './receiver-pairing-transaction.js';

// Adapters own finite I/O deadlines, pinned endpoints, real backup storage,
// raw-reply validation and exchange logs. No default HID adapter is provided.
export class ReceiverPairingExecutor {
  #running=false;
  get running(){return this.#running;}
  async run(io,{signal}={}){
    if(this.#running)throw new Error('配对流程正在进行，请等待当前操作结束。');
    for(const name of ['currentSelection','saveCompleteBackup','performCommand','queryPaired','configurationMatchesBackup','restoreCompleteConfiguration','persist','close'])
      if(typeof io?.[name]!=='function')throw new Error('配对通信适配器尚未完整接入。');
    this.#running=true;
    let transaction,journalError=null,cleanupError=null,journalStopped=false,savedBackupReference=null;
    try{
      const initial=checkedReceiverPairingSelection(io.currentSelection());
      transaction=new ReceiverPairingTransaction(initial);
      const persist=async()=>{
        try{await io.persist(transaction.snapshot);}
        catch(error){journalStopped=true;journalError=error?.message??String(error);throw error;}
      };
      const check=()=>{
        if(signal?.aborted)throw new DOMException('配对已取消。','AbortError');
        const current=io.currentSelection();
        if(!sameReceiverPairingSelection(current,initial))throw new Error('设备选择已变化，停止配对。');
      };
      try{
        check();await persist();check();
        const reference=await io.saveCompleteBackup({signal});
        if(typeof reference!=='string'||!reference.trim()||reference.length>4096)throw new Error('配对备份编号无效。');
        savedBackupReference=reference;check();
        transaction.backupSaved(reference);await persist();
        while(!transaction.terminal){
          check();const phase=transaction.snapshot.phase;
          const operation=transaction.beginOperation(io.currentSelection());
          await persist();check();
          switch(phase){
            case 'keyboardStart':case 'receiverPrepare':case 'receiverStart':
              await io.performCommand(phase,{signal});check();transaction.commandAccepted(operation);break;
            case 'polling':{
              const paired=await io.queryPaired({signal});check();transaction.statusReceived(operation,paired);break;
            }
            case 'configurationRestore':{
              await io.restoreCompleteConfiguration(reference,{signal});check();transaction.configurationRestored(operation);break;
            }
            case 'configurationCheck':{
              const matches=await io.configurationMatchesBackup(reference,{signal});check();transaction.configurationChecked(operation,matches);break;
            }
            default:throw new Error('配对阶段无效。');
          }
          await persist();
          if(phase==='keyboardStart')await delay(10,signal);
          if(phase==='polling'&&transaction.snapshot.phase==='polling')await delay(2000,signal);
        }
      }catch(error){
        if(signal?.aborted||error?.name==='AbortError')transaction.cancel();else transaction.fail(error?.message??String(error));
        if(!journalStopped)try{await persist();}catch(error){journalError=error?.message??String(error);}
        if(transaction.snapshot.phase==='completed')journalError??=error?.message??String(error);
      }
    }finally{
      try{await io.close();}catch(error){cleanupError=error?.message??String(error);}
      this.#running=false;
    }
    return {transaction:transaction.snapshot,savedBackupReference,journalError,cleanupError,succeeded:transaction.snapshot.phase==='completed'&&journalError===null&&cleanupError===null};
  }
}
function delay(milliseconds,signal){
  return new Promise((resolve,reject)=>{
    if(signal?.aborted){reject(new DOMException('配对已取消。','AbortError'));return;}
    const abort=()=>{clearTimeout(timer);signal?.removeEventListener('abort',abort);reject(new DOMException('配对已取消。','AbortError'));};
    const timer=setTimeout(()=>{signal?.removeEventListener('abort',abort);resolve();},milliseconds);
    signal?.addEventListener('abort',abort,{once:true});
  });
}
