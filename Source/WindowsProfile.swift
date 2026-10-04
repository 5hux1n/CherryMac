import Foundation
import CoreFoundation

enum WindowsProfile {
    // Shared between the USB serial queue and the main-actor executor. Old
    // callbacks keep the same ticket, which becomes invalid on stop/reconnect.
    final class HostTextTicket {
        let id:UUID
        private let lock=NSLock()
        private var valid=true
        init(id:UUID=UUID()){self.id=id}
        var isCurrent:Bool {lock.lock();defer{lock.unlock()};return valid}
        func invalidate(){lock.lock();valid=false;lock.unlock()}
    }
    struct HostTextPlan:Equatable {
        let name:String
        let originalText:String
        let windowsFlag:Int?
        let marker:[UInt8]?
        let scalarUTF16:[[UInt16]]
        // Official conversion creates a NUL-terminated host string; the
        // execution thread skips LF, while preserving CR and other units.
        init(action:[String:Any])throws {
            guard try WindowsProfile.integer(action["ActionType"],"ActionType",range:0...4)==3,
                  let content=action["ActionContent"] as? [String:Any],
                  let text=content["ActionText"] as? String else{
                throw HardwareError(message:"Windows 文本动作结构无效。")
            }
            name=action["ActionName"] as? String ?? "文本";originalText=text
            windowsFlag=try action["ActionTextFlag"].map{try WindowsProfile.integer($0,"ActionTextFlag",range:0...Int(Int32.max))}
            let prefix=String(text.prefix{ $0 != "\0" })
            marker=prefix.isEmpty ? nil:[0xA1,0,0]
            scalarUTF16=prefix.unicodeScalars.filter{$0.value != 10}.map{Array(String($0).utf16)}
        }
        static func triggerIndex(eventValue:Int)->Int? {
            (0x700..<0x800).contains(eventValue) ? eventValue-0x700:nil
        }
    }
    // Logical default-assignment fingerprint of Pokémon model 47.
    // The official 126-entry order differs from the USB matrix order.
    static let defaults:[Int] = [
        0x200029, 0x20003A, 0x20003B, 0x20003C, 0x20003D, 0x20003E, 0x20003F, 0x200040, 0x200041, 0x200042,
        0x200043, 0x200044, 0x200045, 0x200046, 0x200047, 0x200048, 0xA00300, 0x309201, 0x30B600, 0x30CD00,
        0x30B500, 0x200035, 0x20001E, 0x20001F, 0x200020, 0x200021, 0x200022, 0x200023, 0x200024, 0x200025,
        0x200026, 0x200027, 0x20002D, 0x20002E, 0x20002A, 0x200049, 0x20004A, 0x20004B, 0x200053, 0x200054,
        0x200055, 0x200056, 0x20002B, 0x200014, 0x20001A, 0x200008, 0x200015, 0x200017, 0x20001C, 0x200018,
        0x20000C, 0x200012, 0x200013, 0x20002F, 0x200030, 0x200031, 0x20004C, 0x20004D, 0x20004E, 0x20005F,
        0x200060, 0x200061, 0x200000, 0x200039, 0x200004, 0x200016, 0x200007, 0x200009, 0x20000A, 0x20000B,
        0x20000D, 0x20000E, 0x20000F, 0x200033, 0x200034, 0x200028, 0x20005C, 0x20005D, 0x20005E, 0x200000,
        0x200000, 0x200000, 0x200000, 0x200000, 0x200200, 0x20001D, 0x20001B, 0x200006, 0x200019, 0x200005,
        0x200011, 0x200010, 0x200036, 0x200037, 0x200038, 0x202000, 0x200052, 0x200059, 0x20005A, 0x20005B,
        0x200000, 0x200000, 0x200064, 0x200000, 0x200032, 0x200100, 0x200800, 0x200400, 0x20002C, 0x204000,
        0xA00100, 0x200065, 0x201000, 0x200050, 0x200051, 0x20004F, 0x200062, 0x200063, 0x200058, 0x200057,
        0xD0A201, 0xD0A202, 0xD0A203, 0xD0A204, 0xD0A205, 0x208000
    ]
    // EXE 0x76c6c8 is the logical matching table, not the JSON defaults.
    // Hidden international/Fn entries differ from the exported model 47 list.
    static let firmwareLogicalDefaults:[Int] = {
        var result=defaults
        for (index,value) in [62:0xF00001,79:0x20008A,80:0x20008B,81:0x200090,82:0x200091,83:0x200088,100:0x200087,101:0x200089,103:0x200085,120:0xF00002,121:0xF00003,122:0xD00100,123:0xD00200,124:0xD00400]{result[index]=value}
        return result
    }()
    struct HostTextTrigger:Equatable {let logicalIndex:Int;let physicalSlot:Int}
    // Fixed EXE: COL 5 / secondary FE -> raw receiver. Saved descriptor:
    // that top-level collection contains Report 5, eight payload bytes.
    // Accept a normalized complete report (ID included). Callers must still
    // establish device/session provenance; parsing does not authorize output.
    static func hostTextEvent(fullReport:[UInt8])->Int? {
        guard fullReport.count==9,fullReport[0]==5 else{return nil}
        let value=Int(fullReport[1]) | Int(fullReport[2])<<8
        guard let slot=HostTextPlan.triggerIndex(eventValue:value),slot<126 else{return nil}
        return value
    }
    static func resolveHostTextTrigger(eventValue:Int,factoryKeymap:[UInt8])throws->HostTextTrigger? {
        guard factoryKeymap.count==378 else{throw HardwareError(message:"文本触发解析需要完整的固件默认键位表。")}
        guard let slot=HostTextPlan.triggerIndex(eventValue:eventValue),slot<126 else{return nil}
        let offset=slot*3,value=Int(factoryKeymap[offset])<<16 | Int(factoryKeymap[offset+1])<<8 | Int(factoryKeymap[offset+2])
        guard let logicalIndex=firmwareLogicalDefaults.firstIndex(of:value) else{return nil}
        // Official matching picks the first physical occurrence. A later
        // duplicate must not dispatch another key's text.
        let first=(0..<126).first{index in let start=index*3;return Array(factoryKeymap[start..<start+3])==Array(factoryKeymap[offset..<offset+3])}
        guard first==slot else{return nil}
        return HostTextTrigger(logicalIndex:logicalIndex,physicalSlot:slot)
    }
    struct HostTextBinding:Equatable {
        let logicalIndex:Int
        let physicalSlot:Int
        let actionIndex:Int
        let plan:HostTextPlan
    }
    // Installation data only. This does not authorize an A1 write, install a
    // listener, or store the text in firmware. The JSON remains on the host.
    struct HostTextInstallation {
        let before:HardwareSnapshot
        let expected:HardwareSnapshot
        let factoryKeymap:[UInt8]
        let officialJSON:Data
        let bindings:[HostTextBinding]
        let changedSlots:[Int]
        init(officialJSON:Data,factoryKeymap:[UInt8],baseline:HardwareSnapshot)throws {
            try baseline.validate()
            guard baseline.deviceInfo[6]==24,baseline.colors != nil,baseline.macroData != nil,factoryKeymap.count==378 else{throw HardwareError(message:"准备文本安装需要本型号完整配置和默认键位表。")}
            let root=try WindowsProfile.templateRoot(officialJSON)
            guard let keys=root["KeyList"] as? [[String:Any]],let actions=root["ActionInfo"] as? [[String:Any]] else{throw HardwareError(message:"Windows 动作列表结构无效。")}
            var slots:[Int:Int]=[:]
            for slot in 0..<126 {
                if let trigger=try WindowsProfile.resolveHostTextTrigger(eventValue:0x700+slot,factoryKeymap:factoryKeymap){slots[trigger.logicalIndex]=slot}
            }
            var selected:[HostTextBinding]=[],target=baseline
            for (logical,key) in keys.enumerated() {
                guard try WindowsProfile.integer(key["ActionLink"] ?? 0,"ActionLink",range:0...1)==1 else{continue}
                let index=try WindowsProfile.integer(key["ActionLinkIndex"],"ActionLinkIndex",range:0...max(0,actions.count-1))
                guard actions.indices.contains(index) else{throw HardwareError(message:"文本安装配置的动作引用无效。")}
                guard try WindowsProfile.integer(actions[index]["ActionType"],"ActionType",range:0...4)==3 else{continue}
                let plan=try HostTextPlan(action:actions[index])
                guard let marker=plan.marker else{continue}
                guard plan.windowsFlag==nil || plan.windowsFlag==1 else{throw HardwareError(message:"文本动作标志尚未支持，未准备安装。")}
                guard let slot=slots[logical] else{throw HardwareError(message:"文本键在固件默认表中没有对应位置。")}
                guard KeymapWriteAuthorization.editableSlots.contains(slot) else{throw HardwareError(message:"内部功能键与隐藏位置不能安装文本绑定。")}
                guard ![UInt8(0x70),0x71].contains(baseline.keymap[slot*3]) else{throw HardwareError(message:"文本键当前绑定宏，请先解除宏绑定。")}
                target.keymap.replaceSubrange(slot*3..<slot*3+3,with:marker)
                selected.append(HostTextBinding(logicalIndex:logical,physicalSlot:slot,actionIndex:index,plan:plan))
            }
            guard !selected.isEmpty else{throw HardwareError(message:"配置没有可安装的非空文本绑定。")}
            before=baseline;expected=target;self.factoryKeymap=factoryKeymap;self.officialJSON=officialJSON
            bindings=selected.sorted{$0.physicalSlot<$1.physicalSlot}
            changedSlots=bindings.filter{binding in let range=binding.physicalSlot*3..<binding.physicalSlot*3+3;return baseline.keymap[range] != target.keymap[range]}.map{$0.physicalSlot}
        }
    }
    // Prepared data only, not a device/report authorization. The eventual
    // listener must verify report provenance and rebuild after configuration
    // changes or reconnect; a saved JSON file alone is insufficient.
    struct HostTextBindings {
        private let bindings:[Int:HostTextBinding]
        var count:Int{bindings.count}
        init(officialJSON:Data,factoryKeymap:[UInt8],currentKeymap:[UInt8])throws {
            guard factoryKeymap.count==378,currentKeymap.count==378 else{throw HardwareError(message:"文本路由需要完整的默认和当前键位表。")}
            let root=try WindowsProfile.templateRoot(officialJSON)
            guard let keys=root["KeyList"] as? [[String:Any]],let actions=root["ActionInfo"] as? [[String:Any]] else{throw HardwareError(message:"Windows 动作列表结构无效。")}
            var result:[Int:HostTextBinding]=[:]
            for slot in 0..<126 {
                guard let trigger=try WindowsProfile.resolveHostTextTrigger(eventValue:0x700+slot,factoryKeymap:factoryKeymap) else{continue}
                let offset=slot*3
                guard Array(currentKeymap[offset..<offset+3])==[0xA1,0,0] else{continue}
                let key=keys[trigger.logicalIndex]
                guard try WindowsProfile.integer(key["ActionLink"] ?? 0,"ActionLink",range:0...1)==1 else{continue}
                let index=try WindowsProfile.integer(key["ActionLinkIndex"],"ActionLinkIndex",range:0...max(0,actions.count-1))
                guard actions.indices.contains(index) else{throw HardwareError(message:"文本动作引用无效。")}
                guard try WindowsProfile.integer(actions[index]["ActionType"],"ActionType",range:0...4)==3 else{continue}
                let plan=try HostTextPlan(action:actions[index])
                guard plan.marker != nil else{continue}
                result[slot]=HostTextBinding(logicalIndex:trigger.logicalIndex,physicalSlot:slot,actionIndex:index,plan:plan)
            }
            bindings=result
        }
        func binding(eventValue:Int)->HostTextBinding? {
            guard let slot=HostTextPlan.triggerIndex(eventValue:eventValue) else{return nil}
            return bindings[slot]
        }
    }
    static let mediaCodes:[UInt16] = [0x0183,0x00CD,0x00B7,0x00B6,0x00B5,0x00EA,0x00E9,0x00E2,0x0223,0x0227,0x0226,0x0224,0x0225,0x022A,0x0221,0x0194,0x0192,0x018A]
    static let modeCodes:[UInt8] = [0,1,2,4,5,6,7,9,10,11,12,13,14,15,16,17,18,19,20,21,3,8,22,23,24]
    // Confirmed JSON getter/setter struct order (seven UInt16 fields), not
    // offsets in the keyboard's USB parameter bank or accepted UI ranges.
    static let systemStageFields=["Repeat","RepeatDelay","Key6Flag","ReportSelectItem","RFReportSelectItem","WFlag","WinFlag"]
    static func systemStageWords(_ root:[String:Any])throws->[UInt16]? {
        guard let value=root["SystemStages"],!(value is NSNull) else{return nil}
        guard let stages=value as? [String:Any] else{throw HardwareError(message:"Windows SystemStages 结构无效。")}
        return try systemStageFields.map{UInt16(try integer(stages[$0],$0,range:0...65535))}
    }
    struct Imported {
        let profile:HardwareProfile
        let keyCount:Int
        let macroCount:Int
        let colorCount:Int
        let ignoredKeyCount:Int
        var summary:String {"已导入 Windows 配置：\(keyCount) 个实体键、\(colorCount) 个颜色、\(macroCount) 个宏（含未绑定）。保留 \(ignoredKeyCount) 个内部／隐藏位置及系统参数；其他未绑定动作未迁移。尚未写入。"}
    }
    static func integer(_ object:Any?,_ name:String,range:ClosedRange<Int>)throws->Int {
        let value:Int?
        if let number=object as? NSNumber,CFGetTypeID(number) != CFBooleanGetTypeID(){
            let raw=number.doubleValue
            value=raw.isFinite && raw>=Double(range.lowerBound) && raw<=Double(range.upperBound) && raw.rounded()==raw ? Int(raw):nil
        }else if let text=object as? String{value=Int(text)}else{value=nil}
        guard let value,range.contains(value)else{throw HardwareError(message:"Windows 配置中的 \(name) 应为 \(range.lowerBound)–\(range.upperBound) 的整数。")};return value
    }
    static func record(_ value:Int)throws->[UInt8]{
        let bytes=[UInt8((value>>16)&255),UInt8((value>>8)&255),UInt8(value&255)]
        guard bytes[0]==0x20 || bytes[0]==0x30 else{throw HardwareError(message:"Windows 配置包含尚未支持的按键动作。")}
        return bytes
    }
    static func physicalSlot(_ value:Int)->Int? {
        if value>>16==0x20,(value>>8)&255==0{return CherryMatrix.usageSlots[value&255].flatMap{[10,75].contains($0) ? nil:$0}}
        let special:[Int:Int]=[0xA00300:6,0xA00100:71,0x200100:5,0x200200:4,0x200400:17,0x200800:11,0x201000:83,0x202000:82,0x204000:65,0x309201:102,0x30B600:108,0x30CD00:114,0x30B500:120]
        return special[value]
    }
    static func isOfficial(_ data:Data)->Bool {
        guard let root=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any]else{return false}
        return root["KeyList"] != nil || root["DeviceBasicInfo"] != nil
    }
    static func templateRoot(_ data:Data)throws->[String:Any] {
        guard data.count<=1_000_000,let root=try JSONSerialization.jsonObject(with:data) as? [String:Any],
              root["//"] as? String=="47",let keys=root["KeyList"] as? [[String:Any]],keys.count==126 else{throw HardwareError(message:"需要本型号的官方配置模板（不超过 1 MB）。")}
        for (i,key) in keys.enumerated(){guard try integer(key["DefaultAssignment"],"DefaultAssignment",range:0...0xFFFFFF)==defaults[i] else{throw HardwareError(message:"Windows 键盘布局不匹配。")}}
        _ = try systemStageWords(root)
        return root
    }
    // ActionInfo serializer shared by the forthcoming full-document exporter.
    // An explicit key binding takes precedence over the library preference.
    static func macroAction(_ macro:KeyboardMacro,playback:MacroPlayback?=nil)throws->[String:Any] {
        try macro.validate()
        let selected=playback ?? macro.preferredPlayback ?? .once
        try selected.validate()
        let mode=selected.mode == .count ? 0:selected.mode == .held ? 1:2
        let events:[[String:Any]]=macro.steps.map{step in
            let mouse=step.kind == .mouse,modifier = !mouse && step.usage>=224
            return ["Type":mouse ? 1:modifier ? 9:10,
                    "Button":modifier ? 1 << Int(step.usage-224):Int(step.usage),
                    "Action":step.pressed ? "down":"up","Delay":step.delayMilliseconds]
        }
        return ["ActionType":2,"ActionName":macro.name,"ActionContent":[
            "ActionMacroType":mode,"ActionMacroLoopValue":selected.count,
            "ActionMacroFixTimeIsSelected":macro.recordingDelay?.fixed == true ? 1:0,
            "ActionMacroFixTimeValue":macro.recordingDelay?.milliseconds ?? 0,
            "ActionMacroEvents":events]]
    }
    private static let macroFields:Set<String>=["ActionMacroType","ActionMacroLoopValue","ActionMacroFixTimeIsSelected","ActionMacroFixTimeValue","ActionMacroEvents"]
    private static let eventFields:Set<String>=["Type","Button","Action","Delay"]
    private static func hasMacroExtras(_ action:[String:Any])throws->Bool {
        guard let content=action["ActionContent"] as? [String:Any],let events=content["ActionMacroEvents"] as? [[String:Any]] else{throw HardwareError(message:"官方宏模板结构无效。")}
        return !Set(action.keys).subtracting(["ActionType","ActionName","ActionContent"]).isEmpty || !Set(content.keys).subtracting(macroFields).isEmpty || events.contains{!Set($0.keys).subtracting(eventFields).isEmpty}
    }
    private static func mergeMacro(_ original:[String:Any],_ next:[String:Any])throws->[String:Any] {
        guard var content=original["ActionContent"] as? [String:Any],let events=content["ActionMacroEvents"] as? [[String:Any]] else{throw HardwareError(message:"官方宏模板结构无效。")}
        let updated=next["ActionContent"] as! [String:Any];var steps=updated["ActionMacroEvents"] as! [[String:Any]]
        for (i,event) in events.enumerated(){
            let extras=event.filter{!eventFields.contains($0.key)};if extras.isEmpty{continue}
            guard steps.indices.contains(i),try integer(event["Type"],"Type",range:0...127)==steps[i]["Type"] as! Int,
                  try integer(event["Button"],"Button",range:0...255)==steps[i]["Button"] as! Int,event["Action"] as? String==steps[i]["Action"] as? String else{throw HardwareError(message:"宏步骤变化后无法对应未知事件字段，不能无损导出。")}
            steps[i]=extras.merging(steps[i]){_,new in new}
        }
        content.merge(updated){_,new in new};content["ActionMacroEvents"]=steps
        var result=original.merging(next){_,new in new};result["ActionContent"]=content;return result
    }
    static func macroSource(_ profile:HardwareProfile,macro:KeyboardMacro)throws->[String:Any]? {
        guard let index=macro.windowsActionIndex else{return nil}
        guard let text=profile.windowsTemplateJSON else{throw HardwareError(message:"宏来源缺少官方模板。")}
        let root=try templateRoot(Data(text.utf8))
        guard let actions=root["ActionInfo"] as? [[String:Any]],actions.indices.contains(index),try integer(actions[index]["ActionType"],"ActionType",range:0...4)==2 else{throw HardwareError(message:"宏来源动作索引无效。")}
        _ = try hasMacroExtras(actions[index]);return actions[index]
    }
    // Intermediate exporter: update keys/macros in an official template while
    // preserving lighting, device settings and unrelated/unknown fields.
    static func encodeKeysAndMacros(_ profile:HardwareProfile,template:Data)throws->Data {
        try profile.validate();let snapshot=try profile.resolvedMacros()
        var root=try templateRoot(template),keys=root["KeyList"] as! [[String:Any]]
        if let value=root["ActionInfo"],!(value is NSNull),!(value is [[String:Any]]){throw HardwareError(message:"Windows 动作结构无效。")}
        let old=root["ActionInfo"] as? [[String:Any]] ?? []
        let sources=try profile.macros.map{try macroSource(profile,macro:$0)}
        var actions:[[String:Any]]=[],remap:[Int:Int]=[:],variants:[String:Int]=[:],emitted:[KeyboardMacro]=[],templates:[String:[[String:Any]]]=[:]
        for (i,action) in old.enumerated(){
            if try integer(action["ActionType"],"ActionType",range:0...4) != 2{remap[i]=actions.count;actions.append(action)}
            else{
                let name=action["ActionName"] as? String ?? ""
                let canonical=try JSONSerialization.data(withJSONObject:action,options:.sortedKeys)
                let associated=try sources.compactMap{$0}.contains{try JSONSerialization.data(withJSONObject:$0,options:.sortedKeys)==canonical}
                if !associated && !profile.macros.contains(where:{$0.name==name}){guard !(try hasMacroExtras(action)) else{throw HardwareError(message:"旧宏包含无法关联到当前宏库的未知字段，不能无损导出。")}}
                templates[name,default:[]].append(action)
            }
        }
        func add(_ index:Int,_ playback:MacroPlayback)throws->Int {
            try playback.validate();let identity="\(index):\(playback.mode.rawValue):\(playback.count)"
            if let existing=variants[identity]{return existing}
            let macro=profile.macros[index],generated=try macroAction(macro,playback:playback)
            let source=sources[index]
            let sourceExists=try source.map{source in
                let canonical=try JSONSerialization.data(withJSONObject:source,options:.sortedKeys)
                return try old.contains{try JSONSerialization.data(withJSONObject:$0,options:.sortedKeys)==canonical}
            } ?? false
            let candidates=sourceExists ? [source!] : (templates[macro.name] ?? [])
            let merged=try candidates.map{try mergeMacro($0,generated)}
            if let first=merged.first{
                let canonical=try JSONSerialization.data(withJSONObject:first,options:.sortedKeys)
                for candidate in merged.dropFirst(){guard try JSONSerialization.data(withJSONObject:candidate,options:.sortedKeys)==canonical else{throw HardwareError(message:"同名官方宏的附加字段不同，无法确定导出对应关系。")}}
            }
            let next=actions.count;actions.append(merged.first ?? generated);emitted.append(macro);variants[identity]=next;return next
        }
        for (index,macro) in profile.macros.enumerated(){_ = try add(index,macro.preferredPlayback ?? .once)}
        for i in keys.indices {
            guard let slot=physicalSlot(defaults[i]),![6,71].contains(slot) else{
                if try integer(keys[i]["ActionLink"] ?? 0,"ActionLink",range:0...1)==1{
                    let index=try integer(keys[i]["ActionLinkIndex"],"ActionLinkIndex",range:0...max(0,old.count-1))
                    guard let mapped=remap[index] else{throw HardwareError(message:"内部位置引用旧宏，无法无损导出。")};keys[i]["ActionLinkIndex"]=mapped
                };continue
            }
            let bytes=Array(snapshot.keymap[slot*3..<slot*3+3])
            if [UInt8(0x70),0x71].contains(bytes[0]){
                let playback=try CherryMacroCodec.playback(bytes,macroCount:profile.macros.count)
                keys[i]["ActionLink"]=1;keys[i]["ActionLinkIndex"]=try add(Int(bytes[1]),playback);keys[i]["Assignment"]=keys[i]["DefaultAssignment"]
            }else{
                guard [UInt8(0x20),0x30].contains(bytes[0]) else{throw HardwareError(message:"此按键动作尚不能导出到官方格式。")}
                keys[i]["Assignment"]=Int(bytes[0])*65536+Int(bytes[1])*256+Int(bytes[2]);keys[i]["ActionLink"]=0;keys[i]["ActionLinkIndex"] = -1
            }
        }
        // Distinct playback variants become separate macros on official import.
        _ = try CherryMacroCodec.encode(emitted)
        root["KeyList"]=keys;root["ActionInfo"]=actions
        let output=try JSONSerialization.data(withJSONObject:root,options:[.prettyPrinted,.sortedKeys])
        guard output.count<=1_000_000 else{throw HardwareError(message:"导出的配置文件过大。")};return output
    }
    static func decode(_ data:Data,baseline:HardwareSnapshot)throws->Imported {
        guard data.count<=1_000_000 else{throw HardwareError(message:"配置文件过大。")}
        try baseline.validate()
        guard let root=try JSONSerialization.jsonObject(with:data) as? [String:Any],root["//"] as? String=="47",
              let keys=root["KeyList"] as? [[String:Any]],keys.count==defaults.count else{throw HardwareError(message:"仅支持 MX 3.0S Pokémon 型号 47 的 Windows JSON 配置。")}
        for (index,key) in keys.enumerated(){
            guard try integer(key["DefaultAssignment"],"DefaultAssignment",range:0...0xFFFFFF)==defaults[index]else{throw HardwareError(message:"Windows 键盘布局不匹配，无法确定按键位置。")}
        }
        for name in ["LightInfo","CustomLightMode"] {
            if let object=root[name],!(object is NSNull),!(object is [String:Any]){throw HardwareError(message:"Windows \(name) 结构无效。")}
        }
        if let object=root["ActionInfo"],!(object is NSNull),!(object is [[String:Any]]){throw HardwareError(message:"Windows ActionInfo 结构无效。")}
        let actions=root["ActionInfo"] as? [[String:Any]] ?? []
        _ = try systemStageWords(root)
        var result=try HardwareProfile.fromHardware(baseline)
        result.windowsTemplateJSON=String(decoding:try JSONSerialization.data(withJSONObject:root,options:.sortedKeys),as:UTF8.self)
        let oldBindings=result.macroBindings ?? [:]
        let physicalSlots=Set(defaults.compactMap{physicalSlot($0)})
        // Replace the imported physical bindings while preserving any raw hidden data.
        result.macroBindings=oldBindings.filter{!physicalSlots.contains($0.key)}
        result.macroModes=(result.macroModes ?? [:]).filter{!physicalSlots.contains($0.key)}
        var importedMacros:[Int:String]=[:];var keyCount=0;var colorCount=0;var ignored=0
        func importMacro(_ index:Int)throws {
            if importedMacros[index] != nil{return}
            guard let content=actions[index]["ActionContent"] as? [String:Any] else{throw HardwareError(message:"Windows 宏内容无效。")}
            let fixed=try integer(content["ActionMacroFixTimeIsSelected"] ?? 0,"ActionMacroFixTimeIsSelected",range:0...1)
            let fixedMilliseconds=try integer(content["ActionMacroFixTimeValue"] ?? 0,"ActionMacroFixTimeValue",range:0...60000)
            guard let events=content["ActionMacroEvents"] as? [[String:Any]],!events.isEmpty,events.count<=256 else{throw HardwareError(message:"Windows 宏事件无效。")}
            let steps=try events.map{event->KeyboardMacro.Step in
                let type=try integer(event["Type"],"宏 Type",range:0...127)
                let button=try integer(event["Button"],"宏 Button",range:0...255)
                let delay=try integer(event["Delay"],"宏 Delay",range:0...60000)
                let usage:UInt8
                if type==1,[1,2,4,8,16].contains(button){usage=UInt8(button)}
                else if type==10,button>=4,button<224{usage=UInt8(button)}
                else if type==9,button>0,button.nonzeroBitCount==1{usage=UInt8(224+button.trailingZeroBitCount)}
                else{throw HardwareError(message:"Windows 宏包含尚未支持的鼠标移动或其他事件。")}
                guard let action=event["Action"] as? String,["down","up"].contains(action)else{throw HardwareError(message:"Windows 宏按下／松开状态无效。")}
                return .init(usage:usage,pressed:action=="down",delayMilliseconds:delay,kind:type==1 ? .mouse:nil)
            }
            let originalName=actions[index]["ActionName"] as? String ?? "导入宏"
            var name=KeyboardMacro.nameStem(originalName);if name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty{name="导入宏"}
            let stem=name;var suffix=1
            while result.macros.contains(where:{$0.name==name}){name="\(stem) (\(suffix))";suffix+=1}
            let mode=try integer(content["ActionMacroType"],"ActionMacroType",range:0...2)
            let repeats=mode==0 ? try integer(content["ActionMacroLoopValue"] ?? 1,"ActionMacroLoopValue",range:1...255):1
            let preferred=MacroPlayback(mode:[.count,.held,.toggle][mode],count:repeats)
            let macro=KeyboardMacro(name:name,steps:steps,recordingDelay:.init(fixed:fixed==1,milliseconds:fixedMilliseconds),preferredPlayback:preferred,windowsActionIndex:index);try macro.validate();result.macros.append(macro);importedMacros[index]=name
        }
        for (index,action) in actions.enumerated() where (try? integer(action["ActionType"],"ActionType",range:0...4))==2{try importMacro(index)}
        for (index,key) in keys.enumerated(){
            guard let slot=physicalSlot(defaults[index])else{ignored+=1;continue}
            if [6,71].contains(slot){ignored+=1;continue}
            let link=try integer(key["ActionLink"] ?? 0,"ActionLink",range:0...1)
            var bytes:[UInt8]
            if link==0 {
                bytes=try record(integer(key["Assignment"],"Assignment",range:0...0xFFFFFF))
            }else {
                let actionIndex=try integer(key["ActionLinkIndex"],"ActionLinkIndex",range:0...max(0,actions.count-1))
                guard actions.indices.contains(actionIndex),let content=actions[actionIndex]["ActionContent"] as? [String:Any]else{throw HardwareError(message:"Windows 动作引用无效。")}
                let type=try integer(actions[actionIndex]["ActionType"],"ActionType",range:0...4)
                switch type {
                case 1:bytes=try record(integer(content["ActionKey"],"ActionKey",range:0...0xFFFFFF))
                case 2:
                    try importMacro(actionIndex)
                    let name=importedMacros[actionIndex]!;result.macroBindings![slot]=name
                    let mode=try integer(content["ActionMacroType"],"ActionMacroType",range:0...2)
                    let repeats=mode==0 ? try integer(content["ActionMacroLoopValue"] ?? 1,"ActionMacroLoopValue",range:1...255):1
                    let playback=MacroPlayback(mode:[.count,.held,.toggle][mode],count:repeats)
                    result.macroModes![slot]=playback
                    bytes=try CherryMacroCodec.binding(result.macros.firstIndex{$0.name==name}!,playback:playback)
                case 3:
                    _=try HostTextPlan(action:actions[actionIndex])
                    throw HardwareError(message:"此配置含文本绑定，需要主机执行服务；普通配置导入尚不处理，请使用专用文本配置流程。原编辑区保留。")
                case 4:
                    let index=try integer(content["ActionMedia"],"ActionMedia",range:0...mediaCodes.count-1)
                    let media=mediaCodes[index];bytes=[0x30,UInt8(media&255),UInt8(media>>8)]
                default:throw HardwareError(message:"Windows 文本和其他动作暂不支持导入，请在 Mac 中重新设置。")
                }
            }
            result.snapshot.keymap.replaceSubrange(slot*3..<slot*3+3,with:bytes);keyCount+=1
        }
        if let lighting=root["LightInfo"] as? [String:Any] {
            let selected=try integer(lighting["SelectItem"],"SelectItem",range:0...modeCodes.count-1)
            let mode=modeCodes[selected]
            guard CherryLighting.modes.contains(where:{$0.1==mode})else{throw HardwareError(message:"此 Windows 灯效不在本型号已验证的 12 个模式中。")}
            result.snapshot.parameters[1]=mode
            result.snapshot.parameters[2]=UInt8(try integer(lighting["Light"],"Light",range:0...4))
            result.snapshot.parameters[3]=UInt8(4-(try integer(lighting["Speed"],"Speed",range:0...4)))
            result.snapshot.parameters[4]=UInt8(try integer(lighting["Fx"],"Fx",range:0...1))
            result.snapshot.parameters[5]=UInt8(try integer(lighting["MultiColor"],"MultiColor",range:0...1))
            for (offset,key) in ["Red","Green","Blue"].enumerated(){result.snapshot.parameters[6+offset]=UInt8(try integer(lighting[key],key,range:0...255))}
        }
        if let custom=root["CustomLightMode"] as? [String:Any] {
            guard let groups=custom["LightColorInfo"] as? [[[String:Any]]],groups.count==1,groups[0].count==126,result.snapshot.colors != nil else{throw HardwareError(message:"Windows 逐键颜色组不匹配，无法导入。")}
            for (index,entry) in groups[0].enumerated(){
                guard let slot=physicalSlot(defaults[index])else{continue}
                let bytes=try ["Red","Green","Blue"].map{UInt8(try integer(entry[$0],$0,range:0...255))}
                result.snapshot.colors!.replaceSubrange(slot*3..<slot*3+3,with:bytes);colorCount+=1
            }
        }
        // Rebuild only when bindings changed; an import without macros must
        // preserve the original bank and its reserved bytes byte-for-byte.
        if result.macroBindings != oldBindings || !importedMacros.isEmpty {result.snapshot=try result.resolvedMacros()}
        try result.validate()
        return Imported(profile:result,keyCount:keyCount,macroCount:importedMacros.count,colorCount:colorCount,ignoredKeyCount:ignored)
    }
}
