import Foundation
import IOKit.hid
import CoreGraphics

struct HardwareError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct CherryPacket {
    static let size = 64
    static func make(_ command: UInt8, payload: [UInt8] = []) throws -> [UInt8] {
        guard payload.count <= 60 else { throw HardwareError(message: "数据包过长。") }
        var bytes = [UInt8](repeating: 0, count: size)
        bytes[0] = 4; bytes[3] = command
        bytes.replaceSubrange(4..<(4 + payload.count), with: payload)
        let checksum = bytes[3...].reduce(0) { $0 + UInt16($1) }
        bytes[1] = UInt8(checksum & 255); bytes[2] = UInt8(checksum >> 8)
        return bytes
    }
    static func chunk(_ command: UInt8, offset: Int, length: Int, data: [UInt8] = []) throws -> [UInt8] {
        guard offset >= 0, offset <= 65535, length > 0, length <= 56,
              data.isEmpty || data.count == length else { throw HardwareError(message: "分块参数无效。") }
        return try make(command, payload: [UInt8(length), UInt8(offset & 255), UInt8(offset >> 8), 0] + data)
    }
    static func validate(_ reply: [UInt8], request: [UInt8]) throws {
        guard request.count == size, reply.count == size, reply[0] == 4, reply[3] == request[3] else {
            throw HardwareError(message: "键盘回复的报告或命令不匹配。")
        }
        let chunked = [UInt8(3),5,6,7,8,9,0x0A,0x0B,0x14,0x15,0x1B].contains(request[3])
        guard reply[7] != 0xFF, reply[7] != 0xFE else { throw HardwareError(message: "键盘拒绝命令 \(String(format: "%02x", request[3]))。") }
        guard reply[7] == request[7] else { throw HardwareError(message: "键盘回复包含未知状态或标志。") }
        if chunked {
            guard reply[4..<7].elementsEqual(request[4..<7]) else { throw HardwareError(message: "键盘回复分块偏移不匹配。") }
            guard reply[7] != 0xFF, reply[7] != 0xFE else { throw HardwareError(message: "键盘拒绝请求（范围或数据不受支持）。") }
        }
        let stored = UInt16(reply[1]) | UInt16(reply[2]) << 8
        let query = [UInt8(3),5,7,8,0x0A,0x14,0x1B].contains(request[3])
        let calculated = (query ? Array(request[3..<8]) : Array(request[3...])).reduce(0) { $0 + UInt16($1) }
        guard stored == calculated else { throw HardwareError(message: "键盘回复校验失败。") }
    }
}

struct HardwareSnapshot: Codable, Equatable {
    var format = "CherryMacHardware"
    var version = 1
    var vendorID = 0x046A
    var productID = 0x01CE
    var keymap: [UInt8]
    var deviceInfo: [UInt8]
    var parameters: [UInt8]
    var colors: [UInt8]?
    var macroData: [UInt8]? = nil
    var createdAt = Date()
    func validate() throws {
        guard format == "CherryMacHardware", version == 1, vendorID == 0x046A,
              productID == 0x01CE, keymap.count == 378, deviceInfo.count == 34, parameters.count == 56,
              colors == nil || colors?.count == 378,
              macroData == nil || macroData?.count == 3071 else { throw HardwareError(message: "此备份不适用于当前宝可梦键盘。") }
    }
}

enum HardwareWritePolicy {
    static let reason="此功能写入暂缓：灯效与宏写入尚未开放。请使用按键页面的独立键位写入。"
    static func requireWrites() throws {throw HardwareError(message:reason)}
    static func validateReadRequest(_ request:[UInt8]) throws {
        guard request.count==64,request[0]==4 else{throw HardwareError(message:"只读查询长度无效。")}
        let limits:[UInt8:Int]=[3:34,5:56,7:378,8:378,0x0A:378,0x14:3071,0x1B:126]
        guard let limit=limits[request[3]] else{try requireWrites();return}
        let count=Int(request[4]),offset=Int(request[5]) | Int(request[6])<<8
        let checksum=Int(request[1]) | Int(request[2])<<8
        guard count>0,count <= (request[3]==0x14 ? 54:56),offset+count<=limit,
              request[7]==0,request[8...].allSatisfy({$0==0}),
              checksum == request[3...].reduce(0,{ $0+Int($1) }) else{
            throw HardwareError(message:"只读查询参数无效，未发送到键盘。")
        }
    }
}

extension HardwareSnapshot {
    static func demo() -> HardwareSnapshot {
        var s=HardwareSnapshot(keymap:Array(repeating:0,count:378),deviceInfo:Array(repeating:0,count:34),parameters:Array(repeating:0,count:56),colors:Array(repeating:0,count:378),macroData:Array(repeating:0,count:3071))
        s.deviceInfo[6]=24;s.parameters.replaceSubrange(1..<9,with:[8,4,2,0,0,255,214,0])
        let modifiers:[Int:UInt8]=[4:2,82:32,5:1,11:8,17:4,65:64,83:16]
        for key in keyboardLayout(){
            guard let slot=CherryMatrix.slot(key) else{continue}
            let parts=key.usage?.split(separator:":"),page=parts.flatMap{Int($0[0])},usage=parts.flatMap{UInt16($0[1])} ?? (key.id=="caps" ? 57:0)
            var record:[UInt8]=page==12 ? [0x30,UInt8(usage&255),UInt8(usage>>8)]:[0x20,modifiers[slot] ?? 0,UInt8(usage&255)]
            if [6,71].contains(slot){record=[0xA0,slot==6 ? 3:1,0]}
            s.keymap.replaceSubrange(slot*3..<slot*3+3,with:record);s.colors!.replaceSubrange(slot*3..<slot*3+3,with:[255,214,0])
        }
        return s
    }
}

