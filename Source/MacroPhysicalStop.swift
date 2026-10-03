#if CHERRY_MACRO_TEST || CHERRY_MACRO_PRODUCT
import Cocoa
import IOKit.hid

private final class MacroStopPanelView:NSView {
    override func draw(_ dirtyRect:NSRect){NSColor.windowBackgroundColor.setFill();bounds.fill();super.draw(dirtyRect)}
}

// Explicit user stopping plus device-filtered quiet/release observation. This
// does not send a firmware stop command or claim to measure its internal state.
final class MacroPhysicalStopController:NSObject,NSWindowDelegate {
    static func requireAccess(beforeWrite:Bool=false)throws{
        guard IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)==kIOHIDAccessTypeGranted else{
            let name=Bundle.main.object(forInfoDictionaryKey:"CFBundleDisplayName") as? String ?? Bundle.main.object(forInfoDictionaryKey:"CFBundleName") as? String ?? "CherryMac"
            throw HardwareError(message:"请先在系统设置的输入监控中允许 \(name)，再重新打开。持续／开关宏需要停止观察权限。\(beforeWrite ? "尚未发送写包。":"后续写入已停止。")")
        }
    }
    let request:MacroStopRequest
    let directory:URL
    let completion:(Result<Void,Error>)->Void
    let manager=IOHIDManagerCreate(kCFAllocatorDefault,0)
    let ledger=RawInputLedger()
    let status=NSTextField(wrappingLabelWithString:"")
    let accept=NSButton(title:"所有持续宏已停止，全部键已松开",target:nil,action:nil)
    var window:NSWindow?,timer:Timer?,opened=false,finished=false,pendingAcknowledgement=false
    var adapter=MacroHIDObservationAdapter(),rows:[[String:Any]]=[]
    var lastActivity=0,quietMilliseconds=200,locationID:Int?
    var metadata:[String:Any]=[:]
    init(request:MacroStopRequest,directory:URL,completion:@escaping(Result<Void,Error>)->Void){
        self.request=request;self.directory=directory;self.completion=completion;super.init()
        quietMilliseconds=max(200,request.requirements.flatMap{$0.repeatingBindings}.map{$0.quietMilliseconds}.max() ?? 200)
    }
    func milliseconds()->Int{Int(ledger.nanoseconds(mach_absolute_time())/1_000_000)}
    func save()throws {
        var value=metadata
        value["format"]="CherryMacPhysicalMacroStop";value["version"]=1;value["phase"]=request.phase.rawValue
        value["scope"]="explicit user stop acknowledgement plus USB-filtered observed quiet/release; no firmware stop command or power-off proof"
        value["quietMilliseconds"]=quietMilliseconds;value["lastActivityMilliseconds"]=lastActivity;value["events"]=rows
        if let locationID{value["locationID"]=locationID}
        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        try encoder.encode(request).write(to:directory.appendingPathComponent("request.json"),options:.atomic)
        try JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent("stop.json"),options:.atomic)
    }
    func finish(_ result:Result<Void,Error>){
        guard !finished else{return};finished=true;timer?.invalidate();accept.isEnabled=false
        if opened{IOHIDManagerUnscheduleFromRunLoop(manager,CFRunLoopGetMain(),CFRunLoopMode.defaultMode.rawValue);IOHIDManagerClose(manager,0);opened=false}
        var result=result
        switch result{case .success:metadata["result"]="acknowledged";case .failure(let error):metadata["result"]="failed";metadata["error"]=error.localizedDescription}
        do{try save()}catch{result = .failure(error)}
        window?.close();completion(result)
    }
    func fail(_ message:String){finish(.failure(HardwareError(message:message)))}
    func windowShouldClose(_ sender:NSWindow)->Bool{if !finished{fail("停止确认已取消；未获得继续写入或恢复的条件。")} ;return true}
    func windowDidResignKey(_ notification:Notification){if !finished{fail("停止确认窗口失去焦点，停止后续写入。")} }
    func receive(page:UInt32,usage:UInt32,value:Int,at now:Int){
        guard !finished else{return}
        do{
            guard let event=try adapter.receive(page:page,usage:usage,value:value,milliseconds:now) else{return}
            guard rows.count<65536 else{throw HardwareError(message:"停止观察记录容量已满。")}
            rows.append(["page":page,"usage":usage,"value":value,"milliseconds":now,"pressed":event.pressed]);lastActivity=max(lastActivity,now)
            try save();tick()
        }catch{fail(error.localizedDescription)}
    }
    func tick(){
        guard !finished else{return}
        let remaining=max(0,quietMilliseconds-(milliseconds()-lastActivity))
        accept.isEnabled=opened && !pendingAcknowledgement && adapter.allReleased && remaining==0 && window?.isKeyWindow==true
        status.stringValue=adapter.allReleased ? "请先按键盘的方式停止所有持续宏。\n停止输出后还需观察 \(String(format:"%.1f",Double(remaining)/1000)) 秒，再用鼠标确认。":"仍检测到这把键盘输出的按键／鼠标按钮按住。请停止宏并完全松开。"
    }
    @objc func acknowledge(){
        guard let event=NSApp.currentEvent,event.type == .leftMouseUp,
              event.modifierFlags.intersection([.control,.option,.command,.shift]).isEmpty,
              opened,adapter.allReleased,milliseconds()-lastActivity>=quietMilliseconds,window?.isKeyWindow==true else{tick();return}
        guard !pendingAcknowledgement else{return}
        pendingAcknowledgement=true;accept.isEnabled=false
        let count=rows.count,activity=lastActivity,clicked=milliseconds()
        // Drain callbacks after the click. A click generated by this keyboard's
        // mouse macro must not act as the user's confirmation of its own stop.
        DispatchQueue.main.asyncAfter(deadline:.now()+0.25){[weak self] in
            guard let self,!self.finished else{return}
            guard self.opened,self.rows.count==count,self.lastActivity==activity,self.adapter.allReleased,self.window?.isKeyWindow==true else{
                self.fail("确认期间检测到键盘输出或窗口状态变化，停止后续发送。");return
            }
            self.metadata["userConfirmedStopped"]=true;self.metadata["acknowledgedMilliseconds"]=clicked
            self.metadata["postAcknowledgementQuietMilliseconds"]=self.milliseconds()-clicked
            self.metadata["limitation"]="Power-off and internal firmware cancellation are not instrumented. User explicitly confirms stopping; continued output or held state prevents acknowledgement."
            self.finish(.success(()))
        }
    }
    func show(relativeTo owner:NSWindow?,observe:Bool=true){
        do{guard !FileManager.default.fileExists(atPath:directory.path) else{throw HardwareError(message:"停止日志目录已存在，不能覆盖。")} ;try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true);lastActivity=milliseconds();try save()}
        catch{completion(.failure(error));return}
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:740,height:340),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        self.window=window;window.delegate=self;window.isReleasedWhenClosed=false;window.title="CherryMac · 停止持续宏"
        let view=MacroStopPanelView(frame:NSRect(x:0,y:0,width:740,height:340));window.contentView=view
        let title=NSTextField(labelWithString:request.phase == .recovery ? "恢复前，先停止键盘正在运行的宏":"改配置前，先停止键盘正在运行的宏")
        title.font = .systemFont(ofSize:21,weight:.semibold);title.frame=NSRect(x:22,y:286,width:696,height:32);view.addSubview(title)
        let bindings=request.requirements.flatMap{$0.repeatingBindings}
        let names=bindings.map{binding->String in
            let name=keyboardLayout().first(where:{CherryMatrix.slot($0)==binding.slot})?.label ?? "槽位 \(binding.slot)"
            return "\(name)：\(binding.playback.mode == .held ? "松开触发键":"用原触发键停止")"
        }
        let scroll=NSScrollView(frame:NSRect(x:22,y:168,width:696,height:105));scroll.hasVerticalScroller=true;scroll.autohidesScrollers=true;scroll.drawsBackground=false
        let instructions=NSTextView(frame:NSRect(x:0,y:0,width:696,height:105));instructions.isEditable=false;instructions.isSelectable=true
        instructions.font = .systemFont(ofSize:13);instructions.textColor = .labelColor;instructions.backgroundColor = .windowBackgroundColor
        instructions.isHorizontallyResizable=false;instructions.isVerticallyResizable=true;instructions.autoresizingMask=[.width]
        instructions.textContainer?.widthTracksTextView=true
        instructions.string=Array(Set(names)).sorted().joined(separator:"；")+"。\n如果不能确定已经停止，请取消，关闭键盘电源后重新连接、读取配置；这个窗口不会代替你停止宏。仅停止正在运行的宏，不要为了确认而启动它。"
        scroll.documentView=instructions;view.addSubview(scroll)
        if let container=instructions.textContainer,let layout=instructions.layoutManager{layout.ensureLayout(for:container);instructions.setFrameSize(NSSize(width:696,height:max(105,layout.usedRect(for:container).height+16)))}
        status.frame=NSRect(x:22,y:86,width:696,height:72);view.addSubview(status)
        accept.target=self;accept.action=#selector(acknowledge);accept.frame=NSRect(x:22,y:25,width:480,height:36);accept.isEnabled=false;view.addSubview(accept)
        let cancel=NSButton(title:"取消并停止发送",target:self,action:#selector(cancel));cancel.frame=NSRect(x:520,y:25,width:195,height:36);view.addSubview(cancel)
        if let owner{window.setFrameOrigin(NSPoint(x:owner.frame.midX-window.frame.width/2,y:owner.frame.midY-window.frame.height/2))}else{window.center()}
        window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
        guard observe else{window.title="CherryMac · 停止宏窗口离线预览";status.stringValue="离线布局预览，未连接键盘，也不发送命令。";return}
        do{try Self.requireAccess()}catch{fail(error.localizedDescription);return}
        IOHIDManagerSetDeviceMatching(manager,[kIOHIDVendorIDKey:1130,kIOHIDProductIDKey:462,kIOHIDTransportKey:"USB"] as CFDictionary)
        IOHIDManagerRegisterInputValueCallback(manager,{context,result,_,value in
            guard let context else{return};let owner=Unmanaged<MacroPhysicalStopController>.fromOpaque(context).takeUnretainedValue()
            guard result==0 else{owner.fail("停止观察 HID 回调失败。");return}
            let element=IOHIDValueGetElement(value)
            owner.receive(page:IOHIDElementGetUsagePage(element),usage:IOHIDElementGetUsage(element),value:IOHIDValueGetIntegerValue(value),at:Int(owner.ledger.nanoseconds(IOHIDValueGetTimeStamp(value))/1_000_000))
        },Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerRegisterDeviceRemovalCallback(manager,{context,_,_,_ in
            guard let context else{return};Unmanaged<MacroPhysicalStopController>.fromOpaque(context).takeUnretainedValue().fail("键盘已断开，停止该会话发送；重新连接后先读取。")} ,Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerScheduleWithRunLoop(manager,CFRunLoopGetMain(),CFRunLoopMode.defaultMode.rawValue)
        opened=IOHIDManagerOpen(manager,0)==0
        guard opened else{fail("无法打开只读停止观察，请检查输入监控权限。");return}
        let devices=IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []
        guard devices.count==1,let device=devices.first,let id=IOHIDDeviceGetProperty(device,kIOHIDLocationIDKey as CFString) as? NSNumber else{fail("无法确认唯一 USB 键盘，停止发送。");return}
        locationID=id.intValue;tick()
        timer=Timer.scheduledTimer(withTimeInterval:0.1,repeats:true){[weak self]_ in self?.tick()}
    }
    static func preview(_ output:URL)throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("CherryMacStopPreview-\(UUID().uuidString)")
        defer{try? FileManager.default.removeItem(at:directory)}
        let macro=KeyboardMacro(name:"AB",steps:[.init(usage:4,pressed:true,delayMilliseconds:0),.init(usage:4,pressed:false,delayMilliseconds:50)])
        var snapshot=HardwareSnapshot.demo();snapshot.macroData=try CherryMacroCodec.encode([macro]);snapshot.keymap.replaceSubrange(306..<309,with:try CherryMacroCodec.binding(0,playback:MacroPlayback(mode:.toggle)))
        let requirements=try CherryMacroCodec.completionRequirements(keymap:snapshot.keymap,macros:[macro])
        let controller=MacroPhysicalStopController(request:.init(phase:.beforeWrite,configurations:[snapshot],requirements:[requirements]),directory:directory){_ in}
        controller.show(relativeTo:nil,observe:false)
        guard let view=controller.window?.contentView,let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds) else{throw HardwareError(message:"无法生成停止窗口预览。")}
        controller.window?.displayIfNeeded();view.layoutSubtreeIfNeeded();view.displayIfNeeded();view.cacheDisplay(in:view.bounds,to:bitmap)
        guard let data=bitmap.representation(using:.png,properties:[:]) else{throw HardwareError(message:"停止窗口 PNG 生成失败。")}
        try data.write(to:output,options:.atomic);controller.finish(.failure(HardwareError(message:"offline preview ended")))
    }
    static func runOfflineTests()throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("CherryMacStopTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:directory)}
        let macro=KeyboardMacro(name:"held",steps:[.init(usage:4,pressed:true,delayMilliseconds:0),.init(usage:4,pressed:false,delayMilliseconds:50)])
        var snapshot=HardwareSnapshot.demo();snapshot.macroData=try CherryMacroCodec.encode([macro]);snapshot.keymap.replaceSubrange(306..<309,with:try CherryMacroCodec.binding(0,playback:MacroPlayback(mode:.held)))
        let requirements=try CherryMacroCodec.completionRequirements(keymap:snapshot.keymap,macros:[macro])
        var outcome:Result<Void,Error>?
        let controller=MacroPhysicalStopController(request:.init(phase:.beforeWrite,configurations:[snapshot],requirements:[requirements]),directory:directory){outcome=$0}
        precondition(controller.quietMilliseconds==250 && !controller.opened)
        controller.receive(page:7,usage:4,value:1,at:1000);precondition(!controller.adapter.allReleased)
        controller.receive(page:7,usage:4,value:0,at:1010);precondition(controller.adapter.allReleased)
        controller.receive(page:1,usage:0x30,value:1,at:1020);precondition(controller.finished && outcome != nil)
        if case .success? = outcome{preconditionFailure("unsupported output must not authorize writing")}
        let data=try Data(contentsOf:directory.appendingPathComponent("stop.json")),metadata=try JSONSerialization.jsonObject(with:data) as! [String:Any]
        precondition(metadata["result"] as? String == "failed" && metadata["userConfirmedStopped"]==nil)
        print("PASS: physical stop requirements, release tracking, unsupported output refusal and durable failure log (simulated; manager never opened)")
    }
    @objc func cancel(){fail("用户取消停止确认，停止后续写入或恢复。")}
    // Runs on the hardware queue; the main run loop stays responsive. The
    // caller owns the object until completion, including all HID callbacks.
    static func confirm(_ request:MacroStopRequest,owner:NSWindow?,directory:URL)throws {
        guard !Thread.isMainThread else{throw HardwareError(message:"停止确认须由硬件队列调用。")}
        let semaphore=DispatchSemaphore(value:0);var result:Result<Void,Error>?,controller:MacroPhysicalStopController?
        DispatchQueue.main.async{
            controller=MacroPhysicalStopController(request:request,directory:directory){outcome in result=outcome;semaphore.signal()}
            controller?.show(relativeTo:owner)
        }
        semaphore.wait();defer{withExtendedLifetime(controller){}};try result!.get()
    }
}
#endif
