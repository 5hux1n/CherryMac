// Separate raw-prefix format. Static boundary identity does not establish the
// installed firmware, a complete region backup or permission to send commands.
const definitions=[['parameters',63,64],['keymap',511,512],['colors',511,512],['macroData',3071,3072]];
const bytes=(value,length)=>Array.isArray(value)&&value.length===length&&Array.from(value).every(byte=>Number.isInteger(byte)&&byte>=0&&byte<=255);
const fields=new Set(['format','version','vendorID','productID','boundaryModel','createdAtMilliseconds','deviceInfo','parameters','keymap','colors','macroData']);
const fail=()=>{throw new Error('扩展备份型号、边界或数据长度无效。');};
export function validateExtendedHardwareBackup(value){
  if(!value)fail();
  const observed=value.version===2,expected=new Set(fields);if(observed)expected.add('usbRevision');
  const boundaryValid=observed?value.boundaryModel==='pokemon-0102-readback'&&value.usbRevision===0x0102:value.version===1&&value.boundaryModel==='pokemon-0104-static';
  if(Object.keys(value).length!==expected.size||Object.keys(value).some(key=>!expected.has(key))||value.format!=='CherryMacExtendedHardware'||!boundaryValid||value.vendorID!==0x046a||value.productID!==0x01ce||!Number.isFinite(value.createdAtMilliseconds)||value.createdAtMilliseconds<0||!bytes(value.deviceInfo,34)||!definitions.every(([name,length])=>bytes(value[name],length)))fail();
}
export function extendedBackupBoundaryDescription(value){
  validateExtendedHardwareBackup(value);
  return value.version===2?'范围依据 Pokémon USB 0102 的实测读取；文件记录的版本不代表当前连接设备身份。':'范围依据旧官方 Pokémon 0104 静态分析，不能据此识别当前固件。';
}
export function extendedBackupCoverage(value){
  validateExtendedHardwareBackup(value);
  return definitions.map(([region,storedBytes,regionBytes])=>({region,storedBytes,regionBytes,missingOffsets:Array.from({length:regionBytes-storedBytes},(_,i)=>storedBytes+i)}));
}
export function extendedBackupMatchesVisible(value,snapshot){
  validateExtendedHardwareBackup(value);
  if(!snapshot||snapshot.format!=='CherryMacHardware'||snapshot.version!==1||snapshot.vendorID!==value.vendorID||snapshot.productID!==value.productID||!bytes(snapshot.deviceInfo,34)||!bytes(snapshot.parameters,56)||!bytes(snapshot.keymap,378)||!bytes(snapshot.colors,378)||!bytes(snapshot.macroData,3071))fail();
  return ['deviceInfo','parameters','keymap','colors','macroData'].every(name=>snapshot[name].every((byte,index)=>byte===value[name][index]));
}
export function sameExtendedCapturedData(first,second){
  validateExtendedHardwareBackup(first);validateExtendedHardwareBackup(second);
  return first.version===second.version&&first.usbRevision===second.usbRevision&&first.boundaryModel===second.boundaryModel&&['deviceInfo','parameters','keymap','colors','macroData'].every(name=>first[name].every((byte,index)=>byte===second[name][index]));
}
