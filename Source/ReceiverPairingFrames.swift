import Foundation

// Fixed Utility report builders. Pure data only: no device opening, output
// report sender or backup/write authorization. A transport must pin the real
// endpoints, serialize replies and supply its established selector word.
enum ReceiverPairingFrames {
    enum Endpoint:String {case keyboard,receiver}
    struct Plan:Equatable {
        let phase:ReceiverPairingTransaction.Phase
        let endpoint:Endpoint
        let selector:UInt16?
        let request:[UInt8]
    }
    struct Reply {
        let bytes:[UInt8]
        let status:UInt8
        let replyCommand:UInt8
        let paired:Bool?
    }
    struct FrameError:LocalizedError {
        let message:String
        var errorDescription:String?{message}
    }
    static func plan(phase:ReceiverPairingTransaction.Phase,selector:UInt16?=nil)throws->Plan{
        let command:UInt8,endpoint:Endpoint
        switch phase {
        case .keyboardStart,.receiverStart:
            guard let selector else{throw FrameError(message:"配对启动缺少已核对的通信选择字段。")}
            command=selector==1 ? 0xa1:0x21;endpoint=phase == .keyboardStart ? .keyboard:.receiver
        case .receiverPrepare:
            guard let selector else{throw FrameError(message:"接收器准备缺少已核对的通信选择字段。")}
            command=selector==1 ? 0xa0:0x20;endpoint = .receiver
        case .polling:
            guard selector==nil else{throw FrameError(message:"配对查询不使用启动命令选择字段。")}
            command=0xaa;endpoint = .receiver
        default:throw FrameError(message:"这个配对阶段没有已确认的报告。")
        }
        var request=[UInt8](repeating:0,count:64);request[0]=4;request[3]=command
        let checksum=request[3...63].reduce(0){$0+Int($1)}
        request[1]=UInt8(checksum&255);request[2]=UInt8(checksum>>8)
        return .init(phase:phase,endpoint:endpoint,selector:selector,request:request)
    }
    static func reply(_ bytes:[UInt8],for candidate:Plan,transportSucceeded:Bool)throws->Reply{
        let canonical=try plan(phase:candidate.phase,selector:candidate.selector)
        guard candidate==canonical else{throw FrameError(message:"配对请求与固定报告不一致。")}
        guard transportSucceeded,bytes.count==64,bytes[0]==4 else{
            throw FrameError(message:"配对交换未完成或回复报告长度无效。")
        }
        guard ![0xff,0xfe].contains(bytes[7]) else{
            let code=bytes[7]==0xff ? -102:-103
            throw FrameError(message:"设备拒绝配对报告（\(code)）。")
        }
        // The audited methods check status and query byte8; they do not prove
        // command/checksum echo fields. Keep those opaque for later transport
        // correlation evidence instead of inventing acceptance conditions.
        return .init(bytes:bytes,status:bytes[7],replyCommand:bytes[3],
                     paired:candidate.phase == .polling ? bytes[8]==0xff:nil)
    }
}
