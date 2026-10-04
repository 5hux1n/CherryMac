import Cocoa
import ApplicationServices
import IOKit.hid
import Darwin

// CGEvent does not expose a keyboard device identifier. Correlate its exact
// timestamp and keycode with input from the vendor-filtered IOHIDManager.
// An unmatched event is always passed through. Never guess by keycode alone.
struct RawKeyRecord {
    let signal: String
    let nanoseconds: UInt64
    let keyCode: UInt16
    let down: Bool
}

let hidToMacKey: [UInt32: UInt16] = [
    4: 0, 5: 11, 6: 8, 7: 2, 8: 14, 9: 3, 10: 5, 11: 4, 12: 34,
    13: 38, 14: 40, 15: 37, 16: 46, 17: 45, 18: 31, 19: 35, 20: 12,
    21: 15, 22: 1, 23: 17, 24: 32, 25: 9, 26: 13, 27: 7, 28: 16, 29: 6,
    30: 18, 31: 19, 32: 20, 33: 21, 34: 23, 35: 22, 36: 26, 37: 28,
    38: 25, 39: 29, 40: 36, 41: 53, 42: 51, 43: 48, 44: 49, 45: 27,
    46: 24, 47: 33, 48: 30, 49: 42, 50: 10, 51: 41, 52: 39, 53: 50,
    54: 43, 55: 47, 56: 44, 57: 57, 58: 122, 59: 120, 60: 99, 61: 118,
    62: 96, 63: 97, 64: 98, 65: 100, 66: 101, 67: 109, 68: 103, 69: 111,
    70: 105, 71: 107, 72: 113, 73: 114, 74: 115, 75: 116, 76: 117,
    77: 119, 78: 121, 79: 124, 80: 123, 81: 125, 82: 126, 83: 71,
    84: 75, 85: 67, 86: 78, 87: 69, 88: 76, 89: 83, 90: 84, 91: 85,
    92: 86, 93: 87, 94: 88, 95: 89, 96: 91, 97: 92, 98: 82, 99: 65,
    100: 10, 101: 110, 103: 81, 104: 105, 105: 107, 106: 113, 107: 106,
    108: 64, 109: 79, 110: 80, 111: 90
]

final class RawInputLedger {
    private let condition = NSCondition()
    private var records: [RawKeyRecord] = []
    private let numerator: UInt64
    private let denominator: UInt64

    init() {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        numerator = UInt64(info.numer)
        denominator = max(1, UInt64(info.denom))
    }
    func nanoseconds(_ absolute: UInt64) -> UInt64 {
        (absolute / denominator) * numerator + ((absolute % denominator) * numerator) / denominator
    }
    func insert(signal: String, timestamp: UInt64, keyCode: UInt16, down: Bool) {
        condition.lock()
        records.append(RawKeyRecord(signal: signal, nanoseconds: timestamp, keyCode: keyCode, down: down))
        if records.count > 512 { records.removeFirst(records.count - 512) }
        condition.broadcast()
        condition.unlock()
    }
    func record(page: UInt32, usage: UInt32, value: Int, absoluteTimestamp: UInt64) {
        guard page == 7, value == 0 || value == 1, let code = hidToMacKey[usage] else { return }
        insert(signal: "\(page):\(usage)", timestamp: nanoseconds(absoluteTimestamp), keyCode: code, down: value == 1)
    }
    func take(timestamp: UInt64, keyCode: UInt16, down: Bool, wait: TimeInterval = 0.005) -> RawKeyRecord? {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(wait)
        while true {
            if let index = records.firstIndex(where: { $0.nanoseconds == timestamp && $0.keyCode == keyCode && $0.down == down }) {
                return records.remove(at: index)
            }
            guard wait > 0, condition.wait(until: deadline) else { return nil }
        }
    }
    func clear() {
        condition.lock(); records.removeAll(); condition.unlock()
    }
}

final class KeyboardEventRouter {
    let ledger: RawInputLedger
    var handle: ((RawKeyRecord, CGEvent) -> Bool)?
    var monitoredCodes = Set<UInt16>()
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var suppressedCodes = Set<UInt16>()
    var running: Bool { tap != nil }
    var allowTestInput = false
    static let testInputTag: Int64 = 0x4348544553

