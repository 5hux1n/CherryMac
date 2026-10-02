<?php
// No account, upload endpoint or server-side configuration storage is needed.
header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-cache');
header('X-Content-Type-Options: nosniff');
header('Referrer-Policy: no-referrer');
header('Permissions-Policy: hid=(self)');
header("Content-Security-Policy: default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'");
?>
<!doctype html>
<html lang="zh-CN">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>CherryMac · 键盘配置</title><link rel="stylesheet" href="assets/style.css?v=0.2.0"><script type="module" src="assets/app.js?v=0.2.0"></script></head>
<body>
<div class="app-shell"><aside class="sidebar"><header class="topbar"><a class="brand" href="./"><span class="brandmark">C</span>CherryMac <span class="webtag">WEB</span></a><a href="https://github.com/5hux1n/CherryMac" target="_blank" rel="noopener noreferrer">GitHub ↗</a></header><div class="tabs navigation" role="tablist" aria-label="配置类别" aria-orientation="vertical"><button role="tab" id="tab-keys" data-tab="keys" aria-selected="true">按键功能</button><button role="tab" id="tab-lights" data-tab="lights" aria-selected="false">灯效</button><button role="tab" id="tab-macros" data-tab="macros" aria-selected="false">宏</button><button role="tab" id="tab-profiles" data-tab="profiles" aria-selected="false">配置与备份</button><button role="tab" id="tab-device" data-tab="device" aria-selected="false">设备与诊断</button></div><p class="sidebar-note">MX 3.0S POKÉMON<br>Wireless</p></aside>
<main>
  <div class="heading"><div><p class="eyebrow">CHERRY MX 3.0S POKÉMON WIRELESS</p><h1 id="page-title">按键功能</h1><p class="subtitle" id="page-description">点选一个按键，设置你习惯的功能。</p></div><div class="connect-area"><span id="connection" class="badge">● 未连接 · 可编辑演示</span><div><button id="connect" class="primary">连接 USB 键盘</button><button id="read" disabled>重新读取</button><button id="disconnect" hidden>断开</button></div></div></div>
  <p class="notice" role="alert"><strong>USB 写入已停用。</strong>当前可读取、编辑和保存配置。灯效异常正在排查，详情见“设备与诊断”。</p>
  <p id="compatibility" class="notice" hidden></p>
  <section id="board-card" class="board-card" aria-label="键盘工程图">
    <div class="board-head"><span class="board-title">点选键盘</span><label id="multi-label" hidden><input type="checkbox" id="multi">多选按键</label></div>
    <div class="board-scroll"><div id="keyboard" class="keyboard" aria-label="可点选键盘"></div></div>
    <div class="board-foot"><span id="selection-label">已选 计算器</span><span id="board-hint">普通键保持正方形 · 点击按键进行设置</span></div>
  </section>
  <div id="workspace" class="workspace">
    <section class="editor-card">
      <div id="pane-keys" role="tabpanel" aria-labelledby="tab-keys"><div class="section-title"><h2>按键功能</h2><span class="badge subtle" id="selected-record"></span></div><p class="muted">设置选中键的输出。Fn 与 CHERRY 键保留内部功能。</p>
        <div class="presets"><button data-record="32,10,33">框选截图 <small>⇧⌘4</small></button><button data-record="32,8,21">刷新 <small>⌘R</small></button><button data-record="48,146,1">系统计算器 <small>媒体键</small></button><button data-record="48,182,0">上一曲</button><button data-record="48,205,0">播放 / 暂停</button><button data-record="48,181,0">下一曲</button><button data-record="48,234,0">音量 −</button><button data-record="48,233,0">音量 ＋</button><button data-record="48,226,0">静音</button><button data-record="32,0,0">禁用按键</button></div>
        <p class="help">刷新预设会让实体键输出 ⌘R，作用于所有应用。macOS 通常不会响应计算器媒体键；需要启动系统计算器时，可用下方快捷操作方案。</p>
        <details><summary>计算器的 Mac 快捷操作方案</summary><p class="help">先在 CherryMac App 中安装“计算器快捷操作”，再把此键设为 ⌃⌥⌘C。网页不能安装 macOS 服务；完整实体启动效果仍待验证。</p><button data-record="32,13,6">设置为 ⌃⌥⌘C</button></details>
        <div class="divider"></div><h3>自定义快捷键</h3><div class="form-row"><label>按键<select id="shortcut-key"></select></label><div class="modifiers"><label><input type="checkbox" value="8" class="modifier">⌘ Command</label><label><input type="checkbox" value="1" class="modifier">⌃ Control</label><label><input type="checkbox" value="4" class="modifier">⌥ Option</label><label><input type="checkbox" value="2" class="modifier">⇧ Shift</label></div><button id="stage-shortcut">保存到编辑区</button></div>
      </div>
      <div id="pane-lights" role="tabpanel" aria-labelledby="tab-lights" hidden><div class="subtabs" role="tablist" aria-label="灯效设置"><button id="tab-light-builtins" role="tab" data-light-tab="builtins" aria-selected="true" aria-controls="light-builtins">内置灯效</button><button id="tab-light-perkey" role="tab" data-light-tab="perkey" aria-selected="false" aria-controls="light-perkey">逐键配色</button></div><div id="light-perkey" role="tabpanel" aria-labelledby="tab-light-perkey" hidden><div class="section-title"><h2>逐键配色</h2><span class="badge subtle" id="light-count">1 键</span></div><p class="muted">先选按键，再选颜色。⌘ 点击可多选。</p>
        <div class="regions"><button data-region="all">全部</button><button data-region="main">主键区</button><button data-region="function">功能键</button><button data-region="num">数字区</button><button data-region="arrows">方向键</button><button data-region="wasd">WASD</button></div>
        <div class="form-row"><label>起点颜色<input id="color" type="color" value="#ffd600"></label><label>HEX<input id="hex" value="#FFD600" maxlength="7"></label><label>终点颜色<input id="end-color" type="color" value="#ff5733"></label></div>
        <details class="advanced"><summary>精细颜色 · RGB 与强度</summary><div class="form-row rgb-row"><label>R<input id="red" type="number" min="0" max="255" value="255"></label><label>G<input id="green" type="number" min="0" max="255" value="214"></label><label>B<input id="blue" type="number" min="0" max="255" value="0"></label><label>颜色强度 <output id="strength-label">100%</output><input id="strength" type="range" min="0" max="100" value="100"></label></div>
        </details><div class="form-row"><label>配色方式<select id="pattern"><option value="solid">自定义颜色</option><option value="horizontal">横向渐变</option><option value="vertical">纵向渐变</option><option value="rainbow">静态彩虹</option><option value="pikachu">皮卡丘配色</option><option value="charizard">喷火龙配色</option></select></label><button id="paint">应用到所选键</button><button id="off">熄灭所选键</button></div>
        </div><div id="light-builtins" role="tabpanel" aria-labelledby="tab-light-builtins"><h2>内置灯效</h2><p class="muted">选择模式，然后调整亮度与速度。</p><div class="form-row"><label>模式<select id="mode"></select></label><label>亮度 <output id="brightness-label">4</output><input id="brightness" type="range" min="0" max="4" value="4"></label><label>慢 ← 速度 → 快<input id="speed" type="range" min="0" max="4" value="2"></label></div>
        <div class="form-row"><label>方向<select id="direction"><option value="">保留原值</option><option value="0">正向</option><option value="1">反向</option></select></label><label>颜色选项<select id="rainbow"><option value="">保留原值</option><option value="0">单色</option><option value="1">彩虹</option></select></label><label>单色颜色<input id="global-color-input" type="color" value="#ffd600"></label><button id="global-color">使用此颜色</button><button id="stage-lights">保存到编辑区</button></div>
        <p class="help">全局亮度与 RGB 颜色强度独立设置。不同模式可能忽略方向、颜色或速度。逐键颜色不代表每键独立动画。</p></div>
      </div>
      <div id="pane-macros" role="tabpanel" aria-labelledby="tab-macros" hidden><div class="section-title"><h2>硬件宏</h2><span class="badge">实验性</span></div><p class="muted">按顺序执行一次。支持键盘按键与延迟，每个按下都需要松开。</p><p id="macro-warning" class="notice" hidden></p>
        <div class="form-row"><label>已保存的宏<select id="macro-list"><option value="">新建宏</option></select></label><label>名称<input id="macro-name" maxlength="80" placeholder="例如：输入 AB"></label></div><div id="macro-steps"></div>
        <div class="form-row"><label>添加按键<select id="macro-key"></select></label><button id="add-pair">添加按下＋松开</button></div>
        <div class="form-row"><button id="save-macro">保存宏</button><button id="assign-macro">分配到所选键</button><button id="delete-macro">删除宏</button></div><p class="help">最多 32 个宏，共用 3071 字节存储区。循环、切换、鼠标宏暂不支持；实体触发与断电保留仍待验证。</p>
      </div>
      <div id="pane-profiles" role="tabpanel" aria-labelledby="tab-profiles" hidden><h2>保存与迁移配置</h2><p class="muted">文件在浏览器本地处理，不会上传到服务器。</p><div class="form-row"><button id="import">导入 JSON 配置</button><button id="export">导出当前配置</button><input type="file" id="file" accept=".json,application/json" hidden></div><p class="help">支持 CherryMac 配置和此型号的 Windows 官方导出文件。Windows 导入前需要读取键盘；不支持的绑定会拒绝整个导入。导入仅更改编辑区。</p><div class="divider"></div><h3>已有本地备份</h3><p class="muted">备份存于当前浏览器与网站的本地数据库。建议下载保存；清理网站数据会删除备份。导入备份仅供预览，当前不能写入或恢复实体键盘。</p><button id="show-backups">查看本地备份</button><div id="backups"></div></div>
