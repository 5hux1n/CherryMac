import Foundation
import Darwin

// Saves the exact raw-prefix record. No device access, implicit conversion,
// restoration or deletion. The directory is supplied by the product adapter.
struct ExtendedHardwareBackupStore {
    let directory: URL
    struct StoreError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    func save(_ snapshot: ExtendedHardwareBackup) throws -> String {
        try snapshot.validate()
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.prettyPrinted]
        let data=try encoder.encode(snapshot)
        guard data.count<=128_000 else { throw StoreError(message:"扩展备份超过大小限制。") }
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        guard try directory.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink != true else { throw StoreError(message:"扩展备份目录无效。") }
        let id=UUID().uuidString.lowercased(),url=try file(id)
        let descriptor=Darwin.open(url.path,O_CREAT|O_EXCL|O_WRONLY|O_NOFOLLOW,0o600)
        guard descriptor>=0 else { throw StoreError(message:"无法创建扩展备份，原文件未覆盖。") }
        let handle=FileHandle(fileDescriptor:descriptor,closeOnDealloc:true)
        try handle.write(contentsOf:data);try handle.synchronize();try handle.close()
        try syncDirectory()
        let restored=try load(id)
        guard restored==snapshot else { throw StoreError(message:"扩展备份读回不一致，停止后续操作。") }
        return id
    }
    func load(_ id: String) throws -> ExtendedHardwareBackup {
        let url=try file(id)
        guard try directory.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink != true else { throw StoreError(message:"扩展备份目录无效。") }
        let descriptor=Darwin.open(url.path,O_RDONLY|O_NOFOLLOW)
        guard descriptor>=0 else { throw StoreError(message:"扩展备份不存在或无法读取。") }
        let handle=FileHandle(fileDescriptor:descriptor,closeOnDealloc:true)
        defer { try? handle.close() }
        var info=stat()
        guard fstat(descriptor,&info)==0,(info.st_mode & S_IFMT)==S_IFREG,info.st_size>0,info.st_size<=128_000 else { throw StoreError(message:"扩展备份文件类型或大小无效。") }
        let data=try handle.read(upToCount:128_001) ?? Data()
        guard data.count==Int(info.st_size),data.count<=128_000 else { throw StoreError(message:"扩展备份读取不完整或超过大小限制。") }
        let snapshot=try JSONDecoder().decode(ExtendedHardwareBackup.self,from:data)
        try snapshot.validate()
        return snapshot
    }
    private func file(_ id: String) throws -> URL {
        guard let uuid=UUID(uuidString:id),uuid.uuidString.lowercased()==id else { throw StoreError(message:"扩展备份标识无效。") }
        return directory.appendingPathComponent(id+".json")
    }
    private func syncDirectory() throws {
        let descriptor=Darwin.open(directory.path,O_RDONLY|O_NOFOLLOW)
        guard descriptor>=0 else { throw StoreError(message:"无法同步扩展备份目录。") }
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor)==0 else { throw StoreError(message:"扩展备份目录同步失败。") }
    }
}
