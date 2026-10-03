#if CHERRY_MACRO_TEST
import Cocoa
import IOKit.hid
import CryptoKit

private final class MacroObserverView:NSView {
    override var acceptsFirstResponder:Bool{true}
    override func keyDown(with event:NSEvent){}
    override func keyUp(with event:NSEvent){}
    override func performKeyEquivalent(with event:NSEvent)->Bool{true}
}

// Read-only research window. Starting it never changes bindings, macros,
// lights or power settings. Actual launching waits until the macro module is
// ready; --macro-observer-self-test only exercises simulated callbacks.
final class MacroObserverTestController:NSObject,NSApplicationDelegate,NSWindowDelegate {
    let manager=IOHIDManagerCreate(kCFAllocatorDefault,0)
    let ledger=RawInputLedger()
    let queue=DispatchQueue(label:"local.cherrymac.macro-observer.read")
    let directory:URL
    let status=NSTextField(wrappingLabelWithString:"正在核对键盘和已写入的宏…")
    let detail=NSTextField(wrappingLabelWithString:"本窗口只观察，不写入，不代替键盘停止宏。")
    let startButton=NSButton(title:"开始观察",target:nil,action:nil)
    let stopButton=NSButton(title:"已用键盘停止宏并完全松开",target:nil,action:nil)
    let closeButton=NSButton(title:"结束并保存",target:nil,action:nil)
    var window:NSWindow?,timer:Timer?,opened=false
    var phase="prepared",baseline:HardwareSnapshot?,locationID:Int?
    var macro:KeyboardMacro?,playback:MacroPlayback?,source:MacroExecutionEvidence.Source = .hid
    var adapter=MacroHIDObservationAdapter(),evidence:MacroExecutionEvidence?
    var startedMilliseconds=0,lastMilliseconds=0
    var stopMarker:MacroExecutionLog.Stop?,interruptions:[MacroExecutionEvidence.Interruption]=[]
    var rawValues:[[String:Any]]=[]
    var terminalError:String?
    init(directory:URL?=nil){
        if let directory{self.directory=directory}
        else if let i=CommandLine.arguments.firstIndex(of:"--test-dir"),CommandLine.arguments.count>i+1{self.directory=URL(fileURLWithPath:CommandLine.arguments[i+1])}
        else{self.directory=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CherryMac/HardwareTests/MacroObservation-\(UUID().uuidString)")}
        super.init()
    }
    func milliseconds()->Int{Int(ledger.nanoseconds(mach_absolute_time())/1_000_000)}
    func encode<T:Encodable>(_ value:T)throws->Data{let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys];return try encoder.encode(value)}
    func persist(at now:Int)throws {
        var metadata:[String:Any]=["format":"CherryMacMacroObservationSession","version":1,"phase":phase,"scope":"read-only; existing calculator-slot macro; no writes or power-cycle proof","rawValues":rawValues]
        if let locationID{metadata["locationID"]=locationID}
        if let terminalError{metadata["error"]=terminalError}
        try JSONSerialization.data(withJSONObject:metadata,options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent("session.json"),options:.atomic)
        if let baseline,!FileManager.default.fileExists(atPath:directory.appendingPathComponent("baseline.json").path){try HardwareProfile(snapshot:baseline).encoded().write(to:directory.appendingPathComponent("baseline.json"),options:.atomic)}
        if let evidence,let macro,let playback {
            let log=MacroExecutionLog(format:"CherryMacMacroExecution",version:1,macro:macro,playback:playback,source:source,startedMilliseconds:startedMilliseconds,
                events:evidence.observations,stop:stopMarker,assessedMilliseconds:max(now,lastMilliseconds),interruptions:interruptions)
            let data=try encode(log);try data.write(to:directory.appendingPathComponent("execution.json"),options:.atomic)
            let report=MacroExecutionReport(inputSHA256:SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined(),assessment:try evidence.assessment(milliseconds:max(now,lastMilliseconds)))
            try encode(report).write(to:directory.appendingPathComponent("assessment.json"),options:.atomic)
        }
    }
    func save(){do{try persist(at:milliseconds())}catch{terminalError=error.localizedDescription;evidence?.invalidate(.loggingFailed);phase="failed";timer?.invalidate();status.stringValue="日志保存失败，测试中止。请停止正在执行的宏。"}}
    func invalidate(_ reason:MacroExecutionEvidence.Interruption,_ message:String){
        if !interruptions.contains(reason){interruptions.append(reason)}
        evidence?.invalidate(reason);terminalError=message;phase="failed";timer?.invalidate();startButton.isEnabled=false;stopButton.isEnabled=false
        status.stringValue=message;detail.stringValue="请停止键盘宏，必要时关闭键盘电源。本窗口没有发送停止或恢复指令。日志：\(directory.path)";save()
    }
    func configure(_ snapshot:HardwareSnapshot,source:MacroExecutionEvidence.Source)throws {
        try snapshot.validate();guard let bank=snapshot.macroData else{throw HardwareError(message:"缺少宏区备份。")}
        let library=try CherryMacroCodec.decode(bank),binding=Array(snapshot.keymap[306..<309])
        let mode=try CherryMacroCodec.playback(binding,macroCount:library.count)
        baseline=snapshot;macro=library[Int(binding[1])];playback=mode;self.source=source;phase="ready"
        startButton.isEnabled=true;stopButton.isHidden=mode.mode == .count;stopButton.isEnabled=false
        status.stringValue="已核对计算器键的宏：\(macro!.name) · \(mode.label)。尚未开始观察。"
        detail.stringValue="先停止旧宏并松开全部键，用鼠标点击开始，再按计算器键。日志会自动保存。"
    }
    func begin(at now:Int)throws {
        guard phase=="ready",adapter.allReleased,let macro,let playback else{throw HardwareError(message:"请先完成读取并松开全部键。")}
        evidence=try MacroExecutionEvidence(macro:macro,playback:playback,source:source,startedMilliseconds:now)
        startedMilliseconds=now;lastMilliseconds=now;phase="observing";startButton.isEnabled=false
        status.stringValue=playback.mode == .count ? "请按下并松开计算器键一次，等待自动检查。":"请触发宏，观察至少两轮；按官方方式停止后，再用鼠标点击停止确认。"
        try persist(at:now)
    }
    func receive(page:UInt32,usage:UInt32,value:Int,at now:Int){
        do{
            let event=try adapter.receive(page:page,usage:usage,value:value,milliseconds:now)
            guard phase=="observing",let event else{return}
            guard rawValues.count<65536 else{invalidate(.loggingFailed,"记录容量已满，观察中止。");return}
            rawValues.append(["page":page,"usage":usage,"value":value,"milliseconds":now])
            try evidence?.observe(event);lastMilliseconds=max(lastMilliseconds,now)
            do{try persist(at:now)}catch{invalidate(.loggingFailed,"日志保存失败，观察中止：\(error.localizedDescription)")}
        }catch{invalidate(.reportRejected,error.localizedDescription)}
    }
    func markStop(at now:Int,source:MacroExecutionEvidence.StopSource)throws {
        guard phase=="observing",let evidence,try evidence.assessment(milliseconds:max(now,lastMilliseconds)).completedCycles>=2 else{throw HardwareError(message:"先观察至少两轮完整宏输出，再停止并确认。")}
        try self.evidence?.requestStop(milliseconds:now,source:source);stopMarker = .init(milliseconds:now,source:source);lastMilliseconds=max(lastMilliseconds,now)
        stopButton.isEnabled=false;try persist(at:now)
    }
    func poll(at now:Int){
        guard phase=="observing",let evidence else{return}
        do{
            let result=try evidence.assessment(milliseconds:max(now,lastMilliseconds))
            stopButton.isEnabled=playback?.mode != .count && result.completedCycles>=2 && stopMarker==nil
            if result.passed{phase="complete";timer?.invalidate();status.stringValue="观察检查通过：\(result.completedCycles) 轮，按键全部释放。";detail.stringValue="仅本次输出观察通过；写入、时序和断电需要分别核对。日志：\(directory.path)";stopButton.isEnabled=false}
            else if result.status=="failed"{invalidate(.reportRejected,"宏输出检查未通过：\(result.failure ?? "unknown")");return}
            else if now-startedMilliseconds>300_000{invalidate(.cancelled,"观察超过五分钟，测试中止。请先停止宏。");return}
            try persist(at:now)
        }catch{invalidate(.reportRejected,error.localizedDescription)}
    }
    @objc func start(){
        do{guard NSEvent.modifierFlags.intersection([.control,.option,.command,.shift]).isEmpty else{throw HardwareError(message:"请先松开修饰键。")};try begin(at:milliseconds());window?.makeFirstResponder(window?.contentView)
            timer=Timer.scheduledTimer(withTimeInterval:0.1,repeats:true){[weak self] _ in guard let self else{return};self.poll(at:self.milliseconds())}
        }catch{if phase=="observing"{invalidate(.loggingFailed,error.localizedDescription)}else{status.stringValue=error.localizedDescription}}
    }
    @objc func acknowledgeStop(){
        guard let event=NSApp.currentEvent,event.type == .leftMouseUp,event.modifierFlags.intersection([.control,.option,.command,.shift]).isEmpty else{status.stringValue="停止宏并松键后，请用鼠标点击确认。";return}
        do{try markStop(at:milliseconds(),source:.userAcknowledged)}catch{status.stringValue=error.localizedDescription}
    }
    @objc func finish(){if phase=="observing"{invalidate(.cancelled,"用户结束观察。请确认键盘宏已停止。")}else{save()};NSApp.terminate(nil)}
    func windowShouldClose(_ sender:NSWindow)->Bool{finish();return true}
    func windowDidResignKey(_ notification:Notification){if phase=="observing"{invalidate(.focusLost,"窗口失去焦点，观察中止。请停止键盘宏。")} }
    func applicationDidFinishLaunching(_ notification:Notification){
        do{guard !FileManager.default.fileExists(atPath:directory.path) else{throw HardwareError(message:"测试目录已存在，不能覆盖旧证据。")};try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true);try persist(at:milliseconds())}
        catch{fputs(error.localizedDescription+"\n",stderr);NSApp.terminate(nil);return}
        NSApp.setActivationPolicy(.regular)
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:740,height:320),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        self.window=window;window.title="CherryMac · 宏输出只读观察";window.delegate=self;window.isReleasedWhenClosed=false
        let view=MacroObserverView(frame:NSRect(x:0,y:0,width:740,height:320));window.contentView=view
        let title=NSTextField(labelWithString:"核对已写入宏的实体输出");title.font = .systemFont(ofSize:22,weight:.semibold);title.frame=NSRect(x:22,y:265,width:696,height:34);view.addSubview(title)
        status.font = .systemFont(ofSize:16,weight:.medium);status.frame=NSRect(x:22,y:151,width:696,height:100);view.addSubview(status)
        detail.textColor = .secondaryLabelColor;detail.frame=NSRect(x:22,y:78,width:696,height:66);view.addSubview(detail)
        startButton.target=self;startButton.action=#selector(start);startButton.frame=NSRect(x:22,y:24,width:145,height:32);startButton.isEnabled=false;view.addSubview(startButton)
        stopButton.target=self;stopButton.action=#selector(acknowledgeStop);stopButton.frame=NSRect(x:176,y:24,width:325,height:32);stopButton.isEnabled=false;view.addSubview(stopButton)
        closeButton.target=self;closeButton.action=#selector(finish);closeButton.frame=NSRect(x:533,y:24,width:185,height:32);view.addSubview(closeButton)
        window.center();window.makeKeyAndOrderFront(nil);window.makeFirstResponder(view);NSApp.activate(ignoringOtherApps:true)
        guard IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)==kIOHIDAccessTypeGranted else{invalidate(.observerDisconnected,"请先在系统设置的输入监控中允许 CherryMac，再重新打开测试；没有监听权限，不能检查实体输出。");return}
        IOHIDManagerSetDeviceMatching(manager,[kIOHIDVendorIDKey:1130,kIOHIDProductIDKey:462,kIOHIDTransportKey:"USB"] as CFDictionary)
        IOHIDManagerRegisterInputValueCallback(manager,{context,result,_,value in
            guard let context else{return};let owner=Unmanaged<MacroObserverTestController>.fromOpaque(context).takeUnretainedValue()
            guard result==0 else{owner.invalidate(.reportRejected,"HID 观察回调失败。");return}
            let element=IOHIDValueGetElement(value)
            owner.receive(page:IOHIDElementGetUsagePage(element),usage:IOHIDElementGetUsage(element),value:IOHIDValueGetIntegerValue(value),at:Int(owner.ledger.nanoseconds(IOHIDValueGetTimeStamp(value))/1_000_000))
        },Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerRegisterDeviceRemovalCallback(manager,{context,_,_,_ in guard let context else{return};let owner=Unmanaged<MacroObserverTestController>.fromOpaque(context).takeUnretainedValue();owner.invalidate(.observerDisconnected,"键盘已断开，观察中止。")},Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerScheduleWithRunLoop(manager,CFRunLoopGetMain(),CFRunLoopMode.defaultMode.rawValue)
        let result=IOHIDManagerOpen(manager,0);opened=result==0
        guard opened else{invalidate(.observerDisconnected,"无法打开只读观察，请检查输入监控权限。") ;return}
        let devices=IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []
        guard devices.count==1,let device=devices.first,let id=IOHIDDeviceGetProperty(device,kIOHIDLocationIDKey as CFString) as? NSNumber else{invalidate(.observerDisconnected,"需要一把 USB 有线键盘，无法确认设备身份。");return}
        locationID=id.intValue
        queue.async{[weak self] in
            let result:Result<HardwareSnapshot,Error>=Result{try CherryUSB().completeSnapshot()}
            DispatchQueue.main.async{guard let self,self.phase=="prepared" else{return};do{try self.configure(result.get(),source:.hid);self.save()}catch{self.invalidate(.reportRejected,"无法开始观察：\(error.localizedDescription)")}}
        }
    }
    deinit{timer?.invalidate();if opened{IOHIDManagerUnscheduleFromRunLoop(manager,CFRunLoopGetMain(),CFRunLoopMode.defaultMode.rawValue);IOHIDManagerClose(manager,0)}}
    func runOfflineTests(){
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("CherryMacMacroObserver-\(UUID().uuidString)")
        defer{try? FileManager.default.removeItem(at:folder)}
        do{
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            let controller=MacroObserverTestController(directory:folder)
            let macro=KeyboardMacro(name:"AB",steps:[.init(usage:4,pressed:true,delayMilliseconds:0),.init(usage:4,pressed:false,delayMilliseconds:50),.init(usage:5,pressed:true,delayMilliseconds:10),.init(usage:5,pressed:false,delayMilliseconds:30)])
            var snapshot=HardwareSnapshot.demo();snapshot.macroData=try CherryMacroCodec.encode([macro]);snapshot.keymap.replaceSubrange(306..<309,with:try CherryMacroCodec.binding(0,playback:MacroPlayback(count:2)))
            try controller.configure(snapshot,source:.simulation);try controller.begin(at:1000)
            for cycle in 0..<2{for (index,step) in macro.steps.enumerated(){controller.receive(page:7,usage:UInt32(step.usage),value:step.pressed ? 1:0,at:1000+cycle*100+index*10);controller.receive(page:7,usage:UInt32(step.usage),value:step.pressed ? 1:0,at:1000+cycle*100+index*10)}}
            controller.poll(at:1420);precondition(controller.phase=="complete")
            let data=try Data(contentsOf:folder.appendingPathComponent("execution.json"));let log=try JSONDecoder().decode(MacroExecutionLog.self,from:data)
            let replay = try log.replay();precondition(log.events.count==8 && replay.passed)
            let report=try JSONSerialization.jsonObject(with:Data(contentsOf:folder.appendingPathComponent("assessment.json"))) as! [String:Any]
            precondition(report["inputSHA256"] as? String == SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined())
            var mouse=MacroHIDObservationAdapter();precondition(try! mouse.receive(page:9,usage:3,value:0,milliseconds:0)==nil)
            precondition(try! mouse.receive(page:9,usage:3,value:1,milliseconds:1)?.kind == .mouse)
            precondition(try! mouse.receive(page:9,usage:3,value:1,milliseconds:2)==nil)
            precondition(try! mouse.receive(page:9,usage:3,value:0,milliseconds:3)?.usage==4 && mouse.allReleased)
            for mode in [MacroPlayback.Mode.held,.toggle]{
                let subfolder=folder.appendingPathComponent(mode.rawValue);try FileManager.default.createDirectory(at:subfolder,withIntermediateDirectories:true)
                let looping=MacroObserverTestController(directory:subfolder)
                snapshot.keymap.replaceSubrange(306..<309,with:try CherryMacroCodec.binding(0,playback:MacroPlayback(mode:mode)))
                try looping.configure(snapshot,source:.simulation);try looping.begin(at:1000)
                for cycle in 0..<2{for (index,step) in macro.steps.enumerated(){looping.receive(page:7,usage:UInt32(step.usage),value:step.pressed ? 1:0,at:1000+cycle*100+index*10)}}
                looping.poll(at:1420);precondition(looping.phase=="observing")
                try looping.markStop(at:1420,source:.simulation);looping.poll(at:1710);precondition(looping.phase=="complete")
                let interrupted=MacroObserverTestController(directory:subfolder)
                try interrupted.configure(snapshot,source:.simulation);try interrupted.begin(at:1000)
                interrupted.invalidate(.observerDisconnected,"simulated disconnect");interrupted.poll(at:1710)
                precondition(interrupted.phase=="failed")
                let failedLog=try JSONDecoder().decode(MacroExecutionLog.self,from:Data(contentsOf:subfolder.appendingPathComponent("execution.json")))
                precondition(!(try! failedLog.replay()).passed)
            }
            print("PASS: read-only macro observer adapter, duplicate report normalization, exact count capture, durable replay and input SHA association (simulated; manager never opened)")
        }catch{fputs(error.localizedDescription+"\n",stderr);exit(1)}
    }
}
#endif
