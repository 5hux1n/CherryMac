// Checks authenticated companion metadata only; no navigator/device opening.
export function checkedReceiverInventory(value){
  const fail=()=>{throw new Error('Mac 接收器描述信息不完整或无效。');};
  const exact=(object,keys)=>object&&typeof object==='object'&&!Array.isArray(object)&&Object.keys(object).length===keys.length&&keys.every(key=>Object.hasOwn(object,key));
  if(!exact(value,['format','version','opensDevice','sendsReports','entries'])||value.format!=='CherryMacUSBReceiverInventory'||value.version!==1||value.opensDevice!==false||value.sendsReports!==false||!Array.isArray(value.entries)||value.entries.length>16)fail();
  const seen=new Set(),entries=Array.from(value.entries).map(entry=>{
    if(!exact(entry,['role','sessionToken','vendorID','productID','usbRevision','transport','configurationReportSupported','descriptorBytes','descriptorSHA256'])||!['keyboard','receiver'].includes(entry.role)||entry.vendorID!==0x046a||entry.productID!==(entry.role==='keyboard'?0x01ce:0x01cf)||entry.transport!=='USB'||!Number.isInteger(entry.usbRevision)||entry.usbRevision<0||entry.usbRevision>65535||typeof entry.configurationReportSupported!=='boolean'||!Number.isInteger(entry.descriptorBytes)||entry.descriptorBytes<0||entry.descriptorBytes>65536||typeof entry.sessionToken!=='string'||!/^[1-9][0-9]{0,19}$/.test(entry.sessionToken)||BigInt(entry.sessionToken)>18446744073709551615n||seen.has(entry.sessionToken))fail();
    if(entry.descriptorBytes===0?(entry.descriptorSHA256!==null||entry.configurationReportSupported):(typeof entry.descriptorSHA256!=='string'||!/^[0-9a-f]{64}$/.test(entry.descriptorSHA256)))fail();
    seen.add(entry.sessionToken);return Object.freeze({...entry});
  });
  return Object.freeze({...value,entries:Object.freeze(entries)});
}
export function receiverInventorySummary(value){
  const inventory=checkedReceiverInventory(value);
  const counts=[['keyboard','键盘'],['receiver','接收器']].map(([role,name])=>{
    const rows=inventory.entries.filter(entry=>entry.role===role);
    return rows.length?`${name}：发现 ${rows.length} 个 USB 接口，其中 ${rows.filter(entry=>entry.configurationReportSupported).length} 个具备配置报告接口`:`${name}：未发现 USB 连接`;
  });
  return counts.join('；')+'。仅本次查询有效，不代表已配对或配置保持。';
}
