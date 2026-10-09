// All bytes of four known regions; not wireless identity records, a live
// capture, firmware identity, reset/restore permission or a pairing backup.
const keys=['format','version','scope','vendorID','productID','createdAtMilliseconds','deviceInfo','parameters','keymap','colors','macroData'];
const bytes=(value,count)=>Array.isArray(value)&&value.length===count&&Array.from(value).every(byte=>Number.isInteger(byte)&&byte>=0&&byte<=255);
export function validatePairingConfigurationRegions(value){
  if(!value||Object.keys(value).length!==keys.length||keys.some(key=>!Object.hasOwn(value,key))||value.format!=='CherryMacFullConfigurationRegions'||value.version!==1||value.scope!=='keyboard-configuration-regions'||value.vendorID!==0x046a||value.productID!==0x01ce||!Number.isFinite(value.createdAtMilliseconds)||value.createdAtMilliseconds<0||!bytes(value.deviceInfo,34)||!bytes(value.parameters,64)||!bytes(value.keymap,512)||!bytes(value.colors,512)||!bytes(value.macroData,3072))throw new Error('完整配置区记录的型号、范围或数据长度无效。');
}
export function samePairingConfigurationRegionData(first,second){
  validatePairingConfigurationRegions(first);validatePairingConfigurationRegions(second);
  return ['deviceInfo','parameters','keymap','colors','macroData'].every(key=>first[key].every((byte,index)=>byte===second[key][index]));
}
export function pairingConfigurationRegionScope(value){
  validatePairingConfigurationRegions(value);
  return Object.freeze({includesWirelessIdentityRecords:false,authorizesPairing:false});
}
