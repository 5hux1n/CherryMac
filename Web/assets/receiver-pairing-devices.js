import {ReceiverPairingDiscovery} from './receiver-pairing-discovery.js';

// Explicit lifecycle for the future pairing page. No access occurs on import or
// construction. This class only discovers/selects; it never opens or writes.
export class ReceiverPairingDevices {
  #hid;#discovery=new ReceiverPairingDiscovery();#active=false;
  #disconnected=new WeakSet();
  #epoch=0;#revision=0;#picker=null;#onChange;#onError;
  constructor(hid,{onChange=()=>{},onError=()=>{}}={}){
    this.#hid=hid;this.#onChange=onChange;this.#onError=onError;
  }
  get candidates(){return this.#discovery.candidates;}
  #publish(){this.#onChange(this.candidates);}
  #connect=event=>{if(!this.#active)return;this.#disconnected.delete(event.device);void this.refresh().catch(error=>this.#onError(error));};
  #disconnect=event=>{
    if(!this.#active)return;
    ++this.#revision; // Invalidate an earlier getDevices snapshot immediately.
    this.#disconnected.add(event.device);
    this.#discovery.remove(event.device);this.#publish();
    void this.refresh().catch(error=>this.#onError(error));
  };
  async start(){
    if(this.#active)return this.refresh();
    if(!this.#hid?.getDevices||!this.#hid?.requestDevice)throw new Error('此浏览器未提供 WebHID，请使用支持 WebHID 的桌面浏览器。');
    this.#disconnected=new WeakSet();
    this.#active=true;++this.#epoch;
    this.#hid.addEventListener('connect',this.#connect);
    this.#hid.addEventListener('disconnect',this.#disconnect);
    return this.refresh();
  }
  async refresh(){
    if(!this.#active)return false;
    const epoch=this.#epoch,revision=++this.#revision;
    try{
      const devices=await this.#hid.getDevices();
      if(!this.#active||epoch!==this.#epoch||revision!==this.#revision)return false;
      this.#discovery.update(devices.filter(device=>!this.#disconnected.has(device)));this.#publish();return true;
    }catch(error){
      if(!this.#active||epoch!==this.#epoch||revision!==this.#revision)return false;
      this.#discovery.clear();this.#publish();throw error;
    }
  }
  // Call directly from the click handler so transient user activation survives.
  async request(role){
    if(!this.#active)throw new Error('请先打开配对设备选择页面。');
    if(role!=='keyboard'&&role!=='receiver')throw new Error('设备类型无效。');
    if(this.#picker)throw new Error('请先完成当前设备选择。');
    const epoch=this.#epoch,picker=Symbol('picker');this.#picker=picker;
    try{
      const devices=await this.#hid.requestDevice({filters:[{vendorId:0x046a,productId:role==='keyboard'?0x01ce:0x01cf,usagePage:0xff1c,usage:0x92}]});
      if(!this.#active||epoch!==this.#epoch)throw new Error('配对页面已关闭，请重新选择设备。');
      if(devices.length!==1)throw new Error('未选择设备，配对没有开始。');
      if(!await this.refresh())throw new Error('设备列表发生变化，请重新选择。');
      if(!this.#active||epoch!==this.#epoch)throw new Error('配对页面已关闭，请重新选择设备。');
      const candidate=this.#discovery.candidateFor(devices[0]);
      if(!candidate||candidate.productID!==(role==='keyboard'?0x01ce:0x01cf))throw new Error('此设备未提供所需的配对报告接口，或已断开连接。');
      return candidate;
    }finally{if(this.#picker===picker)this.#picker=null;}
  }
  resolve(selection={}){
    if(!this.#active)throw new Error('配对设备列表已关闭，请重新选择。');
    return this.#discovery.resolve(selection);
  }
  stop(){
    this.#active=false;++this.#epoch;++this.#revision;this.#picker=null;
    this.#hid?.removeEventListener?.('connect',this.#connect);
    this.#hid?.removeEventListener?.('disconnect',this.#disconnect);
    this.#discovery.clear();this.#publish();
  }
}
