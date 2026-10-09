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

export function checkedReceiverPairingSelection(input){
  const invalid=()=>{throw new Error('配对设备身份不完整或无效。');};
  if(!input||Object.keys(input).length!==2||!Object.hasOwn(input,'keyboard')||!Object.hasOwn(input,'receiver'))invalid();
  const candidate=value=>{
    const keys=['token','vendorID','productID','usagePage','usage'];
    if(!value||Object.keys(value).length!==keys.length||keys.some(key=>!Object.hasOwn(value,key))||typeof value.token!=='string'||!value.token||new TextEncoder().encode(value.token).length>128||keys.slice(1).some(key=>!Number.isInteger(value[key])||value[key]<0||value[key]>65535))invalid();
    return Object.freeze(Object.fromEntries(keys.map(key=>[key,value[key]])));
  };
  const keyboard=candidate(input.keyboard),receiver=candidate(input.receiver);
  if(receiverPairingRole(keyboard)!=='keyboard'||receiverPairingRole(receiver)!=='receiver'||keyboard.token===receiver.token)invalid();
  return Object.freeze({keyboard,receiver});
}
export function sameReceiverPairingSelection(left,right){
  left=checkedReceiverPairingSelection(left);right=checkedReceiverPairingSelection(right);
  return ['keyboard','receiver'].every(role=>Object.keys(left[role]).every(key=>left[role][key]===right[role][key]));
}
