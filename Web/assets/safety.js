// Stop all device mutation after the 0.1.0 lighting malfunction report.
// This is a fixed policy, without URL, local-storage or caller overrides.
export const WRITE_BLOCK_REASON='USB 写入已停用：0.1.0 灯效写入曾导致设备异常，原因仍在排查。当前仅允许读取、预览、导入导出和下载备份。';
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
