import {checkedReceiverPairingSelection,sameReceiverPairingSelection} from './receiver-pairing-selection.js';
import {receiverPairingFrame} from './receiver-pairing-frames.js';

// Fixed official startup parameters, deliberately opt-in. No hardware query,
// I/O, write authority or claim that every Windows mutation is known. The wire
// adapter continues to require an explicit selector source.
export class ReceiverPairingInitialProfile {
  #selection;
  constructor(selection){this.#selection=checkedReceiverPairingSelection(selection);}
  get evidence(){
    return Object.freeze({profileID:'pokemon47-official-initial-a92412c6',
      executableSHA256:'a92412c6e3bd05d722c30e0d1ab1762570934b28bd31ea482ad2b51ce187f396',
      origin:'Fixed Utility initial registry metadata word+0x9c; not live hardware readback',
      keyboardRegistryRows:Object.freeze([126,127,128]),receiverRegistryRows:Object.freeze([129,130,131]),
      keyboardSelector:0,receiverSelector:0,hardwareReadbackVerified:false});
  }
  #check(current){
    if(!sameReceiverPairingSelection(checkedReceiverPairingSelection(current),this.#selection))throw new Error('所选配对端点已变化，请重新建立型号参数。');
  }
  selector(endpoint,current){
    this.#check(current);
    if(endpoint==='keyboard')return this.evidence.keyboardSelector;
    if(endpoint==='receiver')return this.evidence.receiverSelector;
    throw new Error('配对端点类型无效。');
  }
  plan(phase,current){
    this.#check(current);
    const endpoint=phase==='keyboardStart'?'keyboard':'receiver';
    return receiverPairingFrame(phase,phase==='polling'?null:this.selector(endpoint,current));
  }
}
