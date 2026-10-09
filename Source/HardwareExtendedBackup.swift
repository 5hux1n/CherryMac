import AppKit

// Separate file inspection and explicitly selected read-only capture.
// Neither adopts a profile or authorizes restoration/configuration writes.
extension HardwareWindowController {
    @objc func captureExtendedBackup(){
        guard !busy,macroRecordingSheet==nil,window?.attachedSheet==nil else{return}
        suspendHostTextForConfiguration();busy=true;controls.forEach{$0.isEnabled=false}
        message.stringValue="正在读取两遍扩展前缀并保存核对；不写入配置…"
        // Wait behind the queued host-text shutdown before opening another
        // USB session, then use the main run loop for the read-only adapter.
        queue.async{[weak self] in DispatchQueue.main.async{[weak self] in
            guard let self else{return}
            defer{self.busy=false;self.controls.forEach{$0.isEnabled=true};self.update()}
            let base=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CherryMac")
            let store=ExtendedHardwareBackupStore(directory:base.appendingPathComponent("ExtendedHardwareBackups"))
            let journal=ExtendedCaptureJournal(directory:base.appendingPathComponent("ExtendedCaptureJournal"))
            do{
                let usb=try ExtendedHardwareUSB()
                let result=try usb.capture(store:store,journal:journal,cancelled:{self.window?.isVisible != true})
                let file=store.directory.appendingPathComponent(result.receipt.backupReference+".json")
                self.message.stringValue="扩展前缀已保存，两遍一致且本机读回核对通过；仍缺四个末字节，不是完整恢复备份。"
                NSWorkspace.shared.activateFileViewerSelecting([file])
            }catch{
                self.message.stringValue="扩展只读捕获未完成："+error.localizedDescription
                if let failure=error as? ExtendedHardwareUSB.OperationFailure{
                    self.message.stringValue+="。日志编号："+failure.operationID
                }
            }
        }}
    }
    @objc func inspectExtendedBackup(){
        guard !busy else{return}
        let directory=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CherryMac/ExtendedHardwareBackups")
        let panel=NSOpenPanel();panel.canChooseDirectories=false;panel.allowsMultipleSelection=false
        panel.message="选择扩展原始备份 JSON；不会连接或修改键盘。";panel.directoryURL=directory
        guard panel.runModal() == .OK,let url=panel.url else{return}
        do{
            let handle=try FileHandle(forReadingFrom:url);defer{try? handle.close()}
            let data=try handle.read(upToCount:128_001) ?? Data()
            guard data.count<=128_000 else{throw HardwareError(message:"扩展备份超过 128 KB。")}
            let snapshot=try JSONDecoder().decode(ExtendedHardwareBackup.self,from:data)
            let names=["parameters":"参数","keymap":"键位","colors":"颜色","macroData":"宏"]
            let coverage=try snapshot.coverage().map{"\(names[$0.region] ?? $0.region)：\($0.storedBytes)/\($0.regionBytes) 字节，未捕获偏移 \($0.missingOffsets.lowerBound)"}.joined(separator:"\n")
            while true{
                let alert=NSAlert();alert.messageText="扩展原始备份";alert.informativeText=coverage+"\n\n"+snapshot.boundaryDescription+"缺失字节不补造；这里只处理已捕获文件，不改变编辑区，不执行完整恢复或配对。"
                for title in ["保存到本机备份库","导出副本…","返回"]{alert.addButton(withTitle:title)}
                let choice=alert.runModal()
                if choice == .alertFirstButtonReturn{
                    let store=ExtendedHardwareBackupStore(directory:directory),id=try store.save(snapshot)
                    guard try store.load(id)==snapshot else{throw HardwareError(message:"本机扩展备份核对失败。")}
                    message.stringValue="扩展备份已保存：\(id)。可再次检查文件从本机库载入；没有读取或写入键盘。"
                    return
                }
                if choice == .alertSecondButtonReturn{
                    let save=NSSavePanel();save.nameFieldStringValue="CherryMac-extended-hardware.json"
                    guard save.runModal() == .OK,let output=save.url else{continue}
                    guard output.standardizedFileURL.resolvingSymlinksInPath() != url.standardizedFileURL.resolvingSymlinksInPath()else{throw HardwareError(message:"副本不能覆盖原始文件。")}
                    let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys];let encoded=try encoder.encode(snapshot)
                    try encoded.write(to:output,options:.atomic)
                    guard try JSONDecoder().decode(ExtendedHardwareBackup.self,from:Data(contentsOf:output))==snapshot else{throw HardwareError(message:"导出副本核对失败。")}
                    message.stringValue="已导出扩展备份副本，全部捕获数据保留；未操作键盘。";return
                }
                return
            }
        }catch{message.stringValue="扩展备份无法载入／保存："+error.localizedDescription}
    }
}
