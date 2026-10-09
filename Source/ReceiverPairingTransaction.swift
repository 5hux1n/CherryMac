import Foundation

// Pure transaction state. Transport must validate each reply before reporting
// success, and compare the complete keyboard configuration after pairing.
// No report generation, hardware access, persistence claims or automatic retry.
struct ReceiverPairingTransaction {
    enum Phase: String, Codable {
        case backup, keyboardStart, receiverPrepare, receiverStart, polling
        case configurationCheck, configurationRestore, completed, failed, cancelled
    }
    struct Event: Codable, Equatable {
        let sequence: Int
        let phase: Phase
        let action: String
        let detail: String
    }
    struct InvalidTransition: LocalizedError {
        let errorDescription: String? = "配对流程状态已改变，请重新开始；已有备份仍需保留。"
    }
    let selection: ReceiverPairingSelection
    var keyboardToken:String{selection.keyboard.token}
    var receiverToken:String{selection.receiver.token}
    private(set) var phase: Phase = .backup
    private(set) var backupReference: String?
    private(set) var pending = false
    private(set) var operationID: Int?
    private(set) var pollCount = 0
    private(set) var mayHaveChanged = false
    private(set) var recoveryRequired = false
    private(set) var restoreAttempted = false
    private(set) var events: [Event] = []
    var terminal: Bool { [.completed, .failed, .cancelled].contains(phase) }

    init(selection: ReceiverPairingSelection) throws {
        try selection.validate();self.selection=selection
        record("created", "等待完整备份保存。")
    }
    private mutating func record(_ action: String, _ detail: String) {
        events.append(Event(sequence: events.count + 1, phase: phase, action: action, detail: detail))
    }
    mutating func backupSaved(reference: String) throws {
        guard phase == .backup, !reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,reference.utf16.count<=4096 else { throw InvalidTransition() }
        backupReference = reference
        record("backupSaved", reference)
        phase = .keyboardStart
    }
    // Must run immediately before every outgoing operation, after a fresh
    // selection/liveness check. Mark uncertainty before I/O, including timeouts.
    mutating func beginOperation(current: ReceiverPairingSelection) throws -> Int {
        guard !terminal, !pending, phase != .backup, backupReference != nil else { throw InvalidTransition() }
        guard current == selection else {
            fail("设备选择已变化，停止配对。")
            throw InvalidTransition()
        }
        if phase == .polling {
            guard pollCount < 5 else { throw InvalidTransition() }
            pollCount += 1
        }
        if phase == .configurationRestore {
            guard !restoreAttempted else { throw InvalidTransition() }
            restoreAttempted = true
        }
        if [.keyboardStart, .receiverPrepare, .receiverStart, .configurationRestore].contains(phase) { mayHaveChanged = true }
        pending = true
        operationID = events.count + 1
        record("begin", phase == .polling ? "状态查询 \(pollCount)/5" : "开始本阶段操作。")
        return operationID!
    }
    mutating func commandAccepted(operation: Int) throws {
        guard pending, operationID == operation, [.keyboardStart, .receiverPrepare, .receiverStart].contains(phase) else { throw InvalidTransition() }
        pending = false; operationID = nil
        record("accepted", "阶段回复已核对；尚未判定配对完成。")
        switch phase {
        case .keyboardStart: phase = .receiverPrepare
        case .receiverPrepare: phase = .receiverStart
        default: phase = .polling
        }
    }
    mutating func statusReceived(operation: Int, paired: Bool) throws {
        guard phase == .polling, pending, operationID == operation else { throw InvalidTransition() }
        pending = false; operationID = nil
        record("status", paired ? "设备报告配对完成，继续核对原配置。" : "设备尚未报告配对完成。")
        if paired { phase = .configurationCheck }
        else if pollCount == 5 { fail("配对状态查询已达五次，未确认完成。") }
    }
    mutating func configurationChecked(operation: Int, unchanged: Bool) throws {
        guard phase == .configurationCheck, pending, operationID == operation else { throw InvalidTransition() }
        pending = false; operationID = nil
        if unchanged {
            recoveryRequired = false; phase = .completed
            record("completed", "配对状态和原配置核对通过；断电保留尚未验证。")
        } else if !restoreAttempted {
            recoveryRequired = true; phase = .configurationRestore
            record("changed", "配对后配置发生变化，进入完整备份恢复。")
        } else { fail("恢复后配置仍与完整备份不一致，停止且不重试。") }
    }
    mutating func configurationRestored(operation: Int) throws {
        guard phase == .configurationRestore, pending, operationID == operation, restoreAttempted else { throw InvalidTransition() }
        pending = false; operationID = nil
        record("restored", "完整配置恢复已返回，仍须重新读回核对。")
        phase = .configurationCheck
    }
    mutating func fail(_ reason: String) {
        guard !terminal else { return }
        pending = false; operationID = nil; recoveryRequired = mayHaveChanged; phase = .failed
        record("failed", reason)
    }
    mutating func cancel() {
        guard !terminal else { return }
        pending = false; operationID = nil; recoveryRequired = mayHaveChanged; phase = .cancelled
        record("cancelled", mayHaveChanged ? "已停止；设备可能已变化，请保留备份并核对恢复。" : "已停止，未开始配对命令。")
    }
}
