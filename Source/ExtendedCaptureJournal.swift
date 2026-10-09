import Foundation
import Darwin

// Immutable event files. Evidence cannot authorize reading, writing or pairing.
struct ExtendedCaptureJournal {
    struct Record:Codable,Equatable {
        var format="CherryMacExtendedCaptureEvent";var version=1
        let id:String;let identity:ExtendedHardwareCapture.Identity
        let revision:Int;let event:ExtendedHardwareCapture.Event
    }
    struct JournalError:LocalizedError{let message:String;var errorDescription:String?{message}}
    let directory:URL
    private func fail()throws->Never{throw JournalError(message:"扩展捕获日志格式、顺序或身份不一致，保留原记录。")}
    static func validateEvents(_ events:[ExtendedHardwareCapture.Event])throws{
        typealias Event=ExtendedHardwareCapture.Event
        var expected:[Event]=[]
        func add(_ phase:String,_ pass:Int=0,_ region:String="",_ offset:Int=0,_ length:Int=0){expected.append(.init(sequence:expected.count+1,phase:phase,pass:pass,region:region,offset:offset,length:length,backupReference:nil,detail:""))}
        add("started")
        for pass in 1...2{for region in ExtendedHardwareCapture.regions{for offset in stride(from:0,to:region.count,by:region.chunkCapacity){let length=min(region.chunkCapacity,region.count-offset);add("readPrepared",pass,region.name,offset,length);add("readAccepted",pass,region.name,offset,length)}}}
        add("saving");add("saved");add("complete")
        guard !events.isEmpty,events.count<=expected.count+1 else{throw JournalError(message:"扩展捕获日志长度无效。")}
        var reference:String?
        for (index,event) in events.enumerated(){
            guard event.sequence==index+1,event.detail.utf16.count<=8192 else{throw JournalError(message:"扩展捕获事件无效。")}
            if let id=event.backupReference{guard UUID(uuidString:id)?.uuidString.lowercased()==id else{throw JournalError(message:"扩展捕获备份标识无效。")}}
            guard reference==nil || event.backupReference==reference else{throw JournalError(message:"扩展捕获备份标识已变化。")}
            if ["failed","cancelled"].contains(event.phase){
                guard index==events.count-1,index<expected.count,event.pass==0,event.region.isEmpty,event.offset==0,event.length==0,!event.detail.isEmpty,
                      event.backupReference==nil || reference != nil || expected[index].phase=="saved" else{throw JournalError(message:"扩展捕获失败阶段无效。")}
            }else{
                guard index<expected.count else{throw JournalError(message:"扩展捕获完成后仍有记录。")}
                let wanted=expected[index]
                guard event.phase==wanted.phase,event.pass==wanted.pass,event.region==wanted.region,event.offset==wanted.offset,event.length==wanted.length,event.detail.isEmpty else{throw JournalError(message:"扩展捕获阶段或读取范围已变化。")}
                guard ["saved","complete"].contains(event.phase) ? event.backupReference != nil:event.backupReference==nil else{throw JournalError(message:"扩展捕获备份引用阶段无效。")}
            }
            reference=event.backupReference
        }
    }
    @discardableResult
    func save(id:String,identity:ExtendedHardwareCapture.Identity,event:ExtendedHardwareCapture.Event)throws->Record{
        try identity.validate()
        return try locked(id){folder in
            let records=try read(folder,id:id)
            if let last=records.last,last.event==event,last.identity==identity{try sync(file(folder,last.revision));try sync(folder);return last}
            guard records.allSatisfy({$0.identity==identity}) else{try fail()}
            try Self.validateEvents(records.map(\.event)+[event])
            let record=Record(id:id,identity:identity,revision:event.sequence,event:event)
            let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys];let data=try encoder.encode(record)
            guard data.count<=32_000 else{try fail()}
            let target=file(folder,event.sequence),fd=Darwin.open(target.path,O_CREAT|O_EXCL|O_WRONLY|O_NOFOLLOW,0o600)
            guard fd>=0 else{try fail()}
            let handle=FileHandle(fileDescriptor:fd,closeOnDealloc:true);try handle.write(contentsOf:data);try handle.synchronize();try handle.close();try sync(folder)
            guard try Data(contentsOf:target)==data else{try fail()};return record
        }
    }
    func load(id:String)throws->[Record]{try locked(id){try read($0,id:id)}}
    private func file(_ folder:URL,_ revision:Int)->URL{folder.appendingPathComponent(String(format:"event-%03d.json",revision))}
    private func read(_ folder:URL,id:String)throws->[Record]{
        let files=try FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:nil).filter{$0.pathExtension=="json"}.sorted{$0.lastPathComponent<$1.lastPathComponent}
        guard files.count<=325 else{try fail()};var records:[Record]=[]
        for (index,url) in files.enumerated(){
            let fd=Darwin.open(url.path,O_RDONLY|O_NOFOLLOW);guard fd>=0 else{try fail()}
            let handle=FileHandle(fileDescriptor:fd,closeOnDealloc:true);defer{try? handle.close()};var info=stat()
            guard fstat(fd,&info)==0,(info.st_mode & S_IFMT)==S_IFREG,info.st_size>0,info.st_size<=32_000 else{try fail()}
            let data=try handle.read(upToCount:32_001) ?? Data();guard data.count==Int(info.st_size) else{try fail()}
            guard let object=try JSONSerialization.jsonObject(with:data) as? [String:Any],Set(object.keys)==Set(["format","version","id","identity","revision","event"]),
                  let identity=object["identity"] as? [String:Any],Set(identity.keys)==Set(["sessionToken","vendorID","productID","usbRevision","transport"]),
                  let event=object["event"] as? [String:Any],Set(event.keys)==Set(["sequence","phase","pass","region","offset","length","backupReference","detail"]) else{try fail()}
            let value=try JSONDecoder().decode(Record.self,from:data);try value.identity.validate()
            guard value.format=="CherryMacExtendedCaptureEvent",value.version==1,value.id==id,value.revision==index+1,value.event.sequence==value.revision,url.lastPathComponent==file(folder,value.revision).lastPathComponent,
                  records.first==nil || records.first!.identity==value.identity else{try fail()};records.append(value)
        }
        if !records.isEmpty{try Self.validateEvents(records.map(\.event))};return records
    }
    private func locked<T>(_ id:String,_ body:(URL)throws->T)throws->T{
        guard UUID(uuidString:id)?.uuidString.lowercased()==id else{try fail()}
        let folder=directory.appendingPathComponent(id,isDirectory:true)
        var missing:[URL]=[],cursor=folder
        while !FileManager.default.fileExists(atPath:cursor.path){missing.append(cursor);let parent=cursor.deletingLastPathComponent();guard parent.path != cursor.path else{try fail()};cursor=parent}
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        for created in missing.reversed(){try sync(created);try sync(created.deletingLastPathComponent())}
        guard try folder.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink != true else{try fail()}
        let fd=Darwin.open(folder.appendingPathComponent(".lock").path,O_CREAT|O_RDWR|O_NOFOLLOW,0o600);guard fd>=0 else{try fail()};defer{Darwin.close(fd)}
        guard flock(fd,LOCK_EX)==0 else{try fail()};defer{flock(fd,LOCK_UN)};return try body(folder)
    }
    private func sync(_ url:URL)throws{let fd=Darwin.open(url.path,O_RDONLY|O_NOFOLLOW);guard fd>=0 else{try fail()};defer{Darwin.close(fd)};guard fsync(fd)==0 else{try fail()}}
}
