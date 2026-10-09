import Foundation
import Darwin

// Local immutable report evidence. Never opens HID, resumes operations or grants
// write permission. The wire adapter requires this concrete store.
struct ReceiverPairingRawLog {
    struct Entry:Decodable,Equatable {
        let format:String
        let version:Int
        let id:String
        let intent:Int
        let phase:ReceiverPairingTransaction.Phase
        let endpoint:String
        let selection:ReceiverPairingSelection
        let selector:UInt16?
        let request:[UInt8]
        let reply:[UInt8]?
        let receivedLength:Int
        let stage:String
        let error:String?
    }
    struct Record:Decodable,Equatable {
        let format:String
        let version:Int
        let id:String
        let sequence:Int
        let savedAt:String
        let entry:Entry
    }
    struct LogError:LocalizedError {
        let message:String
        var errorDescription:String?{message}
    }
    let directory:URL
    @discardableResult
    func save(_ exchange:ReceiverPairingWireAdapter.ExchangeRecord)throws->Record{
        let entryData=try JSONEncoder().encode(exchange)
        let entry=try JSONDecoder().decode(Entry.self,from:entryData)
        try validate(entry,id:exchange.id)
        return try locked(exchange.id,create:true){folder in
            let previous=try read(folder,id:exchange.id)
            let payload:[String:Any]=["format":"CherryMacPairingRawLog","version":1,"id":exchange.id,
                "sequence":previous.count+1,"savedAt":ISO8601DateFormatter().string(from:Date()),
                "entry":try JSONSerialization.jsonObject(with:entryData)]
            let data=try JSONSerialization.data(withJSONObject:payload,options:[.sortedKeys,.prettyPrinted])
            guard data.count<=65536 else{throw LogError(message:"配对原始报告超过大小限制。")}
            let record=try decode(data,id:exchange.id)
            try validateHistory(previous+[record],id:exchange.id)
            let target=file(folder,sequence:record.sequence)
            let fd=Darwin.open(target.path,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0o600)
            guard fd>=0 else{throw LogError(message:"无法新建配对原始报告，原文件未覆盖。")}
            let handle=FileHandle(fileDescriptor:fd,closeOnDealloc:true)
            do{try handle.write(contentsOf:data);try handle.synchronize();try handle.close()}
            catch{try? handle.close();throw error}
            try sync(folder)
            guard try readData(target)==data else{throw LogError(message:"配对原始报告读回不一致。")}
            return record
        }
    }
    func load(operationID:String)throws->[Record]{
        try locked(operationID,create:false){try read($0,id:operationID)}
    }
    private func validate(_ e:Entry,id:String)throws{
        try e.selection.validate()
        guard e.format=="CherryMacPairingRawExchange",e.version==2,e.id==id,
              (1...256).contains(e.intent),["prepared","received","accepted","failed"].contains(e.stage),
              e.receivedLength>=0,e.receivedLength<=9_007_199_254_740_991 else{throw LogError(message:"配对原始报告字段无效。")}
        let plan=try ReceiverPairingFrames.plan(phase:e.phase,selector:e.selector)
        guard e.endpoint==plan.endpoint.rawValue,e.request==plan.request else{
            throw LogError(message:"原始请求与阶段、选择字段或端点不一致。")
        }
        if let reply=e.reply{
            guard reply.count==min(64,e.receivedLength) else{throw LogError(message:"原始回复样本与实际长度不一致。")}
        }
        if e.stage=="prepared"{
            guard e.receivedLength==0,e.reply==nil else{throw LogError(message:"准备阶段不能包含回复。")}
        }
        if e.stage=="accepted"{
            guard let reply=e.reply else{throw LogError(message:"已接受报告缺少回复。")}
            _=try ReceiverPairingFrames.reply(reply,for:plan,transportSucceeded:e.receivedLength==64)
        }
        if e.stage=="failed"{
            guard let error=e.error,!error.isEmpty,error.utf16.count<=8192 else{throw LogError(message:"原始报告错误字段无效。")}
        }else if e.error != nil{throw LogError(message:"非失败阶段包含错误字段。")}
    }
    private func validateHistory(_ records:[Record],id:String)throws{
        guard records.count<=32 else{throw LogError(message:"配对原始报告数量超过范围。")}
        var previous:Entry?
        for (index,record) in records.enumerated(){
            let e=record.entry
            guard record.format=="CherryMacPairingRawLog",record.version==1,record.id==id,
                  record.sequence==index+1,validDate(record.savedAt) else{
                throw LogError(message:"配对原始报告文件顺序无效。")
            }
            try validate(e,id:id)
            if let p=previous{
                guard p.selection==e.selection,p.stage != "failed" else{throw LogError(message:"原始报告端点变化或失败后仍有追加。")}
                if e.intent==p.intent{
                    guard e.phase==p.phase,e.endpoint==p.endpoint,e.selector==p.selector,e.request==p.request else{
                        throw LogError(message:"原始报告意图内容发生变化。")
                    }
                    let allowed=["prepared":["received","failed"],"received":["accepted","failed"],"accepted":["failed"]]
                    guard allowed[p.stage]?.contains(e.stage)==true else{throw LogError(message:"原始报告阶段不连续。")}
                    if ["received","accepted"].contains(p.stage){
                        guard e.receivedLength==p.receivedLength,e.reply==p.reply else{throw LogError(message:"原始报告回复发生变化。")}
                    }
                }else{
                    guard e.intent>p.intent,p.stage=="accepted",e.stage=="prepared" else{throw LogError(message:"原始报告意图顺序不连续。")}
                }
            }else if e.stage != "prepared"{throw LogError(message:"原始报告必须从准备阶段开始。")}
            previous=e
        }
    }
    private func decode(_ data:Data,id:String)throws->Record{
        guard let raw=try JSONSerialization.jsonObject(with:data) as? [String:Any],
              Set(raw.keys)==Set(["format","version","id","sequence","savedAt","entry"]),
              let entry=raw["entry"] as? [String:Any],
              Set(entry.keys)==Set(["format","version","id","intent","phase","endpoint","selection","selector","request","reply","receivedLength","stage","error"]),
              let selection=entry["selection"] as? [String:Any],Set(selection.keys)==Set(["keyboard","receiver"]),
              ["keyboard","receiver"].allSatisfy({role in
                  guard let endpoint=selection[role] as? [String:Any] else{return false}
                  return Set(endpoint.keys)==Set(["token","vendorID","productID","usagePage","usage"])
              }) else{throw LogError(message:"配对原始报告字段不完整，保留原文件。")}
        let record=try JSONDecoder().decode(Record.self,from:data)
        try validate(record.entry,id:id);return record
    }
    private func validDate(_ value:String)->Bool{
        guard value.range(of:"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]{3})?Z$",options:.regularExpression) != nil else{return false}
        let formatter=ISO8601DateFormatter()
        if formatter.date(from:value) != nil{return true}
        formatter.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
        return formatter.date(from:value) != nil
    }
    private func file(_ folder:URL,sequence:Int)->URL{folder.appendingPathComponent(String(format:"report-%03d.json",sequence))}
    private func read(_ folder:URL,id:String)throws->[Record]{
        let urls=try FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:nil)
            .filter{$0.pathExtension=="json"}.sorted{$0.lastPathComponent<$1.lastPathComponent}
        guard urls.count<=32 else{throw LogError(message:"配对原始报告数量超过范围。")}
        let records=try urls.map{url->Record in
            let record=try decode(readData(url),id:id)
            guard url.lastPathComponent==file(folder,sequence:record.sequence).lastPathComponent else{
                throw LogError(message:"配对原始报告文件编号不一致。")
            };return record
        }
        try validateHistory(records,id:id);return records
    }
    private func readData(_ url:URL)throws->Data{
        let fd=Darwin.open(url.path,O_RDONLY|O_NOFOLLOW)
        guard fd>=0 else{throw LogError(message:"无法读取配对原始报告。")}
        let handle=FileHandle(fileDescriptor:fd,closeOnDealloc:true)
        do{
            var info=stat()
            guard fstat(fd,&info)==0,(info.st_mode & mode_t(S_IFMT))==mode_t(S_IFREG),info.st_size<=65536 else{
                throw LogError(message:"配对原始报告文件无效或过大。")
            }
            let data=try handle.read(upToCount:65537) ?? Data();try handle.close()
            guard data.count<=65536 else{throw LogError(message:"配对原始报告超过大小限制。")};return data
        }catch{try? handle.close();throw error}
    }
    private func locked<T>(_ id:String,create:Bool,_ body:(URL)throws->T)throws->T{
        guard UUID(uuidString:id)?.uuidString.lowercased()==id else{throw LogError(message:"原始报告操作编号无效。")}
        let folder=directory.appendingPathComponent(id,isDirectory:true),fm=FileManager.default
        guard create || fm.fileExists(atPath:folder.path) else{throw LogError(message:"没有已保存的配对原始报告。")}
        var missing:[URL]=[],cursor=folder
        while !fm.fileExists(atPath:cursor.path){
            missing.append(cursor);let parent=cursor.deletingLastPathComponent()
            guard parent.path != cursor.path else{throw LogError(message:"无法定位日志父目录。")};cursor=parent
        }
        if create{try fm.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])}
        for url in missing.reversed(){try sync(url);try sync(url.deletingLastPathComponent())}
        guard try folder.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink != true else{
            throw LogError(message:"配对原始报告目录不能是符号链接。")
        }
        let fd=Darwin.open(folder.appendingPathComponent(".lock").path,(create ? O_CREAT:0)|O_RDWR|O_NOFOLLOW,0o600)
        guard fd>=0 else{throw LogError(message:"无法打开配对原始报告锁。")}
        defer{Darwin.close(fd)}
        guard flock(fd,LOCK_EX)==0 else{throw LogError(message:"无法锁定配对原始报告。")}
        defer{flock(fd,LOCK_UN)}
        if create{try sync(folder);try sync(directory)}
        return try body(folder)
    }
    private func sync(_ url:URL)throws{
        let fd=Darwin.open(url.path,O_RDONLY|O_NOFOLLOW)
        guard fd>=0 else{throw LogError(message:"无法同步配对原始报告目录。")}
        defer{Darwin.close(fd)}
        guard fsync(fd)==0 else{throw LogError(message:"配对原始报告目录同步失败。")}
    }
}
