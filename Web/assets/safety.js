import {clone,equal,requireThat,bytes,validateSnapshot} from './model.js?v=0.3.0';
import {keys} from './layout.js?v=0.3.0';
const KEYMAP_SLOTS=new Set(keys.filter(k=>![6,71].includes(k.slot)).map(k=>k.slot));
// Lighting, macros and unknown mutations remain blocked.
// Key writes need an immutable authorization for this exact baseline/target.
export const WRITE_BLOCK_REASON='此功能写入暂缓：灯效、宏和其他设备设置没有开放，仅允许独立键位写入。';
export function assertHardwareWriteAllowed(){throw new Error(WRITE_BLOCK_REASON);}
const READ_LIMITS=new Map([[3,34],[5,56],[8,378],[0x0a,378],[0x14,3071],[0x1b,126]]);
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
