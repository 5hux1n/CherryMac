import Foundation
import Darwin

// Local evidence store; not a backup and never a grant to send HID reports.
struct ReceiverPairingJournal {
    struct State: Codable, Equatable {
        let selection: ReceiverPairingSelection
        let phase: ReceiverPairingTransaction.Phase
        let backupReference: String?
        let pending: Bool
        let operationID: Int?
        let pollCount: Int
        let mayHaveChanged: Bool
        let recoveryRequired: Bool
        let restoreAttempted: Bool
        let events: [ReceiverPairingTransaction.Event]
        init(_ value: ReceiverPairingTransaction) {
            selection=value.selection;phase=value.phase; backupReference=value.backupReference; pending=value.pending
            operationID=value.operationID; pollCount=value.pollCount; mayHaveChanged=value.mayHaveChanged
            recoveryRequired=value.recoveryRequired; restoreAttempted=value.restoreAttempted; events=value.events
        }
        private enum CodingKeys: String, CodingKey {
            case selection, phase, backupReference, pending, operationID, pollCount
            case mayHaveChanged, recoveryRequired, restoreAttempted, events
        }
        func encode(to encoder: Encoder) throws {
            var container=encoder.container(keyedBy:CodingKeys.self)
            try container.encode(selection,forKey:.selection)
            try container.encode(phase,forKey:.phase)
            try container.encode(backupReference,forKey:.backupReference)
            try container.encode(pending,forKey:.pending)
            try container.encode(operationID,forKey:.operationID)
            try container.encode(pollCount,forKey:.pollCount)
            try container.encode(mayHaveChanged,forKey:.mayHaveChanged)
            try container.encode(recoveryRequired,forKey:.recoveryRequired)
            try container.encode(restoreAttempted,forKey:.restoreAttempted)
            try container.encode(events,forKey:.events)
        }
    }
    struct Record: Codable, Equatable {
        let format: String
        let version: Int
        let id: String
        let revision: Int
        let savedAt: String
        let state: State
    }
    struct JournalError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    let directory: URL