protocol CherryHardwareAccess: AnyObject {
    func exchange(_ request: [UInt8]) throws -> [UInt8]
    func read(_ command: UInt8, count: Int, baseOffset: Int) throws -> [UInt8]
    func snapshot(includeColors: Bool) throws -> HardwareSnapshot
    func waitUntilKeysReleased(timeout: TimeInterval) throws
    func backup(_ snapshot: HardwareSnapshot) throws -> URL
    func waitForMacroCompletion(seconds:TimeInterval) throws
}

extension CherryHardwareAccess {
    // Preparation only: no input listener, text posting or configuration write.
    // The owner must discard this routing after a write or USB reconnection.
    func readHostTextBindings(officialJSON:Data)throws->WindowsProfile.HostTextBindings {
        let before=try read(8,count:378)
        let factory=try read(7,count:378)
        let after=try read(8,count:378)
        guard before==after else{throw HardwareError(message:"准备文本监听期间键位发生变化，请重新读取。")}
        return try WindowsProfile.HostTextBindings(officialJSON:officialJSON,factoryKeymap:factory,currentKeymap:after)
    }
    func completeSnapshot() throws -> HardwareSnapshot {
        var snapshot=try snapshot(includeColors:true)
        guard snapshot.deviceInfo[6]==24 else {throw HardwareError(message:"宏容量与已验证固件不同，停止读取。")}
        snapshot.macroData=try read(0x14,count:3071)
        try snapshot.validate();return snapshot
    }
    func snapshotForBaseline(_ baseline:HardwareSnapshot?) throws -> HardwareSnapshot {
        if baseline?.macroData != nil{return try completeSnapshot()}
        return try snapshot(includeColors:true)
    }
    func read(_ command: UInt8, count: Int) throws -> [UInt8] {
        try read(command, count: count, baseOffset: 0)
    }
    func waitUntilKeysReleased() throws { try waitUntilKeysReleased(timeout: 5) }
    func backup(_ snapshot: HardwareSnapshot) throws -> URL { try snapshot.saveBackup() }
    func waitForMacroCompletion(seconds:TimeInterval) throws {
        let deadline=ProcessInfo.processInfo.systemUptime+seconds
        while ProcessInfo.processInfo.systemUptime<deadline {RunLoop.current.run(until:Date().addingTimeInterval(0.02))}
        try waitUntilKeysReleased()
    }
}

extension CherryHardwareAccess {
    // Reconnected recovery uses the saved before/target scope, including an
    // undecodable mixed bank. It never authorizes the mixed bank as a new plan.
    func restoreMacroTransaction(_ authorization:MacroWriteAuthorization,operationLog:HardwareOperationLog? = nil,confirmStopped:((MacroStopRequest)throws->Void)? = nil)throws->HardwareSnapshot {
        let original=authorization.before,target=authorization.expected
        operationLog?.record("phase","reconnect-recovery-read");try operationLog?.requireHealthy()
        let current=try completeSnapshot();try authorization.validateRecovery(current)
        func same(_ a:HardwareSnapshot,_ b:HardwareSnapshot)->Bool {a.deviceInfo==b.deviceInfo && a.parameters==b.parameters && a.colors==b.colors && a.keymap==b.keymap && a.macroData==b.macroData}
        if same(current,original){operationLog?.record("phase","original-already-present");try operationLog?.requireHealthy();return current}
        let saved=try backup(current);operationLog?.record("recoverySnapshot",saved.path);try operationLog?.requireHealthy();try waitUntilKeysReleased()
        if !authorization.beforeCompletion.repeatingBindings.isEmpty || !authorization.targetCompletion.repeatingBindings.isEmpty {
            guard let confirmStopped else{throw HardwareError(message:"缺少持续宏停止流程，未发送恢复写包。")}
            try confirmStopped(.init(phase:.recovery,configurations:[original,target],requirements:[authorization.beforeCompletion,authorization.targetCompletion]))
            try waitUntilKeysReleased();try operationLog?.requireHealthy()
        }
        try authorization.validateRecovery(completeSnapshot())
        func send(_ packet:[UInt8])throws{try authorization.validate(packet);try waitUntilKeysReleased();try operationLog?.requireHealthy();_ = try exchange(packet)}
        func keys(_ map:[UInt8])throws{for offset in stride(from:0,to:378,by:54){try send(CherryPacket.chunk(9,offset:offset,length:54,data:Array(map[offset..<offset+54])))}}
        operationLog?.record("phase","recovery-disable-triggers");try keys(authorization.disabled.keymap)
        try waitForMacroCompletion(seconds:Double(max(authorization.beforeDurationMilliseconds,authorization.targetDurationMilliseconds))/1000)
        guard let bank=original.macroData else{throw HardwareError(message:"缺少原宏备份。")}
        // Header last; no automatic second recovery/retry if a packet fails.
        operationLog?.record("phase","recovery-original-bank")
        for offset in authorization.changedOffsets.reversed(){let end=min(offset+54,3071);try send(CherryPacket.chunk(0x15,offset:offset,length:end-offset,data:Array(bank[offset..<end])))}
        guard try read(0x14,count:3071)==bank else{throw HardwareError(message:"重连恢复宏区读回不一致，停止发送。")}
        operationLog?.record("phase","recovery-original-bindings");try keys(original.keymap)
        let restored=try completeSnapshot();guard same(restored,original) else{throw HardwareError(message:"重连恢复完整读回不一致。")}
        operationLog?.record("phase","reconnect-recovery-complete");try operationLog?.requireHealthy();return restored
    }
}

