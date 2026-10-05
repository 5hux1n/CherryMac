# 在线配置与更新

[打开 CherryMac 在线配置](https://cherrymac.11195666.workers.dev/)

网页版通过 Cloudflare Worker 托管，与本地 PHP 版共用页面和 JavaScript。部署时生成页面，访问者无需 PHP、Node 或构建。请用 Chrome 或 Edge 打开 HTTPS 地址；连接键盘仍需要 USB 有线模式及浏览器选择设备。

在线版目前为 0.29.0 开发预览：按键与宏分别写入，文本可编辑和安装触发键，跨应用文本输入需要 Mac 客户端联动。灯效仅编辑、导出计划；灯效验收与完整恢复默认写入入口没有开放。部署成功不等于新版真机验收通过。

配置、备份和操作日志在浏览器本地处理，不上传 Cloudflare。在线网址与 localhost 的浏览器数据分别保存；迁移前先导出配置与备份，清理网站数据前下载所需资料。服务端只提供页面、静态文件和公开版本清单，不接收键盘配置。页面更新后，完成当前操作、保存草稿，再关闭旧页重新打开；不要在写入中刷新。

后续网页改动随 GitHub 源码同步更新线上部署，本地 App 继续单独打包，PHP ZIP 仍保留。仓库里的 `Web/deploy-cloudflare.sh` 从已提交的 Web 文件生成允许公开的资产，再调用 Wrangler 发布；需要已授权的 Cloudflare 环境。不会上传用户 JSON、私有日志、官方软件、测试脚本或开发依赖。

```sh
sh Web/deploy-cloudflare.sh
```

`/release.json` 提供版本、来源提交、硬件验收状态与页面／脚本哈希。线上缓存设置为 no-store，避免继续使用旧版本资源。源码文件及部署配置更新应先提交，再部署，以保持版本清单的来源可追溯。

托管使用 [Cloudflare Workers Static Assets](https://developers.cloudflare.com/workers/static-assets/)。硬件访问使用浏览器的 [WebHID](https://developer.chrome.com/docs/capabilities/hid)，部署工具不读取或写入键盘。
