import Foundation
import IOKit.hid

// Dedicated read-only USB session, separate from every configuration sender.
// Development code only until the current revision's boundaries are confirmed.
final class ExtendedHardwareUSB {
    private let manager=IOHIDManagerCreate(kCFAllocatorDefault,0)
    private let buffer=UnsafeMutablePointer<UInt8>.allocate(capacity:64)
    private let runLoop=CFRunLoopGetMain()!
    private var device:IOHIDDevice?
    private var selected:ExtendedHardwareCapture.Identity?
    private var received:[[UInt8]]=[]
    private var dead=false
    private var busy=false
    private var scheduled=false
    private var deviceOpened=false
    private var captureActive=false
    private func fail(_ message:String)throws->Never{
        throw ExtendedHardwareCapture.CaptureError(message:message)
    }
    init()throws{
        buffer.initialize(repeating:0,count:64)
        guard Thread.isMainThread else{try fail("扩展USB捕获必须在主线程启动。")}
        IOHIDManagerSetDeviceMatching(manager,[kIOHIDVendorIDKey:0x046a,kIOHIDProductIDKey:0x01ce,kIOHIDTransportKey:"USB"] as CFDictionary)
        let opened=IOHIDManagerOpen(manager,0)
        guard opened==0 else{try fail("扩展只读USB打开被系统拒绝（\(opened)），请检查输入监控。")}
        let devices=IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []
        guard devices.count==1,let target=devices.first else{try fail("扩展捕获需要一把目标USB键盘。")}
        device=target
        let identity=try currentIdentity();try identity.validate();selected=identity
        let result=IOHIDDeviceOpen(target,0)
        guard result==0 else{try fail("扩展只读USB接口打开失败（\(result)）。")}
        deviceOpened=true
        IOHIDDeviceRegisterInputReportCallback(target,buffer,64,{context,result,_,_,id,bytes,count in
            guard let context else{return}
            let owner=Unmanaged<ExtendedHardwareUSB>.fromOpaque(context).takeUnretainedValue()
            guard !owner.dead,owner.busy,id==4 else{return}
            guard result==0,count==64 else{owner.dead=true;return}
            owner.received.append(Array(UnsafeBufferPointer(start:bytes,count:count)))
            if owner.received.count>1{owner.dead=true}
        },Unmanaged.passUnretained(self).toOpaque())
        IOHIDDeviceRegisterRemovalCallback(target,{context,_,_ in
            guard let context else{return}
            Unmanaged<ExtendedHardwareUSB>.fromOpaque(context).takeUnretainedValue().dead=true
        },Unmanaged.passUnretained(self).toOpaque())
        IOHIDDeviceScheduleWithRunLoop(target,runLoop,CFRunLoopMode.defaultMode.rawValue);scheduled=true
    }
    deinit{
        if deviceOpened,let device{
            if scheduled{IOHIDDeviceUnscheduleFromRunLoop(device,runLoop,CFRunLoopMode.defaultMode.rawValue)}
            IOHIDDeviceRegisterInputReportCallback(device,buffer,64,nil,nil)
            IOHIDDeviceRegisterRemovalCallback(device,nil,nil);IOHIDDeviceClose(device,0)
        }
        IOHIDManagerClose(manager,0);buffer.deinitialize(count:64);buffer.deallocate()
    }
    private func currentIdentity()throws->ExtendedHardwareCapture.Identity{
        guard Thread.isMainThread,!dead,let device else{try fail("扩展只读USB会话已失效。")}
        var registryID:UInt64=0
        guard IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device),&registryID)==KERN_SUCCESS,
              let vendor=IOHIDDeviceGetProperty(device,kIOHIDVendorIDKey as CFString) as? NSNumber,
              let product=IOHIDDeviceGetProperty(device,kIOHIDProductIDKey as CFString) as? NSNumber,
              let revision=IOHIDDeviceGetProperty(device,kIOHIDVersionNumberKey as CFString) as? NSNumber,
              let transport=IOHIDDeviceGetProperty(device,kIOHIDTransportKey as CFString) as? String else{try fail("无法读取扩展USB会话的真实身份。")}
        return .init(sessionToken:String(registryID),vendorID:vendor.intValue,productID:product.intValue,usbRevision:revision.intValue,transport:transport)
    }
    func identity()throws->ExtendedHardwareCapture.Identity{
        let current=try currentIdentity();try current.validate()
        guard current==selected else{dead=true;try fail("扩展捕获USB身份或会话已变化。")}
        return current
    }
    private func exchange(_ request:[UInt8],cancelled:()->Bool)throws->[UInt8]{
        guard !busy,!cancelled(),request.count==64 else{try fail("扩展捕获已取消或报告交换尚未结束。")}
        let canonical=try ExtendedHardwareReadFrames.request(command:request[3],offset:Int(request[5])+Int(request[6])*256,length:Int(request[4]))
        guard request==canonical else{try fail("扩展USB仅接受固定范围的无数据读取报告。")}
        _=try identity();guard let device else{try fail("扩展USB已关闭。")}
        busy=true;defer{busy=false};received.removeAll()
        do{
            let sent=request.withUnsafeBufferPointer{IOHIDDeviceSetReport(device,kIOHIDReportTypeOutput,4,$0.baseAddress!,64)}
            guard sent==0 else{try fail("扩展只读报告发送失败（\(sent)）；没有重试。")}
            let deadline=ProcessInfo.processInfo.systemUptime+2
            while ProcessInfo.processInfo.systemUptime<deadline{
                guard !cancelled() else{try fail("扩展捕获已取消。")}
                _=try identity()
                if !received.isEmpty{
                    let reply=received.removeFirst()
                    _=try ExtendedHardwareReadFrames.payload(reply:reply,request:request)
                    return reply
                }
                RunLoop.current.run(until:Date().addingTimeInterval(0.01))
            }
            try fail("扩展只读报告超时；没有重试。")
        }catch{dead=true;throw error}
    }
    func capture(store:ExtendedHardwareBackupStore,journal:ExtendedCaptureJournal,
                 cancelled:()->Bool)throws->(operationID:String,receipt:ExtendedHardwareCapture.Receipt){
        guard !captureActive else{try fail("扩展捕获尚未结束，不能重复启动。")}
        captureActive=true;defer{captureActive=false}
        let bound=try identity(),operationID=UUID().uuidString.lowercased()
        let receipt=try ExtendedHardwareCapture.capture(identity:{try self.identity()},cancelled:cancelled,
            nowMilliseconds:{Date().timeIntervalSince1970*1000},
            persist:{try journal.save(id:operationID,identity:bound,event:$0)},
            exchange:{try self.exchange($0,cancelled:cancelled)},save:store.save,load:store.load)
        return (operationID,receipt)
    }
}