extension CherryHardwareAccess {
    func writeMacroConfiguration(_ expected:HardwareSnapshot,baseline:HardwareSnapshot,operationLog:HardwareOperationLog? = nil,confirmStopped:((MacroStopRequest)throws->Void)? = nil) throws -> HardwareSnapshot {
        let authorization=try MacroWriteAuthorization(baseline:baseline,target:expected,allowUnbounded:confirmStopped != nil)
        guard let wanted=expected.macroData,let original=baseline.macroData else{throw HardwareError(message:"请重新读取包含宏数据的完整配置。")}
        let oldSlots=(0..<126).filter{[UInt8(0x70),0x71].contains(baseline.keymap[$0*3])}
        let before=try completeSnapshot()
        guard before.deviceInfo==baseline.deviceInfo,before.keymap==baseline.keymap,before.macroData==original,before.parameters==baseline.parameters,before.colors==baseline.colors else{throw HardwareError(message:"键盘配置已经变化，请重新读取后写入。")}
        if before.keymap==expected.keymap && original==wanted{return before}
        let backup=try backup(before)
        operationLog?.record("backup",backup.path);operationLog?.record("phase","backed-up");try operationLog?.requireHealthy()
        try waitUntilKeysReleased()
        let offsets=stride(from:0,to:3071,by:54).filter{offset in let end=min(offset+54,3071);return wanted[offset..<end] != original[offset..<end]}
        func keys(_ data:[UInt8])throws{
            for offset in stride(from:0,to:378,by:54){let packet=try CherryPacket.chunk(9,offset:offset,length:54,data:Array(data[offset..<offset+54]));try authorization.validate(packet);try waitUntilKeysReleased();_ = try exchange(packet)}
        }
        func bank(_ data:[UInt8])throws{
            // Write the pointer/header block last, after all event blocks.
            for offset in offsets.reversed(){let end=min(offset+54,3071);let packet=try CherryPacket.chunk(0x15,offset:offset,length:end-offset,data:Array(data[offset..<end]));try authorization.validate(packet);try waitUntilKeysReleased();_ = try exchange(packet)}
        }
        let disabled=authorization.disabled.keymap
        let drain=authorization.beforeDurationMilliseconds
        // Stop before disabling: a toggle macro may need its original trigger
        // to remain available. Do not infer cancellation from disabled keys.
        if !authorization.beforeCompletion.repeatingBindings.isEmpty {
            let request=MacroStopRequest(phase:.beforeWrite,configurations:[before],requirements:[authorization.beforeCompletion])
            operationLog?.record("phase","waiting-for-physical-macro-stop")
            guard let confirmStopped else{throw HardwareError(message:"缺少持续宏停止流程，未发送写包。")}
            try confirmStopped(request);try waitUntilKeysReleased();try operationLog?.requireHealthy()
            let stopped=try completeSnapshot()
            guard stopped.deviceInfo==before.deviceInfo,stopped.keymap==before.keymap,stopped.macroData==before.macroData,stopped.parameters==before.parameters,stopped.colors==before.colors else{throw HardwareError(message:"停止期间配置发生变化，未发送写包。")}
        }
        do {
            if !oldSlots.isEmpty {
                operationLog?.record("phase","disabling-old-triggers")
                try keys(disabled)
                // No new trigger is possible; let a previously started finite
                // sequence finish before changing its stored events.
                try waitForMacroCompletion(seconds:Double(drain)/1000)
            }
            operationLog?.record("phase","writing-macro-bank")
            try bank(wanted)
            guard try read(0x14,count:3071)==wanted else{throw HardwareError(message:"宏数据写后读取不一致。")}
            if expected.keymap != before.keymap || !oldSlots.isEmpty{operationLog?.record("phase","writing-macro-bindings");try keys(expected.keymap)}
            operationLog?.record("phase","readback")
            let after=try completeSnapshot()
            guard after.deviceInfo==before.deviceInfo,after.keymap==expected.keymap,after.macroData==wanted,after.parameters==before.parameters,after.colors==before.colors else{throw HardwareError(message:"宏和键位写后校验失败。")}
            return after
        }catch{
            let failure=error.localizedDescription
            if operationLog?.isCancelled==true{operationLog?.record("phase","cancelled-preserving-recovery");throw HardwareError(message:"宏写入已停止发送，尚未自动恢复。请使用最近宏写入恢复入口。备份：\(backup.path)")}
            operationLog?.record("writeError",failure);operationLog?.record("phase","recovery-preflight")
            do {
                try waitUntilKeysReleased()
                // Disable both old and newly introduced triggers before
                // restoring the original macro bank, then restore key bindings.
                try authorization.validateRecovery(completeSnapshot())
                if !authorization.beforeCompletion.repeatingBindings.isEmpty || !authorization.targetCompletion.repeatingBindings.isEmpty {
                    operationLog?.record("phase","waiting-for-physical-macro-stop-before-recovery")
                    guard let confirmStopped else{throw HardwareError(message:"缺少持续宏停止流程，保留备份并停止恢复。")}
                    try confirmStopped(.init(phase:.recovery,configurations:[before,expected],requirements:[authorization.beforeCompletion,authorization.targetCompletion]))
                    try waitUntilKeysReleased()
                    try authorization.validateRecovery(completeSnapshot())
                }
                try keys(authorization.disabled.keymap)
                let newDuration=authorization.targetDurationMilliseconds
                try waitForMacroCompletion(seconds:Double(max(drain,newDuration))/1000)
                operationLog?.record("phase","restoring-macro-and-bindings")
                try bank(original);try keys(before.keymap)
                let restored=try completeSnapshot()
                guard restored.deviceInfo==before.deviceInfo,restored.keymap==before.keymap,restored.macroData==original,restored.parameters==before.parameters,restored.colors==before.colors else{throw HardwareError(message:"宏恢复后读取不一致。")}
            }catch{throw HardwareError(message:"\(failure) 自动恢复失败：\(error.localizedDescription)。备份：\(backup.path)")}
            operationLog?.record("recovered",true)
            throw HardwareError(message:"\(failure) 已恢复原宏和键位。备份：\(backup.path)")
        }
    }
}

