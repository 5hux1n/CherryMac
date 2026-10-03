import {MacroTestFlow} from './macro-test-flow.js?v=0.5.0';
const root=document.querySelector('#macro-test');
if(isSecureContext&&'hid' in navigator)new MacroTestFlow(root);
else root.textContent='请在本机 localhost 或 HTTPS 上使用支持 WebHID 的浏览器。';
