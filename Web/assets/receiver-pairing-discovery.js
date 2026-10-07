import {receiverPairingRole,resolveReceiverPairingSelection} from './receiver-pairing-selection.js';

// Snapshot adapter for devices supplied by an explicit WebHID picker/getDevices
// caller. Construction/update never requests permission, opens a device or sends.
export class ReceiverPairingDiscovery {
  #entries=new Map();
  #token(){return crypto.randomUUID();}
  update(devices){
    if(!Array.isArray(devices))throw new Error('设备列表无效。');
    const next=new Map();
    for(const device of devices){
      if(!device||next.has(device))continue;
      const base={vendorID:device.vendorId,productID:device.productId,usagePage:0xff1c,usage:0x92};
      if(!receiverPairingRole(base))continue;
      // WebHID collection array positions are not Windows collection numbers.
      const compatible=(device.collections??[]).some(c=>c.usagePage===0xff1c&&c.usage===0x92&&hasReport(c,'inputReports')&&hasReport(c,'outputReports'));
      if(!compatible)continue;
      const previous=this.#entries.get(device);
      next.set(device,{...base,token:previous?.token??this.#token()});
    }
    this.#entries=next;
    return this.candidates;
  }
  get candidates(){return [...this.#entries.values()].map(candidate=>({...candidate}));}
  candidateFor(device){const candidate=this.#entries.get(device);return candidate?{...candidate}:null;}
  remove(device){this.#entries.delete(device);}
  clear(){this.#entries.clear();}
  resolve(selection={}){
    const selected=resolveReceiverPairingSelection(this.candidates,selection);
    const lookup=token=>[...this.#entries].find(([,candidate])=>candidate.token===token)?.[0];
    return {keyboard:lookup(selected.keyboard.token),receiver:lookup(selected.receiver.token),selection:selected};
  }
}
function hasReport(root,kind){
  const pending=[root],seen=new Set();
  while(pending.length){
    const collection=pending.pop();
    if(!collection||seen.has(collection))continue;
    seen.add(collection);
    if(seen.size>256)return false;
    if((collection[kind]??[]).some(report=>report.reportId===4&&Array.isArray(report.items)&&report.items.length>0&&report.items.every(item=>Number.isInteger(item.reportSize)&&item.reportSize>=0&&Number.isInteger(item.reportCount)&&item.reportCount>=0)&&report.items.reduce((sum,item)=>sum+item.reportSize*item.reportCount,0)===504))return true;
    pending.push(...(collection.children??[]));
  }
  return false;
}
