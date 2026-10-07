import Foundation
import Darwin

// Local evidence store; not a backup and never a grant to send HID reports.
struct ReceiverPairingJournal {
    struct State: Codable, Equatable {
        let phase: ReceiverPairingTransaction.Phase
        let backupReference: String?
        let pending: Bool
        let operationID: Int?
        let pollCount: Int
        let mayHaveChanged: Bool
        let recoveryRequired: Bool
        let events: [ReceiverPairingTransaction.Event]
        init(_ value: ReceiverPairingTransaction) {
            phase=value.phase; backupReference=value.backupReference; pending=value.pending
            operationID=value.operationID; pollCount=value.pollCount; mayHaveChanged=value.mayHaveChanged
            recoveryRequired=value.recoveryRequired; events=value.events
        }
        private enum CodingKeys: String, CodingKey {
            case phase, backupReference, pending, operationID, pollCount
            case mayHaveChanged, recoveryRequired, events
        }
        func encode(to encoder: Encoder) throws {
            var container=encoder.container(keyedBy:CodingKeys.self)
            try container.encode(phase,forKey:.phase)
            try container.encode(backupReference,forKey:.backupReference)
            try container.encode(pending,forKey:.pending)
            try container.encode(operationID,forKey:.operationID)
            try container.encode(pollCount,forKey:.pollCount)
            try container.encode(mayHaveChanged,forKey:.mayHaveChanged)
            try container.encode(recoveryRequired,forKey:.recoveryRequired)
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
                guard previous.revision < state.events.count,
                      Array(state.events.prefix(previous.revision)) == previous.state.events,
                      previous.state.backupReference == nil || previous.state.backupReference == state.backupReference,
                      ![.completed,.failed,.cancelled].contains(previous.state.phase) else {
                    throw JournalError(message:"配对日志历史已变化或已结束，不覆盖原记录。")
                }
            }
            let record=Record(format:"CherryMacPairingCheckpoint",version:1,id:operationID,
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
        try withLock(operationID) { try readRecords($0,id:operationID) }
    }
    private func file(_ folder: URL, revision: Int) -> URL {
        folder.appendingPathComponent(String(format:"checkpoint-%03d.json",revision))
    }
    private func validate(_ record: Record, id: String) throws {
        let s=record.state
        guard record.format=="CherryMacPairingCheckpoint",record.version==1,record.id==id,
              record.revision==s.events.count,(1...256).contains(record.revision),(0...5).contains(s.pollCount),
              s.events.enumerated().allSatisfy({ $0.element.sequence==$0.offset+1 && !$0.element.action.isEmpty && $0.element.action.utf16.count<=64 && $0.element.detail.utf16.count<=8192 }),
              s.backupReference == nil || (!(s.backupReference!.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty) && s.backupReference!.utf16.count<=4096),
              s.pending ? (s.operationID != nil && (1...record.revision).contains(s.operationID!)) : s.operationID == nil else {
            throw JournalError(message:"配对日志内容无效。")
        }
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
            let record=try JSONDecoder().decode(Record.self,from:Data(contentsOf:url))
            try validate(record,id:id)
            guard url.lastPathComponent==file(folder,revision:record.revision).lastPathComponent else { throw JournalError(message:"配对日志文件编号不一致。") }
            if let previous=records.last {
                guard record.revision>previous.revision,
                      Array(record.state.events.prefix(previous.revision))==previous.state.events,
                      previous.state.backupReference == nil || previous.state.backupReference==record.state.backupReference,
                      ![.completed,.failed,.cancelled].contains(previous.state.phase) else { throw JournalError(message:"配对日志历史不连续。") }
            }
            records.append(record)
        }
        return records
    }
    private func withLock<T>(_ id: String, _ body: (URL) throws -> T) throws -> T {
        guard id.range(of:"^[A-Za-z0-9_-]{1,128}$",options:.regularExpression) != nil else { throw JournalError(message:"配对日志标识无效。") }
        let folder=directory.appendingPathComponent(id,isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        guard try folder.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink != true else { throw JournalError(message:"配对日志目录不能是符号链接。") }
        let descriptor=Darwin.open(folder.appendingPathComponent(".lock").path,O_CREAT|O_RDWR|O_NOFOLLOW,0o600)
        guard descriptor>=0 else { throw JournalError(message:"无法打开配对日志锁。") }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor,LOCK_EX)==0 else { throw JournalError(message:"无法锁定配对日志。") }
        defer { flock(descriptor,LOCK_UN) }
        try syncDirectory(directory)
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
