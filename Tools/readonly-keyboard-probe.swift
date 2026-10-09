import Cocoa
import IOKit.hid

// Development-only USB probe. The only outgoing commands are 03/05/08/0A/14.
// No configuration sender, event injection, reset, pairing or automatic retry.
struct ProbeError:LocalizedError {let message:String;var errorDescription:String?{message}}
let queryBounds:[UInt8:Int]=[3:34,5:63,8:511,10:511,20:3071]
func packet(_ command:UInt8,_ offset:Int,_ count:Int)throws->[UInt8]{
    guard let limit=queryBounds[command],offset>=0,count>0,count<=(command==20 ? 54:56),offset+count<=limit else{throw ProbeError(message:"只读查询超出指定前缀或命令不允许。")}
    var b=[UInt8](repeating:0,count:64);b[0]=4;b[3]=command;b[4]=UInt8(count);b[5]=UInt8(offset&255);b[6]=UInt8(offset>>8)
    let sum=b[3...].reduce(0){$0+UInt16($1)};b[1]=UInt8(sum&255);b[2]=UInt8(sum>>8);return b
}
final class ReadOnlyUSB {
    let manager=IOHIDManagerCreate(kCFAllocatorDefault,0)
    var device:IOHIDDevice?;let buffer=UnsafeMutablePointer<UInt8>.allocate(capacity:64)
    var replies:[[UInt8]]=[];var identity:[String:Any]=[:]
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
        IOHIDDeviceRegisterInputReportCallback(selected,buffer,64,{context,result,_,_,id,bytes,count in
            guard result==0,id==4,count==64,let context else{return}
            let probe=Unmanaged<ReadOnlyUSB>.fromOpaque(context).takeUnretainedValue();probe.replies.append(Array(UnsafeBufferPointer(start:bytes,count:count)))
            if probe.replies.count>16{probe.replies.removeFirst()}
        },Unmanaged.passUnretained(self).toOpaque())
        IOHIDDeviceScheduleWithRunLoop(selected,CFRunLoopGetCurrent(),CFRunLoopMode.defaultMode.rawValue)
    }
    deinit{if let device{IOHIDDeviceUnscheduleFromRunLoop(device,CFRunLoopGetCurrent(),CFRunLoopMode.defaultMode.rawValue);IOHIDDeviceClose(device,0)};IOHIDManagerClose(manager,0);buffer.deinitialize(count:64);buffer.deallocate()}
    func query(_ request:[UInt8],captureReply:([UInt8])->Void)throws->[UInt8]{
        guard request.count==64,let device,request==(try packet(request[3],Int(request[5])+Int(request[6])*256,Int(request[4]))) else{throw ProbeError(message:"只读请求无效。")}
        replies.removeAll();let sent=request.withUnsafeBufferPointer{IOHIDDeviceSetReport(device,kIOHIDReportTypeOutput,4,$0.baseAddress!,64)}
        guard sent==0 else{throw ProbeError(message:"只读请求发送失败（\(sent)）。")}
        let deadline=ProcessInfo.processInfo.systemUptime+2
        while ProcessInfo.processInfo.systemUptime<deadline{
            if !replies.isEmpty{
                let reply=replies.removeFirst();captureReply(reply)
                guard reply[0]==4,reply[3]==request[3],reply[4..<7].elementsEqual(request[4..<7]),reply[7]==0 else{throw ProbeError(message:"回复报告、偏移或状态不匹配，停止查询。")}
                let sum=request[3..<8].reduce(0){$0+UInt16($1)}
                guard (UInt16(reply[1])|(UInt16(reply[2])<<8))==sum else{throw ProbeError(message:"回复校验不一致。")}
                return Array(reply[8..<8+Int(request[4])])
            }
            RunLoop.current.run(until:Date().addingTimeInterval(0.01))
        }
        throw ProbeError(message:"只读查询超时；没有重试。")
    }
}
let app=NSApplication.shared;app.setActivationPolicy(.prohibited)
var receipt:[String:Any]=["format":"CherryMacReadOnlyProbe","version":1,"keyboardWritesPerformed":false,"queries":[[String:Any]]()]
let output=CommandLine.arguments.count==2 ? URL(fileURLWithPath:CommandLine.arguments[1]):nil
var outputAuthorized=false
func save()throws{
    guard outputAuthorized,let output else{throw ProbeError(message:"需要唯一输出JSON路径。")}
    try JSONSerialization.data(withJSONObject:receipt,options:[.prettyPrinted,.sortedKeys]).write(to:output,options:.atomic)
}
do{
    guard CommandLine.arguments.count==2,let output,!FileManager.default.fileExists(atPath:output.path) else{throw ProbeError(message:"需指定尚不存在的输出文件，原记录不能覆盖。")}
    outputAuthorized=true
    let usb=try ReadOnlyUSB();receipt["identity"]=usb.identity;try save()
    // Selected edge reads only. This does not capture full regions or imply
    // the final byte is readable, complete recovery or pairing is supported.
    for (command,offset,length) in [(UInt8(5),56,7),(UInt8(8),490,21),(UInt8(10),490,21)]{
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
