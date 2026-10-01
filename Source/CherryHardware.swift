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

protocol CherryHardwareAccess: AnyObject {
    func exchange(_ request: [UInt8]) throws -> [UInt8]
    func read(_ command: UInt8, count: Int, baseOffset: Int) throws -> [UInt8]
    func snapshot(includeColors: Bool) throws -> HardwareSnapshot
    func waitUntilKeysReleased(timeout: TimeInterval) throws
    func backup(_ snapshot: HardwareSnapshot) throws -> URL
    func waitForMacroCompletion(seconds:TimeInterval) throws
}

extension CherryHardwareAccess {
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
    func writeMacroConfiguration(_ expected:HardwareSnapshot,baseline:HardwareSnapshot) throws -> HardwareSnapshot {
        try expected.validate();try baseline.validate()
        guard let wanted=expected.macroData,let original=baseline.macroData else{throw HardwareError(message:"请重新读取包含宏数据的完整配置。")}
        let macros=try CherryMacroCodec.decode(wanted),oldMacros=try CherryMacroCodec.decode(original)
        let oldSlots=(0..<126).filter{[UInt8(0x70),0x71].contains(baseline.keymap[$0*3])}
        let newSlots=(0..<126).filter{[UInt8(0x70),0x71].contains(expected.keymap[$0*3])}
        for slot in oldSlots {
            let record=Array(baseline.keymap[slot*3..<slot*3+3])
            guard record[0]==0x70,record[2]==0,Int(record[1])<oldMacros.count else{throw HardwareError(message:"原配置包含重复宏或未知宏绑定，暂不能覆盖；请保留原配置。")}
        }
        for slot in newSlots {
            let record=Array(expected.keymap[slot*3..<slot*3+3])
            guard record[0]==0x70,record[2]==0,Int(record[1])<macros.count else{throw HardwareError(message:"宏绑定无效，或不是执行一次模式。")}
        }
        let before=try completeSnapshot()
        guard before.keymap==baseline.keymap,before.macroData==original,before.parameters==baseline.parameters,before.colors==baseline.colors else{throw HardwareError(message:"键盘配置已经变化，请重新读取后写入。")}
        if before.keymap==expected.keymap && original==wanted{return before}
        let backup=try backup(before)
        try waitUntilKeysReleased()
        let offsets=stride(from:0,to:3071,by:54).filter{offset in let end=min(offset+54,3071);return wanted[offset..<end] != original[offset..<end]}
        func keys(_ data:[UInt8])throws{
            for offset in stride(from:0,to:378,by:54){try waitUntilKeysReleased();_ = try exchange(CherryPacket.chunk(9,offset:offset,length:54,data:Array(data[offset..<offset+54])))}
        }
        func bank(_ data:[UInt8])throws{
            // Write the pointer/header block last, after all event blocks.
            for offset in offsets.reversed(){try waitUntilKeysReleased();let end=min(offset+54,3071);_ = try exchange(CherryPacket.chunk(0x15,offset:offset,length:end-offset,data:Array(data[offset..<end])))}
        }
        var disabled=before.keymap
        for slot in oldSlots{disabled.replaceSubrange(slot*3..<slot*3+3,with:[0x20,0,0])}
        let drain=oldSlots.map{slot in oldMacros[Int(before.keymap[slot*3+1])].steps.reduce(0){$0+$1.delayMilliseconds}}.max() ?? 0
        do {
            if !offsets.isEmpty && !oldSlots.isEmpty {
                try keys(disabled)
                // No new trigger is possible; let a previously started finite
                // sequence finish before changing its stored events.
                try waitForMacroCompletion(seconds:Double(drain)/1000)
            }
            try bank(wanted)
            guard try read(0x14,count:3071)==wanted else{throw HardwareError(message:"宏数据写后读取不一致。")}
            if expected.keymap != before.keymap || (!offsets.isEmpty && !oldSlots.isEmpty){try keys(expected.keymap)}
            let after=try completeSnapshot()
            guard after.keymap==expected.keymap,after.macroData==wanted,after.parameters==before.parameters,after.colors==before.colors else{throw HardwareError(message:"宏和键位写后校验失败。")}
            return after
        }catch{
            let failure=error.localizedDescription
            do {
                try waitUntilKeysReleased()
                // Disable both old and newly introduced triggers before
                // restoring the original macro bank, then restore key bindings.
                var safe=try read(8,count:378)
                for slot in Set(oldSlots+newSlots){safe.replaceSubrange(slot*3..<slot*3+3,with:[0x20,0,0])}
                try keys(safe)
                let newDuration=macros.map{$0.steps.reduce(0){$0+$1.delayMilliseconds}}.max() ?? 0
                try waitForMacroCompletion(seconds:Double(max(drain,newDuration))/1000)
                try bank(original);try keys(before.keymap)
                let restored=try completeSnapshot()
                guard restored.keymap==before.keymap,restored.macroData==original,restored.parameters==before.parameters,restored.colors==before.colors else{throw HardwareError(message:"宏恢复后读取不一致。")}
            }catch{throw HardwareError(message:"\(failure) 自动恢复失败：\(error.localizedDescription)。备份：\(backup.path)")}
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
    init() throws {
        buffer.initialize(repeating: 0, count: 64)
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
        self.manager = manager
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: 0x046A, kIOHIDProductIDKey: 0x01CE, kIOHIDTransportKey: "USB"] as CFDictionary)
        let result = IOHIDManagerOpen(manager, 0)
        guard result == 0 else { throw HardwareError(message: "无法打开 USB 键盘（\(result)）。请检查输入监控权限。") }
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
            guard id == 4, length == 64 else {return}
            owner.received.append(bytes)
            if owner.received.count > 32 { owner.received.removeFirst() }
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDDeviceScheduleWithRunLoop(device, runLoop, CFRunLoopMode.defaultMode.rawValue)
    }
    deinit {
        if let device {
            IOHIDDeviceUnscheduleFromRunLoop(device, runLoop, CFRunLoopMode.defaultMode.rawValue)
            IOHIDDeviceRegisterInputReportCallback(device, buffer, 64, nil, nil)
            IOHIDDeviceClose(device, 0)
        }
        if let manager { IOHIDManagerClose(manager, 0) }
        buffer.deinitialize(count: 64); buffer.deallocate()
    }
    func exchange(_ request: [UInt8]) throws -> [UInt8] {
        guard let device, request.count == 64 else { throw HardwareError(message: "USB 会话已关闭。") }
        received.removeAll()
        trace?("OUT " + request.map { String(format: "%02x", $0) }.joined())
        let result = request.withUnsafeBufferPointer { IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 4, $0.baseAddress!, 64) }
        guard result == 0 else { throw HardwareError(message: "USB 发送失败（\(result)）。") }
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if let index = received.firstIndex(where: { $0[3] == request[3] && (!([UInt8(3),5,6,7,8,9,0x0A,0x0B,0x14,0x15,0x1B].contains(request[3])) || $0[4..<7].elementsEqual(request[4..<7])) }) {
                let reply = received.remove(at: index)
                trace?("IN  " + reply.map { String(format: "%02x", $0) }.joined())
                try CherryPacket.validate(reply, request: request)
                return reply
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
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
    func waitUntilKeysReleased(timeout:TimeInterval = 5) throws {
        guard let device else {throw HardwareError(message:"USB 会话已关闭。")}
        let elements=IOHIDDeviceCopyMatchingElements(device,nil,0) as? [IOHIDElement] ?? []
        let buttons=elements.filter{element in
            IOHIDElementGetType(element)==kIOHIDElementTypeInput_Button && IOHIDElementGetUsage(element) != 0 && [UInt32(7),12,1].contains(IOHIDElementGetUsagePage(element))
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
    func writeKeymap(_ data: [UInt8], baseline: HardwareSnapshot? = nil) throws -> HardwareSnapshot {
        guard data.count == 378 else { throw HardwareError(message: "键位表长度必须为 378 字节。") }
        let before=try snapshotForBaseline(baseline)
        if let baseline {
            try baseline.validate()
            guard before.keymap==baseline.keymap, before.parameters==baseline.parameters, before.colors==baseline.colors,
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
            let after=try snapshotForBaseline(baseline)
            guard after.keymap==data, after.parameters==before.parameters, after.colors==before.colors,after.macroData==before.macroData else {
                throw HardwareError(message:"键位表写后读取不一致，或灯效发生意外变化。")
            }
            return after
        }catch{
            let failure=error.localizedDescription
            do {
                // Never change a mapping while a key or modifier is held.
                try waitUntilKeysReleased();try send(before.keymap)
                let restored=try snapshotForBaseline(baseline)
                guard restored.keymap==before.keymap, restored.parameters==before.parameters, restored.colors==before.colors,restored.macroData==before.macroData else{throw HardwareError(message:"恢复后配置仍不一致。")}
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
