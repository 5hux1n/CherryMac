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
    func validate(maximumEvents:Int = 762) throws {
        if let hardwareReserved{guard hardwareReserved.count==2 else{throw HardwareError(message:"宏保留数据长度无效。")}}
        try preferredPlayback?.validate()
        if let recordingDelay{guard (0...60000).contains(recordingDelay.milliseconds) else{throw HardwareError(message:"固定间隔选项须为 0…60000 毫秒。")}}
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.precomposedStringWithCanonicalMapping.unicodeScalars.count <= 80,
              !steps.isEmpty, steps.count <= maximumEvents else { throw HardwareError(message: "宏名称或步骤数量无效。") }
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

// Portable read metadata only; never used as permission to write a device.
struct LightingMappingContext:Codable,Equatable {
    var deviceInfo:[UInt8]
    var factoryKeymap:[UInt8]
    var ledIndices:[UInt8]
    func slots(for snapshot:HardwareSnapshot)throws->[Int?]{
        guard deviceInfo.count==34,deviceInfo==snapshot.deviceInfo else{throw HardwareError(message:"灯光映射与当前固件信息不一致，请重新读取。")}
        return try WindowsProfile.resolveLightingSlots(factoryKeymap:factoryKeymap,ledIndices:ledIndices)
    }
    static func capture(snapshot:HardwareSnapshot,read:(UInt8,Int)throws->[UInt8])throws->LightingMappingContext {
        try snapshot.validate()
        let factory=try read(7,378),indices=try read(0x1B,126)
        let verifiedFactory=try read(7,378),verifiedIndices=try read(0x1B,126)
        let info=try read(3,34),keymap=try read(8,378)
        guard factory==verifiedFactory,indices==verifiedIndices,info==snapshot.deviceInfo,keymap==snapshot.keymap else{throw HardwareError(message:"读取灯光映射期间配置发生变化，请重新读取。")}
        let result=LightingMappingContext(deviceInfo:info,factoryKeymap:factory,ledIndices:indices)
        _ = try result.slots(for:snapshot);return result
    }
    func colorSlot(_ keySlot:Int)->Int? {
        guard (0..<126).contains(keySlot),ledIndices.count==126,ledIndices[keySlot]<126 else{return nil}
        return Int(ledIndices[keySlot])
    }
}
struct HardwareProfile: Codable, Equatable {
    var format = "CherryMacProfile"
    var version = 1
    var snapshot: HardwareSnapshot
    enum MacroStorageLayout:String,Codable {case sharedLibrary,officialBindings}
    var macroStorageLayout:MacroStorageLayout? = nil
    var macros: [KeyboardMacro] = []
    // nil means that the raw device bank has not been decoded for editing.
    // Optional keeps older exported profiles readable.
    var macroBindings: [Int:String]? = nil
    var macroModes:[Int:MacroPlayback]? = nil
    // Original official document, retained locally for lossless unknown fields.
    var windowsTemplateJSON:String? = nil
    // Portable host draft only; importing never installs or enables text input.
    var hostTextJSON:String? = nil
    var lightingMapping:LightingMappingContext? = nil
    enum LightingColorEncoding:String,Codable {case hardwareRGB,officialRGB}
    var lightingColorEncoding:LightingColorEncoding? = nil
    func validate() throws {
        guard format == "CherryMacProfile", version == 1, macroStorageLayout == .officialBindings || macros.count <= 32 else { throw HardwareError(message: "配置文件格式或版本不受支持。") }
        try snapshot.validate()
        if let lightingMapping{_ = try lightingMapping.slots(for:snapshot)}
        if let windowsTemplateJSON{_ = try WindowsProfile.templateRoot(Data(windowsTemplateJSON.utf8))}
        if let hostTextJSON{_ = try WindowsProfile.validateHostTextDefinition(Data(hostTextJSON.utf8))}
        for macro in macros { try macro.validate(maximumEvents:macroStorageLayout == .officialBindings ? 762:256); _ = try WindowsProfile.macroSource(self,macro:macro) }
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
        guard let bank=snapshot.macroData else{return HardwareProfile(snapshot:snapshot,lightingColorEncoding:.hardwareRGB)}
        let macros=try CherryMacroCodec.decode(bank)
        var bindings:[Int:String]=[:];var modes:[Int:MacroPlayback]=[:]
        for slot in 0..<126 where [UInt8(0x70),0x71].contains(snapshot.keymap[slot*3]) {
            let record=Array(snapshot.keymap[slot*3..<slot*3+3])
            guard ![6,71].contains(slot) else{throw HardwareError(message:"宏绑定不能覆盖内部键。")}
            modes[slot]=try CherryMacroCodec.playback(record,macroCount:macros.count)
            bindings[slot]=macros[Int(record[1])].name
        }
        var profile=HardwareProfile(snapshot:snapshot,macros:macros,macroBindings:bindings,macroModes:modes,lightingColorEncoding:.hardwareRGB)
        if macros.count>32 || macros.contains(where:{$0.steps.count>256}){profile.macroStorageLayout = .officialBindings}
        try profile.validate();return profile
    }
    func colorSlot(_ keySlot:Int)->Int? {
        if let lightingMapping{return lightingMapping.colorSlot(keySlot)}
        return (0..<126).contains(keySlot) ? keySlot:nil
    }
    func resolvedMacros() throws -> HardwareSnapshot {
        try validate()
        guard let bindings=macroBindings else{throw HardwareError(message:"请先读取完整宏配置；未知硬件宏暂不能覆盖。")}
        if macroStorageLayout == .officialBindings{return try officialMacroReceipt().expected}
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
    func officialMacroReceipt(before:HardwareSnapshot?=nil)throws->OfficialMacroDraftReceipt {
        try validate();let original=before ?? snapshot
        guard snapshot.deviceInfo==original.deviceInfo else{throw HardwareError(message:"配置来自不同固件，请重新读取。") }
        guard let mapping=lightingMapping,mapping.deviceInfo==original.deviceInfo else{throw HardwareError(message:"官方宏写入需要重新读取完整默认键位映射。")}
        guard let bindings=macroBindings else{throw HardwareError(message:"未知宏不能覆盖，请先读取完整配置。")}
        return try OfficialMacroDraftReceipt.prepare(before:original,factoryKeymap:mapping.factoryKeymap,macros:macros,bindings:bindings,modes:macroModes ?? [:])
    }
    func macroStorageUsage()throws->Int {
        if macroStorageLayout == .officialBindings{return try officialMacroReceipt().layout.usedBytes}
        let bank=try CherryMacroCodec.encode(macros);return macros.isEmpty ? 0:Int(bank[2]) | Int(bank[3])<<8
    }
    func macroStorageNames()throws->[String] {
        if macroStorageLayout == .officialBindings{return try officialMacroReceipt().layout.records.map{macros[$0.libraryIndex].name}}
        return macros.map{$0.name}
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
        result.snapshot.parameters=previous.snapshot.parameters;result.snapshot.colors=previous.snapshot.colors;result.lightingColorEncoding=previous.lightingColorEncoding
        result.lightingMapping=previous.lightingMapping;result.hostTextJSON=previous.hostTextJSON
        if let template=previous.windowsTemplateJSON {
            var root=try WindowsProfile.templateRoot(Data(template.utf8))
            guard root["ActionInfo"] == nil || root["ActionInfo"] is NSNull || root["ActionInfo"] is [[String:Any]] else{throw HardwareError(message:"当前官方草稿动作列表无效，未合并编辑区。")}
            var actions=root["ActionInfo"] as? [[String:Any]] ?? []
            // Restored macros may refer to an older ActionInfo ordering. Keep
            // their source extras by reusing/appending the exact old action.
            for index in result.macros.indices {
                if let source=try WindowsProfile.macroSource(restored,macro:restored.macros[index]) {
                    let existing=actions.firstIndex{NSDictionary(dictionary:$0).isEqual(to:source)}
                    let destination=existing ?? actions.count
                    if existing==nil{actions.append(source)}
                    result.macros[index].windowsActionIndex=destination
                }
            }
            if root["ActionInfo"] != nil || !actions.isEmpty{root["ActionInfo"]=actions}
            result.windowsTemplateJSON=String(data:try JSONSerialization.data(withJSONObject:root,options:[.sortedKeys]),encoding:.utf8)
        }

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
        let storedNames=try macroStorageNames()
        let changed=oldBank != nextBank
        var lines=["宏库：\(old.count) → \(next.count) 个，\(changed ? "将更新":"内容保留")。"]
        if changed {
            lines += next.enumerated().prefix(6).map{index,macro in "准备写入：\(storedNames.indices.contains(index) ? storedNames[index]:macro.name) · \(macro.steps.count) 步"}
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
                    description="\(storedNames.indices.contains(index) ? storedNames[index]:next[index].name) · \(mode.label)"
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
        let data=try encoder.encode(self)
        guard data.count<=3_000_000 else{throw HardwareError(message:"配置文件超过 3 MB，请精简文本或分别导出。")};return data
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
        if bytes == [0xA1,0,0]{return "文本 · 需要 CherryMac 运行"}
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
            if let index=WindowsProfile.mediaCodes.firstIndex(of:UInt16(code)){return WindowsProfile.mediaNames[index]}
            return "媒体键 \(code)"
        }
        if bytes[0] == 0xA0 { return "键盘内部功能 \(bytes[1])" }
        return bytes.map{String(format:"%02X",$0)}.joined(separator:" ")
    }
}

// Local editor provenance, never a device-write authorization. Keep the raw
// palette separate from the verified, brightness-scaled hardware snapshot.
struct RawLightingMetadata:Codable {
    var format="CherryMacRawLightingMetadata"
    var version=1
    let snapshot:HardwareSnapshot
    let rawColors:[UInt8]
    let lightingMapping:LightingMappingContext
    func validate()throws {
        try snapshot.validate();_ = try lightingMapping.slots(for:snapshot)
        guard format=="CherryMacRawLightingMetadata",version==1,rawColors.count==378,snapshot.parameters[1]==8 else{throw HardwareError(message:"本地原始配色资料无效。")}
        var draft=HardwareProfile(snapshot:snapshot,lightingMapping:lightingMapping,lightingColorEncoding:.officialRGB)
        draft.snapshot.colors=rawColors
        let plan=try WindowsProfile.planCustomLighting(draft,bank:0,transportSelector:0,chunkCapacity:56,beginRequired:true)
        guard try plan.expectedReadback(from:snapshot).colors==snapshot.colors else{throw HardwareError(message:"本地原始配色与保存的硬件颜色不一致。")}
    }
    static func capture(_ draft:HardwareProfile,current:HardwareSnapshot)throws->RawLightingMetadata? {
        try draft.validate();try current.validate()
        guard draft.lightingColorEncoding == .officialRGB,current.parameters[1]==8,
              let mapping=draft.lightingMapping,let colors=draft.snapshot.colors else{return nil}
        // A local palette does not require a firmware transaction's commit
        // flag. Match actual lighting controls and colors, preserving all
        // current hardware parameters in the provenance snapshot.
        let offsets=Array(0...8)+[21]
        guard draft.snapshot.deviceInfo==current.deviceInfo,
              offsets.allSatisfy({draft.snapshot.parameters[$0]==current.parameters[$0]}) else{return nil}
        let plan=try WindowsProfile.planCustomLighting(draft,bank:0,transportSelector:0,chunkCapacity:56,beginRequired:true)
        guard try plan.expectedReadback(from:current).colors==current.colors else{return nil}
        let value=RawLightingMetadata(snapshot:current,rawColors:colors,lightingMapping:mapping)
        try value.validate();return value
    }
    func adopting(into profile:HardwareProfile)throws->HardwareProfile? {
        try validate();try profile.validate()
        guard profile.lightingMapping==lightingMapping,profile.snapshot.deviceInfo==snapshot.deviceInfo,
              profile.snapshot.parameters==snapshot.parameters,profile.snapshot.colors==snapshot.colors else{return nil}
        var next=profile;next.snapshot.colors=rawColors;next.lightingColorEncoding = .officialRGB
        try next.validate();return next
    }
}

struct MacroMetadataRecord:Codable {
    let format:String
    let version:Int
    let profile:HardwareProfile
    let receipt:OfficialMacroDraftReceipt?
    static func capture(snapshot:HardwareSnapshot,mapping:LightingMappingContext?,known:HardwareProfile?=nil)->Self? {
        if let known,let record=try? prepare(known,snapshot:snapshot){return record}
        guard var decoded=try? HardwareProfile.fromHardware(snapshot) else{return nil}
        decoded.lightingMapping=mapping
        // Select a representation only when it reconstructs the exact bank.
        if mapping != nil{decoded.macroStorageLayout = .officialBindings;if let record=try? prepare(decoded,snapshot:snapshot){return record}}
        decoded.macroStorageLayout = .sharedLibrary
        return try? prepare(decoded,snapshot:snapshot)
    }
    static func prepare(_ draft:HardwareProfile,snapshot:HardwareSnapshot,before:HardwareSnapshot?=nil)throws->Self {
        var saved=draft;saved.snapshot=snapshot;saved.lightingColorEncoding = .hardwareRGB;try saved.validate()
        let resolved=try saved.resolvedMacros()
        guard resolved.deviceInfo==snapshot.deviceInfo,resolved.keymap==snapshot.keymap,resolved.macroData==snapshot.macroData else{throw HardwareError(message:"宏名称与设备数据不一致，未保存名称。")}
        var receipt:OfficialMacroDraftReceipt?
        if saved.macroStorageLayout == .officialBindings {
            let next=try saved.officialMacroReceipt(before:before ?? snapshot)
            _ = try next.reconcile(observed:snapshot,factoryKeymap:saved.lightingMapping!.factoryKeymap);receipt=next
        }
        return .init(format:"CherryMacMacroMetadata",version:1,profile:saved,receipt:receipt)
    }
    func restore(snapshot:HardwareSnapshot,mapping:LightingMappingContext?)throws->HardwareProfile {
        guard format=="CherryMacMacroMetadata",version==1 else{throw HardwareError(message:"宏名称记录格式或版本无效。")}
        try profile.validate();try snapshot.validate()
        guard profile.snapshot.deviceInfo==snapshot.deviceInfo else{throw HardwareError(message:"宏名称记录来自不同固件。")}
        if profile.macroStorageLayout == .officialBindings {
            guard let receipt,let mapping,mapping.deviceInfo==snapshot.deviceInfo,
                  receipt.macros==profile.macros,receipt.bindings==profile.macroBindings,
                  receipt.modes==(profile.macroModes ?? [:]) else{throw HardwareError(message:"官方宏名称记录缺少匹配的草稿或实际默认映射。")}
            _ = try receipt.reconcile(observed:snapshot,factoryKeymap:mapping.factoryKeymap)
        }else if receipt != nil{throw HardwareError(message:"宏名称记录的存储方式不一致。")}
        var saved=profile;if saved.macroStorageLayout==nil{saved.macroStorageLayout = .sharedLibrary};saved.snapshot=snapshot;saved.lightingMapping=mapping;saved.lightingColorEncoding = .hardwareRGB
        let resolved=try saved.resolvedMacros()
        guard resolved.keymap==snapshot.keymap,resolved.macroData==snapshot.macroData else{throw HardwareError(message:"宏名称记录与完整读回数据不一致。")}
        return saved
    }
}