    init(ledger: RawInputLedger) { self.ledger = ledger }
    func start() -> Bool {
        if tap != nil { return true }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                               eventsOfInterest: CGEventMask(mask), callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let router = Unmanaged<KeyboardEventRouter>.fromOpaque(context).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = router.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            return router.consume(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else { return false }
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        guard let runLoopSource else { stop(); return false }
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }
    func consume(type: CGEventType, event: CGEvent, wait: TimeInterval = 0.005) -> Bool {
        let tag = event.getIntegerValueField(.eventSourceUserData)
        // All synthesized input, including our own shortcut output, passes
        // through. The special test tag is enabled only by --system-test.
        guard tag == 0 || (allowTestInput && tag == Self.testInputTag) else { return false }
        guard type == .keyDown || type == .keyUp else { return false }
        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        guard monitoredCodes.contains(code) || suppressedCodes.contains(code) else { return false }
        let down = type == .keyDown
        if down, event.getIntegerValueField(.keyboardEventAutorepeat) != 0, suppressedCodes.contains(code) { return true }
        guard let raw = ledger.take(timestamp: event.timestamp, keyCode: code, down: down, wait: wait) else {
            // An uncorrelated press could be from another keyboard. Clear any
            // repeat ownership before passing it through.
            suppressedCodes.remove(code)
            return false
        }
        if !down {
            let consumed = suppressedCodes.remove(code) != nil
            return consumed
        }
        let consumed = handle?(raw, event) ?? false
        if consumed { suppressedCodes.insert(code) } else { suppressedCodes.remove(code) }
        return consumed
    }
    func reset() { ledger.clear(); suppressedCodes.removeAll() }
    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil; runLoopSource = nil
        reset()
    }
    deinit { stop() }
}

// Host execution core only: no listener is installed and no firmware marker
// is written here. A confirmed device trigger must supply the target PID.
enum HostTextExecutor {
    @MainActor static func execute(_ plan:WindowsProfile.HostTextPlan,targetPID:pid_t,cancelled:()->Bool={false})async throws -> Int {
        guard plan.marker != nil,!plan.scalarUTF16.isEmpty else{return 0}
        guard plan.windowsFlag == nil || plan.windowsFlag == 1 else{throw HardwareError(message:"该文本标志尚未支持执行。")}
        guard targetPID>0, targetPID != getpid(),
              let target=NSRunningApplication(processIdentifier:targetPID),!target.isTerminated else{
            throw HardwareError(message:"文本目标应用无效。")
        }
        guard AXIsProcessTrusted() else{throw HardwareError(message:"文本输入需要此 App 的辅助功能权限。")}
        // Target an explicit process; stop if focus changes. Do not use the
        // clipboard or encode Unicode as physical keycode macros.
        var postedUnits=0
        for units in plan.scalarUTF16 {
            try Task.checkCancellation()
            guard !cancelled(),!target.isTerminated,NSWorkspace.shared.frontmostApplication?.processIdentifier==targetPID else{
                throw HardwareError(message:"文本输入已中止（已发送 \(postedUnits) 个 UTF-16 单元）。")
            }
            guard NSEvent.modifierFlags.intersection([.command,.control,.option,.shift]).isEmpty else{
                throw HardwareError(message:"文本输入已停止，请松开修饰键。")
            }
            guard let down=CGEvent(keyboardEventSource:nil,virtualKey:0,keyDown:true),
                  let up=CGEvent(keyboardEventSource:nil,virtualKey:0,keyDown:false) else{throw HardwareError(message:"无法创建文本输入事件。")}
            units.withUnsafeBufferPointer{buffer in
                down.keyboardSetUnicodeString(stringLength:units.count,unicodeString:buffer.baseAddress!)
                up.keyboardSetUnicodeString(stringLength:units.count,unicodeString:buffer.baseAddress!)
            }
            down.flags=[];up.flags=[]
            down.setIntegerValueField(.eventSourceUserData,value:adapterEventTag)
            up.setIntegerValueField(.eventSourceUserData,value:adapterEventTag)
            // Always send the release once its press has been posted.
            down.postToPid(targetPID);up.postToPid(targetPID)
            postedUnits += units.count
            await Task.yield()
        }
        return postedUnits
    }
}

