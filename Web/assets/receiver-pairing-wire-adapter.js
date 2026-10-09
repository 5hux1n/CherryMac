import {checkedReceiverPairingSelection,sameReceiverPairingSelection} from './receiver-pairing-selection.js';
import {receiverPairingFrame,receiverPairingReply} from './receiver-pairing-frames.js';
import {savePairingCheckpoint} from './receiver-pairing-journal.js';

// The caller must provide a real bounded raw transport and verified complete
// backup storage. There is no default sender, device opening or selector guess.
export class ReceiverPairingWireAdapter{
  #selection;#id;#live;#selector;#exchange;#backup;#matches;#log;#shutdown;
  #checkpoint=null;#consumed=new Set();#backupAttempted=false;#failed=false;#closed=false;#closeError=null;
  constructor({selection,id,live,selector,exchange,backup,matches,log,shutdown}){
    this.#selection=checkedReceiverPairingSelection(selection);
    if(typeof id!=='string'||!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(id)||![live,selector,exchange,backup,matches,log,shutdown].every(fn=>typeof fn==='function'))throw new Error('配对传输适配器缺少操作编号或必需接口。');
    this.#id=id;this.#live=live;this.#selector=selector;this.#exchange=exchange;
    this.#backup=backup;this.#matches=matches;this.#log=log;this.#shutdown=shutdown;
  }
  currentSelection(){
    if(this.#closed)throw new Error('配对传输已经关闭。');
    const current=checkedReceiverPairingSelection(this.#live());
    if(!sameReceiverPairingSelection(current,this.#selection))throw new Error('配对端点已变化。');return current;
  }
  async saveCompleteBackup({signal}={}){
    if(this.#failed||this.#backupAttempted||this.#checkpoint?.phase!=='backup'||this.#checkpoint.pending)throw new Error('完整备份只能在本次配对的备份阶段执行一次。');
    this.#backupAttempted=true;this.currentSelection();cancel(signal);
    try{return await this.#backup({signal});}catch(error){this.#failed=true;throw error;}
  }
  async persist(state){
    if(!sameReceiverPairingSelection(state.selection,this.#selection))throw new Error('配对检查点属于其他端点。');
    if(!['completed','failed','cancelled'].includes(state.phase))this.currentSelection();
    const saved=await savePairingCheckpoint(this.#id,state);this.#checkpoint=structuredClone(saved.state);
  }
  async #perform(phase,{signal}={}){
    const state=this.#checkpoint;
    if(this.#closed||this.#failed||!state?.pending||state.phase!==phase||!Number.isInteger(state.operationID)||!state.backupReference||!sameReceiverPairingSelection(state.selection,this.#selection)||this.#consumed.has(state.operationID))throw new Error('配对报告缺少本次已保存的阶段意图，或该意图已使用。');
    const intent=state.operationID;this.#consumed.add(intent);let plan=null,reply=null,logStopped=false,receivedLength=0;
    const record=async(stage,error=null)=>{
      if(!plan)return;
      try{await this.#log(structuredClone({format:'CherryMacPairingRawExchange',version:1,id:this.#id,intent,phase,endpoint:plan.endpoint,selection:this.#selection,request:plan.request,reply,receivedLength,stage,error}));}
      catch(error){logStopped=true;throw error;}
    };
    const checkIntent=()=>{
      if(this.#closed||this.#failed||JSON.stringify(this.#checkpoint)!==JSON.stringify(state))throw new Error('配对已保存意图在等待期间发生变化。');
      this.currentSelection();cancel(signal);
    };
    try{
      checkIntent();
      const endpoint=phase==='keyboardStart'?'keyboard':'receiver';
      plan=receiverPairingFrame(phase,phase==='polling'?null:await this.#selector(endpoint,{signal}));
      await record('prepared');checkIntent();
      // Give the transport its own copy; callbacks cannot alter the plan.
      const received=await this.#exchange(plan.endpoint,Array.from(plan.request),{signal});
      if(!(Array.isArray(received)||received instanceof Uint8Array))throw new Error('配对传输没有返回原始报告。');
      receivedLength=received.length;const sample=Array.from(received.slice(0,64));
      const validBytes=sample.every(byte=>Number.isInteger(byte)&&byte>=0&&byte<=255);reply=validBytes?sample:null;
      await record('received');checkIntent();
      if(receivedLength!==64||!validBytes)throw new Error('配对传输回复长度或字节无效。');
      const result=receiverPairingReply(reply,plan,{transportSucceeded:true});
      await record('accepted');checkIntent();return result;
    }catch(error){
      this.#failed=true;
      if(!logStopped)try{await record('failed',String(error?.message??error));}
      catch(logging){throw new Error(String(error?.message??error)+'；原始报告日志保存失败：'+String(logging?.message??logging),{cause:error});}
      throw error;
    }
  }
  async performCommand(phase,options={}){
    if(!['keyboardStart','receiverPrepare','receiverStart'].includes(phase))throw new Error('不支持的配对命令阶段。');
    await this.#perform(phase,options);
  }
  async queryPaired(options={}){return (await this.#perform('polling',options)).paired;}
  async configurationMatchesBackup(reference,{signal}={}){
    const state=this.#checkpoint;
    if(this.#closed||this.#failed||state?.phase!=='configurationCheck'||!state.pending||state.backupReference!==reference||!Number.isInteger(state.operationID)||this.#consumed.has(state.operationID))throw new Error('配对配置核对缺少本次已保存意图。');
    this.#consumed.add(state.operationID);this.currentSelection();cancel(signal);
    const result=await this.#matches(reference,{signal});
    if(this.#closed||this.#failed||JSON.stringify(this.#checkpoint)!==JSON.stringify(state))throw new Error('配对配置核对意图已经变化。');
    this.currentSelection();cancel(signal);
    if(typeof result!=='boolean')throw new Error('配对配置核对没有返回有效结果。');return result;
  }
  async close(){
    if(this.#closed){if(this.#closeError)throw this.#closeError;return;}
    this.#closed=true;try{await this.#shutdown();}catch(error){this.#closeError=error;throw error;}
  }
}
function cancel(signal){if(signal?.aborted)throw new DOMException('配对已取消。','AbortError');}
