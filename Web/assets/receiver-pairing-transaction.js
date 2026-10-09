import {checkedReceiverPairingSelection,sameReceiverPairingSelection} from './receiver-pairing-selection.js';
// Pure stage controller. Caller owns saved backup, validated replies, liveness,
// request logging and complete post-pair configuration comparison. No HID calls.
export class ReceiverPairingTransaction {
  #selection;#phase='backup';#backup=null;#pending=false;
  #operation=null;#pollCount=0;#changed=false;#recovery=false;#events=[];
  constructor(selection){
    this.#selection=checkedReceiverPairingSelection(selection);
    this.#record('created','等待完整备份保存。');
  }
  get snapshot(){return {selection:structuredClone(this.#selection),phase:this.#phase,backupReference:this.#backup,pending:this.#pending,operationID:this.#operation,pollCount:this.#pollCount,mayHaveChanged:this.#changed,recoveryRequired:this.#recovery,events:this.#events.map(event=>({...event}))};}
  get terminal(){return ['completed','failed','cancelled'].includes(this.#phase);}
  #require(condition){if(!condition)throw new Error('配对流程状态已改变，请重新开始；已有备份仍需保留。');}
  #record(action,detail){this.#events.push({sequence:this.#events.length+1,phase:this.#phase,action,detail});}
  backupSaved(reference){
    this.#require(this.#phase==='backup'&&typeof reference==='string'&&reference.trim().length>0&&reference.length<=4096);
    this.#backup=reference;this.#record('backupSaved',reference);this.#phase='keyboardStart';
  }
  beginOperation(current){
    this.#require(!this.terminal&&!this.#pending&&this.#phase!=='backup'&&this.#backup!==null);
    let matched=false;try{matched=sameReceiverPairingSelection(current,this.#selection);}catch{}
    if(!matched){this.fail('设备选择已变化，停止配对。');this.#require(false);}
    if(this.#phase==='polling'){this.#require(this.#pollCount<5);this.#pollCount++;}
    if(['keyboardStart','receiverPrepare','receiverStart'].includes(this.#phase))this.#changed=true;
    this.#pending=true;this.#operation=this.#events.length+1;
    this.#record('begin',this.#phase==='polling'?`状态查询 ${this.#pollCount}/5`:'开始本阶段操作。');
    return this.#operation;
  }
  commandAccepted(operation){
    this.#require(this.#pending&&this.#operation===operation&&['keyboardStart','receiverPrepare','receiverStart'].includes(this.#phase));
    this.#pending=false;this.#operation=null;this.#record('accepted','阶段回复已核对；尚未判定配对完成。');
    this.#phase={keyboardStart:'receiverPrepare',receiverPrepare:'receiverStart',receiverStart:'polling'}[this.#phase];
  }
  statusReceived(operation,paired){
    this.#require(this.#phase==='polling'&&this.#pending&&this.#operation===operation&&typeof paired==='boolean');
    this.#pending=false;this.#operation=null;this.#record('status',paired?'设备报告配对完成，继续核对原配置。':'设备尚未报告配对完成。');
    if(paired)this.#phase='configurationCheck';else if(this.#pollCount===5)this.fail('配对状态查询已达五次，未确认完成。');
  }
  configurationChecked(operation,unchanged){
    this.#require(this.#phase==='configurationCheck'&&this.#pending&&this.#operation===operation&&typeof unchanged==='boolean');
    this.#pending=false;this.#operation=null;
    if(unchanged){this.#phase='completed';this.#record('completed','配对状态和原配置核对通过；断电保留尚未验证。');}
    else this.fail('配对后配置与备份不一致，需要恢复原配置。');
  }
  fail(reason){
    if(this.terminal)return;
    this.#pending=false;this.#operation=null;this.#recovery=this.#changed;this.#phase='failed';this.#record('failed',String(reason));
  }
  cancel(){
    if(this.terminal)return;
    this.#pending=false;this.#operation=null;this.#recovery=this.#changed;this.#phase='cancelled';
    this.#record('cancelled',this.#changed?'已停止；设备可能已变化，请保留备份并核对恢复。':'已停止，未开始配对命令。');
  }
}