// Explicitly submitted jobs only. This object does not open USB, request
// permissions, install event taps or choose another application's focus.
@MainActor final class HostTextDispatcher {
    typealias Execution = @MainActor (WindowsProfile.HostTextPlan,pid_t,@escaping ()->Bool) async throws -> Int
    private struct Job {
        let plan:WindowsProfile.HostTextPlan
        let targetPID:pid_t
        let ticket:WindowsProfile.HostTextTicket
        let generation:UUID
    }
    private var pending:[Job]=[]
    private var worker:Task<Void,Never>?
    private var generation=UUID()
    private let execution:Execution
    private let onError:(Error)->Void
    private let onPostedUnits:(Int)->Void
    init(onError:@escaping (Error)->Void,onPostedUnits:@escaping (Int)->Void={_ in},
         execution:@escaping Execution={plan,pid,cancelled in try await HostTextExecutor.execute(plan,targetPID:pid,cancelled:cancelled)}){
        self.execution=execution;self.onError=onError;self.onPostedUnits=onPostedUnits
    }
    @discardableResult func submit(_ plan:WindowsProfile.HostTextPlan,targetPID:pid_t,ticket:WindowsProfile.HostTextTicket)->Bool {
        guard ticket.isCurrent,targetPID>0,targetPID != getpid() else{return false}
        guard pending.count<64 else{stop();onError(HardwareError(message:"文本触发过于密集，已停止待执行文本。"));return false}
        pending.append(Job(plan:plan,targetPID:targetPID,ticket:ticket,generation:generation));startWorker();return true
    }
    func stop(){generation=UUID();pending.removeAll();worker?.cancel()}
    private func startWorker(){
        guard worker==nil,!pending.isEmpty else{return}
        worker=Task{[weak self] in await self?.drain()}
    }
    private func drain()async {
        defer{worker=nil;startWorker()}
        while !Task.isCancelled,!pending.isEmpty {
            let job=pending.removeFirst()
            guard job.ticket.isCurrent,job.generation==generation else{continue}
            do{
                let units=try await execution(job.plan,job.targetPID,{[weak self] in
                    !job.ticket.isCurrent || self?.generation != job.generation
                })
                if job.ticket.isCurrent,job.generation==generation,!Task.isCancelled{onPostedUnits(units)}
            }catch{
                guard job.ticket.isCurrent,job.generation==generation,!Task.isCancelled else{continue}
                stop();onError(error)
            }
        }
    }
    deinit{worker?.cancel()}
}

// Owns USB and its run loop on one dedicated thread. Constructing the worker
// does not open hardware; only an explicit service start launches it.
private final class HostTextUSBWorker {
    private let completion=DispatchGroup()
    private let lock=NSLock()
    private var stopped=false
    private var ticket:WindowsProfile.HostTextTicket?
    private var runLoop:CFRunLoop?
    private let officialJSON:Data
    private let diagnostics:HostTextDiagnostics
    private let onBinding:(WindowsProfile.HostTextBinding,WindowsProfile.HostTextTicket)->Void
    private let onReady:()->Void
    private let onError:(Error)->Void
    init(officialJSON:Data,diagnostics:HostTextDiagnostics,onBinding:@escaping (WindowsProfile.HostTextBinding,WindowsProfile.HostTextTicket)->Void,onReady:@escaping ()->Void,onError:@escaping (Error)->Void){
        self.officialJSON=officialJSON;self.diagnostics=diagnostics;self.onBinding=onBinding;self.onReady=onReady;self.onError=onError
    }
    private var isStopped:Bool{lock.lock();defer{lock.unlock()};return stopped}
    func stop(){
        lock.lock();stopped=true;let active=ticket,loop=runLoop;lock.unlock()
        active?.invalidate();if let loop{CFRunLoopWakeUp(loop)}
    }
    func waitUntilStopped(){completion.wait()}
    func start(after shutdown:@escaping ()->Void={}){
        completion.enter()
        Thread{[self] in defer{completion.leave()};shutdown();autoreleasepool{run()}}.start()
    }
    private func run(){
        guard !isStopped else{return}
        lock.lock();runLoop=CFRunLoopGetCurrent();lock.unlock()
        defer{lock.lock();ticket=nil;runLoop=nil;lock.unlock()}
        do{
            try diagnostics.phase("connecting")
            let usb=try CherryUSB()
            usb.trace=diagnostics.trace
            defer{usb.stopHostTextObservation()}
            guard !isStopped else{return}
            try usb.startHostTextObservation(officialJSON:officialJSON,onBinding:{[weak self] binding,ticket in
                guard let self,!self.isStopped,ticket.isCurrent else{return};self.onBinding(binding,ticket)
            })
            guard let active=usb.currentHostTextTicket else{throw HardwareError(message:"文本监听未能准备完成。")}
            lock.lock();ticket=active;let cancelled=stopped;lock.unlock()
            if cancelled{active.invalidate();return}
            try diagnostics.requireHealthy()
            onReady()
            while !isStopped,active.isCurrent{
                _=RunLoop.current.run(mode:.default,before:Date().addingTimeInterval(0.05))
            }
            if !isStopped{throw HardwareError(message:"键盘连接或文本会话已失效，请重新启用文本服务。")}
        }catch{if !isStopped{onError(error)}}
    }
}

