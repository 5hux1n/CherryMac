import Foundation

// Pure selection policy for the official 01CE <-> 01CF registry relationship.
// A candidate is an interface supplied by a future discovery adapter, not proof
// of an existing wireless bond. Tokens must identify current interface objects.
// This module neither discovers devices nor authorizes or sends reports.
struct ReceiverPairingCandidate: Codable, Equatable {
    let token: String
    let vendorID: Int
    let productID: Int
    let usagePage: Int
    let usage: Int

    var role: ReceiverPairingRole? {
        guard vendorID == 0x046a, usagePage == 0xff1c, usage == 0x92 else { return nil }
        switch productID {
        case 0x01ce: return .keyboard
        case 0x01cf: return .receiver
        default: return nil
        }
    }
}

enum ReceiverPairingRole { case keyboard, receiver }

struct ReceiverPairingSelection: Codable, Equatable {
    let keyboard: ReceiverPairingCandidate
    let receiver: ReceiverPairingCandidate

    enum SelectionError: String, Error, LocalizedError {
        case invalidIdentity = "设备标识无效或重复，请重新选择设备。"
        case missingKeyboard = "请连接并选择 USB 有线键盘。"
        case missingReceiver = "请连接并选择对应的 USB 接收器。"
        case ambiguousKeyboard = "发现多个键盘接口，请明确选择要配对的键盘。"
        case ambiguousReceiver = "发现多个接收器接口，请明确选择要配对的接收器。"
        case staleSelection = "所选设备已不在当前候选列表中，请重新选择。"
        var errorDescription: String? { rawValue }
    }

    func validate() throws {
        guard keyboard.role == .keyboard,receiver.role == .receiver,
              !keyboard.token.isEmpty,!receiver.token.isEmpty,
              keyboard.token.utf8.count<=128,receiver.token.utf8.count<=128,
              keyboard.token != receiver.token else{throw SelectionError.invalidIdentity}
    }

    static func resolve(_ candidates: [ReceiverPairingCandidate],
                        keyboardToken: String? = nil, receiverToken: String? = nil) throws -> Self {
        var tokens = Set<String>()
        for candidate in candidates {
            guard !candidate.token.isEmpty, tokens.insert(candidate.token).inserted else {
                throw SelectionError.invalidIdentity
            }
        }
        func choose(_ role: ReceiverPairingRole, _ selected: String?) throws -> ReceiverPairingCandidate {
            let eligible = candidates.filter { $0.role == role }
            if let selected {
                guard let candidate = eligible.first(where: { $0.token == selected }) else {
                    throw SelectionError.staleSelection
                }
                return candidate
            }
            guard !eligible.isEmpty else {
                throw role == .keyboard ? SelectionError.missingKeyboard : SelectionError.missingReceiver
            }
            guard eligible.count == 1 else {
                throw role == .keyboard ? SelectionError.ambiguousKeyboard : SelectionError.ambiguousReceiver
            }
            return eligible[0]
        }
        return try Self(keyboard: choose(.keyboard, keyboardToken), receiver: choose(.receiver, receiverToken))
    }
}
