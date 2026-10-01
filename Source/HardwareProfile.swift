import Foundation

struct KeyboardMacro: Codable, Equatable {
    struct Step: Codable, Equatable {
        var usage: UInt8
        var pressed: Bool
        var delayMilliseconds: Int
    }
    var name: String
    var steps: [Step]
    func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 80,
              !steps.isEmpty, steps.count <= 256 else { throw HardwareError(message: "宏名称或步骤数量无效。") }
        var held = Set<UInt8>()
        for step in steps {
            guard (4...231).contains(step.usage), (0...60000).contains(step.delayMilliseconds) else { throw HardwareError(message: "宏按键或延迟超出范围。") }
            if step.pressed {
                guard held.insert(step.usage).inserted else { throw HardwareError(message: "宏中同一个键重复按下，缺少释放步骤。") }
            } else {
                guard held.remove(step.usage) != nil else { throw HardwareError(message: "宏中存在未按下的释放步骤。") }
            }
        }
        guard held.isEmpty else { throw HardwareError(message: "宏结束时必须释放全部按键。") }
    }
}

struct HardwareProfile: Codable, Equatable {
    var format = "CherryMacProfile"
    var version = 1
    var snapshot: HardwareSnapshot
    var macros: [KeyboardMacro] = []
    func validate() throws {
        guard format == "CherryMacProfile", version == 1, macros.count <= 32 else { throw HardwareError(message: "配置文件格式或版本不受支持。") }
        try snapshot.validate()
        for macro in macros { try macro.validate() }
        guard Set(macros.map { $0.name }).count == macros.count else { throw HardwareError(message: "宏名称不能重复。") }
    }
    static func decode(_ data: Data) throws -> HardwareProfile {
        guard data.count <= 1_000_000 else { throw HardwareError(message: "配置文件过大。") }
        let decoder = JSONDecoder()
        let profile: HardwareProfile
        if let snapshot = try? decoder.decode(HardwareSnapshot.self, from: data) { profile = HardwareProfile(snapshot: snapshot) }
        else { profile = try decoder.decode(HardwareProfile.self, from: data) }
        try profile.validate(); return profile
    }
    func encoded() throws -> Data {
        try validate(); let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        return try encoder.encode(self)
    }
}

// Matrix positions in this keyboard's 126-slot firmware table. These remain
// stable when assignments change; a configured HID usage is not a key identity.
enum CherryMatrix {
    static let special: [String:Int] = ["esc":0,"cherry":6,"caps":3,"shiftL":4,"shiftR":82,"modL0":5,"modL1":11,"modL2":17,"modR0":65,"modR1":71,"modR2":83,"modR3":77,"calculator":102,"mediaPrevious":108,"mediaPlay":114,"mediaNext":120]
    static let usageSlots: [Int:Int] = [4:9,5:40,6:28,7:21,8:20,9:27,10:33,11:39,12:50,13:45,14:51,15:57,16:52,17:46,18:56,19:62,20:8,21:26,22:15,23:32,24:44,25:34,26:14,27:22,28:38,29:16,30:7,31:13,32:19,33:25,34:31,35:37,36:43,37:49,38:55,39:61,40:81,41:0,42:79,43:2,44:41,45:67,46:73,47:68,48:74,49:80,50:75,51:63,52:69,53:1,54:58,55:64,56:70,57:3,58:12,59:18,60:24,61:30,62:36,63:42,64:48,65:54,66:60,67:66,68:72,69:78,70:84,71:90,72:96,73:85,74:91,75:97,76:86,77:92,78:98,79:101,80:89,81:95,82:94,83:103,84:109,85:115,86:121,87:122,88:124,89:106,90:112,91:118,92:105,93:111,94:117,95:104,96:110,97:116,98:113,99:119,100:10,101:77]
    static func slot(_ key: KeySpec) -> Int? {
        if let slot = special[key.id] { return slot }
        guard let signal=key.usage?.split(separator: ":"), signal.count==2, signal[0]=="7", let usage=Int(signal[1]) else { return nil }
        return usageSlots[usage]
    }
    static func describe(_ bytes: [UInt8]) -> String {
        guard bytes.count == 3 else { return "无记录" }
        if bytes[0] == 0x20 {
            var mods = ""
            if bytes[1] & 0x11 != 0 { mods += "⌃" }
            if bytes[1] & 0x22 != 0 { mods += "⇧" }
            if bytes[1] & 0x44 != 0 { mods += "⌥" }
            if bytes[1] & 0x88 != 0 { mods += "⌘" }
            let names = [4:"A",5:"B",6:"C",7:"D",8:"E",9:"F",10:"G",11:"H",12:"I",13:"J",14:"K",15:"L",16:"M",17:"N",18:"O",19:"P",20:"Q",21:"R",22:"S",23:"T",24:"U",25:"V",26:"W",27:"X",28:"Y",29:"Z",30:"1",31:"2",32:"3",33:"4",34:"5",35:"6",36:"7",37:"8",38:"9",39:"0",40:"Enter",41:"Esc",44:"Space",57:"Caps"]
            if bytes[2] == 0 { return mods.isEmpty ? "禁用" : mods }
            return mods + (names[Int(bytes[2])] ?? "HID \(bytes[2])")
        }
        if bytes[0] == 0x30 {
            let code=Int(bytes[1]) | Int(bytes[2])<<8
            return [402:"计算器",182:"上一曲",205:"播放 / 暂停",181:"下一曲",233:"音量增加",234:"音量降低",226:"静音"][code] ?? "媒体键 \(code)"
        }
        if bytes[0] == 0xA0 { return "键盘内部功能 \(bytes[1])" }
        return bytes.map{String(format:"%02X",$0)}.joined(separator:" ")
    }
}
