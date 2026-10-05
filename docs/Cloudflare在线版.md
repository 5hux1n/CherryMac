# 在线配置与更新

[打开 CherryMac 在线配置](https://cherrymac.goforit.si/app/)

[项目官网](https://cherrymac.goforit.si/) 位于根路径，配置工具位于 `/app/`。两者由同一个 Cloudflare Worker 提供；原有 CNAME 保留，开启该子域名代理并绑定 `cherrymac.goforit.si/*` 路由。原 workers.dev 地址也采用相同目录布局。

2026-10-05 按用户提供的正式地址完成部署：来源提交 `6cff1a836a3920442b2eaa3e88107c54f3726900`，Worker 版本标识 `eda0790d-7d4e-4ac2-9f5c-70f7294c2f2e`，应用版本仍为 0.29.0。根目录官网和 `/app/` 工具目录独立生成，首页按钮进入 `/app/`；`/app` 重定向到 `/app/`，旧 PHP 页面地址仍可使用。域名的 CNAME 目标仍为 `5hux1n.github.io`，Cloudflare 代理开启后由 Worker 路由提供内容。后续默认更新这个正式域名，而非让用户切换到 workers.dev 地址。

最新在线 0.31.0 来源为 `b84bce987b8932d6daab3656dc57610250826754`，Worker 版本标识 `6c3741a6-abc4-4342-90f1-064b1d939604`。修正备份导入编辑区残留旧文本草稿的问题；与文件导入共用配置接收流程，先暂停文本联动，备份不含文本定义时清空原文本草稿。导入仍不写入键盘，也不启用文本输入服务。本轮仅做语法、打包完整性和线上文件核对，未进行浏览器行为或真机测试。

最新在线 0.30.0 来源为 `3c66ef9edf079d44c955a4529dfcf859ac05cca2`，Worker 版本标识 `08d68a22-a6f2-4e4c-817c-b54f33e568c9`。统一五类本地数据库的连接管理：打开失败后不永久缓存错误，被占用后迟到的成功连接关闭，版本变化或异常关闭后允许重新打开；不会自动重试配置操作。日志读取事务中止也会返回错误。原数据库名称、版本与记录结构保持。完成语法、依赖、打包和部署文件核对，未运行数据库行为或真机测试。

2026-10-05 已发布 0.29.0，页面与脚本来源提交 `a3594f54ca82d480801f595dd684a8e50d8bb5bb`，Worker 版本标识 `f35d0a15-af0e-4a60-b579-43f24f517fa5`。线上 17 个页面／脚本文件哈希与清单一致；首页、`/index.php`、`/app/` 返回 200，HID 权限和缓存响应头已核对。没有打开浏览器或访问键盘，不计作功能或真机验收。

随后统一了 PHP 预览 ZIP 与线上版的版本来源 `Web/preview-versions.json`。线上发布清单现同步为提交 `a98222931b3a5a46640850e73e366040deb078bc`，Worker 版本标识 `18971a6c-1dc4-4343-9ee5-c37a05a0f554`。页面与脚本没有变化，版本仍为 0.29.0；新增对未提交网页代码及未跟踪运行文件的部署拒绝检查。该提交生成的 PHP ZIP SHA-256 为 `0e5e2af5b1b8833fc902d55939c736c5a57d77791dde4806f5fcd6636c6c19fa`。更新发布工具不扩展硬件验收范围。

网页版通过 Cloudflare Worker 托管，与本地 PHP 版共用页面和 JavaScript。部署时生成页面，访问者无需 PHP、Node 或构建。请用 Chrome 或 Edge 打开 HTTPS 地址；连接键盘仍需要 USB 有线模式及浏览器选择设备。

在线版目前为 0.31.0 开发预览：按键与宏分别写入，文本可编辑和安装触发键，跨应用文本输入需要 Mac 客户端联动。灯效仅编辑、导出计划；灯效验收与完整恢复默认写入入口没有开放。部署成功不等于新版真机验收通过。

配置、备份和操作日志在浏览器本地处理，不上传 Cloudflare。在线网址与 localhost 的浏览器数据分别保存；迁移前先导出配置与备份，清理网站数据前下载所需资料。服务端只提供页面、静态文件和公开版本清单，不接收键盘配置。页面更新后，完成当前操作、保存草稿，再关闭旧页重新打开；不要在写入中刷新。

后续网页改动随 GitHub 源码同步更新线上部署，本地 App 继续单独打包，PHP ZIP 仍保留。仓库里的 `Web/deploy-cloudflare.sh` 从已提交的 Web 文件生成允许公开的资产，再调用 Wrangler 发布；需要已授权的 Cloudflare 环境。不会上传用户 JSON、私有日志、官方软件、测试脚本或开发依赖。

```sh
sh Web/deploy-cloudflare.sh
```

`/release.json` 提供版本、来源提交、硬件验收状态与页面／脚本哈希。线上缓存设置为 no-store，避免继续使用旧版本资源。源码文件及部署配置更新应先提交，再部署，以保持版本清单的来源可追溯。

托管使用 [Cloudflare Workers Static Assets](https://developers.cloudflare.com/workers/static-assets/)。硬件访问使用浏览器的 [WebHID](https://developer.chrome.com/docs/capabilities/hid)，部署工具不读取或写入键盘。
