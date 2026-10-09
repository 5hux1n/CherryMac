import Foundation

// Correlates existing evidence stores only; never discovers devices, sends
// reports, resumes a transaction or treats saved booleans as hardware proof.
struct ReceiverPairingDiagnostic:Encodable {
    struct Exchange:Encodable {
        let intent:Int
        let phase:ReceiverPairingTransaction.Phase
        let rawStage:String
        let controllerConfirmed:Bool
        let rawAccepted:Bool
        let pairedSignal:Bool?
        private enum CodingKeys:String,CodingKey{case intent,phase,rawStage,controllerConfirmed,rawAccepted,pairedSignal}
        func encode(to encoder:Encoder)throws{
            var c=encoder.container(keyedBy:CodingKeys.self)
            try c.encode(intent,forKey:.intent);try c.encode(phase,forKey:.phase)
            try c.encode(rawStage,forKey:.rawStage);try c.encode(controllerConfirmed,forKey:.controllerConfirmed)
            try c.encode(rawAccepted,forKey:.rawAccepted);try c.encode(pairedSignal,forKey:.pairedSignal)
        }
    }
    struct DiagnosticError:LocalizedError {
        let message:String
        var errorDescription:String?{message}
    }
    let format="CherryMacPairingDiagnostic"
    let version=1
    let id:String
    let historicalOnly=true
    let checkpointRevision:Int
    let phase:ReceiverPairingTransaction.Phase
    let pending:Bool
    let pendingOperationID:Int?
    let mayHaveChanged:Bool
    let selection:ReceiverPairingSelection
    let backupReference:String?
    let restoreAttempted:Bool
    let recoveryRequired:Bool
    let stableAcrossReads:Bool
    let rawRecordCount:Int
    let rawLoadError:String?
    let exchanges:[Exchange]
    let uncertainIntents:[Int]
    let issues:[String]
    let controlAcknowledgementsCorroborated:Bool
    let configurationDataIncluded=false
    let powerCycleVerified=false
    private enum CodingKeys:String,CodingKey{
        case format,version,id,historicalOnly,checkpointRevision,phase,pending,pendingOperationID,mayHaveChanged,selection,backupReference
        case restoreAttempted,recoveryRequired,stableAcrossReads,rawRecordCount,rawLoadError
        case exchanges,uncertainIntents,issues,controlAcknowledgementsCorroborated,configurationDataIncluded,powerCycleVerified
    }
    func encode(to encoder:Encoder)throws{
        var c=encoder.container(keyedBy:CodingKeys.self)
        try c.encode(format,forKey:.format);try c.encode(version,forKey:.version);try c.encode(id,forKey:.id)
        try c.encode(historicalOnly,forKey:.historicalOnly);try c.encode(checkpointRevision,forKey:.checkpointRevision)
        try c.encode(phase,forKey:.phase);try c.encode(pending,forKey:.pending)
        try c.encode(pendingOperationID,forKey:.pendingOperationID);try c.encode(mayHaveChanged,forKey:.mayHaveChanged)
        try c.encode(selection,forKey:.selection)
        try c.encode(backupReference,forKey:.backupReference);try c.encode(restoreAttempted,forKey:.restoreAttempted)
        try c.encode(recoveryRequired,forKey:.recoveryRequired);try c.encode(stableAcrossReads,forKey:.stableAcrossReads)
        try c.encode(rawRecordCount,forKey:.rawRecordCount);try c.encode(rawLoadError,forKey:.rawLoadError)
        try c.encode(exchanges,forKey:.exchanges);try c.encode(uncertainIntents,forKey:.uncertainIntents)
        try c.encode(issues,forKey:.issues);try c.encode(controlAcknowledgementsCorroborated,forKey:.controlAcknowledgementsCorroborated)
        try c.encode(configurationDataIncluded,forKey:.configurationDataIncluded);try c.encode(powerCycleVerified,forKey:.powerCycleVerified)
    }
    static func inspect(operationID id:String,journal:ReceiverPairingJournal,rawLog:ReceiverPairingRawLog)throws->Self{
        guard UUID(uuidString:id)?.uuidString.lowercased()==id else{throw DiagnosticError(message:"配对诊断编号无效。")}
        let checkpoints=try journal.load(operationID:id)
        guard let latest=checkpoints.last else{throw DiagnosticError(message:"没有可检查的配对检查点。")}
        func readRaw()->(records:[ReceiverPairingRawLog.Record],error:String?){
            do{return (try rawLog.load(operationID:id),nil)}catch{return ([],error.localizedDescription)}
        }
        let raw=readRaw(),secondCheckpoints=try journal.load(operationID:id),secondRaw=readRaw()
        let stable=checkpoints==secondCheckpoints && raw.records==secondRaw.records && raw.error==secondRaw.error
        let state=latest.state
        let phases:[ReceiverPairingTransaction.Phase]=[.keyboardStart,.receiverPrepare,.receiverStart,.polling]
        let begins=state.events.filter{$0.action=="begin" && phases.contains($0.phase)}
        var groups:[Int:[ReceiverPairingRawLog.Entry]]=[:],issues:[String]=[],uncertain:[Int]=[],exchanges:[Exchange]=[]
        if !stable{issues.append("读取期间日志变化；本次结果不能作为稳定证据。")}
        if let error=raw.error{issues.append("原始报告日志未能校验："+error)}
        for record in raw.records{
            let entry=record.entry
            guard entry.selection==state.selection,let begin=begins.first(where:{$0.sequence==entry.intent}),begin.phase==entry.phase else{
                issues.append("原始报告\(record.sequence)没有对应的已读取端点与阶段意图。")
                continue
            }
            groups[entry.intent,default:[]].append(entry)
        }
        for begin in begins{
            let rows=groups[begin.sequence] ?? [],last=rows.last,accepted=rows.first{$0.stage=="accepted"}
            let next=state.events.first{$0.sequence>begin.sequence}
            let confirmed=next?.phase==begin.phase && next?.action==(begin.phase == .polling ? "status":"accepted")
            var paired:Bool?
            if begin.phase == .polling,let bytes=accepted?.reply,bytes.count==64{paired=bytes[8]==0xff}
            if confirmed && last?.stage != "accepted"{
                issues.append("意图\(begin.sequence)已有流程确认，但缺少对应的最终接受报告。")
            }
            if confirmed,begin.phase == .polling,let next{
                let expected=next.detail=="设备报告配对完成，继续核对原配置。"
                if paired != expected{issues.append("意图\(begin.sequence)的流程状态与原始查询回复不一致。")}
            }
            if !confirmed || last?.stage != "accepted"{uncertain.append(begin.sequence)}
            exchanges.append(.init(intent:begin.sequence,phase:begin.phase,rawStage:last?.stage ?? "not-recorded",
                controllerConfirmed:confirmed,rawAccepted:accepted != nil,pairedSignal:paired))
        }
        return .init(id:id,checkpointRevision:latest.revision,phase:state.phase,pending:state.pending,pendingOperationID:state.operationID,mayHaveChanged:state.mayHaveChanged,selection:state.selection,
            backupReference:state.backupReference,restoreAttempted:state.restoreAttempted,recoveryRequired:state.recoveryRequired,
            stableAcrossReads:stable,rawRecordCount:raw.records.count,rawLoadError:raw.error,exchanges:exchanges,
            uncertainIntents:uncertain,issues:issues,
            controlAcknowledgementsCorroborated:stable && !begins.isEmpty && issues.isEmpty && uncertain.isEmpty)
    }
}