@MainActor final class HostTextService {
    enum Stage:String{case stopped,preparing,observing,failed}
    private(set) var stage:Stage = .stopped
    private var worker:HostTextUSBWorker?
    private var retiringWorker:HostTextUSBWorker?
    private var generation=UUID()
    private let onState:(String)->Void
    private var diagnostics:HostTextDiagnostics?
    private var lastDiagnosticURL:URL?
    var diagnosticURL:URL?{diagnostics?.url ?? lastDiagnosticURL}
    private lazy var dispatcher=HostTextDispatcher(onError:{[weak self] error in self?.fail(error)},onPostedUnits:{[weak self] units in
        guard let self else{return}
        do{try self.diagnostics?.posted(units)}catch{self.fail(error);return}
        self.onState("已发送 \(units) 个 UTF-16 单元；实际输入结果需在目标应用确认。")
    })
    init(onState:@escaping (String)->Void){self.onState=onState}
    func start(officialJSON:Data)throws {
        stop(reason:"replaced")
        // Validate the model before opening USB; permission is checked only
        // when the user explicitly enables this service. No request prompt.
        _=try WindowsProfile.templateRoot(officialJSON)
        guard AXIsProcessTrusted() else{throw HardwareError(message:"启用文本服务需要此 App 的辅助功能权限。")}
        let journal=try HostTextDiagnostics();diagnostics=journal;lastDiagnosticURL=journal.url
        do{try journal.phase("preparing")}catch{stop(reason:"log-error",error:error);throw error}
        let expected=generation
        let source=HostTextUSBWorker(officialJSON:officialJSON,diagnostics:journal,onBinding:{[weak self] binding,ticket in
            Task{@MainActor [weak self] in
                guard let self,self.generation==expected,ticket.isCurrent else{return}
                do{try journal.triggered(binding)}catch{self.fail(error);return}
                guard let pid=NSWorkspace.shared.frontmostApplication?.processIdentifier,pid != getpid() else{return}
                self.dispatcher.submit(binding.plan,targetPID:pid,ticket:ticket)
            }
        },onReady:{[weak self] in Task{@MainActor [weak self] in
            guard let self,self.generation==expected else{return}
            do{try journal.phase("observing")}catch{self.fail(error);return}
            self.stage = .observing
            self.onState("文本服务已开启；切换到目标应用后按文本绑定键。")
        }},onError:{[weak self] error in Task{@MainActor [weak self] in
            guard let self,self.generation==expected else{return};self.fail(error)
        }})
        let previous=retiringWorker;retiringWorker=nil;worker=source
        stage = .preparing
        // Reserve this worker's completion before notifying the UI. A
        // reentrant stop/start must still wait for the previous USB owner.
        source.start(after:{previous?.waitUntilStopped()})
        onState("正在读取键盘并准备文本服务。")
    }
    func stop(reason:String="stopped",error:Error?=nil){stage = .stopped;generation=UUID();if let worker{worker.stop();retiringWorker=worker};worker=nil;dispatcher.stop();diagnostics?.finish(reason:reason,error:error);diagnostics=nil}
    // Wait on the configuration queue, never on the main actor.
    func stopForConfiguration()->()->Void {
        stop(reason:"configuration-operation")
        let previous=retiringWorker
        return {previous?.waitUntilStopped()}
    }
    private func fail(_ error:Error){
        stop(reason:"error",error:error)
        stage = .failed
        onState(error.localizedDescription)
    }
    deinit{worker?.stop();diagnostics?.finish(reason:"service-released")}
}

#if CHERRY_MACRO_PRODUCT
// Opt-in loopback transport. No HID access, permissions or text execution here;
// the product controller supplies the explicitly authorized command handler.
import Network

