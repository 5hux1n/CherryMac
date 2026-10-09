import AppKit

// Separate file inspection and explicitly selected read-only capture.
// Neither adopts a profile or authorizes restoration/configuration writes.
extension HardwareWindowController {
    @objc func inspectExtendedCaptureJournal(){
        guard !busy,macroRecordingSheet==nil,window?.attachedSheet==nil else{return}
        let directory=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CherryMac/ExtendedCaptureJournal")
        let panel=NSOpenPanel();panel.canChooseDirectories=true;panel.canChooseFiles=false;panel.allowsMultipleSelection=false
        panel.directoryURL=directory;panel.message="选择一次扩展捕获的日志文件夹；这里只检查已有记录。"
        guard panel.runModal() == .OK,let folder=panel.url else{return}
        do{
            let journal=ExtendedCaptureJournal(directory:folder.deletingLastPathComponent())
            let records=try journal.load(id:folder.lastPathComponent)
            guard let last=records.last else{throw HardwareError(message:"日志没有已保存事件。")}
            let count=records.filter{$0.event.phase=="readAccepted"}.count
            let phases=["started":"开始","readPrepared":"待读取回复","readAccepted":"已接受读取","saving":"保存中","saved":"已保存，待核对","complete":"记录显示流程结束","failed":"失败","cancelled":"已取消"]
            let summary="日志编号：\(last.id)\n记录的 USB 版本：\(String(format:"%04X",last.identity.usbRevision))\n已接受读取：\(count)/160\n最后阶段：\(phases[last.event.phase] ?? last.event.phase)\n备份编号：\(last.event.backupReference ?? "尚无")\n\(last.event.detail)\n\n这里只检查历史日志，不连接键盘。记录结束不等于当前配置核对、完整恢复或断电验收。"
            while true{
                let alert=NSAlert();alert.messageText="扩展捕获日志";alert.informativeText=summary
                for title in ["导出日志 JSON…","打开日志文件夹","返回"]{alert.addButton(withTitle:title)}
                let choice=alert.runModal()
                if choice == .alertSecondButtonReturn{NSWorkspace.shared.open(folder);return}
                guard choice == .alertFirstButtonReturn else{return}
                let save=NSSavePanel();save.nameFieldStringValue="CherryMac-extended-capture-log.json"
                guard save.runModal() == .OK,let output=save.url else{continue}
                guard output.deletingLastPathComponent().resolvingSymlinksInPath() != folder.resolvingSymlinksInPath() else{throw HardwareError(message:"请将导出副本放在原日志文件夹以外，保留原始事件。")}
                let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
                let data=try encoder.encode(records);guard data.count<=2_000_000 else{throw HardwareError(message:"导出日志超过 2 MB。")}
                try data.write(to:output,options:.atomic)
                guard try Data(contentsOf:output)==data else{throw HardwareError(message:"日志副本保存核对失败。")}
                message.stringValue="已导出扩展捕获日志；可在网页版设备与诊断中检查，没有操作键盘。";return
            }
        }catch{message.stringValue="扩展捕获日志无法检查："+error.localizedDescription+"。原始记录保留。"}
    }
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
