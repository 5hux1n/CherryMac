import Foundation

// A test build may send only the canonical baseline/target keymap blocks.
// This research authorization is separate from the scoped product key writer.
struct CalculatorKeyTestAuthorization {
    static let slot=102
    static let target:[UInt8]=[0x20,0x0D,0x06] // left Control + Option + Command + C
    let before:HardwareSnapshot
    let expected:HardwareSnapshot
    init(baseline:HardwareSnapshot) throws {
        try baseline.validate()
        guard baseline.deviceInfo[6]==24,baseline.colors != nil,baseline.macroData != nil,
              Array(baseline.keymap[306..<309])==[0x30,0x92,0x01] else{
            throw HardwareError(message:"计算器测试需要完整备份和原始计算器媒体键，未授权任何写入。")
        }
        before=baseline
        var next=baseline;next.keymap.replaceSubrange(306..<309,with:Self.target);expected=next
    }
    func validate(_ request:[UInt8]) throws {
        guard request.count==64,request[0]==4,request[3]==9 else{throw HardwareError(message:"此测试只允许计算器键所在键位表的受限写入。")}
        let offset=Int(request[5]) | Int(request[6])<<8
        guard offset%54==0,offset<=324,request[4]==54 else{throw HardwareError(message:"计算器测试分块范围无效。")}
        for snapshot in [before,expected] {
            let canonical=try CherryPacket.chunk(9,offset:offset,length:54,data:Array(snapshot.keymap[offset..<offset+54]))
            if request==canonical{return}
        }
        throw HardwareError(message:"数据与已备份的原表或仅修改计算器键的目标表不符，停止写入。")
    }
}

enum CalculatorKeyRetention:String {
    case retained, reverted, unexpected
    static func compare(_ current:HardwareSnapshot,authorization:CalculatorKeyTestAuthorization)->Self {
        let original=authorization.before,expected=authorization.expected
        guard current.deviceInfo==original.deviceInfo,current.parameters==original.parameters,
              current.colors==original.colors,current.macroData==original.macroData else{return .unexpected}
        if current.keymap==expected.keymap{return .retained}
        if current.keymap==original.keymap{return .reverted}
        return .unexpected
    }
}

// USB removal is observable; battery power-off requires the user's explicit confirmation.
struct CalculatorPowerCycleEvidence {
    let originalRegistryID:UInt64
    private(set) var disconnectedAt:Double?
    private(set) var powerOffConfirmedAt:Double?
    private(set) var reconnectedAt:Double?
    private(set) var reconnectedRegistryID:UInt64?
    mutating func disconnected(at:Double){if disconnectedAt==nil{disconnectedAt=at}}
    mutating func confirmPowerOff(at:Double)->Bool {
        guard let removed=disconnectedAt,at>=removed,reconnectedAt==nil else{return false}
        if powerOffConfirmedAt==nil{powerOffConfirmedAt=at}
        return true
    }
    mutating func reconnected(at:Double,registryID:UInt64)->Bool {
        guard let removed=disconnectedAt,at>removed,registryID != originalRegistryID,reconnectedAt==nil else{return false}
        reconnectedAt=at;reconnectedRegistryID=registryID;return true
    }
    var confirmedOffInterval:Double? {
        guard let off=powerOffConfirmedAt,let on=reconnectedAt else{return nil}
        return on-off
    }
    var hasConfirmedPowerCycle:Bool{(confirmedOffInterval ?? -1)>=15}
}
