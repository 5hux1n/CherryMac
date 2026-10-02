#if CHERRY_PRODUCT_TEST
import Cocoa
import IOKit.hid

// Research-only orchestration of the actual editor and production key writer.
// It observes physical HID values; it never intercepts or synthesizes input.
final class ProductKeymapTestController:NSObject,NSApplicationDelegate,NSWindowDelegate {
    struct Case {
        let name:String,action:Int,record:[UInt8],signals:Set<String>
    }
    let cases:[Case] = [
        Case(name:"普通键 B",action:1,record:[0x20,0,5],signals:["7:5"]),
        Case(name:"计算器组合键 ⌃⌥⌘C",action:2,record:[0x20,13,6],signals:["7:6","7:224","7:226","7:227"]),
        Case(name:"媒体键 · 上一曲",action:5,record:[0x30,182,0],signals:["12:182"]),
        Case(name:"禁用",action:8,record:[0x20,0,0],signals:[])
    ]
    let directory:URL = {
        if let i=CommandLine.arguments.firstIndex(of:"--test-dir"),CommandLine.arguments.count>i+1{return URL(fileURLWithPath:CommandLine.arguments[i+1])}
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CherryMac/HardwareTests/ProductKeys-\(UUID().uuidString)")
    }()
    let manager=IOHIDManagerCreate(kCFAllocatorDefault,0)
    let queue=DispatchQueue(label:"local.cherrymac.product-test.read")
    let editor=HardwareWindowController()
    let status=NSTextField(wrappingLabelWithString:"正在读取并核对备份，请先不要按键。")
    let detail=NSTextField(wrappingLabelWithString:"这里只临时修改计算器键，灯效与宏不写入。")
    let confirm=NSButton(title:"已按计算器键并松开，没有反应",target:nil,action:nil)
    let startButton=NSButton(title:"开始四项按键测试",target:nil,action:nil)
    let stopButton=NSButton(title:"恢复原配置并结束",target:nil,action:nil)
    var window:NSWindow!,timer:Timer?
    var before:HardwareSnapshot?,targets:[HardwareSnapshot]=[],index=0,phase="preflight",afterWrite=""
    var down=Set<String>(),up=Set<String>(),held=Set<String>()
    var events:[[String:Any]]=[],results:[[String:Any]]=[],state:[String:Any]=[:]
    var since=ProcessInfo.processInfo.systemUptime,settle:Double?,cancel=false,done=false,restored=false
    var previousBackup:String?
    func now()->String{ISO8601DateFormatter().string(from:Date())}
    func save() throws {
        var value=state;value["phase"]=phase;value["events"]=events;value["results"]=results;value["capturedAt"]=now()
        value["format"]="CherryMacProductKeyTest";value["scope"]="calculator slot 102 only; production editor/writer; no macro or lighting writes"
        try JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent("test-log.json"),options:.atomic)
    }
    func persist(){do{try save()}catch{status.stringValue="日志保存失败：\(error.localizedDescription)";cancel=true;if phase=="waiting"{restore()}}}
    func same(_ a:HardwareSnapshot,_ b:HardwareSnapshot)->Bool{a.keymap==b.keymap && a.parameters==b.parameters && a.colors==b.colors && a.macroData==b.macroData && a.deviceInfo==b.deviceInfo}
    func snapshotFile(_ s:HardwareSnapshot,_ name:String) throws {
        let file=directory.appendingPathComponent(name);try HardwareProfile(snapshot:s).encoded().write(to:file,options:.atomic)
        guard same(try HardwareProfile.decode(Data(contentsOf:file)).snapshot,s) else{throw HardwareError(message:"备份校验失败。")}
    }
    func applicationDidFinishLaunching(_ n:Notification){
        do{try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true);try save()}catch{fputs("\(error)\n",stderr);NSApp.terminate(nil);return}
        previousBackup=UserDefaults.standard.string(forKey:"hardware.lastKeyBackup")
        NSApp.setActivationPolicy(.regular);CalculatorService.configureApplicationMenu()
        window=NSWindow(contentRect:NSRect(x:0,y:0,width:720,height:300),styleMask:[.titled,.closable],backing:.buffered,defer:false);window.title="CherryMac · 新版按键流程实机验收";window.delegate=self
        let view=NSView(frame:NSRect(x:0,y:0,width:720,height:300));window.contentView=view
        let title=NSTextField(labelWithString:"按窗口提示，测试右上角计算器键");title.font = .systemFont(ofSize:22,weight:.semibold);title.frame=NSRect(x:22,y:244,width:680,height:35);view.addSubview(title)
        status.font = .systemFont(ofSize:16,weight:.medium);status.frame=NSRect(x:22,y:132,width:680,height:94);view.addSubview(status)
        detail.textColor = .secondaryLabelColor;detail.frame=NSRect(x:22,y:64,width:680,height:60);view.addSubview(detail)
        confirm.target=self;confirm.action=#selector(confirmDisabled);confirm.frame=NSRect(x:22,y:20,width:360,height:32);confirm.isHidden=true;view.addSubview(confirm)
        startButton.target=self;startButton.action=#selector(start);startButton.frame=confirm.frame;startButton.isEnabled=false;view.addSubview(startButton)
        stopButton.target=self;stopButton.action=#selector(stop);stopButton.frame=NSRect(x:465,y:20,width:230,height:32);view.addSubview(stopButton)
        window.center();window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
        IOHIDManagerSetDeviceMatching(manager,[kIOHIDVendorIDKey:1130,kIOHIDProductIDKey:462,kIOHIDTransportKey:"USB"] as CFDictionary)
        IOHIDManagerRegisterInputValueCallback(manager,{context,result,_,value in
            guard result==0,let context else{return};let owner=Unmanaged<ProductKeymapTestController>.fromOpaque(context).takeUnretainedValue()
            let e=IOHIDValueGetElement(value),p=IOHIDElementGetUsagePage(e),u=IOHIDElementGetUsage(e),v=IOHIDValueGetIntegerValue(value)
            guard [UInt32(7),12].contains(p),u != 0,(v==0 || v==1) else{return}
            let signal="\(p):\(u)"
            if v==1{owner.held.insert(signal)}else{owner.held.remove(signal)}
            guard ["waiting","waiting-restored"].contains(owner.phase) else{return}
            if v==1{owner.down.insert(signal)}else{owner.up.insert(signal)}
            owner.events.append(["at":owner.now(),"stage":owner.phase=="waiting-restored" ? "restored":owner.cases[owner.index].name,"signal":signal,"value":v,"hidTimestamp":String(IOHIDValueGetTimeStamp(value))]);owner.persist()
        },Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerScheduleWithRunLoop(manager,CFRunLoopGetMain(),CFRunLoopMode.defaultMode.rawValue)
        let opened=IOHIDManagerOpen(manager,0);state["inputOpenResult"]=opened
        guard opened==0,let devices=IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>,devices.count==1 else{finish(error:"实体监听未就绪，未写入。");return}
        NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.didActivateApplicationNotification,object:nil,queue:.main){[weak self] n in
            guard let self,self.phase=="waiting",self.index==1,let app=n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,app.bundleIdentifier=="com.apple.calculator" else{return}
            self.state["calculatorActivatedDuringChord"]=true;self.persist()
        }
        timer=Timer.scheduledTimer(withTimeInterval:0.25,repeats:true){[weak self] _ in self?.tick()}
        editor.readKeyboardThen{[weak self] snapshot in
            guard let self,!self.cancel,!self.done else{return}
            do{
                guard let i=CommandLine.arguments.firstIndex(of:"--baseline"),CommandLine.arguments.count>i+1 else{throw HardwareError(message:"缺少已核对的基线文件。")}
                let expected=try HardwareProfile.decode(Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[i+1]))).snapshot
                guard self.same(snapshot,expected) else{throw HardwareError(message:"配置与准备时的基线不同，未写入。")}
                guard Array(snapshot.keymap[306..<309])==[0x30,0x92,1] else{throw HardwareError(message:"计算器键不是已核对的原始功能，未启动预定测试。")}
                self.before=snapshot;try self.snapshotFile(snapshot,"before.json");self.state["baselineVerified"]=true
                self.phase="ready";try self.save();self.startButton.isEnabled=true
                self.status.stringValue="备份与配置核对完成，尚未写入。\n准备好后，用鼠标点击“开始四项按键测试”。"
                self.detail.stringValue="约需 2–4 分钟。依次测试普通键、组合键、媒体键和禁用，最后恢复原配置。等待点击期间不计时。"
            }catch{self.finish(error:error.localizedDescription)}
        }
    }
    @objc func start(){
        guard phase=="ready",!cancel,!done,!editor.busy else{return}
        startButton.isEnabled=false;startButton.isHidden=true;state["userStartedAt"]=now();stageNext()
    }
    func lockEditor(){editor.controls.forEach{$0.isEnabled=false};editor.keyButtons.forEach{$0.isEnabled=false};editor.writeButtons.forEach{$0.isEnabled=false}}
    func stagedDraft(_ c:Case) throws -> HardwareProfile {
        editor.selected="calculator";editor.loadSelectedAssignment();editor.actionPicker.selectItem(at:c.action)
        if c.action==1{editor.keyPicker.selectItem(at:editor.shortcutKeys.firstIndex{$0.1==5}!);editor.modifiers.forEach{$0.state = .off}}
        editor.actionChanged();editor.stageKey()
        guard let draft=editor.profile,Array(draft.snapshot.keymap[306..<309])==c.record else{throw HardwareError(message:"编辑器输出与预期不符。")}
        return draft
    }
    func stageNext(){
        guard !cancel,let original=before,let current=editor.baseline,index<cases.count else{restore();return}
        let c=cases[index],draft:HardwareProfile
        do{draft=try stagedDraft(c)}catch{state["failure"]=error.localizedDescription;restore();return}
        var expected=current;expected.keymap.replaceSubrange(306..<309,with:c.record)
        guard same(draft.snapshot,expected) else{state["failure"]="编辑器改动超出计算器键。";restore();return}
        do{let auth=try KeymapWriteAuthorization(baseline:original,keymap:expected.keymap);guard auth.changedSlots==[102] else{throw HardwareError(message:"测试目标超出预定键位。")};try snapshotFile(expected,"target-\(index).json");targets.append(expected);phase="writing";afterWrite="waiting";try save()}
        catch{state["failure"]=error.localizedDescription;restore();return}
        status.stringValue="第 \(index+1)/4 项：正在写入「\(c.name)」并读回核对。\n请松开所有按键，等提示后再按计算器键。"
        confirm.isHidden=true;editor.performKeyWrite(draft:draft,baseline:current);lockEditor()
    }
    func expectedSignals()->Set<String>{phase=="waiting-restored" ? ["12:402"]:cases[index].signals}
    func tick(){
        if phase=="preflight",!editor.busy,before==nil{finish(error:editor.message.stringValue);return}
        if ["writing","restoring-write"].contains(phase),!editor.busy{
            lockEditor()
            let expected=phase=="restoring-write" ? before:targets.last
            guard let actual=editor.baseline,let expected,same(actual,expected) else{
                state["failure"]=editor.message.stringValue
                if phase=="restoring-write"{finish(error:"恢复失败，请保留备份。\n\(editor.message.stringValue)")}else{restore()};return
            }
            do{try snapshotFile(actual,phase=="restoring-write" ? "restored.json":"readback-\(index).json")}catch{
                state["failure"]=error.localizedDescription
                if phase=="restoring-write"{restored=true;state["fullConfigurationRestored"]=true;verifyFinalRead()}else{restore()};return
            }
            phase=afterWrite;down.removeAll();up.removeAll();settle=nil;since=ProcessInfo.processInfo.systemUptime;persist()
            if phase=="waiting-restored"{
                restored=true;state["fullConfigurationRestored"]=true;persist()
                status.stringValue="原配置已恢复，五个配置区读回一致。\n最后请按一次计算器键并完全松开，核对恢复后的实体输出。";detail.stringValue="预期恢复为原计算器媒体码（12:402）。完成后自动保存结果。"
            }else{
                status.stringValue="第 \(index+1)/4 项：「\(cases[index].name)」已写入且读回一致。\n请按一次右上角计算器键，然后完全松开。\n松开后请等待下一项提示，不要连续按键。"
                detail.stringValue=index==3 ? "禁用应没有键盘输出。按过计算器键并松开后，请用鼠标点下方确认按钮。":"程序只观察实体报告。自动进入下一项时会提示；灯效与宏区保持原值。"
                confirm.isHidden=index != 3;confirm.isEnabled=true
            }
            if cancel{if restored{verifyFinalRead()}else{restore()};return};window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
        }
        guard ["waiting","waiting-restored"].contains(phase) else{return}
        let wanted=expectedSignals(),elapsed=ProcessInfo.processInfo.systemUptime-since
        if !wanted.isEmpty,wanted.isSubset(of:down),wanted.isSubset(of:up),held.isEmpty{
            if settle==nil{settle=ProcessInfo.processInfo.systemUptime}
            if ProcessInfo.processInfo.systemUptime-settle! >= 3 {
                if phase=="waiting-restored"{state["restoredPhysicalOutputVerified"]=true;verifyFinalRead();return}
                results.append(["name":cases[index].name,"record":cases[index].record,"readbackVerified":true,"physicalPressAndReleaseVerified":true,"observedDown":Array(down).sorted(),"observedUp":Array(up).sorted()]);persist();index+=1;stageNext()
            }
        }else{settle=nil}
        if elapsed>180{state["failure"]="实体按键等待超时。";if restored{verifyFinalRead()}else{restore()}}
    }
    @objc func confirmDisabled(){
        guard phase=="waiting",index==3,held.isEmpty,ProcessInfo.processInfo.systemUptime-since>=2 else{return}
        let unexpected=down.contains("12:402") || down.contains("7:5") || down.contains("7:6") || down.contains("12:182")
        if unexpected{state["failure"]="禁用阶段仍观察到候选输出。";restore();return}
        results.append(["name":"禁用","record":cases[index].record,"readbackVerified":true,"physicalPressUserConfirmed":true,"noCandidateHIDOutputObserved":true,"limitation":"Silence cannot independently prove the physical press; confirmed by user clicking this button."])
        persist();index+=1;restore()
    }
    @objc func stop(){
        if done{window.close();return};cancel=true;state["cancelled"]=true;confirm.isEnabled=false;startButton.isHidden=true
        if phase=="waiting-restored"{verifyFinalRead()}
        else if phase=="ready" || phase=="preflight"{finish(error:"已取消，未写入键盘。")}
        else if !editor.busy{restore()}
    }
    func restore(){
        guard let original=before else{finish(error:state["failure"] as? String);return}
        guard !["restoring-read","restoring-write","waiting-restored","verifying-final","complete"].contains(phase) else{return}
        phase="restoring-read";confirm.isHidden=true;status.stringValue="正在读取当前配置，核对范围后恢复原计算器键。\n请松开所有按键，保持 USB 连接。";persist()
        queue.async{[weak self] in
            guard let self else{return}
            let result:Result<HardwareSnapshot,Error>=Result{
                let usb=try CherryUSB(),log=try HardwareOperationLog(kind:"read");usb.trace=log.trace
                let current=try usb.completeSnapshot();log.record("phase","complete")
                guard current.parameters==original.parameters,current.colors==original.colors,current.macroData==original.macroData,current.deviceInfo==original.deviceInfo else{throw HardwareError(message:"发现键位范围之外的变化，停止自动覆盖。")}
                guard self.same(current,original) || self.targets.contains(where:{self.same($0,current)}) else{throw HardwareError(message:"当前键位不属于本测试目标，停止自动覆盖。")};return current
            }
            DispatchQueue.main.async{
                switch result{
                case .success(let current):
                    if self.same(current,original){self.restored=true;self.state["fullConfigurationRestored"]=true;self.verifyFinalRead();return}
                    self.editor.baseline=current;var draft=HardwareProfile(snapshot:current);draft.snapshot.keymap=original.keymap
                    self.phase="restoring-write";self.afterWrite="waiting-restored";self.persist();self.editor.performKeyWrite(draft:draft,baseline:current);self.lockEditor()
                case .failure(let error):self.finish(error:error.localizedDescription)
                }
            }
        }
    }
    func verifyFinalRead(){
        guard let original=before,phase != "verifying-final",!done else{return};phase="verifying-final";persist()
        status.stringValue="正在用独立 USB 会话做最后读回核对，请稍候。"
        queue.async{[weak self] in
            guard let self else{return};let result:Result<HardwareSnapshot,Error>=Result{try CherryUSB().completeSnapshot()}
            DispatchQueue.main.async{switch result{
                case .success(let actual):
                    self.state["independentFinalReadMatches"]=self.same(actual,original)
                    do{try self.snapshotFile(actual,"independent-final.json")}catch{self.finish(error:error.localizedDescription);return}
                    self.finish(error:self.same(actual,original) ? self.state["failure"] as? String:"独立读回与原配置不一致。")
                case .failure(let error):self.finish(error:error.localizedDescription)
            }}
        }
    }
    func finish(error:String?){
        done=true;phase="complete";timer?.invalidate();confirm.isHidden=true;startButton.isHidden=true;stopButton.title="关闭测试窗口";state["error"]=error as Any? ?? NSNull();state["finishedAt"]=now()
        if let previousBackup{UserDefaults.standard.set(previousBackup,forKey:"hardware.lastKeyBackup")}else{UserDefaults.standard.removeObject(forKey:"hardware.lastKeyBackup")}
        let passed=results.count==cases.count && state["restoredPhysicalOutputVerified"] as? Bool==true && state["independentFinalReadMatches"] as? Bool==true
        state["allPhysicalCasesPassed"]=passed
        persist();status.stringValue=error.map{"测试已停止：\($0)"} ?? (passed ? "四项按键测试完成，原配置已恢复并独立读回核对。":"测试已结束，原配置已恢复。尚有实体操作未完成，未标记全部通过。")
        detail.stringValue="日志自动保存：\(directory.path)";window?.makeKeyAndOrderFront(nil)
    }
    func windowShouldClose(_ sender:NSWindow)->Bool{if done{return true};stop();return false}
    func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply{if done{return .terminateNow};stop();return .terminateCancel}
    func windowWillClose(_ n:Notification){if done{NSApp.terminate(nil)}}
    func runOfflineTests(){
        var fixture=HardwareSnapshot(keymap:Array(repeating:0,count:378),deviceInfo:Array(repeating:0,count:34),parameters:Array(repeating:0,count:56),colors:Array(repeating:255,count:378),macroData:Array(repeating:0,count:3071))
        fixture.deviceInfo[6]=24;fixture.keymap.replaceSubrange(306..<309,with:[0x30,0x92,1])
        var later=fixture;later.createdAt=fixture.createdAt.addingTimeInterval(60)
        precondition(fixture != later && same(fixture,later),"Acquisition timestamp must not masquerade as configuration change")
        for c in cases{
            editor.profile=try! HardwareProfile.fromHardware(fixture);editor.baseline=fixture
            let draft=try! stagedDraft(c),auth=try! KeymapWriteAuthorization(baseline:fixture,keymap:draft.snapshot.keymap)
            precondition(auth.changedSlots==[102] && same(draft.snapshot,auth.expected) && editor.baseline==fixture)
            var unexpected=draft.snapshot;unexpected.keymap[3] ^= 1
            do{try auth.validateRecovery(unexpected);preconditionFailure("Unrelated key change must reject restore")}catch{}
        }
        print("PASS: actual editor stages four bounded calculator-key cases; acquisition timestamps ignored, non-key banks and original baseline preserved, unrelated recovery rejected (offline, no USB)")
    }
}
#endif
