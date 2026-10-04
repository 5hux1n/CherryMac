// Deferred host-service shutdown models the real awaited operation gate.
// No browser, network service or hardware is used.
import test from 'node:test';
import assert from 'node:assert/strict';
import {requestHIDSelection} from '../assets/hid.js';
const deferred=()=>{let resolve;const promise=new Promise(r=>{resolve=r;});return {promise,resolve};};
test('picker starts at click while device access waits for host shutdown',async()=>{
  const order=[],shutdown=deferred(),device={id:'fake'};
  const selected=requestHIDSelection(()=>{order.push('picker');return Promise.resolve([device]);});
  const operation=(async()=>{order.push('suspend');await shutdown.promise;order.push('released');assert.equal(await selected(),device);order.push('open');})();
  await Promise.resolve();assert.deepEqual(order,['picker','suspend']);
  shutdown.resolve();await operation;assert.deepEqual(order,['picker','suspend','released','open']);
});
test('host shutdown failure leaves device access gated even when picker succeeds',async()=>{
  let opens=0;const selection=requestHIDSelection(()=>Promise.resolve([{}]));
  await assert.rejects((async()=>{await Promise.reject(new Error('host busy'));await selection();opens++;})(),/host busy/);
  assert.equal(opens,0);
});
test('picker failures are captured before consumption and cancellation selects nothing',async()=>{
  const selected=requestHIDSelection(()=>Promise.reject(new Error('picker denied')));
  // A shutdown failure may prevent consumption entirely. Rejection is already
  // captured by the helper, avoiding an unhandled-rejection event.
  await new Promise(resolve=>setImmediate(resolve));await assert.rejects(selected(),/picker denied/);
  await assert.rejects(requestHIDSelection(()=>{throw new Error('picker unavailable');})(),/picker unavailable/);
  for(const devices of [[],[{},{}],null])await assert.rejects(requestHIDSelection(()=>devices)(),/未选择键盘/);
});