// Use a monotonic clock. A quick down/up, or any held modifier, resets the
// entire settling interval; seeing one empty report is insufficient.
struct ReleasedKeyGate {
    private var idleSince: TimeInterval?
    mutating func observe(anyKeyDown: Bool, now: TimeInterval) -> Bool {
        if anyKeyDown { idleSince = nil; return false }
        guard let since = idleSince else { idleSince = now; return false }
        return now - since >= 0.2
    }
}

// A session owns one run loop and is used only on the hardware serial queue.
// The keyboard remains available to macOS; no seize/detach options are used.
final class CherryUSB: CherryHardwareAccess {
    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    private var received: [[UInt8]] = []
    private let runLoop = CFRunLoopGetCurrent()!
    var trace: ((String) -> Void)?
    var observedReport: ((UInt32,[UInt8]) -> Void)?
    private var transportDead=false {didSet{if transportDead{stopHostTextObservation()}}}
    private var hostTextGeneration=UUID()
    private var hostTextRouting:WindowsProfile.HostTextBindings?
    private var hostTextSink:((WindowsProfile.HostTextBinding,WindowsProfile.HostTextTicket)->Void)?
    private var hostTextTicket:WindowsProfile.HostTextTicket?
    private(set) var hostTextObservationToken:UUID?
    // Access only on the owning hardware queue; the returned ticket itself
    // supports thread-safe cancellation from the main actor.
    var currentHostTextTicket:WindowsProfile.HostTextTicket?{hostTextTicket}
    func stopHostTextObservation(){
        hostTextTicket?.invalidate();hostTextTicket=nil
        hostTextGeneration=UUID();hostTextObservationToken=nil;hostTextRouting=nil;hostTextSink=nil
    }
    // Opt-in preparation on this session's hardware queue. No Unicode output
    // is sent here. A consumer must check the token when executing later.
    func startHostTextObservation(officialJSON:Data,onBinding:@escaping (WindowsProfile.HostTextBinding,WindowsProfile.HostTextTicket)->Void)throws {
        stopHostTextObservation()
        guard !transportDead,device != nil else{throw HardwareError(message:"USB 会话已失效，请重新连接。")}
        let generation=hostTextGeneration
        let routing=try readHostTextBindings(officialJSON:officialJSON)
        guard !transportDead,hostTextGeneration==generation else{throw HardwareError(message:"准备文本监听期间配置或 USB 会话发生变化，请重新读取。")}
        hostTextRouting=routing;hostTextSink=onBinding;hostTextObservationToken=generation;hostTextTicket=WindowsProfile.HostTextTicket(id:generation)
    }
    private var keymapAuthorization:KeymapWriteAuthorization?
    private var keymapLog:HardwareOperationLog?
    private var lastKeyWriteAt:TimeInterval?
    func applyKeymap(_ keymap:[UInt8],baseline:HardwareSnapshot,log:HardwareOperationLog) throws -> HardwareSnapshot {
        guard keymapAuthorization==nil else{throw HardwareError(message:"此会话已经用于键位写入，不能更换目标。")}
        #if CHERRY_MACRO_TEST || CHERRY_MACRO_PRODUCT
        guard macroAuthorization==nil else{throw HardwareError(message:"宏事务尚未结束，不能更换目标。")}
        #endif
        let authorization=try KeymapWriteAuthorization(baseline:baseline,keymap:keymap)
        try log.requireHealthy();keymapAuthorization=authorization;keymapLog=log;trace=log.trace
        log.record("changedSlots",authorization.changedSlots);log.record("phase","preflight")
        log.record("beforeKeymap",baseline.keymap);log.record("targetKeymap",keymap)
        do{
            let result=try writeKeymap(keymap,baseline:baseline,recoveryAuthorization:authorization,operationLog:log)
            log.record("phase","complete")
            do{try log.requireHealthy()}catch{throw HardwareError(message:"键位已写入并读回一致，但操作日志收尾失败：\(error.localizedDescription)")}
            return result
        }catch{log.record("phase","failed");log.record("error",error.localizedDescription);throw error}
    }
    #if CHERRY_MACRO_TEST || CHERRY_MACRO_PRODUCT
    private var macroAuthorization:MacroWriteAuthorization?
    func recoverMacro(_ authorization:MacroWriteAuthorization,log:HardwareOperationLog,confirmStopped:((MacroStopRequest)throws->Void)? = nil)throws->HardwareSnapshot {
        guard keymapAuthorization==nil,macroAuthorization==nil else{throw HardwareError(message:"已有写入事务，不能开始恢复。")}
        if !authorization.beforeCompletion.repeatingBindings.isEmpty || !authorization.targetCompletion.repeatingBindings.isEmpty{try MacroPhysicalStopController.requireAccess(beforeWrite:true)}
        try log.requireHealthy();macroAuthorization=authorization;keymapLog=log;trace=log.trace
        defer{macroAuthorization=nil;keymapLog=nil;trace=nil}
        log.record("scope","reconnected recovery of saved macro transaction only")
        do{ return try restoreMacroTransaction(authorization,operationLog:log,confirmStopped:confirmStopped) }
        catch{log.record("phase","reconnect-recovery-failed");log.record("error",error.localizedDescription);throw error}
    }
    func applyMacro(_ target:HardwareSnapshot,baseline:HardwareSnapshot,log:HardwareOperationLog,confirmStopped:((MacroStopRequest)throws->Void)? = nil)throws->HardwareSnapshot {
        guard keymapAuthorization==nil,macroAuthorization==nil else{throw HardwareError(message:"已有写入事务，不能更换目标。")}
        let authorization=try MacroWriteAuthorization(baseline:baseline,target:target,allowUnbounded:confirmStopped != nil)
        // Check before installing a repeating target: recovery must remain
        // available even when the original configuration contains no macro.
        if !authorization.beforeCompletion.repeatingBindings.isEmpty || !authorization.targetCompletion.repeatingBindings.isEmpty{try MacroPhysicalStopController.requireAccess(beforeWrite:true)}
        try log.requireHealthy();macroAuthorization=authorization;keymapLog=log;trace=log.trace
        defer{macroAuthorization=nil;keymapLog=nil;trace=nil}
        log.record("scope","macro bank and macro bindings only");log.record("before",try HardwareProfile(snapshot:baseline).encoded().base64EncodedString());log.record("target",try HardwareProfile(snapshot:target).encoded().base64EncodedString());log.record("phase","preflight")
        do{let result=try writeMacroConfiguration(target,baseline:baseline,operationLog:log,confirmStopped:confirmStopped);log.record("phase","complete");try log.requireHealthy();return result}
        catch{log.record("phase","failed");log.record("error",error.localizedDescription);throw error}
    }
    #endif
    #if CHERRY_CALCULATOR_TEST
    private var calculatorTestAuthorization:CalculatorKeyTestAuthorization?
    func authorizeCalculatorTest(baseline:HardwareSnapshot) throws {
        guard calculatorTestAuthorization==nil else{throw HardwareError(message:"此 USB 测试会话已经授权，不能更换基线。")}
        calculatorTestAuthorization=try CalculatorKeyTestAuthorization(baseline:baseline)
    }
    #endif
    init() throws {
        buffer.initialize(repeating: 0, count: 64)
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
        self.manager = manager
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: 0x046A, kIOHIDProductIDKey: 0x01CE, kIOHIDTransportKey: "USB"] as CFDictionary)
        let result = IOHIDManagerOpen(manager, 0)
        guard result == 0 else { transportDead=true;throw HardwareError(message: "无法打开 USB 键盘（\(result)）。请检查输入监控权限。") }
        let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []
        guard devices.count == 1, let device = devices.first else {
            throw HardwareError(message: "请用数据线连接一把宝可梦键盘并切换到有线模式。")
        }
        self.device = device
        let opened = IOHIDDeviceOpen(device, 0)
        guard opened == 0 else { throw HardwareError(message: "USB 接口打开失败（\(opened)）。") }
        IOHIDDeviceRegisterInputReportCallback(device, buffer, 64, { context, result, _, _, id, report, length in
            guard result == 0, length > 0, length <= 64, let context else { return }
            let owner = Unmanaged<CherryUSB>.fromOpaque(context).takeUnretainedValue()
            let bytes=Array(UnsafeBufferPointer(start:report,count:length))
            owner.observedReport?(id,bytes)
            if !owner.transportDead,id==5,let ticket=owner.hostTextTicket,ticket.isCurrent,
               let value=WindowsProfile.hostTextEvent(fullReport:bytes),let binding=owner.hostTextRouting?.binding(eventValue:value){
                owner.hostTextSink?(binding,ticket)
            }
            guard id == 4, length == 64 else {return}
            owner.received.append(bytes)
            if owner.received.count > 32 { owner.received.removeFirst() }
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDDeviceRegisterRemovalCallback(device,{context,_,_ in
            guard let context else{return}
            let owner=Unmanaged<CherryUSB>.fromOpaque(context).takeUnretainedValue()
            owner.transportDead=true;owner.keymapLog?.record("phase","disconnected")
        },Unmanaged.passUnretained(self).toOpaque())
        IOHIDDeviceScheduleWithRunLoop(device, runLoop, CFRunLoopMode.defaultMode.rawValue)
    }
    deinit {
        stopHostTextObservation()
        if let device {
            IOHIDDeviceUnscheduleFromRunLoop(device, runLoop, CFRunLoopMode.defaultMode.rawValue)
            IOHIDDeviceRegisterInputReportCallback(device, buffer, 64, nil, nil)
            IOHIDDeviceRegisterRemovalCallback(device,nil,nil)
            IOHIDDeviceClose(device, 0)
        }
        if let manager { IOHIDManagerClose(manager, 0) }
        buffer.deinitialize(count: 64); buffer.deallocate()
    }
    private func validateMacroResearchPacket(_ request:[UInt8])throws->Bool {
        #if CHERRY_MACRO_TEST || CHERRY_MACRO_PRODUCT
        if request.count==64,[UInt8(9),0x15].contains(request[3]),let authorization=macroAuthorization {
            try authorization.validate(request);return true
        }
        #endif
        return false
    }
    func exchange(_ request: [UInt8]) throws -> [UInt8] {
        if request.count==64,[UInt8(6),9,0x0B,0x15].contains(request[3]){stopHostTextObservation()}
        guard !transportDead else{throw HardwareError(message:"USB 会话已失效，停止发送。命令可能已执行，请重新连接并读取后恢复。")}
        let scopedWrite=try validateMacroResearchPacket(request)
        if scopedWrite{
            try keymapLog?.requireHealthy()
            if let lastKeyWriteAt{while ProcessInfo.processInfo.systemUptime-lastKeyWriteAt<1.5{RunLoop.current.run(until:Date().addingTimeInterval(0.02))}}
            try waitUntilKeysReleased()
        }else if request.count==64,request[3]==9,let authorization=keymapAuthorization {
            try authorization.validate(request);try keymapLog?.requireHealthy()
            if let lastKeyWriteAt{
                while ProcessInfo.processInfo.systemUptime-lastKeyWriteAt<1.5 {RunLoop.current.run(until:Date().addingTimeInterval(0.02))}
            }
            try waitUntilKeysReleased()
        }else{
        #if CHERRY_CALCULATOR_TEST
        if request.count==64,request[3]==9,let authorization=calculatorTestAuthorization {
            try authorization.validate(request)
            try waitUntilKeysReleased()
        }else{try HardwareWritePolicy.validateReadRequest(request)}
        #else
        try HardwareWritePolicy.validateReadRequest(request)
        #endif
        }
        guard let device, request.count == 64 else { throw HardwareError(message: "USB 会话已关闭。") }
        received.removeAll()
        trace?("OUT " + request.map { String(format: "%02x", $0) }.joined())
        if scopedWrite || (request[3]==9 && keymapAuthorization != nil){try keymapLog?.requireHealthy();lastKeyWriteAt=ProcessInfo.processInfo.systemUptime}
        let result = request.withUnsafeBufferPointer { IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 4, $0.baseAddress!, 64) }
        guard result == 0 else { transportDead=true;throw HardwareError(message: "USB 发送失败（\(result)）。") }
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            guard !transportDead else{throw HardwareError(message:"USB 已断开，命令可能已执行。停止发送，请重新连接并读取后恢复。")}
            if let index = received.firstIndex(where: { $0[3] == request[3] && (!([UInt8(3),5,6,7,8,9,0x0A,0x0B,0x14,0x15,0x1B].contains(request[3])) || $0[4..<7].elementsEqual(request[4..<7])) }) {
                let reply = received.remove(at: index)
                trace?("IN  " + reply.map { String(format: "%02x", $0) }.joined())
                do{try CherryPacket.validate(reply, request: request)}catch{transportDead=true;throw error}
                return reply
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        transportDead=true
        throw HardwareError(message: "键盘回复超时（命令 \(String(format: "%02x", request[3]))）。未自动重试写入。")
    }
    func read(_ command: UInt8, count: Int, baseOffset: Int = 0) throws -> [UInt8] {
        guard [UInt8(3),5,7,8,0x0A,0x14,0x1B].contains(command), count > 0, count <= (command==0x14 ? 3071:512), baseOffset >= 0, baseOffset + count <= (command==0x14 ? 3071:65536) else { throw HardwareError(message: "读取参数无效。") }
        var data: [UInt8] = []
        let chunkSize=command==0x14 ? 54:56
        for offset in stride(from: 0, to: count, by: chunkSize) {
            let size = min(chunkSize, count - offset)
            let reply = try exchange(CherryPacket.chunk(command, offset: baseOffset + offset, length: size))
            data += reply[8..<(8 + size)]
        }
        return data
    }
    func snapshot(includeColors: Bool = false) throws -> HardwareSnapshot {
        let result = HardwareSnapshot(keymap: try read(8, count: 378), deviceInfo: try read(3, count: 34), parameters: try read(5, count: 56), colors: includeColors ? try read(0x0A, count: 378) : nil)
        try result.validate(); return result
    }
    func waitForMacroCompletion(seconds:TimeInterval)throws {
        guard seconds.isFinite,seconds>=0 else{throw HardwareError(message:"宏等待时间无效。")}
        let deadline=ProcessInfo.processInfo.systemUptime+seconds
        while ProcessInfo.processInfo.systemUptime<deadline {
            guard !transportDead else{throw HardwareError(message:"等待宏完成期间 USB 已断开，停止后续发送。")}
            try keymapLog?.requireHealthy()
            RunLoop.current.run(until:Date().addingTimeInterval(0.02))
        }
        guard !transportDead else{throw HardwareError(message:"USB 已断开，停止后续发送。")}
        try waitUntilKeysReleased()
    }
    func waitUntilKeysReleased(timeout:TimeInterval = 5) throws {
        guard let device else {throw HardwareError(message:"USB 会话已关闭。")}
        let elements=IOHIDDeviceCopyMatchingElements(device,nil,0) as? [IOHIDElement] ?? []
        let buttons=elements.filter{element in
            IOHIDElementGetType(element)==kIOHIDElementTypeInput_Button && IOHIDElementGetUsage(element) != 0 && [UInt32(7),12,1,9].contains(IOHIDElementGetUsagePage(element))
        }
        guard !buttons.isEmpty else{throw HardwareError(message:"无法确认键盘按键状态，停止写入。")}
        let valueOut=UnsafeMutablePointer<Unmanaged<IOHIDValue>>.allocate(capacity:1)
        defer{valueOut.deallocate()}
        let deadline=ProcessInfo.processInfo.systemUptime + timeout
        var gate=ReleasedKeyGate()
        while ProcessInfo.processInfo.systemUptime < deadline {
            RunLoop.current.run(until:Date().addingTimeInterval(0.02))
            var down=false
            for element in buttons {
                let status=IOHIDDeviceGetValue(device,element,valueOut)
                guard status==0 else{throw HardwareError(message:"无法读取按键状态，停止写入。")}
                if IOHIDValueGetIntegerValue(valueOut.pointee.takeUnretainedValue()) != 0 {down=true;break}
            }
            let mask:CGEventFlags=[.maskCommand,.maskControl,.maskAlternate,.maskShift]
            down = down || !CGEventSource.flagsState(.hidSystemState).intersection(mask).isEmpty
            if gate.observe(anyKeyDown: down, now: ProcessInfo.processInfo.systemUptime) { return }
        }
        throw HardwareError(message:"无法确认全部按键已松开，已停止后续写入。请松开所有按键后重新读取键盘配置。")
    }
}

