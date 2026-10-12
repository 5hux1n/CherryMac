import {ReceiverPairingDevices} from './receiver-pairing-devices.js?v=0.6.0';

// The product chooser binds actual WebHID objects. Construction only wires UI.
// Discovery is explicit, and this component never opens devices or sends reports.
export function installReceiverPage({operation,busy,status}){
  const $=id=>document.getElementById(id),key=$('receiver-keyboard'),receiver=$('receiver-receiver'),summary=$('receiver-selection-status');
  let active=false,selection=null;
  const supported=isSecureContext&&!!navigator.hid;
  const token=picker=>picker.value||null;
  const devices=new ReceiverPairingDevices(navigator.hid,{onChange:rows=>{
    if(selection&&!['keyboard','receiver'].every(role=>rows.some(row=>row.token===selection[role].token))){selection=null;summary.textContent='所选设备已断开或改变，请重新选择并核对。';}
    render();
  },onError:error=>{selection=null;summary.textContent=error.message;render();}});
  function render(){
    const rows=devices.candidates;
    for(const [role,picker] of [['keyboard',key],['receiver',receiver]]){
      const previous=token(picker),eligible=rows.filter(row=>row.productID===(role==='keyboard'?0x01ce:0x01cf));
      picker.replaceChildren(new Option(eligible.length?'请选择设备':'未发现已授权的可用接口',''));
      for(const row of eligible)picker.add(new Option(`${role==='keyboard'?'键盘':'接收器'} · ${row.vendorID.toString(16).padStart(4,'0').toUpperCase()}:${row.productID.toString(16).padStart(4,'0').toUpperCase()} · 接口 ${row.token.slice(0,12)}`,row.token));
      if(eligible.some(row=>row.token===previous))picker.value=previous;else if(eligible.length===1)picker.value=eligible[0].token;
      picker.disabled=busy()||!active||!eligible.length;
    }
    for(const id of ['receiver-grant-keyboard','receiver-grant-receiver','receiver-refresh'])$(id).disabled=busy()||!supported;
    $('receiver-selection-check').disabled=busy()||!active||!token(key)||!token(receiver);
    $('receiver-selection-stop').disabled=busy()||!active;
  }
  async function refresh(){
    active=true;selection=null;summary.textContent='正在查看已授权设备…';
    try{await devices.start();summary.textContent='列表已刷新。缺少设备时，分别点击选择键盘和接收器授权。';}
    catch(error){stop();summary.textContent=error.message;throw error;}
  }
  function stop(){active=false;selection=null;devices.stop();summary.textContent='已停止查看，所选连接已清除。';render();}
  for(const [role,id] of [['keyboard','receiver-grant-keyboard'],['receiver','receiver-grant-receiver']])$(id).onclick=()=>{
    if(busy()||!supported)return;
    // requestDevice must run in the click before any awaited host suspension.
    active=true;selection=null;
    const started=devices.start();
    const picked=devices.request(role);
    // Attach rejection handlers immediately while operation serializes UI work.
    const completed=Promise.all([started,picked]);completed.catch(()=>{});
    void operation(async()=>{
      try{const [,candidate]=await completed;const picker=role==='keyboard'?key:receiver;render();picker.value=candidate.token;summary.textContent='设备已选择，请选择另一个设备并核对连接。';}
      catch(error){selection=null;summary.textContent=error.message;throw error;}
    },{localOnly:true});
  };
  $('receiver-refresh').onclick=()=>operation(refresh,{localOnly:true});
  $('receiver-selection-check').onclick=()=>operation(async()=>{
    const keyboardToken=token(key),receiverToken=token(receiver);
    if(!active||!keyboardToken||!receiverToken)throw new Error('请先分别选择键盘和接收器。');
    selection=null;
    try{
      if(!await devices.refresh())throw new Error('设备列表已变化，请重新选择。');
      const resolved=devices.resolve({keyboardToken,receiverToken});selection=resolved.selection;
      summary.textContent='所选连接已核对。尚未发送配对命令；后续配对前仍需完整备份与协议确认。';status('所选连接已核对，尚未配对。');
    }catch(error){selection=null;summary.textContent=error.message;throw error;}
  },{localOnly:true});
  $('receiver-selection-stop').onclick=()=>{if(!busy())stop();};
  for(const picker of [key,receiver])picker.onchange=()=>{selection=null;summary.textContent='选择已修改，请重新核对连接。';render();};
  window.addEventListener('pagehide',stop);
  if(!supported)summary.textContent='此浏览器不能选择 WebHID 设备。请使用 HTTPS 页面上的桌面 Chrome 或 Edge。';
  render();return {render,stop};
}
