#if CHERRY_MACRO_TEST
import Cocoa
import IOKit.hid
import CryptoKit

private final class MacroTestInputView:NSView {
    override func draw(_ dirtyRect:NSRect){NSColor.windowBackgroundColor.setFill();bounds.fill()}
    override var acceptsFirstResponder:Bool{true}
    override func keyDown(with event:NSEvent){}
    override func keyUp(with event:NSEvent){}
    override func performKeyEquivalent(with event:NSEvent)->Bool{true}
}

// Full research flow. This entry is never launched by an offline check or by
// normal product startup. Test writes still wait for macro-module acceptance.
final class MacroHardwareTestController:NSObject,NSApplicationDelegate,NSWindowDelegate {
    enum Phase:String {case preparing,ready,writing,observeReady,observing,disconnect,reconnect,reading,restoreReady,restoring,complete,failed}
    let manager=IOHIDManagerCreate(kCFAllocatorDefault,0),ledger=RawInputLedger()
    let queue=DispatchQueue(label:"local.cherrymac.macro-hardware-test")
    let directory:URL
    let resumeDirectory:URL?
    let status=NSTextField(wrappingLabelWithString:"正在核对设备和宏配置…")
    let detail=NSTextField(wrappingLabelWithString:"仅测试计算器键绑定的 AB 两次宏；日志自动保存。")
    let action=NSButton(title:"准备中",target:nil,action:nil)
    let off=NSButton(checkboxWithTitle:"已关闭键盘电源（不只是拔 USB）",target:nil,action:nil)
    let restore=NSButton(title:"停止测试并恢复原配置",target:nil,action:nil)
    var window:NSWindow?,timer:Timer?,opened=false,busy=false
    var phase:Phase = .preparing,authorization:MacroWriteAuthorization?,power:CalculatorPowerCycleEvidence?
    var adapter=MacroHIDObservationAdapter(),execution:MacroExecutionEvidence?,executionStart=0
    var powerVerified=false,firstExecutionPassed=false,secondExecutionPassed=false,restored=false
    var passed:Bool{firstExecutionPassed && secondExecutionPassed && powerVerified && restored && errorMessage==nil && interruptions.isEmpty}
    var locationID:Int?,errorMessage:String?,raw:[[String:Any]]=[]
    var interruptions:[MacroExecutionEvidence.Interruption]=[]
    static let playback=MacroPlayback(count:2)
    static let testMacro=KeyboardMacro(name:"CherryMac 实体测试 AB",steps:[.init(usage:4,pressed:true,delayMilliseconds:0),.init(usage:4,pressed:false,delayMilliseconds:80),.init(usage:5,pressed:true,delayMilliseconds:80),.init(usage:5,pressed:false,delayMilliseconds:80)])
    init(directory:URL?=nil,resumeDirectory:URL?=nil){
        self.resumeDirectory=resumeDirectory
        self.directory=directory ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CherryMac/HardwareTests/Macro-\(UUID().uuidString)");super.init()
    }
    static func plan(_ baseline:HardwareSnapshot)throws->MacroWriteAuthorization {
        try baseline.validate()
        guard Array(baseline.keymap[306..<309])==[0x30,0x92,0x01],let bank=baseline.macroData else{throw HardwareError(message:"本轮需要原始计算器键和完整宏备份，未授权写入。")}
        var library=try CherryMacroCodec.decode(bank);guard library.count<32 else{throw HardwareError(message:"宏库已满，测试不会覆盖现有宏。")}
        let index=library.count;library.append(testMacro)
        var target=baseline;target.macroData=try CherryMacroCodec.encode(library)
        target.keymap.replaceSubrange(306..<309,with:try CherryMacroCodec.binding(index,playback:playback))
        return try MacroWriteAuthorization(baseline:baseline,target:target,allowUnbounded:true)
    }
    static func resumePlan(directory:URL,current:HardwareSnapshot)throws->MacroWriteAuthorization {
        let before=try HardwareProfile.decode(Data(contentsOf:directory.appendingPathComponent("original.json"))).snapshot
        let target=try HardwareProfile.decode(Data(contentsOf:directory.appendingPathComponent("target.json"))).snapshot
        let plan=try MacroWriteAuthorization(baseline:before,target:target,allowUnbounded:true)
        try plan.validateRecovery(current);return plan
    }
    static func matches(_ a:HardwareSnapshot,_ b:HardwareSnapshot)->Bool{a.keymap==b.keymap && a.macroData==b.macroData && a.deviceInfo==b.deviceInfo && a.parameters==b.parameters && a.colors==b.colors}
    func milliseconds()->Int{Int(ledger.nanoseconds(mach_absolute_time())/1_000_000)}
    func encoded<T:Encodable>(_ value:T)throws->Data{let e=JSONEncoder();e.outputFormatting=[.prettyPrinted,.sortedKeys];return try e.encode(value)}
    func persist()throws {
        var session:[String:Any]=["format":"CherryMacMacroHardwareTest","version":1,"phase":phase.rawValue,"source":execution?.source.rawValue ?? "hid","passed":passed,"scope":"calculator-slot AB twice only; exact firmware delay and other playback modes require separate acceptance","firstExecutionPassed":firstExecutionPassed,"secondExecutionPassed":secondExecutionPassed,"retainedAfterConfirmedPowerCycle":powerVerified,"originalRestored":restored,"rawValues":raw,"powerOffEvidence":"explicit user confirmation; internal battery power is not measured"]
        if let errorMessage{session["error"]=errorMessage};if let locationID{session["locationID"]=locationID}
        if let power{session["originalRegistryID"]=String(power.originalRegistryID);session["disconnectedAt"]=power.disconnectedAt;session["powerOffConfirmedAt"]=power.powerOffConfirmedAt;session["reconnectedAt"]=power.reconnectedAt;session["confirmedOffInterval"]=power.confirmedOffInterval}
        try JSONSerialization.data(withJSONObject:session,options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent("session.json"),options:.atomic)
        if let execution {
            let log=MacroExecutionLog(format:"CherryMacMacroExecution",version:1,macro:Self.testMacro,playback:Self.playback,source:execution.source,startedMilliseconds:executionStart,events:execution.observations,stop:nil,assessedMilliseconds:max(milliseconds(),execution.observations.last?.milliseconds ?? executionStart),interruptions:interruptions)
            let data=try encoded(log),name=powerVerified ? "execution-after-power":"execution-before-power"
            try data.write(to:directory.appendingPathComponent(name+".json"),options:.atomic)
            try encoded(MacroExecutionReport(inputSHA256:SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined(),assessment:try log.replay())).write(to:directory.appendingPathComponent(name+"-assessment.json"),options:.atomic)
        }
    }
    func fail(_ message:String,_ interruption:MacroExecutionEvidence.Interruption = .cancelled){
        if execution != nil{execution?.invalidate(interruption);if !interruptions.contains(interruption){interruptions.append(interruption)}}
        phase = .failed;errorMessage=message;status.stringValue=message;action.isEnabled=false;off.isEnabled=false
        restore.isEnabled=authorization != nil && !busy;detail.stringValue="停止正在运行的宏；重连后可点击恢复。备份与日志：\(directory.path)";try? persist()
    }
    func set(_ next:Phase,_ text:String)throws{phase=next;status.stringValue=text;action.isEnabled=[.ready,.observeReady,.restoreReady,.complete].contains(next);restore.isEnabled=authorization != nil && !busy && next != .complete;try persist()}
    func registry(_ device:IOHIDDevice)->UInt64?{var id:UInt64=0;return IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device),&id)==KERN_SUCCESS ? id:nil}
    func devices()->Set<IOHIDDevice>{IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []}
    func soleDevice()throws->IOHIDDevice{let all=devices();guard all.count==1,let d=all.first,(IOHIDDeviceGetProperty(d,kIOHIDLocationIDKey as CFString) as? NSNumber)?.intValue==locationID else{throw HardwareError(message:"无法确认同一把 USB 键盘，停止操作。")};return d}
    func stop(_ request:MacroStopRequest)throws{try MacroPhysicalStopController.confirm(request,owner:window,directory:directory.appendingPathComponent("stop-\(UUID().uuidString)"))}
    @objc func next(){
        guard !busy,let event=NSApp.currentEvent,event.type == .leftMouseUp,event.modifierFlags.intersection([.control,.option,.command,.shift]).isEmpty else{return}
        switch phase {
        case .ready:write()
        case .observeReady:
            do{guard adapter.allReleased else{throw HardwareError(message:"请完全松开按键后开始观察。")};_ = try soleDevice()
                executionStart=milliseconds();execution=try MacroExecutionEvidence(macro:Self.testMacro,playback:Self.playback,source:.hid,startedMilliseconds:executionStart);interruptions=[];raw=[]
                try set(.observing,"请按下并完全松开计算器键一次；预期 AB、AB，共八个按下／松开事件。");window?.makeFirstResponder(window?.contentView)
            }catch{fail(error.localizedDescription)}
        case .restoreReady:recover()
        case .complete:NSApp.terminate(nil)
        default:break
        }
    }
    func write(){
        guard let authorization else{return};do{_ = try soleDevice();busy=true;try set(.writing,"正在备份、写入并完整读回宏。请勿按键或拔线。")}catch{busy=false;fail(error.localizedDescription);return}
        queue.async{[self] in
            let result=Result<HardwareSnapshot,Error>{let usb=try CherryUSB(),log=try HardwareOperationLog(kind:"macro-test-write",directory:directory.appendingPathComponent("operations"));return try usb.applyMacro(authorization.expected,baseline:authorization.before,log:log,confirmStopped:stop)}
            DispatchQueue.main.async{[self] in busy=false;do{let snapshot=try result.get();try HardwareProfile(snapshot:snapshot).encoded().write(to:directory.appendingPathComponent("after-write.json"),options:.atomic)
                guard phase == .writing else{restore.isEnabled=true;return};action.title="开始实体输出观察";try set(.observeReady,"写入和完整读回一致。松开全部键，点击开始，再按计算器键。")
            }catch{fail(error.localizedDescription)}}
        }
    }
    @objc func confirmOff(){guard phase == .reconnect,off.state == .on,power?.confirmPowerOff(at:ProcessInfo.processInfo.systemUptime)==true else{off.state = .off;return};off.isEnabled=false;status.stringValue="关闭电源已确认；等待至少 15 秒，再开电、接 USB 并切换有线模式。";do{try persist()}catch{fail(error.localizedDescription,.loggingFailed)}}
    func tick(){
        if phase == .observing,let execution{
            do{let result=try execution.assessment(milliseconds:milliseconds());try persist()
                if result.status=="failed"{fail(result.failure ?? "宏执行检查失败。",.reportRejected);return}
                if result.passed{
                    if powerVerified{secondExecutionPassed=true;action.title="恢复原配置";try set(.restoreReady,"断电后的实体输出检查通过。点击恢复原配置，完成本轮测试。")}
                    else{firstExecutionPassed=true;action.title="等候断开";try set(.disconnect,"实体输出检查通过。请拔 USB 并关闭键盘电源；断开后勾选电源关闭确认。")}
                }else if milliseconds()-executionStart>300_000{fail("观察超时，请停止宏并恢复原配置。");return}
            }catch{fail(error.localizedDescription,.loggingFailed)}
        }
    }
    func connected(_ device:IOHIDDevice){
        guard phase == .reconnect,let id=registry(device),power?.reconnected(at:ProcessInfo.processInfo.systemUptime,registryID:id)==true else{return}
        guard power?.hasConfirmedPowerCycle==true else{fail("USB 在关闭电源确认前或 15 秒内重新连接，断电测试未通过；请恢复原配置。");return}
        readReconnected()
    }
    func removed(){
        adapter=MacroHIDObservationAdapter()
        if phase == .disconnect{power?.disconnected(at:ProcessInfo.processInfo.systemUptime);do{try set(.reconnect,"USB 已断开。请关闭键盘电源并勾选确认，至少等待 15 秒。");off.isEnabled=true}catch{fail(error.localizedDescription,.loggingFailed)}}
        else if phase != .reconnect && phase != .complete{fail("键盘在预定步骤外断开；本次测试未通过。请重连后恢复。",.observerDisconnected)}
    }
    func readReconnected(){
        do{_ = try soleDevice();busy=true;try set(.reading,"已检测到重连，先读取宏、绑定和其他配置；不会先重写目标。")}catch{busy=false;fail(error.localizedDescription);return}
        queue.async{[self] in
            let result=Result<HardwareSnapshot,Error>{try CherryUSB().completeSnapshot()}
            DispatchQueue.main.async{[self] in busy=false;do{let s=try result.get();try HardwareProfile(snapshot:s).encoded().write(to:directory.appendingPathComponent("after-reconnect.json"),options:.atomic)
                guard phase == .reading,let authorization,power?.hasConfirmedPowerCycle==true else{throw HardwareError(message:"断电／重连证据或阶段不足，不能判定保留。")}
                guard Self.matches(s,authorization.expected) else{throw HardwareError(message:"断电后宏／绑定未完整保留或其他配置变化；请恢复原配置。")}
                powerVerified=true;execution=nil;adapter=MacroHIDObservationAdapter();action.title="开始断电后输出观察";try set(.observeReady,"断电后宏、绑定和其他配置读回一致。点击开始，再按计算器键一次。")
            }catch{fail(error.localizedDescription)}}
        }
    }
    @objc func requestRestore(){guard !busy,authorization != nil else{return};if phase == .observing{execution?.invalidate(.cancelled);interruptions.append(.cancelled)};recover()}
    func recover(){
        guard let authorization else{return};do{_ = try soleDevice();busy=true;try set(.restoring,"正在按原事务范围读取并恢复原宏与绑定。请勿拔线或按键。")}catch{busy=false;fail(error.localizedDescription);return}
        queue.async{[self] in
            let result=Result<HardwareSnapshot,Error>{let usb=try CherryUSB(),log=try HardwareOperationLog(kind:"macro-test-recovery",directory:directory.appendingPathComponent("operations"));return try usb.recoverMacro(authorization,log:log,confirmStopped:stop)}
            DispatchQueue.main.async{[self] in busy=false;do{let s=try result.get();try HardwareProfile(snapshot:s).encoded().write(to:directory.appendingPathComponent("restored.json"),options:.atomic)
                guard Self.matches(s,authorization.before) else{throw HardwareError(message:"恢复读回不一致。")};restored=true;action.title="完成并关闭"
                try set(.complete,passed ? "本轮宏写入、两次实体输出、断电保留和恢复均通过。":"原配置已恢复；宏测试未完成全部验收，不计作通过。")
            }catch{fail(error.localizedDescription)}}
        }
    }
    func receive(_ value:IOHIDValue){
        let element=IOHIDValueGetElement(value),page=IOHIDElementGetUsagePage(element),usage=IOHIDElementGetUsage(element),v=IOHIDValueGetIntegerValue(value),at=Int(ledger.nanoseconds(IOHIDValueGetTimeStamp(value))/1_000_000)
        do{let event=try adapter.receive(page:page,usage:usage,value:v,milliseconds:at);guard phase == .observing,let event else{return}
            guard raw.count<65536 else{throw HardwareError(message:"记录容量已满。")};raw.append(["page":page,"usage":usage,"value":v,"milliseconds":at]);try execution?.observe(event);try persist()
        }catch{if phase == .observing || phase == .observeReady{fail(error.localizedDescription,.reportRejected)}}
    }
    func windowShouldClose(_ sender:NSWindow)->Bool{guard !busy,(authorization==nil || restored) else{status.stringValue="请先停止测试并恢复原配置；操作中不能关闭窗口。";return false};NSApp.terminate(nil);return true}
    func windowDidResignKey(_ notification:Notification){if phase == .observing{fail("窗口失去焦点，宏输出观察中止。请恢复原配置。",.focusLost)}}
    func applicationDidFinishLaunching(_ notification:Notification){
        do{guard !FileManager.default.fileExists(atPath:directory.path) else{throw HardwareError(message:"测试目录已存在，不能覆盖。")};try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true);try persist()}catch{fputs(error.localizedDescription+"\n",stderr);NSApp.terminate(nil);return}
        makeWindow(show:true)
        guard IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)==kIOHIDAccessTypeGranted else{fail("缺少输入监控权限；不能进行实体宏测试，未写入。");return}
        IOHIDManagerSetDeviceMatching(manager,[kIOHIDVendorIDKey:1130,kIOHIDProductIDKey:462,kIOHIDTransportKey:"USB"] as CFDictionary)
        IOHIDManagerRegisterInputValueCallback(manager,{context,result,_,value in guard let context else{return};let owner=Unmanaged<MacroHardwareTestController>.fromOpaque(context).takeUnretainedValue();if result==0{owner.receive(value)}else{owner.fail("HID 观察失败。",.reportRejected)}},Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerRegisterDeviceRemovalCallback(manager,{context,_,_,_ in guard let context else{return};Unmanaged<MacroHardwareTestController>.fromOpaque(context).takeUnretainedValue().removed()},Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerRegisterDeviceMatchingCallback(manager,{context,_,_,device in guard let context else{return};Unmanaged<MacroHardwareTestController>.fromOpaque(context).takeUnretainedValue().connected(device)},Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerScheduleWithRunLoop(manager,CFRunLoopGetMain(),CFRunLoopMode.defaultMode.rawValue);opened=IOHIDManagerOpen(manager,0)==0
        guard opened,devices().count==1,let d=devices().first,let id=registry(d),let location=IOHIDDeviceGetProperty(d,kIOHIDLocationIDKey as CFString) as? NSNumber else{fail("需要唯一的 USB 有线键盘和有效输入监控权限。");return}
        locationID=location.intValue;power=CalculatorPowerCycleEvidence(originalRegistryID:id)
        timer=Timer.scheduledTimer(withTimeInterval:0.1,repeats:true){[weak self] _ in self?.tick()}
        busy=true;queue.async{[self] in
            let result=Result<MacroWriteAuthorization,Error>{
                let s=try CherryUSB().completeSnapshot()
                let plan:MacroWriteAuthorization
                if let resumeDirectory{
                    plan=try Self.resumePlan(directory:resumeDirectory,current:s)
                    try HardwareProfile(snapshot:s).encoded().write(to:directory.appendingPathComponent("recovery-start.json"),options:.atomic)
                }else{plan=try Self.plan(s)}
                try HardwareProfile(snapshot:plan.before).encoded().write(to:directory.appendingPathComponent("original.json"),options:.atomic)
                try HardwareProfile(snapshot:plan.expected).encoded().write(to:directory.appendingPathComponent("target.json"),options:.atomic);return plan
            }
            DispatchQueue.main.async{[self] in busy=false;do{let plan=try result.get();guard phase == .preparing else{return};authorization=plan
                if resumeDirectory != nil{errorMessage="恢复以前中断的测试，不计作本轮宏验收通过。";action.title="恢复原配置";try set(.restoreReady,"已核对以前测试的原表、目标和当前配置。点击恢复原宏与计算器键；不会重写测试目标。")}
                else{action.title="备份并写入测试宏";try set(.ready,"已保存原配置和测试目标。点击后，仅把计算器键绑定到 AB 两次宏；灯效不变。")};detail.stringValue="测试完成将恢复原配置。日志：\(directory.path)"}catch{fail(error.localizedDescription)}}
        }
    }
    func makeWindow(show:Bool){
        NSApp.setActivationPolicy(.regular);let w=NSWindow(contentRect:NSRect(x:0,y:0,width:760,height:350),styleMask:[.titled,.closable],backing:.buffered,defer:false);window=w;w.title="CherryMac · 宏写入与断电测试";w.delegate=self;w.isReleasedWhenClosed=false
        let view=MacroTestInputView(frame:NSRect(x:0,y:0,width:760,height:350));w.contentView=view
        let title=NSTextField(labelWithString:"宏 · 写入、输出、断电保留与恢复");title.font = .systemFont(ofSize:22,weight:.semibold);title.frame=NSRect(x:22,y:295,width:716,height:32);view.addSubview(title)
        status.font = .systemFont(ofSize:16,weight:.medium);status.frame=NSRect(x:22,y:170,width:716,height:110);view.addSubview(status)
        detail.textColor = .secondaryLabelColor;detail.frame=NSRect(x:22,y:100,width:716,height:60);view.addSubview(detail)
        action.target=self;action.action=#selector(next);action.frame=NSRect(x:22,y:54,width:230,height:32);action.isEnabled=false;view.addSubview(action)
        restore.target=self;restore.action=#selector(requestRestore);restore.frame=NSRect(x:270,y:54,width:300,height:32);restore.isEnabled=false;view.addSubview(restore)
        action.bezelStyle = .rounded;restore.bezelStyle = .rounded
        off.target=self;off.action=#selector(confirmOff);off.frame=NSRect(x:22,y:12,width:700,height:30);off.isEnabled=false;view.addSubview(off)
        w.center();if show{w.makeKeyAndOrderFront(nil);w.makeFirstResponder(view);NSApp.activate(ignoringOtherApps:true)}
    }
    static func preview(_ url:URL)throws {
        let controller=MacroHardwareTestController();controller.makeWindow(show:false)
        controller.status.stringValue="写入和完整读回一致。松开全部键，点击开始，再按计算器键。"
        controller.detail.stringValue="完成输出检查后，窗口会提示断电重连，并恢复原配置。日志自动保存。"
        controller.action.title="开始实体输出观察";controller.action.isEnabled=true
        guard let view=controller.window?.contentView,let image=view.bitmapImageRepForCachingDisplay(in:view.bounds) else{throw HardwareError(message:"窗口预览失败。")}
        view.displayIfNeeded();view.cacheDisplay(in:view.bounds,to:image)
        guard let data=image.representation(using:.png,properties:[:]) else{throw HardwareError(message:"窗口图片保存失败。")};try data.write(to:url)
    }
    deinit{timer?.invalidate();if opened{IOHIDManagerUnscheduleFromRunLoop(manager,CFRunLoopGetMain(),CFRunLoopMode.defaultMode.rawValue);IOHIDManagerClose(manager,0)}}
    static func runOfflineTests()throws {
        let baseline=HardwareSnapshot.demo(),plan=try Self.plan(baseline)
        precondition(plan.before==baseline && plan.expected.parameters==baseline.parameters && plan.expected.colors==baseline.colors)
        for slot in 0..<126 where slot != 102{precondition(plan.expected.keymap[slot*3..<slot*3+3]==baseline.keymap[slot*3..<slot*3+3])}
        let library=try CherryMacroCodec.decode(plan.expected.macroData!);precondition(library.last?.steps==Self.testMacro.steps)
        let decoded=try CherryMacroCodec.playback(Array(plan.expected.keymap[306..<309]),macroCount:library.count);precondition(decoded==Self.playback)
        let existing=KeyboardMacro(name:"existing",steps:[.init(usage:4,pressed:true,delayMilliseconds:0,kind:.mouse),.init(usage:4,pressed:false,delayMilliseconds:50,kind:.mouse)])
        var occupied=baseline;occupied.macroData=try CherryMacroCodec.encode([existing]);occupied.keymap.replaceSubrange(324..<327,with:try CherryMacroCodec.binding(0,playback:MacroPlayback(count:3)))
        let appended=try Self.plan(occupied),decodedLibrary=try CherryMacroCodec.decode(appended.expected.macroData!)
        precondition(decodedLibrary.count==2 && decodedLibrary[0].steps==existing.steps && appended.expected.keymap[324..<327]==occupied.keymap[324..<327])
        var full=baseline;full.macroData=try CherryMacroCodec.encode((0..<32).map{KeyboardMacro(name:"macro \($0)",steps:existing.steps)})
        do{_ = try Self.plan(full);throw HardwareError(message:"full macro bank accepted")}catch let e as HardwareError{precondition(e.message != "full macro bank accepted")}
        var changed=baseline;changed.keymap[306]=0x20;do{_ = try Self.plan(changed);throw HardwareError(message:"non-original calculator accepted")}catch let e as HardwareError{precondition(e.message != "non-original calculator accepted")}
        var outside=plan.expected;outside.colors![0]^=1;precondition(!Self.matches(outside,plan.expected))
        var power=CalculatorPowerCycleEvidence(originalRegistryID:1);power.disconnected(at:1);precondition(power.confirmPowerOff(at:2));precondition(power.reconnected(at:17,registryID:2) && power.hasConfirmedPowerCycle)
        var early=CalculatorPowerCycleEvidence(originalRegistryID:1);early.disconnected(at:1);precondition(early.confirmPowerOff(at:2));precondition(early.reconnected(at:5,registryID:2) && !early.hasConfirmedPowerCycle)
        precondition(!early.reconnected(at:20,registryID:2) && !early.hasConfirmedPowerCycle)
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("CherryMacMacroFullFlow-\(UUID().uuidString)")
        defer{try? FileManager.default.removeItem(at:folder)};try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        try HardwareProfile(snapshot:plan.before).encoded().write(to:folder.appendingPathComponent("original.json"))
        try HardwareProfile(snapshot:plan.expected).encoded().write(to:folder.appendingPathComponent("target.json"))
        let resumed=try Self.resumePlan(directory:folder,current:plan.expected);precondition(resumed.before==plan.before && resumed.expected==plan.expected)
        do{_ = try Self.resumePlan(directory:folder,current:outside);throw HardwareError(message:"outside resume accepted")}catch let e as HardwareError{precondition(e.message != "outside resume accepted")}
        let controller=MacroHardwareTestController(directory:folder);controller.authorization=plan
        for afterPower in [false,true]{
            controller.powerVerified=afterPower;controller.phase = .observing;controller.executionStart=controller.milliseconds()-2000
            controller.execution=try MacroExecutionEvidence(macro:Self.testMacro,playback:Self.playback,source:.simulation,startedMilliseconds:controller.executionStart)
            for cycle in 0..<2{for (index,step) in Self.testMacro.steps.enumerated(){try controller.execution?.observe(.init(usage:step.usage,pressed:step.pressed,milliseconds:controller.executionStart+cycle*400+index*80))}}
            controller.tick();precondition(controller.phase==(afterPower ? .restoreReady:.disconnect))
            let data=try Data(contentsOf:folder.appendingPathComponent(afterPower ? "execution-after-power.json":"execution-before-power.json"))
            let log=try JSONDecoder().decode(MacroExecutionLog.self,from:data);precondition(log.source == .simulation && (try! log.replay()).passed)
        }
        precondition(controller.firstExecutionPassed && controller.secondExecutionPassed)
        controller.restored=true;precondition(controller.passed)
        controller.phase = .observing;controller.fail("simulated interruption",.focusLost);precondition(controller.phase == .failed && !controller.passed)
        print("PASS: macro hardware-flow plan preserves other keys/lights, requires original calculator, verifies full retained configuration and explicit power evidence (offline; manager never opened, no writes)")
    }
}
#endif