    @discardableResult
    func save(operationID: String, transaction: ReceiverPairingTransaction) throws -> Record {
        try withLock(operationID) { folder in
            let state=State(transaction), previous=try readRecords(folder, id:operationID).last
            if let previous {
                if previous.state == state {
                    try syncFile(file(folder, revision:previous.revision))
                    try syncDirectory(folder)
                    return previous
                }
                guard previous.state.selection == state.selection,previous.revision < state.events.count,
                      Array(state.events.prefix(previous.revision)) == previous.state.events,
                      previous.state.backupReference == nil || previous.state.backupReference == state.backupReference,
                      ![.completed,.failed,.cancelled].contains(previous.state.phase) else {
                    throw JournalError(message:"配对日志历史已变化或已结束，不覆盖原记录。")
                }
            }
            let record=Record(format:"CherryMacPairingCheckpoint",version:4,id:operationID,
                              revision:state.events.count,savedAt:ISO8601DateFormatter().string(from:Date()),state:state)
            try validate(record, id:operationID)
            let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.prettyPrinted]
            let data=try encoder.encode(record), target=file(folder,revision:record.revision)
            guard data.count <= 3_000_000 else { throw JournalError(message:"配对日志超过大小限制。") }
            let descriptor=Darwin.open(target.path,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0o600)
            guard descriptor >= 0 else { throw JournalError(message:"无法新建配对日志，原记录未覆盖。") }
            let handle=FileHandle(fileDescriptor:descriptor,closeOnDealloc:true)
            try handle.write(contentsOf:data)
            try handle.synchronize()
            try handle.close()
            try syncDirectory(folder)
            guard try Data(contentsOf:target) == data else { throw JournalError(message:"配对日志读回不一致。") }
            return record
        }
    }
    func load(operationID: String) throws -> [Record] {
        try withLock(operationID,create:false) { try readRecords($0,id:operationID) }
    }
    private func file(_ folder: URL, revision: Int) -> URL {
        folder.appendingPathComponent(String(format:"checkpoint-%03d.json",revision))
    }
    private func validate(_ record: Record, id: String) throws {
        let s=record.state
        try s.selection.validate()
        guard record.format=="CherryMacPairingCheckpoint",record.version==4,record.id==id,
              record.revision==s.events.count,(1...256).contains(record.revision),(0...5).contains(s.pollCount),
              s.events.enumerated().allSatisfy({ $0.element.sequence==$0.offset+1 && !$0.element.action.isEmpty && $0.element.action.utf16.count<=64 && $0.element.detail.utf16.count<=8192 }),
              s.backupReference == nil || (!(s.backupReference!.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty) && s.backupReference!.utf16.count<=4096),
              s.pending ? (s.operationID != nil && (1...record.revision).contains(s.operationID!)) : s.operationID == nil else {
            throw JournalError(message:"配对日志内容无效。")
        }
        try validateTransitions(s)
    }
    private func validateTransitions(_ state:State)throws{
        var replay=try ReceiverPairingTransaction(selection:state.selection)
        func requirePrefix()throws{
            guard replay.events.count<=state.events.count,
                  Array(state.events.prefix(replay.events.count))==replay.events else{
                throw JournalError(message:"配对日志事件不能还原保存的流程状态。")
            }
        }
        try requirePrefix()
        while replay.events.count<state.events.count{
            let event=state.events[replay.events.count],previousCount=replay.events.count
            switch event.action{
            case "backupSaved":try replay.backupSaved(reference:event.detail)
            case "begin":_ = try replay.beginOperation(current:state.selection)
            case "accepted":
                guard let operation=replay.operationID else{throw JournalError(message:"配对日志缺少待核对操作。")}
                try replay.commandAccepted(operation:operation)
            case "status":
                guard let operation=replay.operationID,
                      ["设备报告配对完成，继续核对原配置。","设备尚未报告配对完成。"].contains(event.detail) else{
                    throw JournalError(message:"配对日志查询结果无效。")
                }
                try replay.statusReceived(operation:operation,paired:event.detail=="设备报告配对完成，继续核对原配置。")
            case "changed":
                guard let operation=replay.operationID else{throw JournalError(message:"配对日志缺少配置核对操作。")}
                try replay.configurationChecked(operation:operation,unchanged:false)
            case "restored":
                guard let operation=replay.operationID else{throw JournalError(message:"配对日志缺少恢复操作。")}
                try replay.configurationRestored(operation:operation)
            case "completed":
                guard let operation=replay.operationID else{throw JournalError(message:"配对日志缺少配置核对操作。")}
                try replay.configurationChecked(operation:operation,unchanged:true)
            case "failed":replay.fail(event.detail)
            case "cancelled":replay.cancel()
            default:throw JournalError(message:"配对日志含未知流程事件。")
            }
            guard replay.events.count>previousCount else{throw JournalError(message:"配对日志在结束状态后仍有事件。")}
            try requirePrefix()
        }
        guard State(replay)==state else{throw JournalError(message:"配对日志事件与最终状态不一致。")}
    }
    private func readRecords(_ folder: URL, id: String) throws -> [Record] {
        let urls=try FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:nil)
            .filter { $0.pathExtension=="json" }.sorted { $0.lastPathComponent<$1.lastPathComponent }
        guard urls.count<=256 else { throw JournalError(message:"配对日志数量异常。") }
        var records:[Record]=[]
        for url in urls {
            let attributes=try FileManager.default.attributesOfItem(atPath:url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 3_000_000 else { throw JournalError(message:"配对日志文件无效。") }
            let handle=try FileHandle(forReadingFrom:url)
            let data:Data
            do{data=try handle.read(upToCount:3_000_001) ?? Data();try handle.close()}
            catch{try? handle.close();throw error}
            guard data.count<=3_000_000 else{throw JournalError(message:"配对日志超过大小限制。")}
            guard let raw=try JSONSerialization.jsonObject(with:data) as? [String:Any],
                  Set(raw.keys)==Set(["format","version","id","revision","savedAt","state"]),
                  let state=raw["state"] as? [String:Any],
                  Set(state.keys)==Set(["selection","phase","backupReference","pending","operationID","pollCount","mayHaveChanged","recoveryRequired","restoreAttempted","events"]),
                  let selected=state["selection"] as? [String:Any],Set(selected.keys)==Set(["keyboard","receiver"]),
                  ["keyboard","receiver"].allSatisfy({role in
                      guard let endpoint=selected[role] as? [String:Any] else{return false}
                      return Set(endpoint.keys)==Set(["token","vendorID","productID","usagePage","usage"])
                  }),let events=state["events"] as? [[String:Any]],
                  events.allSatisfy({Set($0.keys)==Set(["sequence","phase","action","detail"])}) else{
                throw JournalError(message:"配对日志字段或端点身份不完整；保留原记录。")
            }
            let record=try JSONDecoder().decode(Record.self,from:data)
            try validate(record,id:id)
            guard url.lastPathComponent==file(folder,revision:record.revision).lastPathComponent else { throw JournalError(message:"配对日志文件编号不一致。") }
            if let previous=records.last {
                guard record.state.selection == previous.state.selection,record.revision>previous.revision,
                      Array(record.state.events.prefix(previous.revision))==previous.state.events,
                      previous.state.backupReference == nil || previous.state.backupReference==record.state.backupReference,
                      ![.completed,.failed,.cancelled].contains(previous.state.phase) else { throw JournalError(message:"配对日志历史不连续。") }
            }
            records.append(record)
        }
        return records
    }
    private func withLock<T>(_ id: String,create:Bool=true, _ body: (URL) throws -> T) throws -> T {
        guard id.range(of:"^[A-Za-z0-9_-]{1,128}$",options:.regularExpression) != nil else { throw JournalError(message:"配对日志标识无效。") }
        let folder=directory.appendingPathComponent(id,isDirectory:true)
        guard create || FileManager.default.fileExists(atPath:folder.path) else{throw JournalError(message:"没有已保存的配对日志目录。")}
        var missing:[URL]=[],cursor=folder
        while !FileManager.default.fileExists(atPath:cursor.path){
            missing.append(cursor);let parent=cursor.deletingLastPathComponent()
            guard parent.path != cursor.path else{throw JournalError(message:"配对日志父目录无法定位。")};cursor=parent
        }
        if create{try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])}
        for created in missing.reversed(){try syncDirectory(created);try syncDirectory(created.deletingLastPathComponent())}
        guard try folder.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink != true else { throw JournalError(message:"配对日志目录不能是符号链接。") }
        let descriptor=Darwin.open(folder.appendingPathComponent(".lock").path,(create ? O_CREAT:0)|O_RDWR|O_NOFOLLOW,0o600)
        guard descriptor>=0 else { throw JournalError(message:"无法打开配对日志锁。") }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor,LOCK_EX)==0 else { throw JournalError(message:"无法锁定配对日志。") }
        defer { flock(descriptor,LOCK_UN) }
        if create{try syncDirectory(directory)}
        return try body(folder)
    }
    private func syncFile(_ url: URL) throws {
        let descriptor=Darwin.open(url.path,O_RDONLY|O_NOFOLLOW)
        guard descriptor>=0 else { throw JournalError(message:"无法同步配对日志。") }
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor)==0 else { throw JournalError(message:"配对日志同步失败。") }
    }
    private func syncDirectory(_ url: URL) throws { try syncFile(url) }
}
