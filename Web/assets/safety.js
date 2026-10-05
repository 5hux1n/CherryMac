import {defaultConfigurationReports,reviewDefaultRestoreProgress,reviewDefaultRecoveryProgress,lightingRestoreReports,officialLightingReports,officialLightingReadbackTarget,clone,equal,requireThat,bytes,validateSnapshot,decodeBank,decodeMacroBinding,macroCompletionRequirements,prepareHostTextInstallation} from './model.js?v=0.6.0';
import {keys} from './layout.js?v=0.6.0';
const KEYMAP_SLOTS=new Set(keys.filter(k=>![6,71].includes(k.slot)).map(k=>k.slot));
// Lighting, macros and unknown mutations remain blocked.
// Key writes need an immutable authorization for this exact baseline/target.
export const WRITE_BLOCK_REASON='此功能写入暂缓：灯效、宏和其他设备设置没有开放，仅允许独立键位写入。';
export function assertHardwareWriteAllowed(){throw new Error(WRITE_BLOCK_REASON);}
// Research-only installation by CherryHID. Each accepted reply consumes exactly
// one immutable report; this object does not authorize ordinary product writes.
export class LightingCandidateAuthorization{
  #reports;#index=0;#invalidated=false;
  constructor(plan,baseline){
    officialLightingReadbackTarget(plan,baseline);
    requireThat(baseline.deviceInfo[6]===24&&plan.bank===0&&plan.transportSelector===0&&plan.chunkCapacity===56&&plan.stages.every(stage=>stage.beginRequired),'灯效研究仅允许指定固件、配置 0 和已打开 USB 路径的完整开始／结束布局。');
    this.#reports=officialLightingReports(plan);
  }
  static recovery(recovery){
    const reports=lightingRestoreReports(recovery),scope=new LightingCandidateAuthorization(recovery.sourceRecord.plan,recovery.sourceRecord.original);
    scope.#reports=reports;return scope;
  }
  validate(request){requireThat(!this.#invalidated&&this.#index<this.#reports.length&&equal(Array.from(request),this.#reports[this.#index].request),'灯效报告偏离本次计划顺序或会话已失效，停止发送。');}
  accept(reply,request){
    try{
    this.validate(request);reply=Array.from(reply);const sum=request.slice(3).reduce((n,v)=>n+v,0);
    requireThat(bytes(reply,64)&&reply[0]===4&&reply[3]===request[3]&&equal(reply.slice(4,8),request.slice(4,8))&&reply[7]!==255&&reply[7]!==254&&reply[1]===(sum&255)&&reply[2]===(sum>>8),'灯效候选回复无效。');this.#index++;
    }catch(error){this.#invalidated=true;throw error;}
  }
  invalidate(){this.#invalidated=true;}
  get complete(){return !this.#invalidated&&this.#index===this.#reports.length;}
}
// Packet scope only; callers must bind and check their actual device session.
export class DefaultCandidateAuthorization{
  #reports;#deviceInfo;#index=0;#pending=false;#invalidated=false;
  constructor(review,started){
    const progress=reviewDefaultRestoreProgress(review,started);
    requireThat(progress.configurationMatchesOriginal,'默认恢复授权需要原始完整基线。');
    this.#reports=clone(defaultConfigurationReports(review));this.#deviceInfo=clone(review.original.deviceInfo);
  }
  static recovery(plan,started){
    const progress=reviewDefaultRecoveryProgress(plan,started),scope=new DefaultCandidateAuthorization(plan.sourceReview,plan.sourceReview.original);
    scope.#reports=progress.configurationMatchesOriginal?[]:clone(plan.reports);return scope;
  }
  #check(request){requireThat(!this.#invalidated&&this.#index<this.#reports.length&&equal(Array.from(request),this.#reports[this.#index].request),'默认恢复报告偏离本次计划或授权已失效。');}
  validate(request){try{this.#check(request);}catch(error){this.#invalidated=true;throw error;}}
  begin(request){
    try{this.#check(request);requireThat(!this.#pending,'默认恢复上一包尚未确认，不能重复发送。');this.#pending=true;}
    catch(error){this.#invalidated=true;throw error;}
  }
  accept(reply,request){
    try{
      this.#check(request);requireThat(this.#pending,'默认恢复回复没有对应发送记录。');request=Array.from(request);reply=Array.from(reply);
      const sum=request.slice(3).reduce((n,v)=>n+v,0);
      requireThat(bytes(reply,64)&&reply[0]===4&&reply[3]===request[3]&&equal(reply.slice(4,8),request.slice(4,8))&&reply[7]!==255&&reply[7]!==254&&reply[1]===(sum&255)&&reply[2]===(sum>>8),'默认恢复回复无效。');
      if(request[3]===3)requireThat(equal(reply.slice(8,42),this.#deviceInfo),'默认恢复设备查询与原始资料不一致。');
      this.#pending=false;this.#index++;
    }catch(error){this.#invalidated=true;this.#pending=false;throw error;}
  }
  invalidate(){this.#invalidated=true;this.#pending=false;}
  get complete(){return !this.#invalidated&&!this.#pending&&this.#index===this.#reports.length;}
}
const READ_LIMITS=new Map([[3,34],[5,56],[7,378],[8,378],[0x0a,378],[0x14,3071],[0x1b,126]]);
export function assertReadOnlyRequest(request){
  const limit=READ_LIMITS.get(request?.[3]);
  if(!limit)assertHardwareWriteAllowed();
  const offset=request[5]|request[6]<<8,length=request[4];
  if(request.length!==64||request[0]!==4||request[7]!==0||length<1||length>54||offset+length>limit||request.slice(8).some(v=>v!==0)){
    throw new Error('只读查询格式无效，未发送到键盘。');
  }
  const checksum=request.slice(3).reduce((n,v)=>n+v,0);
  if((request[1]|request[2]<<8)!==checksum)throw new Error('只读查询校验无效，未发送到键盘。');
}

export class KeymapWriteAuthorization{
  #before;#expected;#packets;#changed;
  constructor(before,keymap){
    validateSnapshot(before,true);requireThat(before.deviceInfo[6]===24&&bytes(keymap,378),'需要本型号已验证固件的完整配置。');
    this.#before=clone(before);this.#expected=clone(before);this.#expected.keymap=clone(keymap);this.#changed=[];
    for(let slot=0;slot<126;slot++){
      const r=keymap.slice(slot*3,slot*3+3),old=before.keymap.slice(slot*3,slot*3+3);if(equal(r,old))continue;
      requireThat(KEYMAP_SLOTS.has(slot),'内部功能键与隐藏位置不能改写。');
      requireThat(![0x70,0x71].includes(old[0])&&![0x70,0x71].includes(r[0]),'宏绑定改动暂缓写入，请保留原绑定或撤销相关编辑。');
      requireThat((r[0]===0x20&&(r[2]===0||(r[2]>=4&&r[2]<224)))||r[0]===0x30,'只支持普通键、修饰键组合、媒体键与禁用。');this.#changed.push(slot);
    }
    this.#packets=new Set();
    for(const s of [this.#before,this.#expected])for(let offset=0;offset<378;offset+=54)this.#packets.add(JSON.stringify(Array.from(this.packet(s.keymap,offset))));
  }
  get before(){return clone(this.#before);}get expected(){return clone(this.#expected);}get changedSlots(){return [...this.#changed];}
  packet(map,offset){
    const b=new Uint8Array(64);b[0]=4;b[3]=9;b[4]=54;b[5]=offset&255;b[6]=offset>>8;b.set(map.slice(offset,offset+54),8);
    const sum=b.slice(3).reduce((n,v)=>n+v,0);b[1]=sum&255;b[2]=sum>>8;return b;
  }
  validate(request){requireThat(this.#packets.has(JSON.stringify(Array.from(request))),'写包与本次备份／目标不一致，停止发送。');}
  validateRecovery(current){
    validateSnapshot(current,true);
    requireThat(['deviceInfo','parameters','colors','macroData'].every(k=>equal(current[k],this.#before[k])),'读取到操作范围之外的配置变化，停止自动覆盖；请保留备份。');
    for(let offset=0;offset<378;offset+=54)this.validate(this.packet(current.keymap,offset));
  }
}

// Separate text-trigger permission. No caller-supplied target keymap is trusted.
export class HostTextWriteAuthorization{
  #before;#expected;#packets=new Set();#changed;#root;#factory;
  constructor(root,factoryKeymap,baseline){
    const plan=prepareHostTextInstallation(root,factoryKeymap,baseline);
    this.#root=plan.officialJSON;this.#factory=plan.factoryKeymap;
    this.#before=plan.before;this.#expected=plan.expected;this.#changed=plan.changedSlots;
    for(const snapshot of [this.#before,this.#expected])for(let offset=0;offset<378;offset+=54)this.#packets.add(JSON.stringify(Array.from(this.packet(snapshot.keymap,offset))));
  }
  get before(){return clone(this.#before);}get expected(){return clone(this.#expected);}get changedSlots(){return [...this.#changed];}
  packet(map,offset){
    const b=new Uint8Array(64);b[0]=4;b[3]=9;b[4]=54;b[5]=offset&255;b[6]=offset>>8;b.set(map.slice(offset,offset+54),8);
    const sum=b.slice(3).reduce((n,v)=>n+v,0);b[1]=sum&255;b[2]=sum>>8;return b;
  }
  validate(request){requireThat(this.#packets.has(JSON.stringify(Array.from(request))),'写包与文本安装备份／目标不一致，停止发送。');}
  recovery(current){
    this.validateRecovery(current);
    // This private-state copy retains the original allowlist; callers cannot
    // grant additional packets by altering the recovery snapshot afterwards.
    return this.#recoveryInstance(current);
  }
  #recoveryInstance(current){
    // Private fields require construction, then replace only verified state.
    const result=new HostTextWriteAuthorization(this.#root,this.#factory,this.#before);
    result.#before=clone(current);result.#expected=clone(this.#before);
    result.#changed=Array.from({length:126},(_,slot)=>slot).filter(slot=>!equal(current.keymap.slice(slot*3,slot*3+3),this.#before.keymap.slice(slot*3,slot*3+3)));
    result.#packets=new Set(this.#packets);
    return result;
  }
  validateRecovery(current){
    validateSnapshot(current,true);
    requireThat(['deviceInfo','parameters','colors','macroData'].every(k=>equal(current[k],this.#before[k])),'文本安装范围之外的配置发生变化，停止恢复。');
    for(let offset=0;offset<378;offset+=54)this.validate(this.packet(current.keymap,offset));
  }
}

// A pure plan for the next macro writer. No transport capability is granted.
export class MacroWriteAuthorization {
  #before;#expected;#disabled;#packets=new Set();#offsets;#beforeDuration;#targetDuration;#beforeCompletion;#targetCompletion;
  constructor(before,target,{allowUnbounded=false}={}){
    validateSnapshot(before,true);validateSnapshot(target,true);
    requireThat(before.deviceInfo[6]===24&&['deviceInfo','parameters','colors'].every(k=>equal(before[k],target[k])),'宏操作必须保留当前设备参数与灯效。');
    this.#before=clone(before);this.#expected=clone(target);this.#disabled=clone(before);
    const libraries=[decodeBank(before.macroData),decodeBank(target.macroData)];
    this.#beforeCompletion=macroCompletionRequirements(before.keymap,libraries[0]);this.#targetCompletion=macroCompletionRequirements(target.keymap,libraries[1]);
    requireThat(allowUnbounded===true||(this.#beforeCompletion.repeatingBindings.length===0&&this.#targetCompletion.repeatingBindings.length===0),'持续与开关宏需要明确停止流程，暂不能使用默认写入。');
    this.#beforeDuration=this.#beforeCompletion.finiteDurationMilliseconds;this.#targetDuration=this.#targetCompletion.finiteDurationMilliseconds;
    for(let slot=0;slot<126;slot++){
      const old=before.keymap.slice(slot*3,slot*3+3),next=target.keymap.slice(slot*3,slot*3+3);
      const wasMacro=[0x70,0x71].includes(old[0]),isMacro=[0x70,0x71].includes(next[0]);
      for(const [r,count] of [[old,libraries[0].length],[next,libraries[1].length]])if([0x70,0x71].includes(r[0])){
        decodeMacroBinding(r,count);
      }
      if(wasMacro||isMacro){requireThat(KEYMAP_SLOTS.has(slot),'内部与隐藏位置的宏绑定不能改写。');this.#disabled.keymap.splice(slot*3,3,0x20,0,0);}
      if(!equal(old,next)){
        requireThat(wasMacro||isMacro,'宏写入不能夹带普通键位修改，请先单独写入按键。');
        requireThat(isMacro||(next[0]===0x20&&(next[2]===0||(next[2]>=4&&next[2]<224)))||next[0]===0x30,'移除宏后的键位记录尚未支持。');
      }
    }
    this.#offsets=[];
    for(let offset=0;offset<3071;offset+=54)if(!equal(before.macroData.slice(offset,offset+54),target.macroData.slice(offset,offset+54)))this.#offsets.push(offset);
    for(const s of [this.#before,this.#expected,this.#disabled])for(let offset=0;offset<378;offset+=54)this.#packets.add(JSON.stringify(Array.from(this.packet(9,s.keymap,offset))));
    for(const s of [this.#before,this.#expected])for(const offset of this.#offsets)this.#packets.add(JSON.stringify(Array.from(this.packet(0x15,s.macroData,offset))));
  }
  get beforeCompletion(){return clone(this.#beforeCompletion);}get targetCompletion(){return clone(this.#targetCompletion);}
  get before(){return clone(this.#before);}get expected(){return clone(this.#expected);}get disabled(){return clone(this.#disabled);}get changedOffsets(){return [...this.#offsets];}get beforeDurationMilliseconds(){return this.#beforeDuration;}get targetDurationMilliseconds(){return this.#targetDuration;}
  packet(command,data,offset){
    requireThat([9,0x15].includes(command)&&bytes(data,command===9?378:3071)&&Number.isInteger(offset)&&offset>=0&&offset<data.length&&offset%54===0,'宏写包参数无效。');
    const b=new Uint8Array(64),length=Math.min(54,data.length-offset);b[0]=4;b[3]=command;b[4]=length;b[5]=offset&255;b[6]=offset>>8;b.set(data.slice(offset,offset+length),8);
    const sum=b.slice(3).reduce((n,v)=>n+v,0);b[1]=sum&255;b[2]=sum>>8;return b;
  }
  validate(request){requireThat(this.#packets.has(JSON.stringify(Array.from(request))),'写包超出本次宏备份、目标或临时禁用范围。');}
  validateRecovery(current){
    validateSnapshot(current,true);
    requireThat(['deviceInfo','parameters','colors'].every(k=>equal(current[k],this.#before[k])),'宏恢复范围外的配置发生变化，停止自动覆盖。');
    for(let offset=0;offset<3071;offset+=54){const block=current.macroData.slice(offset,offset+54);
      requireThat([this.#before,this.#expected].some(s=>equal(block,s.macroData.slice(offset,offset+54))),'宏区出现本次操作之外的数据，停止自动覆盖。');
    }
    for(let offset=0;offset<378;offset+=54)this.validate(this.packet(9,current.keymap,offset));
  }
}
