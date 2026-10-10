#if CHERRY_MACRO_TEST
import Cocoa
import IOKit.hid
import CryptoKit
import Darwin

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
    enum Phase:String {case preparing,ready,writing,observeReady,observing,disconnect,reconnect,reading,restoreReady,restoring,complete,failed,cancelled}
    let manager=IOHIDManagerCreate(kCFAllocatorDefault,0),ledger=RawInputLedger()
    let queue=DispatchQueue(label:"local.cherrymac.macro-hardware-test")
    let directory:URL
    var scenario:Scenario
    var includePowerCycle:Bool
    let scenarioPicker=NSPopUpButton(frame:.zero,pullsDown:false)
    let powerOption=NSButton(checkboxWithTitle:"本轮同时测试断电保留（输出通过后按提示断电）",target:nil,action:nil)
    let resumeDirectory:URL?
    let status=NSTextField(wrappingLabelWithString:"正在核对设备和宏配置…")
    let detail=NSTextField(wrappingLabelWithString:"仅测试计算器键绑定的 AB 两次宏；日志自动保存。")
    let action=NSButton(title:"准备中",target:nil,action:nil)
    let off=NSButton(checkboxWithTitle:"已关闭键盘电源（不只是拔 USB）",target:nil,action:nil)
    let stopButton=NSButton(title:"已停止，核对输出",target:nil,action:nil)
    var stopMarker:MacroExecutionLog.Stop?
    let restore=NSButton(title:"停止测试并恢复原配置",target:nil,action:nil)
    var window:NSWindow?,timer:Timer?,opened=false,busy=false
    var phase:Phase = .preparing,authorization:MacroWriteAuthorization?,power:CalculatorPowerCycleEvidence?
    var adapter=MacroHIDObservationAdapter(),execution:MacroExecutionEvidence?,executionStart=0
    var powerVerified=false,firstExecutionPassed=false,secondExecutionPassed=false,restored=false
    var passed:Bool{firstExecutionPassed && (!includePowerCycle || (secondExecutionPassed && powerVerified)) && restored && errorMessage==nil && interruptions.isEmpty}
    var locationID:Int?,errorMessage:String?,raw:[[String:Any]]=[]
    var activeRegistryID:UInt64?,recoveryRebinds:[[String:Any]]=[]
    var factoryKeymap:[UInt8]?
    var executionArtifactHashes:[String:String]=[:]
    var frozenExecutionAssessmentMilliseconds:Int?
    var pendingLogSave=false,lastLogSaveMilliseconds:Int?
    var interruptions:[MacroExecutionEvidence.Interruption]=[]
    var writeAttempted=false
    var transitions:[[String:Any]]=[]
    static let playback=MacroPlayback(count:2)
    static let testMacro=KeyboardMacro(name:"CherryMac 实体测试 AB",steps:[.init(usage:4,pressed:true,delayMilliseconds:0),.init(usage:4,pressed:false,delayMilliseconds:80),.init(usage:5,pressed:true,delayMilliseconds:80),.init(usage:5,pressed:false,delayMilliseconds:80)])
    enum Scenario:String,CaseIterable {
        case abTwice="ab-twice",abOnce="ab-once",abThree="ab-three",maximumCount="ab-255",modifier="modifier",extended="keyboard-300",movement="mouse-xy"
        case official="official-ab",officialExtended="official-300"
        case mouseLeft="mouse-left",mouseRight="mouse-right",mouse="mouse",mouseBack="mouse-back",mouseForward="mouse-forward"
        case held="held",toggle="toggle"
        var isMouse:Bool{[Self.mouse,.mouseLeft,.mouseRight,.mouseBack,.mouseForward].contains(self)}
        var mouseCode:UInt8{
            switch self{case .mouseLeft:return 1;case .mouseRight:return 2;case .mouseBack:return 8;case .mouseForward:return 16;default:return 4}
        }
        var mouseName:String{
            switch self{case .mouseLeft:return "鼠标左键";case .mouseRight:return "鼠标右键";case .mouseBack:return "鼠标后退";case .mouseForward:return "鼠标前进";default:return "鼠标中键"}
        }
        var playback:MacroPlayback{MacroPlayback(mode:self == .held ? .held:self == .toggle ? .toggle:.count,count:self == .maximumCount ? 255:[Self.abTwice,.official].contains(self) ? 2:self == .abThree ? 3:1)}
        var macro:KeyboardMacro{
            switch self {
            case .abTwice,.abOnce,.abThree,.maximumCount,.held,.toggle,.official:return MacroHardwareTestController.testMacro
            case .modifier:return KeyboardMacro(name:"CherryMac 修饰键测试",steps:[
                .init(usage:225,pressed:true,delayMilliseconds:0),
                .init(usage:4,pressed:true,delayMilliseconds:80),
                .init(usage:4,pressed:false,delayMilliseconds:80),
                .init(usage:225,pressed:false,delayMilliseconds:80)])
            case .extended,.officialExtended:return KeyboardMacro(name:"CherryMac 300步容量测试",steps:(0..<150).flatMap{_ in [
                KeyboardMacro.Step(usage:4,pressed:true,delayMilliseconds:20),
                KeyboardMacro.Step(usage:4,pressed:false,delayMilliseconds:20)]})
            case .movement:return KeyboardMacro(name:"CherryMac XY位移测试",steps:[
                .init(usage:1,pressed:false,delayMilliseconds:100,kind:.mouseX),
                .init(usage:1,pressed:true,delayMilliseconds:100,kind:.mouseX),
                .init(usage:1,pressed:false,delayMilliseconds:100,kind:.mouseY),
                .init(usage:1,pressed:true,delayMilliseconds:100,kind:.mouseY),
                .init(usage:255,pressed:false,delayMilliseconds:100,kind:.mouseX),
                .init(usage:0,pressed:true,delayMilliseconds:100,kind:.mouseX),
                .init(usage:255,pressed:false,delayMilliseconds:100,kind:.mouseY),
                .init(usage:0,pressed:true,delayMilliseconds:100,kind:.mouseY)])
            case .mouse,.mouseLeft,.mouseRight,.mouseBack,.mouseForward:return KeyboardMacro(name:"CherryMac \(mouseName)测试",steps:[
                .init(usage:mouseCode,pressed:true,delayMilliseconds:0,kind:.mouse),
                .init(usage:mouseCode,pressed:false,delayMilliseconds:80,kind:.mouse)])
            }
        }
        var label:String{
            switch self {
            case .abTwice:return "AB 两次"
            case .abOnce:return "AB 一次"
            case .abThree:return "AB 三次"
            case .maximumCount:return "AB 255 次（次数上限）"
            case .modifier:return "Shift+A 一次（全部释放）"
            case .extended:return "300 步键盘宏（150 次 A，单次触发）"
            case .movement:return "X／Y 正负位移（含 +255／-256）"
            case .official:return "官方绑定存储：AB 两次"
            case .officialExtended:return "官方绑定存储：300 步单次"
            case .mouse,.mouseLeft,.mouseRight,.mouseBack,.mouseForward:return "\(mouseName)一次（按下并释放）"
            case .held:return "AB 按住持续、松开停止"
            case .toggle:return "AB 开关、再次按键停止"
            }
        }
        var instruction:String{
            if self == .held{return "按住计算器键约两秒，看到至少两轮 AB 后松开；再用鼠标点击「已停止，核对输出」。"}
            if self == .toggle{return "按一下并松开计算器键启动，约两秒后再次按一下并松开停止；再点击「已停止，核对输出」。"}
            if isMouse{return "先把鼠标指针移到窗口空白处，避开按钮和输入框，再按下并完全松开计算器键一次；预期 \(label)，共两个鼠标按钮事件。不要用实际鼠标代替键盘触发。"}
            if self == .movement{return "把指针移到屏幕中央，开始观察后不要移动实际鼠标；按一次计算器键并松开。预期X、Y依次各+1/-1，再各+255/-256，共8个非零轴回调；不以屏幕像素距离核对。"}
            if [Self.extended,.officialExtended].contains(self){return "只按下并松开计算器键一次，等待300个按下／松开事件及静默核对。每步设定等待20ms，总等待量约6秒，不代表实际固件时序已验证。"}
            if self == .maximumCount{return "只按下并松开计算器键一次，等候255轮AB、共1020个事件。设定等待总量约61秒；不要重复触发，完成后按提示恢复。"}
            return "请按下并完全松开计算器键一次；预期 \(label)，共 \(macro.steps.count*playback.count) 个按下／松开事件。"
        }
    }
    init(directory:URL?=nil,resumeDirectory:URL?=nil,scenario:Scenario = .abTwice,includePowerCycle:Bool?=nil){
        self.includePowerCycle=includePowerCycle ?? (scenario == .abTwice);self.scenario=scenario;self.resumeDirectory=resumeDirectory
        self.directory=directory ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CherryMac/HardwareTests/Macro-\(UUID().uuidString)");super.init()
    }
    static func plan(_ baseline:HardwareSnapshot,scenario:Scenario = .abTwice,factoryKeymap:[UInt8]?=nil)throws->MacroWriteAuthorization {
        try baseline.validate()
        guard Array(baseline.keymap[306..<309])==[0x30,0x92,0x01],let bank=baseline.macroData else{throw HardwareError(message:"本轮需要原始计算器键和完整宏备份，未授权写入。")}
        var library=try CherryMacroCodec.decode(bank)
        if [Scenario.official,.officialExtended].contains(scenario){
            guard let factoryKeymap,library.isEmpty,
                  !(0..<126).contains(where:{[UInt8(0x70),0x71].contains(baseline.keymap[$0*3])}) else{
                throw HardwareError(message:"官方布局验收需实际双遍默认表及无现存宏的基线；不会清除旧宏来准备测试。")
            }
            let receipt=try OfficialMacroDraftReceipt.prepare(before:baseline,factoryKeymap:factoryKeymap,
                macros:[scenario.macro],bindings:[102:scenario.macro.name],modes:[102:scenario.playback])
            try receipt.validate()
            guard (0..<126).filter({$0 != 102}).allSatisfy({receipt.expected.keymap[$0*3..<$0*3+3]==baseline.keymap[$0*3..<$0*3+3]}) else{
                throw HardwareError(message:"官方布局验收目标改变了其他键位，拒绝准备。")
            }
            return try MacroWriteAuthorization(baseline:baseline,target:receipt.expected,allowUnbounded:true)
        }
        if scenario == .extended{
            let (targetBank,index)=try appendExtendedRecord(bank,macro:scenario.macro)
            var target=baseline;target.macroData=targetBank
            target.keymap.replaceSubrange(306..<309,with:[0x70,index,0])
            return try MacroWriteAuthorization(baseline:baseline,target:target,allowUnbounded:true)
        }
        guard library.count<32 else{throw HardwareError(message:"宏库已满，测试不会覆盖现有宏。")}
        let index=library.count;library.append(scenario.macro)
        let headerReserved=bank[0]==0xaa && bank[1]==0x55 ? Array(bank[6..<16]):[]
        let encoded=try CherryMacroCodec.encode(library,headerReserved:headerReserved)
        let used=Int(encoded[2]) | Int(encoded[3])<<8
        var targetBank=bank;targetBank.replaceSubrange(0..<used,with:encoded[0..<used])
        var target=baseline;target.macroData=targetBank
        target.keymap.replaceSubrange(306..<309,with:try CherryMacroCodec.binding(index,playback:scenario.playback))
        return try MacroWriteAuthorization(baseline:baseline,target:target,allowUnbounded:true)
    }
    static func appendExtendedRecord(_ bank:[UInt8],macro:KeyboardMacro)throws->([UInt8],UInt8){
        let old=try CherryMacroCodec.decode(bank,maximumRecords:126,maximumEvents:762)
        guard old.count<126 else{throw HardwareError(message:"宏记录已满，容量测试不删除现有宏。")}
        let events=try CherryMacroCodec.encodeEvents(macro,maximumEvents:762)
        let recognized=bank[0]==0xaa && bank[1]==0x55
        let oldUsed=recognized ? Int(bank[2]) | Int(bank[3])<<8:16
        let oldTableEnd=16+old.count*2,newTableEnd=oldTableEnd+2,newStart=oldUsed+2
        let used=newStart+4+events.count
        guard used<=CherryMacroCodec.accessibleSize else{throw HardwareError(message:"剩余宏容量不足以追加300步；保留现有宏，未准备写入。")}
        var result=bank
        if !recognized{result.replaceSubrange(0..<16,with:Array(repeating:UInt8(0),count:16))}
        result[0]=0xaa;result[1]=0x55
        func word(_ offset:Int,_ value:Int){result[offset]=UInt8(value&255);result[offset+1]=UInt8(value>>8)}
        // Make room for one extra offset-table entry. Existing record bytes,
        // opaque gaps and reservations move together; no old events are re-encoded.
        result.replaceSubrange(newTableEnd..<newStart,with:bank[oldTableEnd..<oldUsed])
        for index in 0..<old.count{
            let position=16+index*2,offset=Int(bank[position]) | Int(bank[position+1])<<8
            word(position,offset+2)
        }
        word(oldTableEnd,newStart);word(newStart,macro.steps.count)
        result[newStart+2]=0;result[newStart+3]=0
        result.replaceSubrange(newStart+4..<used,with:events)
        word(2,used);word(4,old.count+1)
        let decoded=try CherryMacroCodec.decode(result,maximumRecords:126,maximumEvents:762)
        guard decoded.count==old.count+1,decoded.last?.steps==macro.steps,
              zip(old,decoded).allSatisfy({$0.steps==$1.steps && $0.hardwareReserved==$1.hardwareReserved}) else{
            throw HardwareError(message:"容量测试目标未保持现有宏事件与保留数据。")
        }
        return (result,UInt8(old.count))
    }
    struct RecoveryPlanReceipt:Codable {
        let format:String,version:Int,originalSHA256:String,targetSHA256:String
        let originalBytes:Int,targetBytes:Int
    }
    static func digest(_ data:Data)->String{SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
    static func savedRecoveryFile(_ url:URL)throws->Data {
        let descriptor=Darwin.open(url.path,O_RDONLY|O_NOFOLLOW|O_NONBLOCK)
        guard descriptor>=0 else{throw HardwareError(message:"恢复资料无法打开或是符号链接："+url.lastPathComponent)}
        let handle=FileHandle(fileDescriptor:descriptor,closeOnDealloc:true);defer{try? handle.close()}
        var metadata=stat()
        guard fstat(descriptor,&metadata)==0,metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_size>=0,metadata.st_size<=2_097_152 else{throw HardwareError(message:"恢复资料不是有效的大小受限普通文件。")}
        let data=try handle.read(upToCount:2_097_153) ?? Data()
        guard data.count==Int(metadata.st_size),data.count<=2_097_152 else{throw HardwareError(message:"恢复资料读取不完整或读取时发生变化。")}
        return data
    }
    static func saveRecoveryPlan(_ plan:MacroWriteAuthorization,directory:URL)throws {
        let original=try HardwareProfile(snapshot:plan.before).encoded(),target=try HardwareProfile(snapshot:plan.expected).encoded()
        try original.write(to:directory.appendingPathComponent("original.json"),options:.atomic)
        try target.write(to:directory.appendingPathComponent("target.json"),options:.atomic)
        let receipt=RecoveryPlanReceipt(format:"CherryMacMacroRecoveryPlan",version:1,
            originalSHA256:digest(original),targetSHA256:digest(target),originalBytes:original.count,targetBytes:target.count)
        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        // Publish the pairing receipt last. An interrupted replacement fails
        // digest checks rather than silently combining two different plans.
        try encoder.encode(receipt).write(to:directory.appendingPathComponent("recovery-plan.json"),options:.atomic)
    }
    static func resumePlan(directory:URL,current:HardwareSnapshot)throws->MacroWriteAuthorization {
        let receiptData=try savedRecoveryFile(directory.appendingPathComponent("recovery-plan.json"))
        let receipt=try JSONDecoder().decode(RecoveryPlanReceipt.self,from:receiptData)
        let original=try savedRecoveryFile(directory.appendingPathComponent("original.json")),targetData=try savedRecoveryFile(directory.appendingPathComponent("target.json"))
        guard receipt.format=="CherryMacMacroRecoveryPlan",receipt.version==1,
              receipt.originalBytes==original.count,receipt.targetBytes==targetData.count,
              receipt.originalSHA256==digest(original),receipt.targetSHA256==digest(targetData) else{
            throw HardwareError(message:"原配置与测试目标的恢复关联不一致，不能自动恢复。旧日志缺少关联文件时需单独核对。")
        }
        let before=try HardwareProfile.decode(original).snapshot
        let target=try HardwareProfile.decode(targetData).snapshot
        let plan=try MacroWriteAuthorization(baseline:before,target:target,allowUnbounded:true)
        try plan.validateRecovery(current);return plan
    }
    static func matches(_ a:HardwareSnapshot,_ b:HardwareSnapshot)->Bool{a.keymap==b.keymap && a.macroData==b.macroData && a.deviceInfo==b.deviceInfo && a.parameters==b.parameters && a.colors==b.colors}
    func milliseconds()->Int{Int(ledger.nanoseconds(mach_absolute_time())/1_000_000)}
    func encoded<T:Encodable>(_ value:T)throws->Data{let e=JSONEncoder();e.outputFormatting=[.prettyPrinted,.sortedKeys];return try e.encode(value)}
    func persist()throws {
        var session:[String:Any]=["format":"CherryMacMacroHardwareTest","version":2,"phase":phase.rawValue,"source":execution?.source.rawValue ?? "hid","passed":passed,"scenario":scenario.rawValue,"powerTestRequested":includePowerCycle,"scope":"calculator-slot "+scenario.label+" only; exact firmware delay and other playback modes require separate acceptance","firstExecutionPassed":firstExecutionPassed,"secondExecutionPassed":secondExecutionPassed,"retainedAfterConfirmedPowerCycle":powerVerified,"originalRestored":restored,"writeAttempted":writeAttempted,"transitions":transitions,"rawValues":raw,"powerOffEvidence":"explicit user confirmation; internal battery power is not measured"]
        if let errorMessage{session["error"]=errorMessage};if let locationID{session["locationID"]=locationID}
        if let activeRegistryID{session["activeRegistryID"]=String(activeRegistryID)}
        if let factoryKeymap{session["factoryKeymapByteSHA256"]=Self.digest(Data(factoryKeymap))}
        session["macroStoragePath"]=[Scenario.official,.officialExtended].contains(scenario) ? "OfficialMacroDraftReceipt.prepare":"research append/shared layout"
        session["recoveryRebinds"]=recoveryRebinds
        if let power{session["originalRegistryID"]=String(power.originalRegistryID);session["disconnectedAt"]=power.disconnectedAt;session["powerOffConfirmedAt"]=power.powerOffConfirmedAt;session["reconnectedAt"]=power.reconnectedAt;session["confirmedOffInterval"]=power.confirmedOffInterval}
        if let execution {
            let assessed=frozenExecutionAssessmentMilliseconds ?? max(milliseconds(),execution.observations.last?.milliseconds ?? executionStart)
            let log=MacroExecutionLog(format:"CherryMacMacroExecution",version:1,macro:scenario.macro,playback:scenario.playback,source:execution.source,startedMilliseconds:executionStart,events:execution.observations,stop:stopMarker,assessedMilliseconds:assessed,interruptions:interruptions)
            let data=try encoded(log),name=powerVerified ? "execution-after-power":"execution-before-power"
            try data.write(to:directory.appendingPathComponent(name+".json"),options:.atomic)
            let assessmentData=try encoded(MacroExecutionReport(inputSHA256:SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined(),assessment:try log.replay()))
            try assessmentData.write(to:directory.appendingPathComponent(name+"-assessment.json"),options:.atomic)
            executionArtifactHashes[name+".json"]=SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()
            executionArtifactHashes[name+"-assessment.json"]=SHA256.hash(data:assessmentData).map{String(format:"%02x",$0)}.joined()
        }
        session["executionArtifacts"]=executionArtifactHashes
        session["saveScope"]="Derived files first, session last; per-file atomic replacement, not a multi-file transaction or power-loss guarantee"
        session["savePolicy"]="Input callbacks mark dirty; timer attempts coalesced saves after 250ms; stage, stop and terminal saves are immediate. Forced termination can lose pending input."
        try JSONSerialization.data(withJSONObject:session,options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent("session.json"),options:.atomic)
        pendingLogSave=false;lastLogSaveMilliseconds=milliseconds()
    }
    func flushPendingLog(at now:Int)throws{
        guard pendingLogSave else{return}
        if let lastLogSaveMilliseconds,now-lastLogSaveMilliseconds<250{return}
        try persist()
    }
    func fail(_ message:String,_ interruption:MacroExecutionEvidence.Interruption = .cancelled){
        if phase == .observing{freezeExecutionAssessment()}
        if phase == .observing,execution != nil{execution?.invalidate(interruption);if !interruptions.contains(interruption){interruptions.append(interruption)}}
        scenarioPicker.isEnabled=false;stopButton.isEnabled=false;powerOption.isEnabled=false;phase = .failed;transitions.append(["phase":"failed","at":Date().timeIntervalSince1970,"error":message]);errorMessage=message;status.stringValue=message;action.isEnabled=false;off.isEnabled=false
        restore.isEnabled=authorization != nil && !busy;detail.stringValue="停止正在运行的宏；重连后可点击恢复。备份与日志：\(directory.path)";try? persist()
    }
    func freezeExecutionAssessment(at assessed:Int?=nil){
        if frozenExecutionAssessmentMilliseconds==nil,let execution{
            frozenExecutionAssessmentMilliseconds=max(assessed ?? milliseconds(),execution.observations.last?.milliseconds ?? executionStart)
        }
    }
    func set(_ next:Phase,_ text:String)throws{phase=next;transitions.append(["phase":next.rawValue,"at":Date().timeIntervalSince1970]);try persist()
        // UI completion follows a successful save of the derived evidence and
        // final session. The caller reports logging failure instead on throw.
        status.stringValue=text;action.isEnabled=[.ready,.observeReady,.restoreReady,.complete].contains(next);restore.isEnabled=authorization != nil && !busy && ![.ready,.complete,.cancelled].contains(next);
        if next != .observing{stopButton.isEnabled=false}
        scenarioPicker.isEnabled=next == .ready && !busy && !writeAttempted
        powerOption.isEnabled=next == .ready && !busy && !writeAttempted
    }
    func registry(_ device:IOHIDDevice)->UInt64?{var id:UInt64=0;return IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device),&id)==KERN_SUCCESS && id != 0 ? id:nil}
    func devices()->Set<IOHIDDevice>{IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []}
    func soleDevice()throws->IOHIDDevice{let all=devices();guard all.count==1,let d=all.first,
        (IOHIDDeviceGetProperty(d,kIOHIDLocationIDKey as CFString) as? NSNumber)?.intValue==locationID,
        let activeRegistryID,registry(d)==activeRegistryID else{throw HardwareError(message:"无法确认当前选定 USB 连接，停止操作。")};return d}
    static func boundUSB(_ expected:UInt64?)throws->CherryUSB{
        guard let expected,expected != 0 else{throw HardwareError(message:"测试缺少固定 USB 连接标识。")}
        let usb=try CherryUSB();try usb.requireReadOnlyObservationSession(expected);return usb
    }
    func rebindRecoveryIfNeeded()throws {
        // Only reached by the explicit restore action. The transport still
        // validates the saved transaction against a fresh complete readback.
        let all=devices()
        guard all.count==1,let device=all.first,let id=registry(device),id != 0,
              (IOHIDDeviceGetProperty(device,kIOHIDLocationIDKey as CFString) as? NSNumber)?.intValue==locationID else{
            throw HardwareError(message:"恢复需要原 USB 位置的唯一目标键盘。")
        }
        if id != activeRegistryID{
            recoveryRebinds.append(["previousRegistryID":activeRegistryID.map{String($0)} ?? "unknown",
                "registryID":String(id),"at":Date().timeIntervalSince1970,"scope":"recovery only; not power-cycle or execution evidence"])
            activeRegistryID=id;try persist()
        }
    }
    func stop(_ request:MacroStopRequest)throws{try MacroPhysicalStopController.confirm(request,owner:window,directory:directory.appendingPathComponent("stop-\(UUID().uuidString)"))}
    func selectScenario(_ selected:Scenario)throws{
        guard phase == .ready,!busy,!writeAttempted,let authorization else{throw HardwareError(message:"只可在首次写入前选择测试场景。")}
        let updated=try Self.plan(authorization.before,scenario:selected,factoryKeymap:factoryKeymap)
        try Self.saveRecoveryPlan(updated,directory:directory)
        self.authorization=updated;scenario=selected;includePowerCycle=selected == .abTwice
        scenarioPicker.selectItem(at:Scenario.allCases.firstIndex(of:selected)!)
        powerOption.state=includePowerCycle ? .on:.off;stopButton.isHidden=selected.playback.mode == .count
        try set(.ready,"本轮：\(selected.label)。原备份保留，目标已更新；点击写入后按提示操作。")
    }
    @objc func scenarioChanged(){
        guard Scenario.allCases.indices.contains(scenarioPicker.indexOfSelectedItem) else{return}
        do{try selectScenario(Scenario.allCases[scenarioPicker.indexOfSelectedItem])}catch{fail(error.localizedDescription)}
    }
    @objc func powerOptionChanged(){
        guard phase == .ready,!busy,!writeAttempted else{powerOption.state=includePowerCycle ? .on:.off;return}
        includePowerCycle=powerOption.state == .on
        do{try persist()}catch{fail(error.localizedDescription,.loggingFailed)}
    }
    @objc func next(){
        guard !busy,let event=NSApp.currentEvent,event.type == .leftMouseUp,event.modifierFlags.intersection([.control,.option,.command,.shift]).isEmpty else{return}
        switch phase {
        case .ready:write()
        case .observeReady:
            do{guard adapter.allReleased else{throw HardwareError(message:"请完全松开按键后开始观察。")};_ = try soleDevice()
                executionStart=milliseconds();execution=try MacroExecutionEvidence(macro:scenario.macro,playback:scenario.playback,source:.hid,startedMilliseconds:executionStart);frozenExecutionAssessmentMilliseconds=nil;stopMarker=nil;interruptions=[];raw=[]
                try set(.observing,scenario.instruction);window?.makeFirstResponder(window?.contentView)
            }catch{fail(error.localizedDescription)}
        case .restoreReady:recover()
        case .complete:NSApp.terminate(nil)
        default:break
        }
    }
    func markStopped(at now:Int)throws{
        guard phase == .observing,scenario.playback.mode != .count,stopMarker==nil,adapter.allReleased,let execution else{throw HardwareError(message:"请先停止宏并松开全部键，再确认停止。")}
        let assessment=try execution.assessment(milliseconds:now)
        guard assessment.completedCycles>=2,assessment.held.isEmpty,assessment.status != "failed" else{throw HardwareError(message:"需先观察至少两轮完整输出，并释放宏按键。")}
        try self.execution?.requestStop(milliseconds:now,source:.userAcknowledged)
        stopMarker = .init(milliseconds:now,source:.userAcknowledged);stopButton.isEnabled=false
        try persist();status.stringValue="已记录停止确认，继续观察释放及静默；检测到新的按下会使测试失败。"
    }
    @objc func confirmStopped(){
        guard !busy,let event=NSApp.currentEvent,event.type == .leftMouseUp,event.modifierFlags.intersection([.control,.option,.command,.shift]).isEmpty else{return}
        do{_ = try soleDevice();try markStopped(at:milliseconds())}catch{fail(error.localizedDescription,.reportRejected)}
    }
    func write(){
        guard let authorization else{return};writeAttempted=true;do{_ = try soleDevice();busy=true;try set(.writing,"正在备份、写入并完整读回宏。请勿按键或拔线。")}catch{busy=false;fail(error.localizedDescription);return}
        let expectedID=activeRegistryID
        queue.async{[self] in
            let result=Result<HardwareSnapshot,Error>{let usb=try Self.boundUSB(expectedID),log=try HardwareOperationLog(kind:"macro-test-write",directory:directory.appendingPathComponent("operations"));let snapshot=try usb.applyMacro(authorization.expected,baseline:authorization.before,log:log,confirmStopped:stop);try usb.requireReadOnlyObservationSession(expectedID!);return snapshot}
            DispatchQueue.main.async{[self] in busy=false;do{let snapshot=try result.get();try HardwareProfile(snapshot:snapshot).encoded().write(to:directory.appendingPathComponent("after-write.json"),options:.atomic)
                guard phase == .writing else{restore.isEnabled=true;return};action.title="开始实体输出观察";try set(.observeReady,"写入和完整读回一致。松开全部键，点击开始，再按计算器键。")
            }catch{fail(error.localizedDescription)}}
        }
    }
    @objc func confirmOff(){guard phase == .reconnect,off.state == .on,power?.confirmPowerOff(at:ProcessInfo.processInfo.systemUptime)==true else{off.state = .off;return};off.isEnabled=false;status.stringValue="关闭电源已确认；等待至少 15 秒，再开电、接 USB 并切换有线模式。";do{try persist()}catch{fail(error.localizedDescription,.loggingFailed)}}
    func tick(){
        if phase == .reconnect,let confirmed=power?.powerOffConfirmedAt{
            let remaining=max(0,Int(ceil(15-(ProcessInfo.processInfo.systemUptime-confirmed))))
            status.stringValue=remaining>0 ? "已确认关闭电源，还需等待 \(remaining) 秒；先不要开电或接 USB。":"15 秒已满。现在可以开电、接 USB 并切换到有线模式。"
        }
        if phase == .observing,let execution{
            if execution.source == .hid{
                do{_ = try soleDevice()}catch{fail(error.localizedDescription,.observerDisconnected);return}
            }
            do{let assessed=milliseconds();let result=try execution.assessment(milliseconds:assessed);stopButton.isEnabled=scenario.playback.mode != .count && stopMarker==nil && result.completedCycles>=2 && result.held.isEmpty && adapter.allReleased && result.status != "failed"
                if result.status=="failed"{fail(result.failure ?? "宏执行检查失败。",.reportRejected);return}
                if result.passed{
                    freezeExecutionAssessment(at:assessed)
                    if powerVerified{secondExecutionPassed=true;action.title="恢复原配置";try set(.restoreReady,"断电后的实体输出检查通过。点击恢复原配置，完成本轮测试。")}
                    else{firstExecutionPassed=true
                        if includePowerCycle{action.title="等候断开";try set(.disconnect,"实体输出检查通过。请拔 USB 并关闭键盘电源；断开后勾选电源关闭确认。")}
                        else{action.title="恢复原配置";try set(.restoreReady,"实体输出和释放检查通过。本轮未选择断电测试；保持 USB 连接，点击恢复原配置。")}
                    }
                }else if milliseconds()-executionStart>300_000{fail("观察超时，请停止宏并恢复原配置。");return}
                else{try flushPendingLog(at:assessed)}
            }catch{fail(error.localizedDescription,.loggingFailed)}
        }
    }
    func connected(_ device:IOHIDDevice){
        guard phase == .reconnect,let id=registry(device),power?.reconnected(at:ProcessInfo.processInfo.systemUptime,registryID:id)==true else{return}
        guard power?.hasConfirmedPowerCycle==true else{fail("USB 在关闭电源确认前或 15 秒内重新连接，断电测试未通过；请恢复原配置。");return}
        activeRegistryID=id;readReconnected()
    }
    func removed(){
        adapter=MacroHIDObservationAdapter()
        if phase == .disconnect{power?.disconnected(at:ProcessInfo.processInfo.systemUptime);do{try set(.reconnect,"USB 已断开。请关闭键盘电源并勾选确认，至少等待 15 秒。");off.isEnabled=true}catch{fail(error.localizedDescription,.loggingFailed)}}
        else if phase != .reconnect && phase != .complete{fail("键盘在预定步骤外断开；本次测试未通过。请重连后恢复。",.observerDisconnected)}
    }
    func readReconnected(){
        do{_ = try soleDevice();busy=true;try set(.reading,"已检测到重连，先读取宏、绑定和其他配置；不会先重写目标。")}catch{busy=false;fail(error.localizedDescription);return}
        let expectedID=activeRegistryID
        queue.async{[self] in
            let result=Result<HardwareSnapshot,Error>{let usb=try Self.boundUSB(expectedID);let snapshot=try usb.completeSnapshot();try usb.requireReadOnlyObservationSession(expectedID!);return snapshot}
            DispatchQueue.main.async{[self] in busy=false;do{let s=try result.get();try HardwareProfile(snapshot:s).encoded().write(to:directory.appendingPathComponent("after-reconnect.json"),options:.atomic)
                guard phase == .reading,let authorization,power?.hasConfirmedPowerCycle==true else{throw HardwareError(message:"断电／重连证据或阶段不足，不能判定保留。")}
                guard Self.matches(s,authorization.expected) else{throw HardwareError(message:"断电后宏／绑定未完整保留或其他配置变化；请恢复原配置。")}
                powerVerified=true;execution=nil;adapter=MacroHIDObservationAdapter();action.title="开始断电后输出观察";try set(.observeReady,"断电后宏、绑定和其他配置读回一致。点击开始，再按计算器键一次。")
            }catch{fail(error.localizedDescription)}}
        }
    }
    @objc func requestRestore(){guard !busy,authorization != nil,phase != .ready else{return};do{try rebindRecoveryIfNeeded()}catch{fail(error.localizedDescription,.observerDisconnected);return};if phase == .observing{freezeExecutionAssessment();execution?.invalidate(.cancelled);interruptions.append(.cancelled)};recover()}
    func recover(){
        guard let authorization else{return};do{_ = try soleDevice();busy=true;try set(.restoring,"正在按原事务范围读取并恢复原宏与绑定。请勿拔线或按键。")}catch{busy=false;fail(error.localizedDescription);return}
        let expectedID=activeRegistryID
        queue.async{[self] in
            let result=Result<HardwareSnapshot,Error>{let usb=try Self.boundUSB(expectedID),log=try HardwareOperationLog(kind:"macro-test-recovery",directory:directory.appendingPathComponent("operations"));let snapshot=try usb.recoverMacro(authorization,log:log,confirmStopped:stop);try usb.requireReadOnlyObservationSession(expectedID!);return snapshot}
            DispatchQueue.main.async{[self] in busy=false;do{let s=try result.get();try HardwareProfile(snapshot:s).encoded().write(to:directory.appendingPathComponent("restored.json"),options:.atomic)
                guard Self.matches(s,authorization.before) else{throw HardwareError(message:"恢复读回不一致。")};restored=true;action.title="完成并关闭"
                try set(.complete,passed ? (includePowerCycle ? "本轮宏写入、两次实体输出、断电保留和恢复均通过。":"本轮宏写入、实体输出和恢复通过；未测试断电保留。"):"原配置已恢复；宏测试未完成全部验收，不计作通过。")
            }catch{fail(error.localizedDescription)}}
        }
    }
    func receive(_ value:IOHIDValue){
        guard ![Phase.complete,.failed,.cancelled,.disconnect,.reconnect].contains(phase) else{return}
        let element=IOHIDValueGetElement(value),page=IOHIDElementGetUsagePage(element),usage=IOHIDElementGetUsage(element),v=IOHIDValueGetIntegerValue(value),at=Int(ledger.nanoseconds(IOHIDValueGetTimeStamp(value))/1_000_000)
        if activeRegistryID != nil{
            do{let device=try soleDevice();guard CFEqual(IOHIDElementGetDevice(element),device) else{throw HardwareError(message:"宏验收收到其他 USB 连接的输出。")}}
            catch{fail(error.localizedDescription,.observerDisconnected);return}
        }
        do{
            let isMovement=scenario == .movement && phase == .observing && MacroMovementHIDObservation.matches(element)
            let event=try isMovement ? MacroMovementHIDObservation.event(element,value:v,at:at,started:executionStart):adapter.receive(page:page,usage:usage,value:v,milliseconds:at)
            guard phase == .observing,let event else{return}
            guard raw.count<65536 else{throw HardwareError(message:"记录容量已满。")}
            var row:[String:Any]=["page":page,"usage":usage,"value":v,"milliseconds":at]
            if isMovement{row["reportID"]=IOHIDElementGetReportID(element);row["relative"]=IOHIDElementIsRelative(element);row["logicalMinimum"]=IOHIDElementGetLogicalMin(element);row["logicalMaximum"]=IOHIDElementGetLogicalMax(element)}
            raw.append(row);pendingLogSave=true;try execution?.observe(event)
        }catch{if phase == .observing || phase == .observeReady{fail(error.localizedDescription,.reportRejected)}}
    }
    func windowShouldClose(_ sender:NSWindow)->Bool{
        guard !busy,(authorization==nil || restored || (phase == .ready && !writeAttempted)) else{status.stringValue="请先停止测试并恢复原配置；操作中不能关闭窗口。";return false}
        if phase == .ready && !writeAttempted{
            do{try set(.cancelled,"已在首次写入前退出，未进行宏写入或验收。")}catch{status.stringValue="退出记录保存失败："+error.localizedDescription;return false}
        }
        NSApp.terminate(nil);return true
    }
    func windowDidResignKey(_ notification:Notification){if phase == .observing{fail("窗口失去焦点，宏输出观察中止。请恢复原配置。",.focusLost)}}
    func applicationDidFinishLaunching(_ notification:Notification){
        do{guard !FileManager.default.fileExists(atPath:directory.path) else{throw HardwareError(message:"测试目录已存在，不能覆盖。")};try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true);try persist()}catch{fputs(error.localizedDescription+"\n",stderr);NSApp.terminate(nil);return}
        makeWindow(show:true)
        guard IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)==kIOHIDAccessTypeGranted else{
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
            let name=Bundle.main.object(forInfoDictionaryKey:"CFBundleDisplayName") as? String ?? "CherryMac Macro Acceptance"
            fail("请在系统设置 → 隐私与安全性 → 输入监控中允许 \(name)，然后退出并重新打开测试 App。尚未写入键盘。");return
        }
        IOHIDManagerSetDeviceMatching(manager,[kIOHIDVendorIDKey:1130,kIOHIDProductIDKey:462,kIOHIDTransportKey:"USB"] as CFDictionary)
        IOHIDManagerRegisterInputValueCallback(manager,{context,result,_,value in guard let context else{return};let owner=Unmanaged<MacroHardwareTestController>.fromOpaque(context).takeUnretainedValue();guard ![Phase.complete,.failed,.cancelled].contains(owner.phase) else{return};if result==0{owner.receive(value)}else{owner.fail("HID 观察失败。",.reportRejected)}},Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerRegisterDeviceRemovalCallback(manager,{context,_,_,_ in guard let context else{return};Unmanaged<MacroHardwareTestController>.fromOpaque(context).takeUnretainedValue().removed()},Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerRegisterDeviceMatchingCallback(manager,{context,_,_,device in guard let context else{return};Unmanaged<MacroHardwareTestController>.fromOpaque(context).takeUnretainedValue().connected(device)},Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerScheduleWithRunLoop(manager,CFRunLoopGetMain(),CFRunLoopMode.defaultMode.rawValue);opened=IOHIDManagerOpen(manager,0)==0
        guard opened,devices().count==1,let d=devices().first,let id=registry(d),let location=IOHIDDeviceGetProperty(d,kIOHIDLocationIDKey as CFString) as? NSNumber else{fail("需要唯一的 USB 有线键盘和有效输入监控权限。");return}
        locationID=location.intValue;activeRegistryID=id;power=CalculatorPowerCycleEvidence(originalRegistryID:id)
        timer=Timer.scheduledTimer(withTimeInterval:0.1,repeats:true){[weak self] _ in self?.tick()}
        busy=true;queue.async{[self] in
            let result=Result<(MacroWriteAuthorization,[UInt8]?),Error>{
                let usb=try Self.boundUSB(id)
                let s=try usb.completeSnapshot();try usb.requireReadOnlyObservationSession(id)
                let plan:MacroWriteAuthorization
                var factory:[UInt8]?
                if let resumeDirectory{
                    plan=try Self.resumePlan(directory:resumeDirectory,current:s)
                    try HardwareProfile(snapshot:s).encoded().write(to:directory.appendingPathComponent("recovery-start.json"),options:.atomic)
                }else{
                    let first=try usb.read(7,count:378),second=try usb.read(7,count:378)
                    guard first==second,try usb.read(3,count:34)==s.deviceInfo,try usb.read(8,count:378)==s.keymap else{
                        throw HardwareError(message:"默认表两遍读取或基线核对不一致，未准备宏测试。")
                    }
                    try usb.requireReadOnlyObservationSession(id);factory=first
                    let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
                    try encoder.encode(first).write(to:directory.appendingPathComponent("factory-keymap.json"),options:.atomic)
                    plan=try Self.plan(s,scenario:scenario,factoryKeymap:first)
                }
                try Self.saveRecoveryPlan(plan,directory:directory);return (plan,factory)
            }
            DispatchQueue.main.async{[self] in busy=false;do{let (plan,factory)=try result.get();guard phase == .preparing else{return};authorization=plan;factoryKeymap=factory
                if resumeDirectory != nil{errorMessage="恢复以前中断的测试，不计作本轮宏验收通过。";action.title="恢复原配置";try set(.restoreReady,"已核对以前测试的原表、目标和当前配置。点击恢复原宏与计算器键；不会重写测试目标。")}
                else{action.title="备份并写入测试宏";try set(.ready,"已保存原配置和测试目标。点击后，仅把计算器键绑定到 \(scenario.label)；灯效不变。首次写入前可直接关闭窗口退出。")};detail.stringValue="测试完成将恢复原配置。日志：\(directory.path)"}catch{fail(error.localizedDescription)}}
        }
    }
    func makeWindow(show:Bool){
        detail.stringValue="本轮：\(scenario.label)。测试后恢复原配置；日志自动保存。"
        NSApp.setActivationPolicy(.regular);let w=NSWindow(contentRect:NSRect(x:0,y:0,width:760,height:420),styleMask:[.titled,.closable],backing:.buffered,defer:false);window=w;w.title="CherryMac · 宏写入与断电测试";w.delegate=self;w.isReleasedWhenClosed=false
        let view=MacroTestInputView(frame:NSRect(x:0,y:0,width:760,height:420));w.contentView=view
        let title=NSTextField(labelWithString:"宏 · 写入、输出、断电保留与恢复");title.font = .systemFont(ofSize:22,weight:.semibold);title.frame=NSRect(x:22,y:365,width:716,height:32);view.addSubview(title)
        status.font = .systemFont(ofSize:16,weight:.medium);status.frame=NSRect(x:22,y:240,width:716,height:110);view.addSubview(status)
        detail.textColor = .secondaryLabelColor;detail.frame=NSRect(x:22,y:195,width:716,height:40);view.addSubview(detail)
        let scenarioLabel=NSTextField(labelWithString:"本轮场景");scenarioLabel.frame=NSRect(x:22,y:129,width:85,height:24);view.addSubview(scenarioLabel)
        scenarioPicker.addItems(withTitles:Scenario.allCases.map{$0.label});scenarioPicker.selectItem(at:Scenario.allCases.firstIndex(of:scenario)!);scenarioPicker.target=self;scenarioPicker.action=#selector(scenarioChanged);scenarioPicker.isEnabled=false;scenarioPicker.frame=NSRect(x:116,y:126,width:500,height:28);view.addSubview(scenarioPicker)
        powerOption.state=includePowerCycle ? .on:.off;powerOption.target=self;powerOption.action=#selector(powerOptionChanged);powerOption.isEnabled=false;powerOption.frame=NSRect(x:22,y:162,width:716,height:28);view.addSubview(powerOption)
        action.target=self;action.action=#selector(next);action.frame=NSRect(x:22,y:54,width:230,height:32);action.isEnabled=false;view.addSubview(action)
        restore.target=self;restore.action=#selector(requestRestore);restore.frame=NSRect(x:270,y:54,width:300,height:32);restore.isEnabled=false;view.addSubview(restore)
        action.bezelStyle = .rounded;restore.bezelStyle = .rounded
        stopButton.target=self;stopButton.action=#selector(confirmStopped);stopButton.bezelStyle = .rounded;stopButton.isEnabled=false;stopButton.isHidden=scenario.playback.mode == .count;stopButton.frame=NSRect(x:580,y:54,width:158,height:32);view.addSubview(stopButton)
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
        for scenario in Scenario.allCases{
            let scoped=try Self.plan(baseline,scenario:scenario,factoryKeymap:baseline.keymap)
            let macros=try CherryMacroCodec.decode(scoped.expected.macroData!)
            precondition(macros.last?.steps==scenario.macro.steps)
            precondition(try! CherryMacroCodec.playback(Array(scoped.expected.keymap[306..<309]),macroCount:macros.count)==scenario.playback)
            precondition(scoped.before==baseline && scoped.expected.deviceInfo==baseline.deviceInfo && scoped.expected.parameters==baseline.parameters && scoped.expected.colors==baseline.colors)
            for slot in 0..<126 where slot != 102{precondition(scoped.expected.keymap[slot*3..<slot*3+3]==baseline.keymap[slot*3..<slot*3+3])}
            var evidence=try MacroExecutionEvidence(macro:scenario.macro,playback:scenario.playback,source:.simulation,startedMilliseconds:0)
            let cycles=scenario.playback.mode == .count ? scenario.playback.count:2
            for cycle in 0..<cycles{for (index,step) in scenario.macro.steps.enumerated(){
                try evidence.observe(.init(usage:step.usage,pressed:step.pressed,milliseconds:cycle*400+index*80,kind:step.kind))
            }}
            if scenario.playback.mode != .count{try evidence.requestStop(milliseconds:1500,source:.userAcknowledged)}
            let assessed=max(3000,(evidence.observations.last?.milliseconds ?? 0)+evidence.requiredQuietMilliseconds+100)
            let assessment=try evidence.assessment(milliseconds:assessed)
            precondition(assessment.passed && assessment.held.isEmpty && assessment.completedCycles==cycles && assessment.observedEvents==scenario.macro.steps.count*cycles)
            // An additional event must invalidate a completed finite macro.
            try evidence.observe(.init(usage:scenario.macro.steps[0].usage,pressed:true,milliseconds:assessed+100,kind:scenario.macro.steps[0].kind))
            precondition(!(try! evidence.assessment(milliseconds:assessed+1000)).passed)
            if scenario == .mouse{
                var wrong=try MacroExecutionEvidence(macro:scenario.macro,playback:scenario.playback,source:.simulation,startedMilliseconds:0)
                try wrong.observe(.init(usage:4,pressed:true,milliseconds:1))
                precondition(!(try! wrong.assessment(milliseconds:1000)).passed,"keyboard HID 4 must not match mouse middle button 4")
            }
        }
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
        try Self.saveRecoveryPlan(plan,directory:folder)
        let resumed=try Self.resumePlan(directory:folder,current:plan.expected);precondition(resumed.before==plan.before && resumed.expected==plan.expected)
        do{_ = try Self.resumePlan(directory:folder,current:outside);throw HardwareError(message:"outside resume accepted")}catch let e as HardwareError{precondition(e.message != "outside resume accepted")}
        let controller=MacroHardwareTestController(directory:folder);controller.authorization=plan
        try controller.set(.ready,"ready")
        precondition(!controller.restore.isEnabled && controller.action.isEnabled && !controller.writeAttempted)
        controller.requestRestore();precondition(controller.phase == .ready,"restore must not terminate a test before its first write")
        try controller.selectScenario(.held)
        precondition(controller.scenario == .held && !controller.includePowerCycle && !controller.stopButton.isHidden && controller.authorization?.before==baseline)
        let selectedTarget=try HardwareProfile.decode(Data(contentsOf:folder.appendingPathComponent("target.json"))).snapshot
        precondition(selectedTarget==controller.authorization?.expected)
        controller.writeAttempted=true
        do{try controller.selectScenario(.mouse);throw HardwareError(message:"post-write scenario change accepted")}catch let e as HardwareError{precondition(e.message != "post-write scenario change accepted")}
        controller.writeAttempted=false;try controller.selectScenario(.abTwice)

        try controller.set(.cancelled,"closed before write")
        let cancelled=try JSONSerialization.jsonObject(with:Data(contentsOf:folder.appendingPathComponent("session.json"))) as! [String:Any]
        precondition(cancelled["writeAttempted"] as! Bool==false && cancelled["passed"] as! Bool==false && (cancelled["transitions"] as! [[String:Any]]).last?["phase"] as? String == "cancelled")
        controller.writeAttempted=true;try controller.set(.observeReady,"write completed")
        precondition(controller.restore.isEnabled && controller.action.isEnabled)
        for afterPower in [false,true]{
            controller.powerVerified=afterPower;controller.phase = .observing;controller.executionStart=controller.milliseconds()-2000
            controller.execution=try MacroExecutionEvidence(macro:Self.testMacro,playback:Self.playback,source:.simulation,startedMilliseconds:controller.executionStart)
            for cycle in 0..<2{for (index,step) in Self.testMacro.steps.enumerated(){try controller.execution?.observe(.init(usage:step.usage,pressed:step.pressed,milliseconds:controller.executionStart+cycle*400+index*80))}}
            controller.tick();precondition(controller.phase==(afterPower ? .restoreReady:.disconnect))
            let data=try Data(contentsOf:folder.appendingPathComponent(afterPower ? "execution-after-power.json":"execution-before-power.json"))
            let log=try JSONDecoder().decode(MacroExecutionLog.self,from:data);precondition(log.source == .simulation && (try! log.replay()).passed)
        }
        for scenario in [Scenario.held,.toggle]{
            let repeating=MacroHardwareTestController(directory:folder,scenario:scenario)
            repeating.phase = .observing;repeating.executionStart=repeating.milliseconds()-3000
            repeating.execution=try MacroExecutionEvidence(macro:scenario.macro,playback:scenario.playback,source:.simulation,startedMilliseconds:repeating.executionStart)
            do{try repeating.markStopped(at:repeating.executionStart+1);throw HardwareError(message:"premature stop accepted")}catch let e as HardwareError{precondition(e.message != "premature stop accepted")}
            for cycle in 0..<2{for (i,step) in scenario.macro.steps.enumerated(){try repeating.execution?.observe(.init(usage:step.usage,pressed:step.pressed,milliseconds:repeating.executionStart+cycle*400+i*80))}}
            repeating.tick();precondition(repeating.phase == .observing && repeating.stopButton.isEnabled && !repeating.firstExecutionPassed)
            try repeating.markStopped(at:repeating.executionStart+1500);repeating.tick()
            precondition(repeating.phase == .restoreReady && repeating.firstExecutionPassed)
            let log=try JSONDecoder().decode(MacroExecutionLog.self,from:Data(contentsOf:folder.appendingPathComponent("execution-before-power.json")))
            precondition(log.stop?.source == .userAcknowledged && (try! log.replay()).passed)
        }
        let completedData=try Data(contentsOf:folder.appendingPathComponent("execution-after-power.json"))
        controller.phase = .reconnect;controller.fail("late reconnect failure")
        let retainedLog=try JSONDecoder().decode(MacroExecutionLog.self,from:Data(contentsOf:folder.appendingPathComponent("execution-after-power.json")))
        precondition(retainedLog.interruptions?.isEmpty == true && (try! retainedLog.replay()).passed)
        precondition(!completedData.isEmpty && !controller.passed)
        controller.errorMessage=nil
        precondition(controller.firstExecutionPassed && controller.secondExecutionPassed)
        controller.restored=true;precondition(controller.passed)
        controller.phase = .observing;controller.fail("simulated interruption",.focusLost);precondition(controller.phase == .failed && !controller.passed)
        let outputOnly=MacroHardwareTestController(directory:folder,scenario:.mouse)
        precondition(!outputOnly.includePowerCycle)
        outputOnly.executionStart=outputOnly.milliseconds()-2000;outputOnly.phase = .observing
        outputOnly.execution=try MacroExecutionEvidence(macro:Scenario.mouse.macro,playback:Scenario.mouse.playback,source:.simulation,startedMilliseconds:outputOnly.executionStart)
        for (i,step) in Scenario.mouse.macro.steps.enumerated(){try outputOnly.execution?.observe(.init(usage:step.usage,pressed:step.pressed,milliseconds:outputOnly.executionStart+i*80,kind:step.kind))}
        outputOnly.tick();precondition(outputOnly.phase == .restoreReady && outputOnly.firstExecutionPassed && !outputOnly.powerVerified && !outputOnly.secondExecutionPassed)
        outputOnly.restored=true;precondition(outputOnly.passed)
        print("PASS: macro hardware-flow plan preserves other keys/lights, requires original calculator, verifies full retained configuration and explicit power evidence (offline; manager never opened, no writes)")
    }
}
#endif
