import Foundation
import Darwin

// Separate full-region file store. No capture, prefix promotion, restoration
// or pairing authorization. Only the independent schema is accepted.
struct ReceiverPairingConfigurationRegionsStore {
    let directory: URL
    struct StoreError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    func save(_ snapshot: ReceiverPairingConfigurationRegions) throws -> String {
        try snapshot.validate()
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.prettyPrinted]
        let data=try encoder.encode(snapshot)
        guard data.count<=128_000 else { throw StoreError(message:"完整配置区记录超过大小限制。") }
        try prepareDirectory()
        guard try directory.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink != true else { throw StoreError(message:"完整配置区记录目录无效。") }
        let id=UUID().uuidString.lowercased(),url=try file("configuration-regions:"+id)
        let descriptor=Darwin.open(url.path,O_CREAT|O_EXCL|O_WRONLY|O_NOFOLLOW,0o600)
        guard descriptor>=0 else { throw StoreError(message:"无法创建完整配置区记录，原文件未覆盖。") }
        let handle=FileHandle(fileDescriptor:descriptor,closeOnDealloc:true)
        try handle.write(contentsOf:data);try handle.synchronize();try handle.close()
        try syncDirectory(directory)
        let restored=try load("configuration-regions:"+id)
        guard restored==snapshot else { throw StoreError(message:"完整配置区记录读回不一致，停止后续操作。") }
        return "configuration-regions:"+id
    }
    func load(_ id: String) throws -> ReceiverPairingConfigurationRegions {
        let url=try file(id)
        guard try directory.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink != true else { throw StoreError(message:"完整配置区记录目录无效。") }
        let descriptor=Darwin.open(url.path,O_RDONLY|O_NOFOLLOW)
        guard descriptor>=0 else { throw StoreError(message:"完整配置区记录不存在或无法读取。") }
        let handle=FileHandle(fileDescriptor:descriptor,closeOnDealloc:true)
        defer { try? handle.close() }
        var info=stat()
        guard fstat(descriptor,&info)==0,(info.st_mode & S_IFMT)==S_IFREG,info.st_size>0,info.st_size<=128_000 else { throw StoreError(message:"完整配置区记录文件类型或大小无效。") }
        let data=try handle.read(upToCount:128_001) ?? Data()
        guard data.count==Int(info.st_size),data.count<=128_000 else { throw StoreError(message:"完整配置区记录读取不完整或超过大小限制。") }
        let snapshot=try JSONDecoder().decode(ReceiverPairingConfigurationRegions.self,from:data)
        try snapshot.validate()
        return snapshot
    }
    private func file(_ reference: String) throws -> URL {
        guard reference.hasPrefix("configuration-regions:") else { throw StoreError(message:"完整配置区记录标识类型无效。") }
        let id=String(reference.dropFirst("configuration-regions:".count))
        guard let uuid=UUID(uuidString:id),uuid.uuidString.lowercased()==id else { throw StoreError(message:"完整配置区记录标识无效。") }
        return directory.appendingPathComponent("configuration-regions-"+id+".json")
    }
    private func prepareDirectory()throws{
        var missing:[URL]=[],cursor=directory.standardizedFileURL
        while !FileManager.default.fileExists(atPath:cursor.path){
            missing.append(cursor);let parent=cursor.deletingLastPathComponent()
            guard parent.path != cursor.path else{throw StoreError(message:"完整配置区记录目录无效。")};cursor=parent
        }
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        for created in missing.reversed(){try syncDirectory(created);try syncDirectory(created.deletingLastPathComponent())}
    }
    private func syncDirectory(_ folder:URL) throws {
        let descriptor=Darwin.open(folder.path,O_RDONLY|O_NOFOLLOW)
        guard descriptor>=0 else { throw StoreError(message:"无法同步完整配置区记录目录。") }
        defer { Darwin.close(descriptor) }
        var info=stat()
        guard fstat(descriptor,&info)==0,(info.st_mode & S_IFMT)==S_IFDIR,fsync(descriptor)==0 else { throw StoreError(message:"完整配置区记录目录同步失败。") }
    }
}