<div id="pane-device" role="tabpanel" aria-labelledby="tab-device" hidden><h2>设备与诊断</h2><p class="muted">连接状态、配置读取和问题排查。</p><div class="device-summary"><h3>MX 3.0S Pokémon Wireless</h3><p id="device-status">尚未连接键盘</p><p class="help">配置接口使用 USB 数据线及有线模式。浏览器需要 Chrome 或 Edge。</p></div><details class="advanced"><summary>为什么暂时不能写入</summary><p class="help">0.1.0 写入灯效后发生过键盘熄灯、无法使用的情况。原因尚未确认，当前停用全部硬件写入。请关闭旧版页面，保留已恢复正常的配置。</p></details><div class="divider"></div><h3>排查资料</h3><p class="muted">下载本地备份、编辑区配置及新版只读查询记录，便于对比。文件包含按键与宏内容，仅保存到你的电脑，不会自动上传。</p><button id="diagnostics">导出排查资料</button><div class="divider"></div><h3>其他设备设置</h3><p class="help">Win 锁、6 键／全键模式、回报率等官方功能正在核对协议，确认后会在此提供；当前不会改写这些设置。</p></div>
    </section>
    <aside id="review-card" class="review-card"><p class="eyebrow">当前改动</p><h2 id="change-title">USB 写入已停用</h2><div id="changes" class="changes"></div><p id="draft-note" class="help">当前仅允许读取与编辑配置。</p><label class="write-scope">原写入分类<select id="scope"><option value="all">全部待写入配置</option><option value="keys">仅键位与宏</option><option value="lights">仅灯效与颜色</option></select></label><button id="write" class="primary wide" disabled>USB 写入已停用</button><button id="discard" class="wide">撤销编辑区修改</button><p class="help">关闭网页不会撤销此前已写入的设置。请保留已恢复正常的配置与旧备份，排查期间不要再次写入。</p></aside>
  </div>
  <div id="status" class="status" role="status" aria-live="polite">演示模式 · 连接不会自动写入</div>
  <footer><span>CherryMac Web 0.2.0 · 界面预览版 · USB 只读 · 与 CHERRY 官方无关联</span><span>USB 有线 · Chrome / Edge · HTTPS / localhost</span></footer>
</main></div>
<dialog id="confirm"><h2>准备写入键盘</h2><p id="confirm-summary"></p><p>请松开全部按键，包括 Ctrl、Alt、Win 和 Shift，然后用鼠标点击下方按钮。写入期间不要按键，保持此页面在前台。</p><p class="help">浏览器只能检查本页面内的按键事件，无法确认全系统按键是否已释放。写入前会保存备份，完成后完整读回核对。</p><div class="form-row"><button id="cancel-write">返回编辑</button><button id="confirm-write" class="primary">全部已松开，开始写入</button></div></dialog>
</body></html>
