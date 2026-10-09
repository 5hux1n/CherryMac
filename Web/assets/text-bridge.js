import {checkedReceiverInventory} from './receiver-inventory.js?v=0.6.0';
import {requireThat} from './model.js?v=0.6.0';
import {checkedCaptureIdentity} from './extended-hardware-capture.js?v=0.6.0';

// No requests at construction. Optional session storage retains the paired tab
// across reloads, without localStorage or cookies. Commands never write HID.
export class HostTextBridge{
  constructor({fetchImpl=globalThis.fetch.bind(globalThis),storage=null}={}){
    this.fetch=fetchImpl;this.storage=storage;this.client=crypto.randomUUID();this.token=null;this.paired=false;this.resuming=false;this.state='stopped';this.tail=Promise.resolve();
    try{const value=JSON.parse(storage?.getItem('CherryMacHostTextBridgeSession')??'null');if(value&&/^[a-f0-9]{64}$/i.test(value.token)&&/^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i.test(value.client)){this.token=value.token;this.client=value.client;this.paired=true;this.resuming=true;}}catch{}
  }
  save(){if(this.storage)this.storage.setItem('CherryMacHostTextBridgeSession',JSON.stringify({token:this.token,client:this.client}));}
  async resume(){if(this.resuming){await this.request('pair');this.save();this.resuming=false;}}
  async request(command,body={},token=this.token,{keepalive=false}={}){
    requireThat(token&&/^[a-f0-9]{64}$/i.test(token),'请先输入本次运行的 Mac 联动码。');
    const run=async()=>{
      const controller=new AbortController(),timer=setTimeout(()=>controller.abort(),8000);
      try{
        const response=await this.fetch(`http://127.0.0.1:32247/v1/${command}`,{method:'POST',mode:'cors',credentials:'omit',cache:'no-store',redirect:'error',targetAddressSpace:'loopback',keepalive,headers:{'Content-Type':'application/json','X-CherryMac-Token':token,'X-CherryMac-Client':this.client},body:JSON.stringify(body),signal:controller.signal});
        const value=await response.json();if(!response.ok&&this.paired)this.resuming=true;requireThat(response.ok,value.error??'Mac 服务拒绝此操作。');
        requireThat(value.format==='CherryMacHostTextBridge'&&value.version===1&&['stopped','preparing','observing','failed'].includes(value.state)&&typeof value.busy==='boolean','Mac 联动回复无效。');
        this.state=value.state;return value;
      }catch(error){if(this.paired)this.resuming=true;if(error instanceof TypeError||error.name==='AbortError')throw new Error('无法联系 Mac 联动服务。请确认客户端已开启网页联动；配置操作已停止。');throw error;}
      finally{clearTimeout(timer);}
    };
    const pending=this.tail.then(run,run);this.tail=pending.catch(()=>{});return pending;
  }
  async pair(code){const token=code.trim();requireThat(!this.paired||this.resuming||token===this.token,'请先解除当前联动。');await this.request('pair',{},token);this.token=token;this.paired=true;this.resuming=true;this.save();this.resuming=false;}
  async status(){requireThat(this.paired,'网页尚未联动。');await this.resume();return this.request('status');}
  async usbIdentity(){
    requireThat(this.paired,'请先连接 Mac 联动服务，以核对真实 USB 身份。');
    await this.resume();const value=await this.request('usb-identity');
    requireThat(value.state==='stopped'&&!value.busy,'客户端尚未释放配置接口。');
    return checkedCaptureIdentity(value.usbIdentity);
  }
  async receiverInventory(){
    requireThat(this.paired,'请先连接 Mac 联动服务，以查看接收器。');
    await this.resume();const value=await this.request('receiver-inventory');
    requireThat(value.state==='stopped'&&!value.busy,'客户端尚未释放配置接口。');
    return checkedReceiverInventory(value.receiverInventory);
  }
  async activate(root){requireThat(this.paired,'请先连接 Mac 服务。');await this.resume();return this.request('activate',{officialJSON:root});}
  async suspend(){if(!this.paired)return;await this.resume();const value=await this.request('suspend');requireThat(value.state==='stopped'&&!value.busy,'Mac 服务尚未释放配置接口。');}
  async unpair(options={}){if(!this.paired)return;await this.resume();const value=await this.request('unpair',{},this.token,options);requireThat(value.state==='stopped'&&!value.busy,'Mac 服务尚未停止。');this.storage?.removeItem('CherryMacHostTextBridgeSession');this.paired=false;this.resuming=false;this.token=null;}
}
