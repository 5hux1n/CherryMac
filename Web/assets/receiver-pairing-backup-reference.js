// A namespace check prevents accidental use of another store's ID. It cannot
// establish actual complete capture, saved data or permission to send reports.
export function validateCompletePairingBackupReference(reference){
  if(typeof reference!=='string'||!/^pairing-complete-backup:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(reference))throw new Error('配对需要独立的完整备份引用；普通、扩展前缀或仅配置区记录不能代替。');
}
