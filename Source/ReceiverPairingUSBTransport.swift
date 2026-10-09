import Foundation
import IOKit
@preconcurrency import IOKit.hid

// Development-only transport, excluded from public build lists. Construction
// never opens a HID device or sends a report. Frame deadlines do not establish
// a hard bound for synchronous OS open/close calls or disk checkpoint loading.
@MainActor final class ReceiverPairingUSBTransport {
    struct TransportError:LocalizedError {
        let message:String
        var errorDescription:String?{message}
    }
    @MainActor private final class EndpointState {
        weak var owner:ReceiverPairingUSBTransport?
        let role:ReceiverPairingFrames.Endpoint
        let device:IOHIDDevice
        let registryID:UInt64
        let buffer=UnsafeMutablePointer<UInt8>.allocate(capacity:64)
        var opened=false
        var scheduled=false
        init(role:ReceiverPairingFrames.Endpoint,device:IOHIDDevice,registryID:UInt64){
            self.role=role;self.device=device;self.registryID=registryID
            buffer.initialize(repeating:0,count:64)
        }
        deinit{buffer.deinitialize(count:64);buffer.deallocate()}
    }
    // Independently retained until the one-shot OS completion/abort callback.
    // A frame timeout never frees memory that an outstanding send may still use.
    @MainActor private final class SendContext {
        weak var owner:ReceiverPairingUSBTransport?
        let token:UUID
        let device:IOHIDDevice
        let buffer:UnsafeMutablePointer<UInt8>
        init(owner:ReceiverPairingUSBTransport,token:UUID,device:IOHIDDevice,request:[UInt8]){
            self.owner=owner;self.token=token;self.device=device
            buffer = .allocate(capacity:64);buffer.initialize(from:request,count:64)
        }
        deinit{buffer.deinitialize(count:64);buffer.deallocate()}
    }
    private final class Pending {
        let token=UUID()
        let endpoint:ReceiverPairingFrames.Endpoint
        let continuation:CheckedContinuation<[UInt8],Error>
        var sendCompleted=false
        var reply:[UInt8]?
        var timer:Task<Void,Never>?
        init(endpoint:ReceiverPairingFrames.Endpoint,continuation:CheckedContinuation<[UInt8],Error>){
            self.endpoint=endpoint;self.continuation=continuation
        }
    }
    private let devices:ReceiverPairingDevices
    private let selection:ReceiverPairingSelection
    private let journal:ReceiverPairingJournal
    private let rawLog:ReceiverPairingRawLog
    private var endpoints:[ReceiverPairingFrames.Endpoint:EndpointState]=[:]
    private var pending:Pending?
    private var opened=false
    private var closed=false
    private var operationID:String?
    private var consumed=Set<Int>()
    private var closeErrors:[String]=[]
    init(devices:ReceiverPairingDevices,selection:ReceiverPairingSelection,journal:ReceiverPairingJournal)throws{
        try selection.validate();self.devices=devices;self.selection=selection;self.journal=journal
        rawLog=ReceiverPairingRawLog(directory:journal.directory.appendingPathComponent("raw-reports",isDirectory:true))
        let bound=try devices.resolve(keyboardToken:selection.keyboard.token,receiverToken:selection.receiver.token)
        guard bound.selection==selection,!CFEqual(bound.keyboard,bound.receiver) else{throw TransportError(message:"配对端点选择无效。")}
        for (role,device) in [(ReceiverPairingFrames.Endpoint.keyboard,bound.keyboard),(.receiver,bound.receiver)]{
            var registryID:UInt64=0
            guard IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device),&registryID)==KERN_SUCCESS,registryID != 0 else{
                throw TransportError(message:"无法固定配对端点系统身份。")
            }
            let entry=EndpointState(role:role,device:device,registryID:registryID);entry.owner=self;endpoints[role]=entry
        }
    }
    func currentSelection()throws->ReceiverPairingSelection{
        guard !closed else{throw TransportError(message:"配对USB传输已经关闭。")}
        let bound=try devices.resolve(keyboardToken:selection.keyboard.token,receiverToken:selection.receiver.token)
        guard bound.selection==selection else{throw TransportError(message:"配对端点选择发生变化。")}
        for (role,device) in [(ReceiverPairingFrames.Endpoint.keyboard,bound.keyboard),(.receiver,bound.receiver)]{
            guard let entry=endpoints[role],CFEqual(device,entry.device) else{throw TransportError(message:"配对端点对象已更换。")}
            var registryID:UInt64=0
            guard IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device),&registryID)==KERN_SUCCESS,registryID==entry.registryID else{
                throw TransportError(message:"配对端点系统身份已变化。")
            }
        };return selection
    }
    func open()throws{
        guard !opened,!closed,Thread.isMainThread else{throw TransportError(message:"配对USB必须在主线程显式打开一次。")}
        do{
            _=try currentSelection();try Task.checkCancellation()
            for role in [ReceiverPairingFrames.Endpoint.keyboard,.receiver]{
                guard let entry=endpoints[role] else{throw TransportError(message:"配对端点缺失。")}
                let result=IOHIDDeviceOpen(entry.device,0)
                guard result==kIOReturnSuccess else{throw TransportError(message:"配对USB打开失败（\(result)）。")}
                entry.opened=true
                let pointer=Unmanaged.passUnretained(entry).toOpaque()
                IOHIDDeviceRegisterInputReportCallback(entry.device,entry.buffer,64,{raw,result,_,_,id,bytes,count in
                    guard let raw else{return}
                    let entry=Unmanaged<EndpointState>.fromOpaque(raw).takeUnretainedValue()
                    let sample=(0...64).contains(count) ? Array(UnsafeBufferPointer(start:bytes,count:count)):nil
                    guard Thread.isMainThread else{
                        DispatchQueue.main.async{entry.owner?.stop(TransportError(message:"配对输入回调未运行于主线程。"))};return
                    }
                    // Process on the scheduled loop immediately: dispatching an
                    // idle report could incorrectly bind it to a later request.
                    MainActor.assumeIsolated{entry.owner?.input(entry:entry,result:result,reportID:id,count:count,bytes:sample)}
                },pointer)
                IOHIDDeviceRegisterRemovalCallback(entry.device,{raw,_,_ in
                    guard let raw else{return}
                    let entry=Unmanaged<EndpointState>.fromOpaque(raw).takeUnretainedValue()
                    if Thread.isMainThread{
                        MainActor.assumeIsolated{entry.owner?.stop(TransportError(message:"配对端点已断开。"))}
                    }else{DispatchQueue.main.async{entry.owner?.stop(TransportError(message:"配对端点已断开。"))}}
                },pointer)
                IOHIDDeviceScheduleWithRunLoop(entry.device,CFRunLoopGetMain(),CFRunLoopMode.defaultMode.rawValue)
                entry.scheduled=true;_=try currentSelection();try Task.checkCancellation()
            }
            opened=true
        }catch{stop(error);throw error}
    }
    func exchange(_ plan:ReceiverPairingFrames.Plan,operationID id:String,intent:Int)async throws->[UInt8]{
        guard opened,!closed,pending==nil else{throw TransportError(message:"配对USB尚未打开、已失效或正在交换。")}
        guard plan == (try ReceiverPairingFrames.plan(phase:plan.phase,selector:plan.selector)) else{
            throw TransportError(message:"配对USB只接受固定请求。")
        }
        do{
            _=try currentSelection();try Task.checkCancellation()
            let state=try journal.load(operationID:id).last?.state
            let raw=try rawLog.load(operationID:id).last?.entry
            guard let state,let raw,state.pending,state.operationID==intent,state.phase==plan.phase,
                  state.backupReference != nil,state.selection==selection,raw.intent==intent,raw.stage=="prepared",
                  raw.phase==plan.phase,raw.endpoint==plan.endpoint.rawValue,raw.selector==plan.selector,
                  raw.selection==selection,raw.request==plan.request,
                  operationID==nil || operationID==id,!consumed.contains(intent),
                  let entry=endpoints[plan.endpoint],entry.opened else{
                throw TransportError(message:"配对发送缺少本次保存的意图与准备记录，或意图已使用。")
            }
            operationID=id;consumed.insert(intent);_=try currentSelection();try Task.checkCancellation()
            return try await withTaskCancellationHandler(operation:{
                try Task.checkCancellation()
                return try await withCheckedThrowingContinuation{continuation in
                    let current=Pending(endpoint:plan.endpoint,continuation:continuation);pending=current
                    let timeoutMS=plan.endpoint == .keyboard ? 1000:5000
                    let context=SendContext(owner:self,token:current.token,device:entry.device,request:plan.request)
                    let pointer=Unmanaged.passRetained(context).toOpaque()
                    // The SDK documents timeout in milliseconds; the Apple
                    // user-space implementation forwards it to UInt32 timeout.
                    let result=IOHIDDeviceSetReportWithCallback(entry.device,kIOHIDReportTypeOutput,4,context.buffer,64,Double(timeoutMS),{raw,result,_,type,id,_,_ in
                        guard let raw else{return}
                        let context=Unmanaged<SendContext>.fromOpaque(raw).takeRetainedValue()
                        DispatchQueue.main.async{context.owner?.sent(token:context.token,result:result,type:type,id:id)}
                    },pointer)
                    guard result==kIOReturnSuccess else{
                        Unmanaged<SendContext>.fromOpaque(pointer).release()
                        stop(TransportError(message:"配对报告提交失败（\(result)）；没有重试。"));return
                    }
                    current.timer=Task{[weak self] in
                        do{try await Task.sleep(nanoseconds:UInt64(timeoutMS)*1_000_000)}catch{return}
                        guard let self,self.pending?.token==current.token else{return}
                        self.stop(TransportError(message:"配对报告交换超时；没有重试。"))
                    }
                }
            },onCancel:{DispatchQueue.main.async{self.stop(CancellationError())}})
        }catch{stop(error);throw error}
    }
    private func input(entry:EndpointState,result:IOReturn,reportID:UInt32,count:Int,bytes:[UInt8]?){
        guard !closed,reportID==4 else{return}
        guard let current=pending,current.endpoint==entry.role,current.reply==nil else{
            stop(TransportError(message:"收到本次请求之外或重复的配置回复。"));return
        }
        guard result==kIOReturnSuccess,let bytes else{
            stop(TransportError(message:"配对输入报告错误（\(result)，实际长度\(count)）。"));return
        }
        do{_=try currentSelection();current.reply=bytes;finishIfReady()}catch{stop(error)}
    }
    private func sent(token:UUID,result:IOReturn,type:IOHIDReportType,id:UInt32){
        guard !closed,let current=pending,current.token==token else{return}
        guard result==kIOReturnSuccess,type==kIOHIDReportTypeOutput,id==4 else{
            stop(TransportError(message:"配对发送完成回报无效（\(result)）。"));return
        }
        current.sendCompleted=true;finishIfReady()
    }
    private func finishIfReady(){
        guard let current=pending,current.sendCompleted,let reply=current.reply else{return}
        pending=nil;current.timer?.cancel();current.continuation.resume(returning:reply)
    }
    private func stop(_ error:Error){
        guard !closed else{return}
        closed=true;opened=false
        let current=pending;pending=nil;current?.timer?.cancel();current?.continuation.resume(throwing:error)
        cleanup()
    }
    private func cleanup(){
        for entry in endpoints.values{
            guard entry.opened else{continue}
            if entry.scheduled{
                IOHIDDeviceUnscheduleFromRunLoop(entry.device,CFRunLoopGetMain(),CFRunLoopMode.defaultMode.rawValue)
                entry.scheduled=false
            }
            IOHIDDeviceRegisterInputReportCallback(entry.device,entry.buffer,64,nil,nil)
            IOHIDDeviceRegisterRemovalCallback(entry.device,nil,nil)
            let result=IOHIDDeviceClose(entry.device,0);entry.opened=false
            if result != kIOReturnSuccess{closeErrors.append("配对接口关闭失败（\(result)）。")}
        }
    }
    func close()throws{
        if !closed{stop(TransportError(message:"配对USB传输已关闭。"))}
        if !closeErrors.isEmpty{throw TransportError(message:closeErrors.joined(separator:"；"))}
    }
    deinit{
        let retained=Array(endpoints.values)
        DispatchQueue.main.async{
            for entry in retained where entry.opened{
                if entry.scheduled{IOHIDDeviceUnscheduleFromRunLoop(entry.device,CFRunLoopGetMain(),CFRunLoopMode.defaultMode.rawValue)}
                IOHIDDeviceRegisterInputReportCallback(entry.device,entry.buffer,64,nil,nil)
                IOHIDDeviceRegisterRemovalCallback(entry.device,nil,nil);IOHIDDeviceClose(entry.device,0)
            }
            withExtendedLifetime(retained){}
        }
    }
}