extension CherryHardwareAccess {
    func writeKey(index: Int, record: [UInt8]) throws {
        guard (0..<126).contains(index), record.count == 3 else { throw HardwareError(message: "键位记录无效。") }
        let before = try read(8, count: 378)
        var expected = before; expected.replaceSubrange((index*3)..<(index*3+3), with: record)
        try writeKeymap(expected)
    }
    @discardableResult
    func writeKeymap(_ data: [UInt8], baseline: HardwareSnapshot? = nil,recoveryAuthorization:KeymapWriteAuthorization? = nil,operationLog:HardwareOperationLog? = nil) throws -> HardwareSnapshot {
        guard data.count == 378 else { throw HardwareError(message: "键位表长度必须为 378 字节。") }
        let before=try snapshotForBaseline(baseline)
        if let baseline {
            try baseline.validate()
            guard before.deviceInfo==baseline.deviceInfo, before.keymap==baseline.keymap, before.parameters==baseline.parameters, before.colors==baseline.colors,
                  baseline.macroData==nil || before.macroData==baseline.macroData else {
                throw HardwareError(message:"键盘配置已经变化，请重新读取后再写入。")
            }
        }
        let changedMacros=(0..<126).filter{slot in
            [UInt8(0x70),0x71].contains(data[slot*3]) && data[slot*3..<slot*3+3] != before.keymap[slot*3..<slot*3+3]
        }
        if !changedMacros.isEmpty {
            guard let bank=before.macroData else{throw HardwareError(message:"新增宏绑定需要完整读取宏区。")}
            let macros=try CherryMacroCodec.decode(bank)
            for slot in changedMacros {
                guard data[slot*3]==0x70,data[slot*3+2]==0,Int(data[slot*3+1])<macros.count else{throw HardwareError(message:"宏绑定尚未写入，或模式不受支持。请使用宏与键位联合写入。")}
            }
        }
        if data==before.keymap { return before }
        let backup=try backup(before)
        operationLog?.record("backup",backup.path);operationLog?.record("phase","writing")
        try waitUntilKeysReleased()
        func send(_ bytes:[UInt8]) throws {
            // 07 is the factory table. 08 reads the actual user table.
            // This firmware rejects 01/02; 09 takes effect immediately.
            for offset in stride(from:0,to:bytes.count,by:54){
                try waitUntilKeysReleased()
                let block=Array(bytes[offset..<min(offset+54,bytes.count)])
                _=try exchange(CherryPacket.chunk(9,offset:offset,length:block.count,data:block))
            }
        }
        do {
            try send(data)
            operationLog?.record("phase","verifying")
            let after=try snapshotForBaseline(baseline)
            guard after.deviceInfo==before.deviceInfo, after.keymap==data, after.parameters==before.parameters, after.colors==before.colors,after.macroData==before.macroData else {
                throw HardwareError(message:"键位表写后读取不一致，或灯效发生意外变化。")
            }
            return after
        }catch{
            let failure=error.localizedDescription
            operationLog?.record("writeError",failure);operationLog?.record("phase","checking-recovery")
            do {
                // Never change a mapping while a key or modifier is held.
                if let recoveryAuthorization{try recoveryAuthorization.validateRecovery(snapshotForBaseline(baseline))}
                operationLog?.record("phase","restoring")
                try waitUntilKeysReleased();try send(before.keymap)
                let restored=try snapshotForBaseline(baseline)
                guard restored.deviceInfo==before.deviceInfo, restored.keymap==before.keymap, restored.parameters==before.parameters, restored.colors==before.colors,restored.macroData==before.macroData else{throw HardwareError(message:"恢复后配置仍不一致。")}
                operationLog?.record("recovered",true)
            }catch{throw HardwareError(message:"\(failure) 自动恢复失败：\(error.localizedDescription)。备份：\(backup.path)")}
            throw HardwareError(message:"\(failure) 已恢复写入前的键位表。备份：\(backup.path)")
        }
    }

}

