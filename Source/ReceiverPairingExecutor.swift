import Foundation

// Concrete adapters must bind both endpoints for the whole run, apply finite I/O
// timeouts, save a complete backup, validate raw replies, and log raw exchanges.
// No default adapter exists: this executor alone cannot issue HID commands.
@MainActor
protocol ReceiverPairingExecutorIO {
    func currentSelection() throws -> ReceiverPairingSelection
    func saveCompleteBackup() async throws -> String
    func performCommand(_ phase: ReceiverPairingTransaction.Phase) async throws
    func queryPaired() async throws -> Bool
    func configurationMatchesBackup(_ reference: String) async throws -> Bool
    func persist(_ transaction: ReceiverPairingTransaction) async throws
    func close() throws
}

@MainActor
final class ReceiverPairingExecutor {
    struct Result {
        let transaction: ReceiverPairingTransaction
        let journalError: String?
        let cleanupError: String?
        var succeeded: Bool { transaction.phase == .completed && journalError == nil && cleanupError == nil }
    }
    private(set) var running = false

    func run(_ io: any ReceiverPairingExecutorIO) async throws -> Result {
        guard !running else { throw ReceiverPairingTransaction.InvalidTransition() }
        running = true
        defer { running = false }
        var transaction: ReceiverPairingTransaction
        do { transaction = try ReceiverPairingTransaction(selection: io.currentSelection()) }
        catch { try? io.close(); throw error }
        let keyboard = transaction.keyboardToken, receiver = transaction.receiverToken
        func check() throws {
            try Task.checkCancellation()
            let current = try io.currentSelection()
            guard current.keyboard.token == keyboard, current.receiver.token == receiver else {
                throw ReceiverPairingTransaction.InvalidTransition()
            }
        }
        var journalError: String?, cleanupError: String?
        do {
            try check()
            try await io.persist(transaction)
            try check()
            let reference = try await io.saveCompleteBackup()
            try transaction.backupSaved(reference: reference)
            try await io.persist(transaction)
            while !transaction.terminal {
                try check()
                let phase = transaction.phase
                let operation = try transaction.beginOperation(current: io.currentSelection())
                try await io.persist(transaction) // Durable intent before any command.
                try check() // Selection/cancellation may change while journal saves.
                switch phase {
                case .keyboardStart, .receiverPrepare, .receiverStart:
                    try await io.performCommand(phase)
                    try check()
                    try transaction.commandAccepted(operation: operation)
                case .polling:
                    let paired = try await io.queryPaired()
                    try check()
                    try transaction.statusReceived(operation: operation, paired: paired)
                case .configurationCheck:
                    let matches = try await io.configurationMatchesBackup(reference)
                    try check()
                    try transaction.configurationChecked(operation: operation, unchanged: matches)
                default: throw ReceiverPairingTransaction.InvalidTransition()
                }
                try await io.persist(transaction)
                if phase == .keyboardStart { try await Task.sleep(nanoseconds: 10_000_000) }
                if phase == .polling && transaction.phase == .polling {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                }
            }
        } catch {
            if error is CancellationError { transaction.cancel() }
            else { transaction.fail(error.localizedDescription) }
            do { try await io.persist(transaction) }
            catch { journalError = error.localizedDescription }
            // If the final completion journal failed, retrying does not erase
            // that failure: callers must not report a fully recorded success.
            if transaction.phase == .completed { journalError = journalError ?? error.localizedDescription }
        }
        do { try io.close() } catch { cleanupError = error.localizedDescription }
        return Result(transaction: transaction, journalError: journalError, cleanupError: cleanupError)
    }
}
