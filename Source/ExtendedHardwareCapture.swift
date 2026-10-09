import Foundation

// Injectable read-only capture. The product must supply a real, bounded USB
// adapter and durable progress storage; this file never opens a device.
struct ExtendedHardwareCapture {
    struct Identity: Equatable {
        let sessionToken:String
        let vendorID:Int
        let productID:Int
        let usbRevision:Int
        let transport:String
        func validate()throws{
            guard !sessionToken.isEmpty,sessionToken.utf8.count<=128,vendorID==0x046a,productID==0x01ce,
                  usbRevision==0x0104,transport=="USB" else{throw CaptureError(message:"扩展捕获仅有 Pokémon USB 0104 的静态边界依据；当前设备身份／固件范围未匹配。")}
        }
    }
    struct Region {
        let name:String;let command:UInt8;let count:Int;let chunkCapacity:Int
    }
    static let regions:[Region]=[
        .init(name:"deviceInfo",command:3,count:34,chunkCapacity:56),
        .init(name:"parameters",command:5,count:63,chunkCapacity:56),
        .init(name:"keymap",command:8,count:511,chunkCapacity:56),
        .init(name:"colors",command:0x0a,count:511,chunkCapacity:56),
        .init(name:"macroData",command:0x14,count:3071,chunkCapacity:54)]
    struct Event:Codable {
        let sequence:Int;let phase:String;let pass:Int;let region:String
        let offset:Int;let length:Int;let backupReference:String?;let detail:String
    }
    struct Receipt {
        let identity:Identity;let snapshot:ExtendedHardwareBackup;let backupReference:String
        let completedReads:Int
    }
    struct CaptureError:LocalizedError{let message:String;var errorDescription:String?{message}}

    static func capture(identity:()throws->Identity,cancelled:()->Bool,nowMilliseconds:()->Double,
                        persist:(Event)throws->Void,read:(UInt8,Int,Int)throws->[UInt8],
                        save:(ExtendedHardwareBackup)throws->String,
                        load:(String)throws->ExtendedHardwareBackup)throws->Receipt{
        let selected=try identity();try selected.validate()
        var sequence=0,completedReads=0,backupReference:String?
        func check()throws{
            guard !cancelled() else{throw CaptureError(message:"扩展捕获已取消；已有资料保留。")}
            let current=try identity();try current.validate()
            guard current==selected else{throw CaptureError(message:"扩展捕获 USB 会话已改变，停止读取。")}
        }
        func event(_ phase:String,_ pass:Int=0,_ region:String="",_ offset:Int=0,_ length:Int=0,_ detail:String="")throws{
            sequence+=1;try persist(.init(sequence:sequence,phase:phase,pass:pass,region:region,offset:offset,length:length,backupReference:backupReference,detail:detail))
        }
        func capturePass(_ pass:Int)throws->ExtendedHardwareBackup{
            var data:[String:[UInt8]]=[:]
            for region in regions{
                var value:[UInt8]=[]
                for offset in stride(from:0,to:region.count,by:region.chunkCapacity){
                    let length=min(region.chunkCapacity,region.count-offset)
                    try check();try event("readPrepared",pass,region.name,offset,length);try check()
                    let bytes=try read(region.command,offset,length)
                    guard bytes.count==length else{throw CaptureError(message:"扩展捕获回复长度不一致。")}
                    try check();value+=bytes;completedReads+=1;try event("readAccepted",pass,region.name,offset,length)
                }
                data[region.name]=value
            }
            let timestamp=nowMilliseconds();guard timestamp.isFinite,timestamp>=0 else{throw CaptureError(message:"扩展捕获时间无效。")}
            let snapshot=ExtendedHardwareBackup(createdAtMilliseconds:timestamp,deviceInfo:data["deviceInfo"]!,parameters:data["parameters"]!,keymap:data["keymap"]!,colors:data["colors"]!,macroData:data["macroData"]!)
            try snapshot.validate();return snapshot
        }
        do{
            try check();try event("started")
            let first=try capturePass(1),second=try capturePass(2)
            guard try first.hasSameCapturedData(as:second) else{throw CaptureError(message:"扩展数据在两次捕获间发生变化，未作为一致备份保存。")}
            try check();try event("saving")
            let reference=try save(second)
            guard let id=UUID(uuidString:reference),id.uuidString.lowercased()==reference else{throw CaptureError(message:"扩展备份保存标识无效。")}
            backupReference=reference;try event("saved")
            let restored=try load(reference)
            guard restored==second else{throw CaptureError(message:"扩展备份本机读回不一致，保存结果不能用于后续流程。")}
            try check();try event("complete")
            return .init(identity:selected,snapshot:second,backupReference:reference,completedReads:completedReads)
        }catch{
            // A failed final identity/storage check does not delete saved data.
            try event(cancelled() ? "cancelled":"failed",0,"",0,0,error.localizedDescription)
            throw error
        }
    }
}
