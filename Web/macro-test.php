<?php
// Research route remains closed unless explicitly enabled for accepted tests.
if (getenv('CHERRY_MACRO_TEST') !== '1') { http_response_code(403); header('Content-Type: text/plain; charset=utf-8'); echo '宏实体验收入口尚未开放，请使用主配置页面。'; exit; }
header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
header('X-Content-Type-Options: nosniff');
header('Referrer-Policy: no-referrer');
header('Permissions-Policy: hid=(self)');
header("Content-Security-Policy: default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'");
?>
<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>CherryMac · 宏测试</title><link rel="stylesheet" href="assets/style.css?v=0.5.0"><script type="module" src="assets/macro-test-entry.js?v=0.5.0"></script></head><body><main><a href="./">← 返回键盘配置</a><section id="macro-test" class="editor-card"></section></main></body></html>