struct HostTextBridgeRequest {
    let path:String
    let method:String
    let headers:[String:String]
    let body:Data
    static let maxBody=1_000_128
    static func parse(_ bytes:Data)throws->HostTextBridgeRequest? {
        guard bytes.count<=maxBody+16_384 else{throw HardwareError(message:"联动请求过大。")}
        guard let delimiter=bytes.range(of:Data([13,10,13,10])) else{
            guard bytes.count<=16_384 else{throw HardwareError(message:"联动请求头过大。")};return nil
        }
        guard delimiter.lowerBound<=16_384,let header=String(data:bytes[..<delimiter.lowerBound],encoding:.utf8) else{throw HardwareError(message:"联动请求头无效。")}
        let lines=header.components(separatedBy:"\r\n"),first=lines[0].components(separatedBy:" ")
        guard first.count==3,first[2]=="HTTP/1.1",["POST","OPTIONS"].contains(first[0]),["/v1/pair","/v1/status","/v1/activate","/v1/suspend","/v1/unpair"].contains(first[1]) else{throw HardwareError(message:"联动请求不支持。")}
        var fields:[String:String]=[:]
        for line in lines.dropFirst(){
            guard let colon=line.firstIndex(of:":") else{throw HardwareError(message:"联动请求头无效。")}
            let key=String(line[..<colon]).lowercased(),value=String(line[line.index(after:colon)...]).trimmingCharacters(in:.whitespaces)
            guard !key.isEmpty,key.utf8.allSatisfy({($0>=97 && $0<=122)||($0>=48 && $0<=57)||$0==45}),fields[key]==nil,!value.contains("\r"),!value.contains("\n") else{throw HardwareError(message:"联动请求头重复或无效。")}
            fields[key]=value
        }
        guard fields["host"]=="127.0.0.1:32247",fields["transfer-encoding"]==nil,let origin=fields["origin"],validOrigin(origin) else{throw HardwareError(message:"联动来源或地址无效。")}
        let count:Int
        if let length=fields["content-length"]{guard !length.isEmpty,length.utf8.allSatisfy({$0>=48 && $0<=57}),let size=Int(length),size<=maxBody else{throw HardwareError(message:"联动请求长度无效。")};count=size}
        else{guard first[0]=="OPTIONS" else{throw HardwareError(message:"联动请求缺少长度。")};count=0}
        if first[0]=="OPTIONS"{guard count==0,fields["access-control-request-method"]=="POST" else{throw HardwareError(message:"联动预检无效。")}}
        else{guard fields["content-type"]?.lowercased().components(separatedBy:";")[0]=="application/json" else{throw HardwareError(message:"联动请求需要 JSON。")}}
        let expected=delimiter.upperBound+count
        guard bytes.count<=expected else{throw HardwareError(message:"联动请求包含额外数据。")}
        guard bytes.count==expected else{return nil}
        return HostTextBridgeRequest(path:first[1],method:first[0],headers:fields,body:Data(bytes[delimiter.upperBound...]))
    }
    static func validOrigin(_ origin:String)->Bool {
        guard origin.utf8.allSatisfy({$0>=33 && $0<=126}),let url=URLComponents(string:origin),url.url != nil,url.user==nil,url.password==nil,url.query==nil,url.fragment==nil,url.path.isEmpty,let host=url.host,!host.isEmpty else{return false}
        return url.scheme=="https" || (url.scheme=="http" && ["localhost","127.0.0.1","[::1]"].contains(host))
    }
    static func response(status:Int=200,origin:String?=nil,object:[String:Any]=[:])->Data {
        let payload=status==204 ? Data() : (try? JSONSerialization.data(withJSONObject:object,options:[.sortedKeys])) ?? Data("{}".utf8)
        var headers="HTTP/1.1 \(status) \(status==200 ? "OK" : status==204 ? "No Content" : "Error")\r\nContent-Type: application/json\r\nContent-Length: \(payload.count)\r\nCache-Control: no-store\r\nConnection: close\r\n"
        if let origin,validOrigin(origin){headers+="Access-Control-Allow-Origin: \(origin)\r\nVary: Origin\r\nAccess-Control-Allow-Methods: POST, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type, X-CherryMac-Token, X-CherryMac-Client\r\nAccess-Control-Allow-Private-Network: true\r\n"}
        return Data((headers+"\r\n").utf8)+payload
    }
}

