import Foundation

// Immutable, transaction-specific permission: exact original/target blocks only.
// Lighting, macros, firmware commands and internal/hidden keys are excluded.
struct KeymapWriteAuthorization {
    let before:HardwareSnapshot
    let expected:HardwareSnapshot
    let changedSlots:[Int]
    static var editableSlots:Set<Int>{Set(keyboardLayout().compactMap{CherryMatrix.slot($0)}).subtracting([6,71])}
    init(baseline:HardwareSnapshot,keymap:[UInt8]) throws {
        try baseline.validate()
        guard baseline.deviceInfo[6]==24,baseline.colors != nil,baseline.macroData != nil,keymap.count==378 else{throw HardwareError(message:"需要本型号已验证固件的完整配置，未授权写入。")}
        var changed:[Int]=[]
        for slot in 0..<126 {
            let range=slot*3..<slot*3+3,record=Array(keymap[range]),old=Array(baseline.keymap[range])
            if record==old{continue}
            guard Self.editableSlots.contains(slot) else{throw HardwareError(message:"内部功能键与隐藏位置不能改写。")}
            guard ![UInt8(0x70),0x71].contains(old[0]),![UInt8(0x70),0x71].contains(record[0]) else{throw HardwareError(message:"宏绑定改动暂缓写入，请保留原绑定，或撤销相关编辑。")}
            guard (record[0]==0x20 && (record[2]==0 || (4..<224).contains(record[2]))) || record[0]==0x30 else{throw HardwareError(message:"只支持普通键、修饰键组合、媒体键与禁用。")}
            changed.append(slot)
        }
        before=baseline;var next=baseline;next.keymap=keymap;expected=next;changedSlots=changed
    }
    func validate(_ request:[UInt8]) throws {
        guard request.count==64,request[0]==4,request[3]==9,request[4]==54 else{throw HardwareError(message:"仅允许此操作的标准键位表分块。")}
        let offset=Int(request[5]) | Int(request[6])<<8
        guard offset%54==0,offset<=324 else{throw HardwareError(message:"键位写入偏移无效。")}
        for snapshot in [before,expected]{
            if request == (try CherryPacket.chunk(9,offset:offset,length:54,data:Array(snapshot.keymap[offset..<offset+54]))){return}
        }
        throw HardwareError(message:"写包与本次备份／目标不一致，停止发送。")
    }
    func validateRecovery(_ current:HardwareSnapshot) throws {
        try current.validate()
        guard current.deviceInfo==before.deviceInfo,current.parameters==before.parameters,current.colors==before.colors,current.macroData==before.macroData else{throw HardwareError(message:"读取到操作范围之外的配置变化，停止自动覆盖；请保留备份。")}
        for offset in stride(from:0,to:378,by:54){
            try validate(CherryPacket.chunk(9,offset:offset,length:54,data:Array(current.keymap[offset..<offset+54])))
        }
    }
}

final class HardwareOperationLog {
    let url:URL
    private let lock=NSLock()
    private var state:[String:Any]
    private var rows:[[String:Any]]=[]
    private var failure:String?
    init(kind:String,directory:URL? = nil) throws {
        let id=UUID().uuidString
        let folder=directory ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CherryMac/HardwareLogs")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        url=folder.appendingPathComponent("\(id).json")
        state=["format":"CherryMacHardwareOperation","version":1,"id":id,"kind":kind,"startedAt":ISO8601DateFormatter().string(from:Date()),"phase":"prepared","scope":kind=="read" ? "read-only":"keymap only"]
        try persist()
        guard let saved=try JSONSerialization.jsonObject(with:Data(contentsOf:url)) as? [String:Any],saved["id"] as? String == id else{throw HardwareError(message:"操作日志保存校验失败，未写入。")}
    }
    private func persist() throws {
        var value=state;value["trace"]=rows
        try JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys]).write(to:url,options:.atomic)
    }
    func record(_ key:String,_ value:Any){
        lock.lock();defer{lock.unlock()};state[key]=value
        if ["phase","error","writeError","recovered"].contains(key){
            rows.append(["kind":"phase","at":ISO8601DateFormatter().string(from:Date()),"uptime":ProcessInfo.processInfo.systemUptime,"field":key,"value":value])
        }
        do{try persist()}catch{failure=error.localizedDescription}
    }
    func trace(_ message:String){
        lock.lock();defer{lock.unlock()}
        let now=ProcessInfo.processInfo.systemUptime
        var row:[String:Any]=["at":ISO8601DateFormatter().string(from:Date()),"uptime":now,"message":message]
        if message.hasPrefix("IN  "),let outgoing=rows.last(where:{($0["message"] as? String)?.hasPrefix("OUT ") == true}),let start=outgoing["uptime"] as? Double{row["durationMs"]=(now-start)*1000}
        rows.append(row)
        do{try persist()}catch{failure=error.localizedDescription}
    }
    func requireHealthy() throws {
        lock.lock();defer{lock.unlock()}
        if let failure{throw HardwareError(message:"操作日志保存失败，停止后续写入：\(failure)。日志：\(url.path)")}
    }
    func string(_ key:String)->String?{lock.lock();defer{lock.unlock()};return state[key] as? String}
}
