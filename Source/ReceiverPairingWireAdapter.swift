import Foundation

// Connects the executor to a supplied real, finite-deadline raw transport.
// No default transport or complete-backup implementation: constructing this
// adapter never opens a device, sends a report or bypasses backup coverage.
@MainActor final class ReceiverPairingWireAdapter:ReceiverPairingExecutorIO {
    struct ExchangeRecord:Encodable {
        let format:String="CherryMacPairingRawExchange"
        let version:Int=2
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
        private enum CodingKeys:String,CodingKey {
            case format,version,id,intent,phase,endpoint,selection,selector,request,reply,receivedLength,stage,error
        }
        func encode(to encoder:Encoder)throws{
            var c=encoder.container(keyedBy:CodingKeys.self)
            try c.encode(format,forKey:.format);try c.encode(version,forKey:.version)
            try c.encode(id,forKey:.id);try c.encode(intent,forKey:.intent)
            try c.encode(phase,forKey:.phase);try c.encode(endpoint,forKey:.endpoint)
            try c.encode(selection,forKey:.selection);try c.encode(selector,forKey:.selector)
            try c.encode(request,forKey:.request);try c.encode(reply,forKey:.reply)
            try c.encode(receivedLength,forKey:.receivedLength);try c.encode(stage,forKey:.stage)
            try c.encode(error,forKey:.error)
        }
    }
    struct WireError:LocalizedError {
        let message:String
        var errorDescription:String?{message}
    }
    private let selection:ReceiverPairingSelection
    private let id:String
    private let journal:ReceiverPairingJournal
    private let live:()throws->ReceiverPairingSelection
    private let selector:(ReceiverPairingFrames.Endpoint)throws->UInt16
    private let exchange:(ReceiverPairingFrames.Plan,String,Int)async throws->[UInt8]
    private let backup:()async throws->String
    private let matches:(String)async throws->Bool
    private let rawLog:ReceiverPairingRawLog
    private let shutdown:()throws->Void
    private var checkpoint:ReceiverPairingJournal.State?
    private var consumed=Set<Int>()
    private var backupAttempted=false
    private var failed=false
    private var closed=false
    private var closeError:Error?
    init(selection:ReceiverPairingSelection,id:String,journal:ReceiverPairingJournal,
         live:@escaping()throws->ReceiverPairingSelection,
         selector:@escaping(ReceiverPairingFrames.Endpoint)throws->UInt16,
         exchange:@escaping(ReceiverPairingFrames.Plan,String,Int)async throws->[UInt8],
         backup:@escaping()async throws->String,matches:@escaping(String)async throws->Bool,
         shutdown:@escaping()throws->Void)throws{
        try selection.validate()
        guard UUID(uuidString:id)?.uuidString.lowercased()==id else{throw WireError(message:"配对操作编号无效。")}
        self.selection=selection;self.id=id;self.journal=journal;self.live=live;self.selector=selector
        self.exchange=exchange;self.backup=backup;self.matches=matches
        self.rawLog=ReceiverPairingRawLog(directory:journal.directory.appendingPathComponent("raw-reports",isDirectory:true))
        self.shutdown=shutdown
    }
    func currentSelection()throws->ReceiverPairingSelection{
        guard !closed else{throw WireError(message:"配对传输已经关闭。")}
        let current=try live();guard current==selection else{throw WireError(message:"配对端点已变化。")};return current
    }
    func saveCompleteBackup()async throws->String{
        guard !failed,!backupAttempted,checkpoint?.phase == .backup,checkpoint?.pending==false else{
            throw WireError(message:"完整备份只能在本次配对的备份阶段执行一次。")
        }
        backupAttempted=true;_ = try currentSelection();try Task.checkCancellation()
        let reference:String
        do{reference=try await backup()}catch{failed=true;throw error}
        // The executor retains this reference before its fresh selection check.
        // The callback must durably save/verify actual complete configuration.
        return reference
    }
    func persist(_ transaction:ReceiverPairingTransaction)async throws{
        guard transaction.selection==selection else{throw WireError(message:"配对检查点属于其他端点。")}
        if !transaction.terminal{_ = try currentSelection()}
        let saved=try journal.save(operationID:id,transaction:transaction)
        checkpoint=saved.state
    }
    private func perform(_ phase:ReceiverPairingTransaction.Phase)async throws->ReceiverPairingFrames.Reply{
        guard !closed,!failed,let checkpoint,checkpoint.pending,checkpoint.phase==phase,
              let intent=checkpoint.operationID,checkpoint.backupReference != nil,
              checkpoint.selection==selection,!consumed.contains(intent) else{
            throw WireError(message:"配对报告缺少本次已保存的阶段意图，或该意图已使用。")
        }
        consumed.insert(intent)
        var plan:ReceiverPairingFrames.Plan?,reply:[UInt8]?,logStopped=false,receivedLength=0
        func record(_ stage:String,error:String?=nil)async throws{
            guard let plan else{return}
            do{try rawLog.save(.init(id:id,intent:intent,phase:phase,endpoint:plan.endpoint.rawValue,
                selection:selection,selector:plan.selector,request:plan.request,reply:reply,receivedLength:receivedLength,stage:stage,error:error))}
            catch{logStopped=true;throw error}
        }
        func checkIntent()throws{
            guard !closed,!failed,self.checkpoint==checkpoint else{throw WireError(message:"配对已保存意图在等待期间发生变化。")}
            _=try currentSelection();try Task.checkCancellation()
        }
        do{
            try checkIntent()
            let endpoint:ReceiverPairingFrames.Endpoint=phase == .keyboardStart ? .keyboard:.receiver
            plan=try ReceiverPairingFrames.plan(phase:phase,selector:phase == .polling ? nil:selector(endpoint))
            try await record("prepared");try checkIntent()
            guard let plan else{throw WireError(message:"配对报告没有生成。")}
            let received=try await exchange(plan,id,intent)
            receivedLength=received.count;reply=Array(received.prefix(64))
            try await record("received");try checkIntent()
            guard receivedLength==64 else{throw WireError(message:"配对传输回复长度不是64字节。") }
            let result=try ReceiverPairingFrames.reply(reply!,for:plan,transportSucceeded:true)
            try await record("accepted");try checkIntent();return result
        }catch{
            failed=true
            if !logStopped{
                do{try await record("failed",error:error.localizedDescription)}
                catch let logging{throw WireError(message:error.localizedDescription+"；原始报告日志保存失败："+logging.localizedDescription)}
            }
            throw error
        }
    }
    func performCommand(_ phase:ReceiverPairingTransaction.Phase)async throws{
        guard [.keyboardStart,.receiverPrepare,.receiverStart].contains(phase) else{throw WireError(message:"不支持的配对命令阶段。")}
        _=try await perform(phase)
    }
    func queryPaired()async throws->Bool{
        let reply=try await perform(.polling);guard let paired=reply.paired else{throw WireError(message:"配对查询没有有效判据。")};return paired
    }
    func configurationMatchesBackup(_ reference:String)async throws->Bool{
        guard !closed,!failed,let checkpoint,checkpoint.phase == .configurationCheck,checkpoint.pending,
              checkpoint.backupReference==reference,let intent=checkpoint.operationID,!consumed.contains(intent) else{
            throw WireError(message:"配对配置核对缺少本次已保存意图。")
        }
        consumed.insert(intent);_ = try currentSelection();try Task.checkCancellation()
        let result=try await matches(reference)
        guard !closed,!failed,self.checkpoint==checkpoint else{throw WireError(message:"配对配置核对意图已经变化。")}
        _ = try currentSelection();try Task.checkCancellation();return result
    }
    func close()throws{
        if closed{if let closeError{throw closeError};return}
        closed=true;do{try shutdown()}catch{closeError=error;throw error}
    }
}