// Main-thread session policy, independent of the listener and the HID service.
// A tab identity and exact origin join the random code; status refreshes a lease.
@MainActor final class HostTextBridgeSession {
    let token=UUID().uuidString.replacingOccurrences(of:"-",with:"")+UUID().uuidString.replacingOccurrences(of:"-",with:"")
    private(set) var origin:String?
    private(set) var client:String?
    private var lastSeen:TimeInterval=0
    func authorize(_ request:HostTextBridgeRequest,now:TimeInterval=ProcessInfo.processInfo.systemUptime)throws {
        guard request.headers["x-cherrymac-token"]==token,let source=request.headers["origin"],HostTextBridgeRequest.validOrigin(source),let tab=request.headers["x-cherrymac-client"],UUID(uuidString:tab) != nil else{throw HardwareError(message:"联动码或网页身份无效。")}
        if request.path=="/v1/pair",origin==nil{origin=source;client=tab}
        guard origin==source,client==tab else{throw HardwareError(message:"联动已由其他网页占用，请先解除。")}
        lastSeen=now
    }
    func expired(now:TimeInterval=ProcessInfo.processInfo.systemUptime)->Bool{origin != nil && now-lastSeen>120}
    func reset(){origin=nil;client=nil;lastSeen=0}
}

final class HostTextBridgeHTTP {
    typealias Completion=(Data)->Void
    typealias Handler=(HostTextBridgeRequest,@escaping Completion)->Void
    private let queue=DispatchQueue(label:"CherryMac.host-text-loopback")
    private let listener:NWListener
    private let handler:Handler
    private var connections:[UUID:NWConnection]=[:]
    private var stopped=false
    init(handler:@escaping Handler,onState:@escaping(Bool,String)->Void)throws {
        self.handler=handler
        let parameters=NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host:"127.0.0.1",port:32247)
        parameters.allowLocalEndpointReuse=false
        listener=try NWListener(using:parameters)
        listener.stateUpdateHandler={state in
            switch state{case .ready:onState(true,"网页联动已开启，可复制联动码。");case .failed:onState(false,"网页联动启动失败，请检查是否已有 CherryMac 占用联动端口。");default:break}
        }
        listener.newConnectionHandler={[weak self] connection in self?.accept(connection)}
    }
    func start(){listener.start(queue:queue)}
    func stop(){listener.cancel();queue.async{[weak self] in guard let self else{return};self.stopped=true;self.connections.values.forEach{$0.cancel()};self.connections.removeAll()}}
    private func accept(_ connection:NWConnection){
        guard !stopped,connections.count<16 else{connection.cancel();return}
        let id=UUID();connections[id]=connection;connection.start(queue:queue)
        queue.asyncAfter(deadline:.now()+30){[weak self] in self?.connections.removeValue(forKey:id)?.cancel()}
        receive(connection,id:id,buffer:Data())
    }
    private func receive(_ connection:NWConnection,id:UUID,buffer:Data){
        connection.receive(minimumIncompleteLength:1,maximumLength:65_536){[weak self] data,_,complete,error in
            guard let self,self.connections[id] != nil else{return}
            guard error==nil else{self.connections.removeValue(forKey:id)?.cancel();return}
            var bytes=buffer;if let data{bytes.append(data)}
            do{
                if let request=try HostTextBridgeRequest.parse(bytes){
                    if request.method=="OPTIONS"{self.send(HostTextBridgeRequest.response(status:204,origin:request.headers["origin"]),connection,id:id)}
                    else{self.handler(request){[weak self] response in self?.queue.async{[weak self] in guard let self,self.connections[id] != nil else{return};self.send(response,connection,id:id)}}}
                }else if complete{self.send(HostTextBridgeRequest.response(status:400,object:["error":"联动请求不完整。"]),connection,id:id)}
                else{self.receive(connection,id:id,buffer:bytes)}
            }catch{self.send(HostTextBridgeRequest.response(status:400,object:["error":error.localizedDescription]),connection,id:id)}
        }
    }
    private func send(_ data:Data,_ connection:NWConnection,id:UUID){
        connection.send(content:data,completion:.contentProcessed{[weak self] _ in self?.queue.async{[weak self] in self?.connections.removeValue(forKey:id)?.cancel()}})
    }
    deinit{listener.cancel()}
}
#endif
