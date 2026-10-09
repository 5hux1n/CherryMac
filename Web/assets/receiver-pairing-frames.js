// Pure fixed Utility packets. No navigator access or default HID sender.
// The eventual transport owns endpoint identity, reply correlation, durable
// backup and command authorization; this module provides none of those grants.
export function receiverPairingFrame(phase,selector=null){
  let command,endpoint;
  if(['keyboardStart','receiverPrepare','receiverStart'].includes(phase)){
    if(!Number.isInteger(selector)||selector<0||selector>65535)throw new Error('配对命令缺少已核对的通信选择字段。');
    command=phase==='receiverPrepare'?(selector===1?0xa0:0x20):(selector===1?0xa1:0x21);
    endpoint=phase==='keyboardStart'?'keyboard':'receiver';
  }else if(phase==='polling'){
    if(selector!==null)throw new Error('配对查询不使用启动命令选择字段。');
    command=0xaa;endpoint='receiver';
  }else throw new Error('这个配对阶段没有已确认的报告。');
  const request=Array(64).fill(0);request[0]=4;request[3]=command;
  const checksum=request.slice(3).reduce((sum,byte)=>sum+byte,0);request[1]=checksum&255;request[2]=checksum>>8;
  return Object.freeze({phase,endpoint,selector,request:Object.freeze(request)});
}
export function receiverPairingReply(input,plan,{transportSucceeded}={}){
  if(!plan||Object.keys(plan).length!==4||!Array.isArray(plan.request))throw new Error('配对请求与固定报告不一致。');
  const canonical=receiverPairingFrame(plan.phase,plan.selector);
  if(plan.endpoint!==canonical.endpoint||plan.request.length!==64||Array.from(plan.request).some((byte,index)=>byte!==canonical.request[index]))throw new Error('配对请求与固定报告不一致。');
  if(transportSucceeded!==true||!(Array.isArray(input)||input instanceof Uint8Array)||input.length!==64||!Array.from(input).every(byte=>Number.isInteger(byte)&&byte>=0&&byte<=255))throw new Error('配对交换未完成或回复报告长度无效。');
  const bytes=Array.from(input);if(bytes[0]!==4)throw new Error('配对回复报告 ID 无效。');
  if([0xff,0xfe].includes(bytes[7])){
    const error=new Error(`设备拒绝配对报告（${bytes[7]===0xff?-102:-103}）。`);error.code=bytes[7]===0xff?-102:-103;throw error;
  }
  // The audited Windows predicates do not establish command/checksum echoes.
  // Preserve them as opaque bytes until the actual transport proves binding.
  return {bytes,status:bytes[7],replyCommand:bytes[3],paired:plan.phase==='polling'?bytes[8]===0xff:null};
}
