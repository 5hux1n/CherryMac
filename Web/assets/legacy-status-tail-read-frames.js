// Pure, unexecuted0104 candidates. No navigator/HID, general memory reader,
// negative-offset wrapping, keymap-tail request or write/restore authority.
const imageSHA256='31d0a07361ad531fa16867412d46e496737b126efc90482f86baa7e6bd5051bd';
const deviceInfoSHA256='df2355e97afdcb63f8485c1dcf8719615b7ad52c2e190230f1e8125da918c7fa';
function canonical(region){
  const rows={parameters:[63,127],colors:[511,639],macroData:[3071,21587]};
  if(!Object.hasOwn(rows,region))throw new Error('没有这个区域的已确认候选偏移。');
  const [regionOffset,statusOffset]=rows[region],request=Array(64).fill(0);
  request[0]=4;request[3]=0x1d;request[4]=1;request[5]=statusOffset&255;request[6]=statusOffset>>8;
  const sum=request.slice(3).reduce((total,byte)=>total+byte,0);request[1]=sum&255;request[2]=sum>>8;
  return Object.freeze({region,regionOffset,statusOffset,request:Object.freeze(request),imageSHA256,deviceInfoSHA256});
}
export async function legacyStatusTailReadPlan(region,{vendorID,productID,deviceInfo}){
  if(vendorID!==0x046a||productID!==0x01ce||!(Array.isArray(deviceInfo)||deviceInfo instanceof Uint8Array)||deviceInfo.length!==34||!Array.from(deviceInfo).every(byte=>Number.isInteger(byte)&&byte>=0&&byte<=255))throw new Error('候选读取需要目标键盘及匹配的设备信息。');
  const info=Uint8Array.from(deviceInfo);const candidate=canonical(region);
  if(!globalThis.crypto?.subtle)throw new Error('设备信息摘要校验不可用。');
  const digest=await crypto.subtle.digest('SHA-256',info);
  if(Array.from(new Uint8Array(digest),byte=>byte.toString(16).padStart(2,'0')).join('')!==deviceInfoSHA256)throw new Error('设备信息与候选来源不同；匹配也不证明运行固件相同。');
  return candidate;
}
export function legacyStatusTailByte(reply,plan){
  const keys=['region','regionOffset','statusOffset','request','imageSHA256','deviceInfoSHA256'];
  if(!plan||Object.keys(plan).length!==keys.length||keys.some(key=>!Object.hasOwn(plan,key)))throw new Error('候选读取计划不完整。');
  const expected=canonical(plan.region);
  if(keys.some(key=>key==='request'?(!Array.isArray(plan.request)||JSON.stringify(plan.request)!==JSON.stringify(expected.request)):plan[key]!==expected[key])||!(Array.isArray(reply)||reply instanceof Uint8Array)||reply.length!==64||!Array.from(reply).every(byte=>Number.isInteger(byte)&&byte>=0&&byte<=255)||reply[0]!==4)throw new Error('候选读取请求或回复长度无效。');
  if([0xff,0xfe].includes(reply[7]))throw new Error('设备拒绝候选读取；不得重试或补造末字节。');
  if(expected.request.slice(0,8).some((byte,index)=>reply[index]!==byte))throw new Error('候选读取回复头与请求不一致。');
  return reply[8];
}
