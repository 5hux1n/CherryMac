import Foundation

// Type discriminator only, not proof of coverage or a hardware write grant.
// Existing editor/extended/full-region stores never issue this namespace.
enum ReceiverPairingBackupReference {
    struct ReferenceError:LocalizedError {
        var errorDescription:String?{"配对需要独立的完整备份引用；普通、扩展前缀或仅配置区记录不能代替。"}
    }
    static func validate(_ reference:String)throws{
        let prefix="pairing-complete-backup:"
        guard reference.hasPrefix(prefix) else{throw ReferenceError()}
        let id=String(reference.dropFirst(prefix.count))
        guard UUID(uuidString:id)?.uuidString.lowercased()==id else{throw ReferenceError()}
    }
}
