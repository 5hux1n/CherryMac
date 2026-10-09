import {extendedCaptureRegions} from './extended-hardware-regions.js?v=0.6.0';

// Normalized report 4 includes its report ID. A future WebHID adapter must
// add the event's ID to its 63-byte payload and bind exchange to the selected
// live session. This module has no device opening, default sender or retry.
export function extendedReadRequest(command,offset,length){
  const region=extendedCaptureRegions.find(row=>row[1]===command);
  if(!region||![command,offset,length].every(Number.isInteger)||offset<0||offset>=region[2]||length<1||length>region[3]||length>region[2]-offset)throw new Error('扩展只读请求超出捕获范围。');
  const frame=new Uint8Array(64);frame[0]=4;frame[3]=command;frame[4]=length;frame[5]=offset&255;frame[6]=offset>>8;
  const checksum=frame.slice(3,8).reduce((sum,byte)=>sum+byte,0);frame[1]=checksum&255;frame[2]=checksum>>8;
  return frame;
}
function bytes(value){
  if(!(Array.isArray(value)||value instanceof Uint8Array)||value.length!==64||!Array.from(value).every(byte=>Number.isInteger(byte)&&byte>=0&&byte<=255))throw new Error('扩展只读报告长度或字节无效。');
  return Array.from(value);
}
export function extendedReadPayload(reply,request){
  const frame=bytes(request),canonical=extendedReadRequest(frame[3],frame[5]+frame[6]*256,frame[4]);
  if(frame.some((byte,index)=>byte!==canonical[index]))throw new Error('扩展只读请求必须是无数据的读取报告。');
  const response=bytes(reply);
  if(response[0]!==4||response[7]!==0||[1,2,3,4,5,6].some(index=>response[index]!==frame[index]))throw new Error('扩展只读回复报告、偏移、状态或校验不一致。');
  return response.slice(8,8+frame[4]);
}
export async function readExtendedFrame(command,offset,length,exchange){
  if(typeof exchange!=='function')throw new Error('扩展只读缺少真实USB报告交换接口。');
  const frame=extendedReadRequest(command,offset,length);
  // Preserve the authorized request even if an asynchronous transport mutates
  // the buffer it receives. Never accept a reply against that mutated buffer.
  return extendedReadPayload(await exchange(frame.slice()),frame);
}
