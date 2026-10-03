import Foundation

struct KeyboardMacro: Codable, Equatable {
    struct RecordingDelay:Codable,Equatable {
        var fixed:Bool
        var milliseconds:Int
    }
    struct Step: Codable, Equatable {
        var usage: UInt8
        var pressed: Bool
        var delayMilliseconds: Int
        enum Kind:String,Codable {case mouse}
        var kind:Kind? = nil
    }
    var name: String
    var steps: [Step]
    // Recorder preference from Windows JSON, not a firmware delay override.
    var recordingDelay:RecordingDelay? = nil
    var preferredPlayback:MacroPlayback? = nil
    // Index into the retained official source document, independent of edit name.
    var windowsActionIndex:Int? = nil
    // Opaque bytes carried by each firmware record; never interpret as events.
    var hardwareReserved:[UInt8]? = nil
    static func nameStem(_ name:String)->String{name.precomposedStringWithCanonicalMapping.unicodeScalars.prefix(65).map{String($0)}.joined()}
    func validate() throws {
        if let hardwareReserved{guard hardwareReserved.count==2 else{throw HardwareError(message:"宏保留数据长度无效。")}}
        try preferredPlayback?.validate()
        if let recordingDelay{guard (0...60000).contains(recordingDelay.milliseconds) else{throw HardwareError(message:"固定间隔选项须为 0…60000 毫秒。")}}
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.precomposedStringWithCanonicalMapping.unicodeScalars.count <= 80,
              !steps.isEmpty, steps.count <= 256 else { throw HardwareError(message: "宏名称或步骤数量无效。") }
        var held = Set<Int>()
        for step in steps {
            guard (step.kind == .mouse ? [UInt8(1),2,4,8,16].contains(step.usage):(4...231).contains(step.usage)), (0...60000).contains(step.delayMilliseconds) else { throw HardwareError(message: "宏按键或延迟超出范围。") }
            let identity=Int(step.usage)+(step.kind == .mouse ? 256:0)
            if step.pressed {
                guard held.insert(identity).inserted else { throw HardwareError(message: "宏中同一个键重复按下，缺少释放步骤。") }
            } else {
                guard held.remove(identity) != nil else { throw HardwareError(message: "宏中存在未按下的释放步骤。") }
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
    // nil means that the raw device bank has not been decoded for editing.
    // Optional keeps older exported profiles readable.
    var macroBindings: [Int:String]? = nil
    var macroModes:[Int:MacroPlayback]? = nil
    // Original official document, retained locally for lossless unknown fields.
    var windowsTemplateJSON:String? = nil
    func validate() throws {
        guard format == "CherryMacProfile", version == 1, macros.count <= 32 else { throw HardwareError(message: "配置文件格式或版本不受支持。") }
        try snapshot.validate()
        if let windowsTemplateJSON{_ = try WindowsProfile.templateRoot(Data(windowsTemplateJSON.utf8))}
        for macro in macros { try macro.validate(); _ = try WindowsProfile.macroSource(self,macro:macro) }
        guard Set(macros.map { $0.name }).count == macros.count else { throw HardwareError(message: "宏名称不能重复。") }
        for (slot,playback) in macroModes ?? [:]{
            guard macroBindings?[slot] != nil else{throw HardwareError(message:"宏执行方式缺少对应绑定。")};try playback.validate()
        }
        if let bindings=macroBindings {
            for (slot,name) in bindings {
                guard (0..<126).contains(slot), ![6,71].contains(slot),macros.contains(where:{$0.name==name}) else {
                    throw HardwareError(message:"宏绑定的键位或名称无效。")
                }
            }
        }
    }
    static func fromHardware(_ snapshot:HardwareSnapshot) throws -> HardwareProfile {
        try snapshot.validate()
        guard let bank=snapshot.macroData else{return HardwareProfile(snapshot:snapshot)}
        let macros=try CherryMacroCodec.decode(bank)
        var bindings:[Int:String]=[:];var modes:[Int:MacroPlayback]=[:]
        for slot in 0..<126 where [UInt8(0x70),0x71].contains(snapshot.keymap[slot*3]) {
            let record=Array(snapshot.keymap[slot*3..<slot*3+3])
            guard ![6,71].contains(slot) else{throw HardwareError(message:"宏绑定不能覆盖内部键。")}
            modes[slot]=try CherryMacroCodec.playback(record,macroCount:macros.count)
            bindings[slot]=macros[Int(record[1])].name
        }
        let profile=HardwareProfile(snapshot:snapshot,macros:macros,macroBindings:bindings,macroModes:modes)
        try profile.validate();return profile
    }
    func resolvedMacros() throws -> HardwareSnapshot {
        try validate()
        guard let bindings=macroBindings else{throw HardwareError(message:"请先读取完整宏配置；未知硬件宏暂不能覆盖。")}
        var result=snapshot
        for slot in 0..<126 where [UInt8(0x70),0x71].contains(result.keymap[slot*3]) {
            guard bindings[slot] != nil else{throw HardwareError(message:"配置包含未关联的硬件宏，请重新读取配置。")}
        }
        let header=snapshot.macroData.flatMap{bank -> [UInt8]? in bank[0]==0xAA && bank[1]==0x55 ? Array(bank[6..<16]):nil} ?? []
        result.macroData=try CherryMacroCodec.encode(macros,headerReserved:header)
        for (slot,name) in bindings {
            let index=macros.firstIndex{$0.name==name}!
            result.keymap.replaceSubrange(slot*3..<slot*3+3,with:try CherryMacroCodec.binding(index,playback:macroModes?[slot] ?? .once))
        }
        return result
    }
    mutating func assignMacro(named name:String,to slot:Int,playback:MacroPlayback = .once) throws {
        var draft=self;try draft.stageMacroAssignment(named:name,to:slot,playback:playback);self=draft
    }
    private mutating func stageMacroAssignment(named name:String,to slot:Int,playback:MacroPlayback) throws {
        try validate()
        guard ![6,71].contains(slot),(0..<126).contains(slot),macros.contains(where:{$0.name==name}) else{throw HardwareError(message:"请选择可配置按键及已保存的宏。")}
        if macroBindings==nil {
            let oldMacros=try snapshot.macroData.map{try CherryMacroCodec.decode($0)} ?? []
            guard oldMacros.isEmpty,
                  !(0..<126).contains(where:{[UInt8(0x70),0x71].contains(snapshot.keymap[$0*3])}) else {
                throw HardwareError(message:"原硬件宏尚未解码，请先重新读取键盘。")
            }
            macroBindings=[:]
        }
        try playback.validate();macroBindings![slot]=name;if macroModes==nil{macroModes=[:]};macroModes![slot]=playback;snapshot=try resolvedMacros()
    }
    mutating func removeMacro(named name:String) throws {
        guard macroBindings != nil,macros.contains(where:{$0.name==name}) else{throw HardwareError(message:"请先读取并选择已保存的宏。")}
        var draft=self;try draft.validate()
        try draft.removeKnownMacro(named:name);self=draft
    }
    private mutating func removeKnownMacro(named name:String) throws {
        for (slot,binding) in macroBindings ?? [:] where binding==name {
            snapshot.keymap.replaceSubrange(slot*3..<slot*3+3,with:[0x20,0,0])
            macroBindings?.removeValue(forKey:slot);macroModes?.removeValue(forKey:slot)
        }
        macros.removeAll{$0.name==name}
        if macroBindings != nil {snapshot=try resolvedMacros()}
    }
    mutating func unassignMacro(from slot:Int)throws {
        try validate()
        guard macroBindings?[slot] != nil else{throw HardwareError(message:"所选键没有宏绑定。")}
        var draft=self;draft.snapshot.keymap.replaceSubrange(slot*3..<slot*3+3,with:[0x20,0,0])
        draft.macroBindings?.removeValue(forKey:slot);draft.macroModes?.removeValue(forKey:slot)
        draft.snapshot=try draft.resolvedMacros();self=draft
    }
    static func mergeMacroRecovery(restored:HardwareProfile,previous:HardwareProfile?,before:HardwareSnapshot,target:HardwareSnapshot)throws->HardwareProfile {
        try restored.validate();try before.validate();try target.validate()
        guard restored.snapshot.deviceInfo==before.deviceInfo,restored.snapshot.keymap==before.keymap,restored.snapshot.parameters==before.parameters,restored.snapshot.colors==before.colors,restored.snapshot.macroData==before.macroData else{throw HardwareError(message:"宏恢复读回与原配置不一致，未合并编辑区。")}
        guard let previous,previous.snapshot.deviceInfo==restored.snapshot.deviceInfo else{return restored}
        try previous.validate();var result=restored
        result.snapshot.parameters=previous.snapshot.parameters;result.snapshot.colors=previous.snapshot.colors
        for slot in 0..<126 {
            let offset=slot*3
            // Drop unsent macro edits as part of the explicit macro rollback.
            // Only ordinary drafts outside the old/new macro triggers survive.
            if ![before,target,previous.snapshot].contains(where:{[UInt8(0x70),0x71].contains($0.keymap[offset])}){
                result.snapshot.keymap.replaceSubrange(offset..<offset+3,with:previous.snapshot.keymap[offset..<offset+3])
            }
        }
        try result.validate();return result
    }
    func macroWriteReview(before:HardwareSnapshot,target:HardwareSnapshot,labels:[Int:String]=[:])throws->String {
        try before.validate();try target.validate()
        guard let oldBank=before.macroData,let nextBank=target.macroData else{throw HardwareError(message:"缺少完整宏库，无法核对。")}
        let old=try CherryMacroCodec.decode(oldBank),next=try CherryMacroCodec.decode(nextBank)
        let changed=oldBank != nextBank
        var lines=["宏库：\(old.count) → \(next.count) 个，\(changed ? "将更新":"内容保留")。"]
        if changed {
            lines += next.enumerated().prefix(6).map{index,macro in "准备写入：\(macros.indices.contains(index) ? macros[index].name:macro.name) · \(macro.steps.count) 步"}
            if next.count>6{lines.append("另有 \(next.count-6) 个宏。")}
            if next.isEmpty{lines.append("将清空宏库。")}
        }
        var bindings:[String]=[]
        for slot in 0..<126 {
            let offset=slot*3,prior=Array(before.keymap[offset..<offset+3]),record=Array(target.keymap[offset..<offset+3])
            if prior != record || (changed && [UInt8(0x70),0x71].contains(record[0])) {
                let description:String
                if [UInt8(0x70),0x71].contains(record[0]) {
                    let mode=try CherryMacroCodec.playback(record,macroCount:next.count),index=Int(record[1])
                    description="\(macros.indices.contains(index) ? macros[index].name:next[index].name) · \(mode.label)"
                }else{description=CherryMatrix.describe(record)}
                bindings.append("\(labels[slot] ?? "槽位 \(slot)") → \(description)")
            }
        }
        if !bindings.isEmpty{lines.append("绑定目标（含沿用绑定）：");lines += bindings.prefix(8);if bindings.count>8{lines.append("另有 \(bindings.count-8) 个绑定目标。")}}
        return lines.joined(separator:"\n")
    }
    mutating func duplicateMacro(named name:String)throws->String {
        guard macroBindings != nil,let original=macros.first(where:{$0.name==name}) else{throw HardwareError(message:"请先读取并选择已保存的宏。")}
        var draft=self;let stem=KeyboardMacro.nameStem(name);var next="\(stem) 副本",number=2
        while draft.macros.contains(where:{$0.name==next}){next="\(stem) 副本 \(number)";number+=1}
        var copied=original;copied.name=next;draft.macros.append(copied);draft.snapshot=try draft.resolvedMacros();self=draft;return next
    }
    mutating func clearMacros()throws {
        guard macroBindings != nil else{throw HardwareError(message:"原硬件宏尚未解码，不能清空。")}
        var draft=self;for name in macros.map({$0.name}){try draft.removeMacro(named:name)}
        draft.snapshot=try draft.resolvedMacros();self=draft
    }
    static func decode(_ data: Data) throws -> HardwareProfile {
        guard data.count <= 3_000_000 else { throw HardwareError(message: "配置文件超过 3 MB。") }
        let decoder = JSONDecoder()
        var profile: HardwareProfile
        if let snapshot = try? decoder.decode(HardwareSnapshot.self, from: data) { profile = HardwareProfile(snapshot: snapshot) }
        else { profile = try decoder.decode(HardwareProfile.self, from: data) }
        try profile.validate()
        for (slot,name) in profile.macroBindings ?? [:]{profile.macroBindings?[slot]=profile.macros.first(where:{$0.name==name})!.name}
        return profile
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
