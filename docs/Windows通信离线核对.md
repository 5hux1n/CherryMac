# Windows 通信离线核对

这是为最后统一验收准备的开发工具。现在不用抓包或修改键盘；仅有 JSON 导出、稳定读回或程序工作缓冲区，还不能证明官方软件实际发送了某项设置。

`Tools/inspect-windows-usb-capture.py` 读取已有 USBPcap 抓包，提取指定 USB bus／设备地址的 Report 4，按命令计数并保留原始报告、捕获序号、时间、URB 身份和完成状态。对已有命令 06 的结构单独列出候选参数偏移与内容，便于核对回报率所在的 53／54 是否真的被发送。该分类不证明型号、命令接受或保存成功。

用法（地址必须来自该份抓包，不用 Mac 的 registry ID）：

```sh
python3 Tools/inspect-windows-usb-capture.py /私有目录/official.pcap --bus 1 --device 7 > /私有目录/official-analysis.json
```

目前支持经典 pcap 2.4／USBPcap LINKTYPE 249，大小上限 256 MB。若文件是 pcapng，可以在 Wireshark 中离线另存为 pcap，不需要重新捕获。文件格式依据 [USBPcap 原厂格式说明](https://desowin.org/usbpcap/captureformat.html) 与 [原厂头文件](https://github.com/desowin/usbpcap/blob/master/USBPcapDriver/include/USBPcap.h)。所选设备的截断报告或长度不符会中止；文件解析失败不会输出部分成功结果。

工具区分 interrupt OUT 提交、interrupt IN 完成，以及完整 HID SET_REPORT 的控制 SETUP 数据。63 字节或其他非完整控制数据保留 SETUP 与原始片段／摘要，不补造 Report ID 或填补截断包。不匹配的控制完成、旧版分阶段 DATA、Feature 报告和其他流量暂不解码，也不把它们当作“没有配置指令”。同一个 IRP 的 USB 完成不是键盘协议回复，当前版本不自动关联请求与回复，更不把完成状态当写入验收。

只计数其他设备的包，不输出其 payload。指定地址本身不能证明 VID/PID；拔插后地址可能变化，不能跨地址拼接成同一会话。原始抓包和分析 JSON 含本机通信／配置，应留在私有 work 目录，不提交 GitHub。工具不调用 USB、抓包软件、驱动或硬件接口，也没有重放功能。

2026-10-10：首版代码和语法检查完成。工作区没有可用于本工具的真实 Windows 抓包，尚未执行真实文件解析或行为测试；不生成合成抓包测试。本工具不编入公开 App／PHP，公开版本保持 0.96.0。后置验收获得真实官方通信后，再核对设置写入、未知命令、异常回复及读回／断电表现，不据该工具的存在宣布协议或成品完成。
