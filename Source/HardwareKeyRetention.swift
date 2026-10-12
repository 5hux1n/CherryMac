#if CHERRY_LIGHTING_TEST || CHERRY_LIGHTING_PRODUCT
import Cocoa
import IOKit.hid
import Darwin

// Product read-only workflow. Creation performs no HID access; the user starts
// monitoring explicitly. The editor and its unsent drafts stay outside it.
final class KeyRetentionWindow:NSWindowController,NSWindowDelegate {
    let before:HardwareSnapshot,target:HardwareSnapshot,queue:DispatchQueue
    var directory=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CherryMac/HardwareLogs/KeyRetention-\(UUID().uuidString)")
    let state=NSTextField(wrappingLabelWithString:"尚未开始。窗口打开不会访问键盘或写入。")
    let startButton=NSButton(title:"开始记录并只读核对",target:nil,action:nil)
    let offButton=NSButton(title:"已关电",target:nil,action:nil)
    let checkButton=NSButton(title:"重连后只读核对",target:nil,action:nil)
    let filesButton=NSButton(title:"打开本轮资料",target:nil,action:nil)
    var manager:IOHIDManager?,registryID:UInt64?,cycle:CalculatorPowerCycleEvidence?
    var running=false,deviceAccessAttempted=false,revision=0,storageFailure:String?
    var session:[String:Any]=[:],events:[[String:Any]]=[]
    init(before:HardwareSnapshot,target:HardwareSnapshot,queue:DispatchQueue)throws {
        let authorization=try KeymapWriteAuthorization(baseline:before,keymap:target.keymap)
        guard !authorization.changedSlots.isEmpty,target.hasSameConfiguration(as:authorization.expected) else{throw HardwareError(message:"需要本窗口成功写入并核对的按键目标。")}
        self.before=before;self.target=target;self.queue=queue
        let panel=NSWindow(contentRect:NSRect(x:0,y:0,width:750,height:410),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        panel.title="CherryMac · 按键断电检查";super.init(window:panel);panel.delegate=self
        let root=FlippedView(frame:NSRect(x:0,y:0,width:750,height:410));panel.contentView=root
        func text(_ value:String,_ y:CGFloat,_ height:CGFloat){let field=NSTextField(wrappingLabelWithString:value);field.frame=NSRect(x:22,y:y,width:706,height:height);root.addSubview(field)}
        text("检查本窗口最近一次成功按键写入的保留情况",20,32)
        text("先开始记录并只读核对当前配置。提示后拔 USB、关闭键盘电源，点击“已关电”；至少 15 秒后开电、接 USB 并切回有线，再点击重连核对。不会发送写包、恢复配置或替换编辑草稿。",68,74)
        text("记录包含 USB 事件、用户关电确认及可见完整配置比较，不能证明电池实际断电、同一物理序列号或实体按键输出。尚待统一真机验收。",154,62)
        state.frame=NSRect(x:22,y:230,width:706,height:74);root.addSubview(state)
        for (button,action,x,width) in [(startButton,#selector(start),CGFloat(22),CGFloat(240)),(offButton,#selector(powerOff),CGFloat(276),CGFloat(130)),(checkButton,#selector(check),CGFloat(420),CGFloat(280))]{button.target=self;button.action=action;button.frame=NSRect(x:x,y:316,width:width,height:32);root.addSubview(button)}
        filesButton.target=self;filesButton.action=#selector(openFiles);filesButton.frame=NSRect(x:22,y:366,width:180,height:32);root.addSubview(filesButton)
        let close=NSButton(title:"完成",target:self,action:#selector(finish));close.frame=NSRect(x:570,y:366,width:130,height:32);root.addSubview(close)
        render()
    }
    required init?(coder:NSCoder){fatalError()}
    private func identifier(_ device:IOHIDDevice)->UInt64?{var value:UInt64=0;return IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device),&value)==KERN_SUCCESS ? value:nil}
    private func stopMonitor(){
        guard let manager else{return}
        IOHIDManagerRegisterDeviceRemovalCallback(manager,nil,nil);IOHIDManagerRegisterDeviceMatchingCallback(manager,nil,nil)
        IOHIDManagerUnscheduleFromRunLoop(manager,CFRunLoopGetMain(),CFRunLoopMode.commonModes.rawValue);IOHIDManagerClose(manager,0);self.manager=nil
    }
    private func startMonitor()throws {
        stopMonitor();registryID=nil;cycle=nil;deviceAccessAttempted=true
        let m=IOHIDManagerCreate(kCFAllocatorDefault,0),context=Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerSetDeviceMatching(m,[kIOHIDVendorIDKey:0x046A,kIOHIDProductIDKey:0x01CE,kIOHIDTransportKey:"USB"] as CFDictionary)
        IOHIDManagerRegisterDeviceRemovalCallback(m,{context,_,_,device in
            guard let context else{return};let owner=Unmanaged<KeyRetentionWindow>.fromOpaque(context).takeUnretainedValue()
            guard let removed=owner.identifier(device),owner.registryID==removed else{return}
            owner.revision += 1;owner.registryID=nil
            if let cycle=owner.cycle{owner.cycle=CalculatorPowerCycleEvidence(originalRegistryID:cycle.reconnectedRegistryID ?? cycle.originalRegistryID);owner.cycle?.disconnected(at:ProcessInfo.processInfo.systemUptime)}
            owner.session.removeValue(forKey:"current");owner.session.removeValue(forKey:"configurationMatches");owner.session["status"]="disconnected"
            owner.state.stringValue="已记录 USB 拔出。请关闭键盘电源，再点击“已关电”；只拔 USB 不算关闭电池供电。"
            owner.observe("usbDisconnected",registry:removed)
        },context)
        IOHIDManagerRegisterDeviceMatchingCallback(m,{context,_,_,device in
            guard let context else{return};let owner=Unmanaged<KeyRetentionWindow>.fromOpaque(context).takeUnretainedValue()
            guard let found=owner.identifier(device),owner.cycle?.reconnected(at:ProcessInfo.processInfo.systemUptime,registryID:found)==true else{return}
            owner.revision += 1;owner.registryID=found;owner.session["status"]="reconnected"
            owner.state.stringValue="已记录兼容键盘重连。切回有线，点击只读核对；过早接回需重新拔线、关电并等待。";owner.observe("usbReconnected",registry:found)
        },context)
        IOHIDManagerScheduleWithRunLoop(m,CFRunLoopGetMain(),CFRunLoopMode.commonModes.rawValue)
        guard IOHIDManagerOpen(m,0)==0 else{IOHIDManagerUnscheduleFromRunLoop(m,CFRunLoopGetMain(),CFRunLoopMode.commonModes.rawValue);throw HardwareError(message:"无法监测 USB，请检查输入监控权限。")}
        manager=m
        guard let devices=IOHIDManagerCopyDevices(m) as? Set<IOHIDDevice>,devices.count==1,let device=devices.first,let found=identifier(device) else{stopMonitor();throw HardwareError(message:"需连接且仅连接一把目标 USB 键盘。")}
        registryID=found;cycle=CalculatorPowerCycleEvidence(originalRegistryID:found)
    }
    private func sync(_ directory:URL)throws {
        let fd=Darwin.open(directory.path,O_RDONLY|O_NOFOLLOW);guard fd>=0 else{throw HardwareError(message:"无法同步断电记录目录。")};defer{Darwin.close(fd)}
        var info=stat();guard fstat(fd,&info)==0,(info.st_mode & S_IFMT)==S_IFDIR,fsync(fd)==0 else{throw HardwareError(message:"断电记录目录同步失败。")}
    }
    private func persist()throws {
        guard storageFailure==nil else{throw HardwareError(message:"断电记录保存失败："+(storageFailure ?? ""))}
        do{
            session["events"]=events
            if let cycle{session["powerCycle"]=["originalRegistryID":cycle.originalRegistryID,"disconnectedAt":cycle.disconnectedAt.map{$0 as Any} ?? NSNull(),"powerOffConfirmedAt":cycle.powerOffConfirmedAt.map{$0 as Any} ?? NSNull(),"reconnectedAt":cycle.reconnectedAt.map{$0 as Any} ?? NSNull(),"reconnectedRegistryID":cycle.reconnectedRegistryID.map{$0 as Any} ?? NSNull()]}
            let data=try JSONSerialization.data(withJSONObject:session,options:[.prettyPrinted,.sortedKeys])
            var missing:[URL]=[],cursor=directory
            while !FileManager.default.fileExists(atPath:cursor.path){missing.append(cursor);let parent=cursor.deletingLastPathComponent();guard parent != cursor else{throw HardwareError(message:"断电记录目录无效。")};cursor=parent}
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            for created in missing.reversed(){try sync(created);try sync(created.deletingLastPathComponent())}
            let url=directory.appendingPathComponent("session.json");try data.write(to:url,options:.atomic)
            let handle=try FileHandle(forWritingTo:url);defer{try? handle.close()};try handle.synchronize();try sync(directory)
            guard try Data(contentsOf:url)==data else{throw HardwareError(message:"断电记录读回不一致。")}
        }catch{storageFailure=error.localizedDescription;throw error}
    }
    private func observe(_ kind:String,registry:UInt64?=nil){
        guard events.count<4096 else{storageFailure="断电事件超过本轮记录上限。";render();return}
        var entry:[String:Any]=["kind":kind,"at":ISO8601DateFormatter().string(from:Date()),"uptime":ProcessInfo.processInfo.systemUptime];if let registry{entry["registryID"]=registry};events.append(entry)
        do{try persist()}catch{state.stringValue="记录保存失败，本轮不能通过：\(error.localizedDescription)"};render()
    }
    private func render(){
        startButton.isEnabled = !running && manager==nil
        offButton.isEnabled = !running && manager != nil && storageFailure==nil && cycle?.disconnectedAt != nil && cycle?.reconnectedAt==nil
        checkButton.isEnabled = !running && manager != nil && storageFailure==nil && cycle?.hasConfirmedPowerCycle==true && registryID==cycle?.reconnectedRegistryID
        filesButton.isEnabled = !running && !session.isEmpty
    }
    @objc func start(){
        guard !running,manager==nil else{return}
        do{
            directory=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CherryMac/HardwareLogs/KeyRetention-\(UUID().uuidString)")
            storageFailure=nil;events=[];revision += 1
            let encoder=JSONEncoder();session=["format":"CherryMacKeyRetentionSession","version":1,"id":UUID().uuidString,"at":ISO8601DateFormatter().string(from:Date()),"status":"prepared","before":try JSONSerialization.jsonObject(with:encoder.encode(before)),"target":try JSONSerialization.jsonObject(with:encoder.encode(target)),"evidenceScope":"USB events and user power-off confirmation; no proof of battery disconnection, physical serial identity or key output"]
            try persist();try startMonitor();readCurrent(retention:false)
        }catch{stopMonitor();state.stringValue=error.localizedDescription;render()}
    }
    @objc func powerOff(){guard !running,storageFailure==nil,cycle?.confirmPowerOff(at:ProcessInfo.processInfo.systemUptime)==true else{return};session["status"]="powerOffConfirmed";state.stringValue="已记录关电确认。至少 15 秒后开电、接 USB 并切回有线，再点击只读核对。";observe("userConfirmedPowerOff")}
    @objc func check(){guard !running,cycle?.hasConfirmedPowerCycle==true else{return};readCurrent(retention:true)}
    private func readCurrent(retention:Bool){
        guard !running,storageFailure==nil,let selected=registryID else{return}
        let startedRevision=revision,expectedCycle=cycle?.reconnectedRegistryID
        running=true;state.stringValue="正在只读核对，不修改编辑草稿或发送写包…";render()
        queue.async{[weak self] in
            guard let self else{return}
            let result:Result<HardwareSnapshot,Error>=Result{
                let log=try HardwareOperationLog(kind:"read");log.record("scope","key retention read-only");try log.requireHealthy()
                do{let usb=try CherryUSB();usb.trace=log.trace;guard try usb.lightingRegistryID()==selected else{throw HardwareError(message:"只读会话与选定 USB 不同。")}
                    let snapshot=try usb.completeSnapshot();guard try usb.lightingRegistryID()==selected else{throw HardwareError(message:"读回期间 USB 标识改变。")};log.record("phase","complete");try log.requireHealthy();return snapshot
                }catch{log.record("phase","failed");log.record("error",error.localizedDescription);throw error}
            }
            DispatchQueue.main.async{
                self.running=false
                do{
                    guard self.revision==startedRevision,self.registryID==selected,self.storageFailure==nil else{throw HardwareError(message:"读回期间连接或记录改变，请重新开始本轮检查。")}
                    if retention{guard self.cycle?.hasConfirmedPowerCycle==true,self.cycle?.reconnectedRegistryID==expectedCycle else{throw HardwareError(message:"关电确认或重连记录改变。")}}
                    let snapshot=try result.get();self.session["current"]=try JSONSerialization.jsonObject(with:JSONEncoder().encode(snapshot))
                    let matches=snapshot.hasSameConfiguration(as:self.target);self.session["configurationMatches"]=matches;self.session["status"]=retention ? (matches ? "readbackMatched":"readbackMismatch"):(matches ? "waitingDisconnect":"initialMismatch")
                    try self.persist()
                    if !matches{self.stopMonitor();self.state.stringValue="读回与最近写入目标不同。记录已保留；本入口没有恢复或再次写入键盘。"}
                    else{self.state.stringValue=retention ? "关电确认至少 15 秒后，可见完整配置与写入目标一致。实体键输出、电池实际断电和物理身份未由此证明。":"当前配置与目标一致。请拔 USB、关闭电源，再点击“已关电”；然后至少等待 15 秒再开电并接回。"}
                }catch{self.session["status"]="failed";self.session["failure"]=error.localizedDescription;if self.storageFailure==nil{try? self.persist()};self.stopMonitor();self.state.stringValue=error.localizedDescription}
                self.render()
            }
        }
    }
    @objc func openFiles(){guard !running,!session.isEmpty else{return};NSWorkspace.shared.open(directory)}
    @objc func finish(){guard !running else{return};stopMonitor();if let window{window.sheetParent?.endSheet(window);window.orderOut(nil)}}
    func windowShouldClose(_ sender:NSWindow)->Bool{guard !running else{return false};finish();return false}
}
#endif
