import {MacroTestFlow} from './macro-test-flow.js?v=0.6.0';
const root=document.querySelector('#macro-test');
if(isSecureContext&&'hid' in navigator){try{new MacroTestFlow(root,{scenarioId:new URLSearchParams(location.search).get('scenario')??'ab-twice'});}catch(e){root.textContent=e.message;}}
else root.textContent='请在本机 localhost 或 HTTPS 上使用支持 WebHID 的浏览器。';
