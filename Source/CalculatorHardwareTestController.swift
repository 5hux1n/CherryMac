#if CHERRY_CALCULATOR_TEST
import Cocoa
import IOKit.hid

final class CalculatorHardwareTestController:NSObject,NSApplicationDelegate,NSWindowDelegate {
    let powerCycleMode=CommandLine.arguments.contains("--power-cycle")
    let queue=DispatchQueue(label:"local.cherrymac.calculator-test.usb")
    let inputManager=IOHIDManagerCreate(kCFAllocatorDefault,0)
    let runDirectory:URL = {
        if let i=CommandLine.arguments.firstIndex(of:"--test-dir"),CommandLine.arguments.count>i+1{return URL(fileURLWithPath:CommandLine.arguments[i+1])}
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CherryMac/HardwareTests/CalculatorTest-\(UUID().uuidString)")
    }()
    let status=NSTextField(wrappingLabelWithString:"正在备份并检查，请先不要按键。")
    let details=NSTextField(wrappingLabelWithString:"")
    var window:NSWindow!
    var stopButton:NSButton!
    var powerOffButton:NSButton!
    var powerCycle:CalculatorPowerCycleEvidence?
    var originalSerial=""
    var retention:CalculatorKeyRetention?
    var usb:CherryUSB? // used only on queue; created there so its run loop stays correct.
    var baseline:HardwareSnapshot?
    var mapped:HardwareSnapshot?
    var phase="preflight"
    var traceRows:[[String:Any]]=[]
    var inputs:[[String:Any]]=[]
    var evidence:[String:Any]=[:]
    var held=Set<UInt32>()
    var downs=Set<UInt32>()
    var ups=Set<UInt32>()
    var launchObserved=false
    var activationObserved=false
    var initiallyRunning=false
    var restoring=false
    var cancelRequested=false
    var done=false
    var timer:Timer?
    let observedUsages:Set<UInt32>=[6,224,226,227]
    let lock=NSLock()
    let logLock=NSLock()
    func now()->String {ISO8601DateFormatter().string(from:Date())}
    func appendTrace(_ text:String){lock.lock();traceRows.append(["at":now(),"uptime":ProcessInfo.processInfo.systemUptime,"message":text]);lock.unlock();save()}
    func save(){
        logLock.lock();defer{logLock.unlock()}
        lock.lock();var state=evidence;state["trace"]=traceRows;state["inputEvents"]=inputs;lock.unlock()
        state["format"]="CherryMacCalculatorHardwareTest";state["capturedAt"]=now();state["scope"]="calculator key only; no lighting or macro writes"
        do{try JSONSerialization.data(withJSONObject:state,options:[.prettyPrinted,.sortedKeys]).write(to:runDirectory.appendingPathComponent("test-log.json"),options:.atomic)}catch{fputs("LOG ERROR \(error.localizedDescription)\n",stderr)}
    }
    func record(_ key:String,_ value:Any){lock.lock();evidence[key]=value;lock.unlock();save()}
    func setPhase(_ next:String,_ message:String){phase=next;record("phase",next);status.stringValue=message}
    func applicationDidFinishLaunching(_ n:Notification){
        do{try FileManager.default.createDirectory(at:runDirectory,withIntermediateDirectories:true)}catch{fputs("Cannot save backup: \(error)\n",stderr);NSApp.terminate(nil);return}
        NSApp.setActivationPolicy(.regular)
        let main=NSMenu();let item=NSMenuItem(title:"计算器键测试",action:nil,keyEquivalent:"");let menu=NSMenu(title:"计算器键测试");item.submenu=menu;main.addItem(item)
        let servicesItem=NSMenuItem(title:"服务",action:nil,keyEquivalent:"");let services=NSMenu(title:"服务");servicesItem.submenu=services;menu.addItem(servicesItem);NSApp.servicesMenu=services;NSApp.mainMenu=main
        NSApp.registerServicesMenuSendTypes([.string,.fileURL],returnTypes:[])
        window=NSWindow(contentRect:NSRect(x:0,y:0,width:700,height:335),styleMask:[.titled,.closable],backing:.buffered,defer:false);window.title=powerCycleMode ? "CherryMac · 按键断电保留测试":"CherryMac · 计算器键受控测试";window.delegate=self
        let view=NSView(frame:NSRect(x:0,y:0,width:700,height:335));window.contentView=view
        let title=NSTextField(labelWithString:powerCycleMode ? "计算器键 · 写入与断电保留":"只测试右上角的计算器键");title.font = .systemFont(ofSize:23,weight:.semibold);title.frame=NSRect(x:24,y:273,width:650,height:35);view.addSubview(title)
        let note=NSTextField(wrappingLabelWithString:powerCycleMode ? "等提示再拔 USB、关闭键盘电源，勾选下方确认并等待至少 15 秒，再有线连接。\n内置电池供电时只拔 USB 不算断电。重连后先自动读取，再测试实体键并恢复。\n请勿操作其他配置软件。这里只写计算器键，不写灯效或宏。":"准备完成后，点击此窗口，再按下并完全松开一次计算器键。\n测试期间不要操作旧网页或其他配置软件。灯效和宏不会改动。");note.frame=NSRect(x:24,y:207,width:650,height:56);view.addSubview(note)
        status.font = .systemFont(ofSize:15,weight:.medium);status.frame=NSRect(x:24,y:117,width:650,height:70);view.addSubview(status)
        details.font = .systemFont(ofSize:12);details.textColor = .secondaryLabelColor;details.frame=NSRect(x:24,y:49,width:650,height:58);view.addSubview(details)
        stopButton=NSButton(title:"恢复原映射并结束",target:self,action:#selector(stop));stopButton.frame=NSRect(x:464,y:13,width:210,height:30);view.addSubview(stopButton)
        if powerCycleMode{powerOffButton=NSButton(checkboxWithTitle:"已关闭键盘电源（不只是拔 USB）",target:self,action:#selector(confirmPowerOff));powerOffButton.frame=NSRect(x:24,y:13,width:430,height:30);powerOffButton.isEnabled=false;view.addSubview(powerOffButton)}
        window.center();window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
        record("startedAt",now());record("physicalHardware",true);record("powerCycleMode",powerCycleMode)
        initiallyRunning = !NSRunningApplication.runningApplications(withBundleIdentifier:"com.apple.calculator").isEmpty
        record("calculatorInitiallyRunning",initiallyRunning)
        for name in [NSWorkspace.didLaunchApplicationNotification,NSWorkspace.didActivateApplicationNotification]{
            NSWorkspace.shared.notificationCenter.addObserver(forName:name,object:nil,queue:.main){[weak self] n in
                guard let self,let app=n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,app.bundleIdentifier=="com.apple.calculator",self.phase=="waiting" else{return}
                if n.name==NSWorkspace.didLaunchApplicationNotification{self.launchObserved=true}else{self.activationObserved=true}
                self.record("calculatorLaunchedDuringPhysicalTest",self.launchObserved);self.record("calculatorActivatedDuringPhysicalTest",self.activationObserved)
            }
        }
        IOHIDManagerSetDeviceMatching(inputManager,[kIOHIDVendorIDKey:1130,kIOHIDProductIDKey:462,kIOHIDTransportKey:"USB"] as CFDictionary)
        IOHIDManagerRegisterDeviceRemovalCallback(inputManager,{context,_,_,_ in
            guard let context else{return};let owner=Unmanaged<CalculatorHardwareTestController>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async{owner.pollPowerCycle()}
        },Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerRegisterDeviceMatchingCallback(inputManager,{context,_,_,_ in
            guard let context else{return};let owner=Unmanaged<CalculatorHardwareTestController>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async{owner.pollPowerCycle()}
        },Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerRegisterInputValueCallback(inputManager,{context,result,_,value in
            guard result==0,let context else{return};let self_=Unmanaged<CalculatorHardwareTestController>.fromOpaque(context).takeUnretainedValue()
            let e=IOHIDValueGetElement(value),page=IOHIDElementGetUsagePage(e),u=IOHIDElementGetUsage(e),v=IOHIDValueGetIntegerValue(value)
            guard page==7,self_.observedUsages.contains(u),(v==0 || v==1),self_.phase=="waiting" else{return}
            if v==1{self_.held.insert(u);self_.downs.insert(u)}else{self_.held.remove(u);self_.ups.insert(u)}
            self_.lock.lock();self_.inputs.append(["at":self_.now(),"usage":u,"value":v,"hidTimestamp":String(IOHIDValueGetTimeStamp(value))]);self_.lock.unlock();self_.save()
            self_.record("balancedExpectedSignals",self_.downs==self_.observedUsages && self_.ups==self_.observedUsages && self_.held.isEmpty)
        },Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerScheduleWithRunLoop(inputManager,CFRunLoopGetMain(),CFRunLoopMode.defaultMode.rawValue)
        let opened=IOHIDManagerOpen(inputManager,0);record("inputOpenResult",opened)
        guard opened==0,let devices=IOHIDManagerCopyDevices(inputManager) as? Set<IOHIDDevice>,devices.count==1 else{failWithoutWrites("无法启动实体按键监听，未写入。");return}
        if powerCycleMode,let device=devices.first{
            guard let id=registryID(device) else{failWithoutWrites("无法记录 USB 设备标识，未写入。");return}
            powerCycle=CalculatorPowerCycleEvidence(originalRegistryID:id)
            originalSerial=(IOHIDDeviceGetProperty(device,kIOHIDSerialNumberKey as CFString) as? String ?? "").trimmingCharacters(in:.whitespacesAndNewlines)
            record("originalUSBRegistryID",String(id));record("serialIdentityAvailable",!originalSerial.isEmpty)
        }
        guard let baselineArgument=CommandLine.arguments.firstIndex(of:"--baseline"),CommandLine.arguments.count>baselineArgument+1,FileManager.default.fileExists(atPath:CommandLine.arguments[baselineArgument+1])else{failWithoutWrites("需要 --baseline 指定已核对的配置文件，未写入，也未安装系统服务。");return}
        do{try backupService();try CalculatorService.install();record("calculatorServiceInstalled",true)}catch{failWithoutWrites("计算器系统快捷操作未就绪：\(error.localizedDescription)");return}
        timer=Timer.scheduledTimer(withTimeInterval:1,repeats:true){[weak self] _ in self?.tick()}
        let cancelMenu=Timer(timeInterval:0.15,repeats:false){_ in services.cancelTracking()}
        RunLoop.main.add(cancelMenu,forMode:.common)
        services.popUp(positioning:nil,at:NSPoint(x:26,y:250),in:window.contentView)
        let entry=services.items.first{$0.title==CalculatorService.name}
        let ready=entry?.keyEquivalent.lowercased()=="c" && entry?.keyEquivalentModifierMask.intersection([.command,.control,.option,.shift]) == [.command,.control,.option] && entry?.isEnabled==true
        record("systemServiceMenuReady",ready)
        guard ready else{failWithoutWrites("系统服务菜单中的计算器快捷键未就绪，未写入。需要先核对系统快捷操作。");return}
        queue.async{[weak self] in self?.prepare()}
    }
    func backupService() throws {
        let folder=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Services/\(CalculatorService.name).workflow")
        if FileManager.default.fileExists(atPath:folder.path){try FileManager.default.copyItem(at:folder,to:runDirectory.appendingPathComponent("calculator-service-before.workflow"))}
        let domain="pbs" as CFString
        let original=CFPreferencesCopyAppValue("NSServicesStatus" as CFString,domain) as? [String:Any] ?? [:]
        try PropertyListSerialization.data(fromPropertyList:original,format:.xml,options:0).write(to:runDirectory.appendingPathComponent("service-preferences-before.plist"),options:.atomic)
    }
    func comparable(_ a:HardwareSnapshot,_ b:HardwareSnapshot)->Bool{a.keymap==b.keymap && a.parameters==b.parameters && a.colors==b.colors && a.macroData==b.macroData && a.deviceInfo==b.deviceInfo}
    func prepare(){
        defer{usb=nil}
        do{
            let transport=try CherryUSB();usb=transport;transport.trace={ [weak self] text in self?.appendTrace(text) }
            let before=try transport.completeSnapshot()
            guard let index=CommandLine.arguments.firstIndex(of:"--baseline"),CommandLine.arguments.count>index+1 else{throw HardwareError(message:"需要 --baseline 指定已经核对的 CherryMac 配置，未写入。")}
            let reference=try HardwareProfile.decode(Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[index+1]))).snapshot
            guard comparable(before,reference) else{throw HardwareError(message:"配置与刚核对的测试前基线不同，未写入。")}
            baseline=before
            let file=runDirectory.appendingPathComponent("before.json");let profile=HardwareProfile(snapshot:before);try profile.encoded().write(to:file,options:.atomic)
            guard comparable(try HardwareProfile.decode(Data(contentsOf:file)).snapshot,before) else{throw HardwareError(message:"备份读回校验失败，未写入。")}
            record("baselineBackup",file.path);record("baselineMatchesUserExport",true)
            let authorization=try CalculatorKeyTestAuthorization(baseline:before)
            lock.lock();let cancelled=cancelRequested;lock.unlock()
            guard !cancelled else{throw HardwareError(message:"测试已取消，未写入。")}
            try transport.waitUntilKeysReleased();try transport.authorizeCalculatorTest(baseline:before)
            // This is the production writer, including stale-baseline and release checks.
            let after=try transport.writeKeymap(authorization.expected.keymap,baseline:before);mapped=after
            try HardwareProfile(snapshot:after).encoded().write(to:runDirectory.appendingPathComponent("mapped.json"),options:.atomic)
            record("mappedReadbackMatches",comparable(after,authorization.expected))
            DispatchQueue.main.async{
                self.record("waitingSince",ProcessInfo.processInfo.systemUptime)
                if self.powerCycleMode{self.setPhase("waiting-disconnect","写入并读回成功。现在请拔下键盘 USB，并关闭键盘电源。\n断开后勾选下方确认，等至少 15 秒，再开电并有线连接。");self.details.stringValue="已关闭写入会话。重连后会先读取，不会先重写目标映射。"}
                else{self.setPhase("waiting","准备完成：请按下并完全松开一次计算器键。\n系统应启动计算器；随后程序自动恢复原映射。");self.details.stringValue="临时映射：⌃⌥⌘C。日志和备份已保存。不要按住按键。"}
                self.window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
                if self.cancelRequested{self.stop()}
            }
        }catch{
            record("prepareError",error.localizedDescription)
            recoverAfterError(error.localizedDescription)
        }
    }
    func tick(){
        if powerCycleMode,["waiting-disconnect","waiting-reconnect"].contains(phase){
            pollPowerCycle()
            if phase=="waiting-reconnect",let off=powerCycle?.powerOffConfirmedAt{
                let elapsed=Int(ProcessInfo.processInfo.systemUptime-off)
                details.stringValue=elapsed>=15 ? "已等待 \(elapsed) 秒。现在可开电、接 USB 并切换有线模式。":"电源关闭确认已记录。再等 \(15-elapsed) 秒后连接。"
            }
            return
        }
        guard phase=="waiting",!restoring else{return}
        lock.lock();let since=evidence["waitingSince"] as? Double ?? ProcessInfo.processInfo.systemUptime;lock.unlock()
        let balanced=downs==observedUsages && ups==observedUsages && held.isEmpty
        if balanced {
            lock.lock();let detected=evidence["physicalReleaseSince"] as? Double;lock.unlock()
            if detected==nil{record("physicalReleaseSince",ProcessInfo.processInfo.systemUptime)}
            if launchObserved || activationObserved || (detected != nil && ProcessInfo.processInfo.systemUptime-detected!>12){beginRestore()}
        }else if ProcessInfo.processInfo.systemUptime-since>180 || cancelRequested{beginRestore()}
    }
    @objc func stop(){
        if done{NSApp.terminate(nil);return}
        lock.lock();cancelRequested=true;lock.unlock()
        if phase=="waiting" || phase=="waiting-disconnect" || phase=="restore-failed" {beginRestore()}
        else if phase=="waiting-reconnect"{status.stringValue="测试已取消。请重新连接 USB 并切换有线模式，程序会恢复原映射。"}
        else{status.stringValue="正在完成当前操作并恢复，请松开所有按键。"}
    }
    func registryID(_ device:IOHIDDevice)->UInt64?{
        var id:UInt64=0
        guard IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device),&id)==KERN_SUCCESS else{return nil}
        return id
    }
    @objc func confirmPowerOff(){
        guard phase=="waiting-reconnect",powerOffButton.state == .on else{powerOffButton.state = .off;return}
        guard powerCycle?.confirmPowerOff(at:ProcessInfo.processInfo.systemUptime)==true else{return}
        record("powerOffUserConfirmedAt",now());record("powerOffEvidenceSource","user confirmation; USB cannot measure internal battery power")
        powerOffButton.isEnabled=false;status.stringValue="电源关闭已确认。请等至少 15 秒，再开电并连接 USB。"
    }
    func pollPowerCycle(){
        guard powerCycleMode,["waiting-disconnect","waiting-reconnect"].contains(phase) else{return}
        let devices=IOHIDManagerCopyDevices(inputManager) as? Set<IOHIDDevice> ?? []
        if phase=="waiting-disconnect",devices.isEmpty{
            powerCycle?.disconnected(at:ProcessInfo.processInfo.systemUptime);record("usbDisconnectedAt",now())
            setPhase("waiting-reconnect","USB 已断开。请关闭键盘电源，勾选下方确认。\n等至少 15 秒，再开电、接 USB 并切换有线模式。")
            powerOffButton.isEnabled=true;return
        }
        guard phase=="waiting-reconnect",devices.count==1,let device=devices.first,let id=registryID(device) else{return}
        let serial=(IOHIDDeviceGetProperty(device,kIOHIDSerialNumberKey as CFString) as? String ?? "").trimmingCharacters(in:.whitespacesAndNewlines)
        guard originalSerial.isEmpty || serial==originalSerial else{status.stringValue="连接的键盘序列号不同，请接回原键盘。未写入。";return}
        guard powerCycle?.reconnected(at:ProcessInfo.processInfo.systemUptime,registryID:id)==true else{return}
        record("usbReconnectedAt",now());record("reconnectedUSBRegistryID",String(id));record("confirmedOffIntervalSeconds",powerCycle?.confirmedOffInterval ?? -1);record("userConfirmedPowerCycle",powerCycle?.hasConfirmedPowerCycle==true)
        powerOffButton.isEnabled=false
        if cancelRequested{beginRestore();return}
        setPhase("verifying-retention","USB 已重新枚举。正在只读核对断开后的键位，尚未重新写入。")
        queue.async{[weak self] in self?.verifyRetention()}
    }
    func verifyRetention(){
        do{
            guard let original=baseline else{throw HardwareError(message:"缺少测试前备份。")}
            let transport=try CherryUSB();transport.trace={ [weak self] text in self?.appendTrace(text) }
            let current=try transport.completeSnapshot()
            try HardwareProfile(snapshot:current).encoded().write(to:runDirectory.appendingPathComponent("after-reconnect.json"),options:.atomic)
            let result=CalculatorKeyRetention.compare(current,authorization:try CalculatorKeyTestAuthorization(baseline:original))
            record("keymapAfterReconnect",result.rawValue);record("retentionReadBeforeAnyRewrite",true)
            DispatchQueue.main.async{
                self.retention=result
                switch result{
                case .retained:
                    self.record("powerCycleKeymapRetained",self.powerCycle?.hasConfirmedPowerCycle==true)
                    self.record("usbReconnectKeymapRetained",true)
                    self.setPhase("waiting",self.powerCycle?.hasConfirmedPowerCycle==true ? "断电后键位表仍保留（电源关闭由你确认）。\n请点击此窗口，按下并完全松开一次计算器键，随后自动恢复。":"USB 重连后键位表保留；未满足断电确认条件。\n请点击此窗口，按下并完全松开一次计算器键，随后自动恢复。")
                    self.record("waitingSince",ProcessInfo.processInfo.systemUptime);self.details.stringValue="已保存重连后的原始读回；未重写目标。现在核对实体键 ⌃⌥⌘C。";self.window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
                    if self.cancelRequested{self.beginRestore()}
                case .reverted:
                    self.record("powerCycleKeymapRetained",false);self.record("usbReconnectKeymapRetained",false);self.beginRestore()
                case .unexpected:
                    self.setPhase("restore-failed","重连后的配置出现范围之外变化，未自动覆盖。\n请保留窗口和备份，先核对日志。");self.stopButton.isEnabled=true
                }
            }
        }catch{
            record("retentionReadError",error.localizedDescription)
            DispatchQueue.main.async{self.setPhase("restore-failed","重连后读取失败：\(error.localizedDescription)\n尚未重写目标。请确认有线连接，保留窗口与备份。");self.stopButton.isEnabled=true}
        }
    }
    func beginRestore(){
        guard !restoring else{return};restoring=true;setPhase("restoring","请松开所有按键。正在恢复原计算器媒体键，并读回全部配置核对…");stopButton.isEnabled=false
        record("balancedPhysicalInput",downs==observedUsages && ups==observedUsages && held.isEmpty)
        record("calculatorLaunchedDuringPhysicalTest",launchObserved);record("calculatorActivatedDuringPhysicalTest",activationObserved)
        queue.async{[weak self] in self?.restore()}
    }
    func restore(){
        defer{usb=nil}
        do{
            guard let original=baseline else{throw HardwareError(message:"缺少备份，无法恢复。")}
            let transport=try CherryUSB();usb=transport;transport.trace={ [weak self] text in self?.appendTrace(text) }
            let current=try transport.completeSnapshot()
            let expected=try CalculatorKeyTestAuthorization(baseline:original).expected
            guard comparable(current,original) || comparable(current,expected) else{throw HardwareError(message:"出现范围之外的配置变化，停止自动覆盖。保留备份和日志。")}
            try transport.waitUntilKeysReleased();try transport.authorizeCalculatorTest(baseline:original)
            let after=try transport.writeKeymap(original.keymap,baseline:current)
            guard comparable(after,original) else{throw HardwareError(message:"恢复读回与原始备份不一致。")}
            try HardwareProfile(snapshot:after).encoded().write(to:runDirectory.appendingPathComponent("restored.json"),options:.atomic)
            record("restoredReadbackMatches",true)
            record("finalShortcutModifiersHeld",CGEventSource.flagsState(.hidSystemState).intersection([.maskCommand,.maskControl,.maskAlternate,.maskShift]).rawValue)
            usb=nil
            DispatchQueue.main.async{
                self.done=true;self.restoring=false;self.timer?.invalidate()
                var message="原键位已恢复，灯效与宏区读回一致。\n实体快捷键和系统计算器启动结果已记录。"
                if self.powerCycleMode{
                    if self.retention == .reverted{message="重连后测试映射未保留，已确认恢复原键位。结果与日志已保存。"}
                    else if self.retention == .retained{message=self.powerCycle?.hasConfirmedPowerCycle==true ? "断电后映射保留，原键位现已恢复。\n电源关闭由你确认；实体键与系统启动结果已记录。":"USB 重连后映射保留，原键位现已恢复。\n断电确认条件不足，不能判定断电保留。"}
                    else{message="测试已结束，原键位读回一致。未得出断电保留结果。"}
                }
                self.setPhase("complete",message);self.details.stringValue=self.runDirectory.path;self.stopButton.title="关闭测试窗口";self.stopButton.isEnabled=true
            }
        }catch{
            record("restoreError",error.localizedDescription)
            DispatchQueue.main.async{self.restoring=false;self.setPhase("restore-failed","恢复未完成：\(error.localizedDescription)\n请松开 Ctrl、Alt、Win 等按键后，点击恢复按钮。不要强制退出。");self.stopButton.isEnabled=true}
        }
    }
    func recoverAfterError(_ reason:String){
        guard let transport=usb,let original=baseline else{DispatchQueue.main.async{self.failWithoutWrites(reason)};return}
        do{
            let current=try transport.completeSnapshot()
            if comparable(current,original){usb=nil;record("restoredReadbackMatches",true);DispatchQueue.main.async{self.done=true;self.setPhase("failed-restored","测试中止，原配置读回一致：\(reason)");self.stopButton.title="关闭测试窗口"};return}
            DispatchQueue.main.async{self.beginRestore()}
        }catch{record("errorReadbackFailed",error.localizedDescription);DispatchQueue.main.async{self.setPhase("restore-failed","测试中止，需核对恢复：\(reason)\n请保留窗口，松开全部按键后点击恢复。");self.stopButton.isEnabled=true}}
    }
    func failWithoutWrites(_ reason:String){done=true;setPhase("failed-before-write",reason);stopButton.title="关闭测试窗口"}
    func windowShouldClose(_ sender:NSWindow)->Bool{if done{return true};stop();return false}
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool{done}
    func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply{if done{return .terminateNow};stop();return .terminateCancel}
    func applicationWillTerminate(_ n:Notification){timer?.invalidate();IOHIDManagerUnscheduleFromRunLoop(inputManager,CFRunLoopGetMain(),CFRunLoopMode.defaultMode.rawValue);IOHIDManagerClose(inputManager,0)}
}
#endif
