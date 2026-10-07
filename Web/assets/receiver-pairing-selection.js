// Pure selection policy; no navigator.hid access, report construction or sends.
// Discovery adapters must issue unique tokens for current interface objects.
// A model match identifies a candidate, not an existing wireless bond.
export function receiverPairingRole(candidate){
  if(candidate.vendorID!==0x046a||candidate.usagePage!==0xff1c||candidate.usage!==0x92)return null;
  if(candidate.productID===0x01ce)return 'keyboard';
  if(candidate.productID===0x01cf)return 'receiver';
  return null;
}
export function resolveReceiverPairingSelection(candidates,{keyboardToken=null,receiverToken=null}={}){
  const fail=(code,message)=>{const error=new Error(message);error.code=code;throw error;};
  if(!Array.isArray(candidates))fail('invalidIdentity','设备标识无效或重复，请重新选择设备。');
  const tokens=new Set();
  for(const candidate of candidates){
    if(!candidate||typeof candidate.token!=='string'||!candidate.token.length||tokens.has(candidate.token))
      fail('invalidIdentity','设备标识无效或重复，请重新选择设备。');
    tokens.add(candidate.token);
  }
  const choose=(role,selected)=>{
    const eligible=candidates.filter(candidate=>receiverPairingRole(candidate)===role);
    if(selected!==null){
      const candidate=eligible.find(candidate=>candidate.token===selected);
      if(!candidate)fail('staleSelection','所选设备已不在当前候选列表中，请重新选择。');
      return {...candidate};
    }
    if(!eligible.length)fail(role==='keyboard'?'missingKeyboard':'missingReceiver',role==='keyboard'?'请连接并选择 USB 有线键盘。':'请连接并选择对应的 USB 接收器。');
    if(eligible.length!==1)fail(role==='keyboard'?'ambiguousKeyboard':'ambiguousReceiver',role==='keyboard'?'发现多个键盘接口，请明确选择要配对的键盘。':'发现多个接收器接口，请明确选择要配对的接收器。');
    return {...eligible[0]};
  };
  return {keyboard:choose('keyboard',keyboardToken),receiver:choose('receiver',receiverToken)};
}