extension HardwareSnapshot {
    func saveBackup() throws -> URL {
        try validate()
        let directory=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CherryMac/HardwareBackups")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let url=directory.appendingPathComponent("Before-write-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8)).json")
        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        try encoder.encode(self).write(to:url,options:.atomic)
        let saved=try JSONDecoder().decode(HardwareSnapshot.self,from:Data(contentsOf:url))
        try saved.validate()
        guard saved.keymap==keymap,saved.deviceInfo==deviceInfo,saved.parameters==parameters,saved.colors==colors,saved.macroData==macroData else{throw HardwareError(message:"自动备份读回不一致，未写入。")}
        return url
    }
}

extension CherryHardwareAccess {
    // This wireless firmware accepts immediate 06/0B writes. Its 01/02
    // transaction commands return FF and must not gate these writes.
    func writeLighting(_ expected:HardwareSnapshot, baseline:HardwareSnapshot) throws -> HardwareSnapshot {
        try expected.validate();try baseline.validate()
        guard let wanted=expected.colors, let original=baseline.colors,
              expected.parameters[0]==baseline.parameters[0],
              expected.parameters.dropFirst(9)==baseline.parameters.dropFirst(9),
              expected.parameters[1]<=23, expected.parameters[2]<=4, expected.parameters[3]<=4 else {
            throw HardwareError(message:"灯效配置包含不受支持的参数，请重新读取键盘。")
        }
        let before=try snapshotForBaseline(baseline)
        guard before.keymap==baseline.keymap, before.parameters==baseline.parameters,before.colors==original,
              baseline.macroData==nil || before.macroData==baseline.macroData else {
            throw HardwareError(message:"键盘配置已经变化，请重新读取后再写入。")
        }
        let backup=try backup(before)
        try waitUntilKeysReleased()
        let changed=(0..<126).filter{slot in
            wanted[slot*3..<slot*3+3] != original[slot*3..<slot*3+3]
        }
        func writeColors(_ colors:[UInt8]) throws {
            for slot in changed {
                try waitUntilKeysReleased()
                _=try exchange(CherryPacket.chunk(0x0B,offset:slot*3,length:3,data:Array(colors[slot*3..<slot*3+3])))
            }
        }
        func writeParameters(_ parameters:[UInt8]) throws {
            try waitUntilKeysReleased()
            _=try exchange(CherryPacket.make(6,payload:[9,0,0,0x55]+Array(parameters.prefix(9))))
        }
        do {
            try writeColors(wanted)
            if before.parameters.prefix(9) != expected.parameters.prefix(9){try writeParameters(expected.parameters)}
            let after=try snapshotForBaseline(baseline)
            guard after.parameters==expected.parameters, after.colors==wanted,after.keymap==before.keymap,after.macroData==before.macroData else {
                throw HardwareError(message:"灯效写入后读取不一致。")
            }
            return after
        }catch{
            let failure=error.localizedDescription
            do {
                try waitUntilKeysReleased()
                try writeColors(original);try writeParameters(before.parameters)
                let restored=try snapshotForBaseline(baseline)
                guard restored.keymap==before.keymap,restored.parameters==before.parameters,restored.colors==before.colors,restored.macroData==before.macroData else {
                    throw HardwareError(message:"恢复后配置仍不一致。")
                }
            }catch{
                throw HardwareError(message:"\(failure) 自动恢复失败：\(error.localizedDescription)。备份：\(backup.path)")
            }
            throw HardwareError(message:"\(failure) 已恢复写入前的配置。备份：\(backup.path)")
        }
    }
}
