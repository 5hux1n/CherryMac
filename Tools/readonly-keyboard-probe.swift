import Cocoa
import IOKit.hid

// Development-only USB probe. Read commands: 03/05/07/08/0A/14/1B/1D.
// No configuration sender, event injection, reset, pairing or automatic retry.
struct ProbeError:LocalizedError {let message:String;var errorDescription:String?{message}}
let queryBounds:[UInt8:Int]=[3:34,5:64,7:512,8:512,10:512,20:3072,27:126,29:56]
func packet(_ command:UInt8,_ offset:Int,_ count:Int)throws->[UInt8]{
    guard let limit=queryBounds[command],offset>=0,count>0,count<=(command==20 ? 54:56),offset+count<=limit else{throw ProbeError(message:"只读查询超出指定前缀或命令不允许。")}
    var b=[UInt8](repeating:0,count:64);b[0]=4;b[3]=command;b[4]=UInt8(count);b[5]=UInt8(offset&255);b[6]=UInt8(offset>>8)
    let sum=b[3...].reduce(0){$0+UInt16($1)};b[1]=UInt8(sum&255);b[2]=UInt8(sum>>8);return b
}
final class ReadOnlyUSB {
    let manager=IOHIDManagerCreate(kCFAllocatorDefault,0)
    var device:IOHIDDevice?;let buffer=UnsafeMutablePointer<UInt8>.allocate(capacity:64)
    var replies:[[UInt8]]=[];private(set) var identity:[String:Any]=[:];var dead=false
    var deviceOpened=false;var scheduled=false
    init()throws{
        buffer.initialize(repeating:0,count:64)
        IOHIDManagerSetDeviceMatching(manager,[kIOHIDVendorIDKey:0x046a,kIOHIDProductIDKey:0x01ce,kIOHIDTransportKey:"USB"] as CFDictionary)
        let opened=IOHIDManagerOpen(manager,0);guard opened==0 else{throw ProbeError(message:"USB只读打开被系统拒绝（\(opened)）；请开启本App输入监控权限。")}
        let devices=IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []
        guard devices.count==1,let selected=devices.first else{throw ProbeError(message:"需仅连接一把目标USB键盘。")};device=selected
        var registryID:UInt64=0;guard IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(selected),&registryID)==KERN_SUCCESS else{throw ProbeError(message:"无法绑定USB会话。")}
        identity=["vendorID":0x046a,"productID":0x01ce,"transport":"USB","registryID":String(registryID)]
        if let revision=IOHIDDeviceGetProperty(selected,kIOHIDVersionNumberKey as CFString) as? NSNumber{identity["usbRevision"]=revision.intValue}
        let result=IOHIDDeviceOpen(selected,0);guard result==0 else{throw ProbeError(message:"目标USB接口打开失败（\(result)）。")}
        deviceOpened=true
        IOHIDDeviceRegisterInputReportCallback(selected,buffer,64,{context,result,_,_,id,bytes,count in
            guard result==0,id==4,count==64,let context else{return}
            let probe=Unmanaged<ReadOnlyUSB>.fromOpaque(context).takeUnretainedValue();guard !probe.dead else{return};probe.replies.append(Array(UnsafeBufferPointer(start:bytes,count:count)))
            if probe.replies.count>16{probe.replies.removeFirst()}
        },Unmanaged.passUnretained(self).toOpaque())
        IOHIDDeviceRegisterRemovalCallback(selected,{context,_,_ in
            guard let context else{return};Unmanaged<ReadOnlyUSB>.fromOpaque(context).takeUnretainedValue().dead=true
        },Unmanaged.passUnretained(self).toOpaque())
        IOHIDDeviceScheduleWithRunLoop(selected,CFRunLoopGetCurrent(),CFRunLoopMode.defaultMode.rawValue)
        scheduled=true
    }
    deinit{if deviceOpened,let device{if scheduled{IOHIDDeviceUnscheduleFromRunLoop(device,CFRunLoopGetCurrent(),CFRunLoopMode.defaultMode.rawValue)};IOHIDDeviceRegisterInputReportCallback(device,buffer,64,nil,nil);IOHIDDeviceRegisterRemovalCallback(device,nil,nil);IOHIDDeviceClose(device,0)};IOHIDManagerClose(manager,0);buffer.deinitialize(count:64);buffer.deallocate()}
    func checkSession()throws{
        guard !dead,let device else{throw ProbeError(message:"USB只读会话已失效。")}
        var current:UInt64=0
        guard IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device),&current)==KERN_SUCCESS,
              let revision=IOHIDDeviceGetProperty(device,kIOHIDVersionNumberKey as CFString) as? NSNumber,
              let selectedRevision=identity["usbRevision"] as? Int,
              String(current)==identity["registryID"] as? String,
              (IOHIDDeviceGetProperty(device,kIOHIDVendorIDKey as CFString) as? NSNumber)?.intValue==0x046a,
              (IOHIDDeviceGetProperty(device,kIOHIDProductIDKey as CFString) as? NSNumber)?.intValue==0x01ce,
              (IOHIDDeviceGetProperty(device,kIOHIDTransportKey as CFString) as? String)=="USB",
              revision.intValue==selectedRevision else{
            dead=true;throw ProbeError(message:"USB只读设备身份或会话已改变。")
        }
    }
    func query(_ request:[UInt8],captureReply:([UInt8])->Void)throws->[UInt8]{
        guard request.count==64,let device,request==(try packet(request[3],Int(request[5])+Int(request[6])*256,Int(request[4]))) else{throw ProbeError(message:"只读请求无效。")}
        try checkSession()
        replies.removeAll();let sent=request.withUnsafeBufferPointer{IOHIDDeviceSetReport(device,kIOHIDReportTypeOutput,4,$0.baseAddress!,64)}
        guard sent==0 else{throw ProbeError(message:"只读请求发送失败（\(sent)）。")}
        let deadline=ProcessInfo.processInfo.systemUptime+2
        while ProcessInfo.processInfo.systemUptime<deadline{
            try checkSession()
            if !replies.isEmpty{
                let reply=replies.removeFirst();captureReply(reply)
                guard reply[0]==4,reply[3]==request[3],reply[4..<7].elementsEqual(request[4..<7]),reply[7]==0 else{throw ProbeError(message:"回复报告、偏移或状态不匹配，停止查询。")}
                let sum=request[3..<8].reduce(0){$0+UInt16($1)}
                guard (UInt16(reply[1])|(UInt16(reply[2])<<8))==sum else{throw ProbeError(message:"回复校验不一致。")}
                try checkSession();return Array(reply[8..<8+Int(request[4])])
            }
            RunLoop.current.run(until:Date().addingTimeInterval(0.01))
        }
        throw ProbeError(message:"只读查询超时；没有重试。")
    }
}
let app=NSApplication.shared;app.setActivationPolicy(.prohibited)
var receipt:[String:Any]=["format":"CherryMacReadOnlyProbe","version":1,"keyboardWritesPerformed":false,"queries":[[String:Any]]()]
let output=[2,4].contains(CommandLine.arguments.count) ? URL(fileURLWithPath:CommandLine.arguments[1]):nil
var outputAuthorized=false
func save()throws{
    guard outputAuthorized,let output else{throw ProbeError(message:"需要唯一输出JSON路径。")}
    try JSONSerialization.data(withJSONObject:receipt,options:[.prettyPrinted,.sortedKeys]).write(to:output,options:.atomic)
}
do{
    guard [2,4].contains(CommandLine.arguments.count),let output,!FileManager.default.fileExists(atPath:output.path) else{throw ProbeError(message:"需指定尚不存在的输出文件，原记录不能覆盖。")}
    var queries:[(UInt8,Int,Int)]=[(5,56,7),(8,490,21),(10,490,21)]
    if CommandLine.arguments.count==4{
        guard CommandLine.arguments[2]=="--plan" else{throw ProbeError(message:"计划参数无效。")}
        let handle=try FileHandle(forReadingFrom:URL(fileURLWithPath:CommandLine.arguments[3]));defer{try? handle.close()}
        let data=try handle.read(upToCount:128_001) ?? Data()
        guard data.count<=128_000,let rows=try JSONSerialization.jsonObject(with:data) as? [[String:Any]],!rows.isEmpty,rows.count<=200 else{throw ProbeError(message:"只读查询计划过大或格式无效。")}
        func integer(_ value:Any?)throws->Int{
            guard let n=value as? NSNumber,CFGetTypeID(n) != CFBooleanGetTypeID(),n.doubleValue.isFinite,n.doubleValue.rounded()==n.doubleValue,n.doubleValue>=0,n.doubleValue<=65535 else{throw ProbeError(message:"只读计划需要有限整数。")};return n.intValue
        }
        queries=try rows.map{row in
            guard Set(row.keys)==Set(["command","offset","length"]) else{throw ProbeError(message:"只读查询计划含未知字段。")}
            let command=try integer(row["command"]),offset=try integer(row["offset"]),length=try integer(row["length"])
            guard command<=255 else{throw ProbeError(message:"只读查询命令无效。")};_ = try packet(UInt8(command),offset,length)
            return (UInt8(command),offset,length)
        }
    }
    outputAuthorized=true
    let usb=try ReadOnlyUSB();receipt["identity"]=usb.identity;try save()
    // Bounded read plans only. Accepted spans do not imply final-byte access,
    // complete recovery or pairing support.
    for (command,offset,length) in queries{
        let request=try packet(command,offset,length);var rows=receipt["queries"] as! [[String:Any]]
        rows.append(["command":Int(command),"offset":offset,"length":length,"request":request,"status":"prepared"]);receipt["queries"]=rows;try save()
        var captured:[UInt8]?
        do{
            let bytes=try usb.query(request,captureReply:{captured=$0});rows[rows.count-1]["status"]="accepted";rows[rows.count-1]["data"]=bytes
        }catch{
            rows[rows.count-1]["status"]="failed";rows[rows.count-1]["error"]=error.localizedDescription
            if let captured{rows[rows.count-1]["reply"]=captured};receipt["queries"]=rows;try save();throw error
        }
        if let captured{rows[rows.count-1]["reply"]=captured};receipt["queries"]=rows;try save()
    }
    receipt["status"]="complete";try save()
}catch{receipt["status"]="failed";receipt["error"]=error.localizedDescription;try? save();fputs(error.localizedDescription+"\n",stderr);exit(1)}
