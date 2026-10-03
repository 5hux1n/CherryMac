import Foundation
import CoreFoundation

enum WindowsProfile {
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
    static let mediaCodes:[UInt16] = [0x0183,0x00CD,0x00B7,0x00B6,0x00B5,0x00EA,0x00E9,0x00E2,0x0223,0x0227,0x0226,0x0224,0x0225,0x022A,0x0221,0x0194,0x0192,0x018A]
    static let modeCodes:[UInt8] = [0,1,2,4,5,6,7,9,10,11,12,13,14,15,16,17,18,19,20,21,3,8,22,23,24]
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
    // Intermediate exporter: update keys/macros in an official template while
    // preserving lighting, device settings and unrelated/unknown fields.
    static func encodeKeysAndMacros(_ profile:HardwareProfile,template:Data)throws->Data {
        try profile.validate();let snapshot=try profile.resolvedMacros()
        guard template.count<=1_000_000,var root=try JSONSerialization.jsonObject(with:template) as? [String:Any],
              root["//"] as? String=="47",var keys=root["KeyList"] as? [[String:Any]],keys.count==126 else{throw HardwareError(message:"需要本型号的官方配置模板。")}
        for (i,key) in keys.enumerated(){guard try integer(key["DefaultAssignment"],"DefaultAssignment",range:0...0xFFFFFF)==defaults[i] else{throw HardwareError(message:"Windows 键盘布局不匹配。")}}
        if let value=root["ActionInfo"],!(value is NSNull),!(value is [[String:Any]]){throw HardwareError(message:"Windows 动作结构无效。")}
        let old=root["ActionInfo"] as? [[String:Any]] ?? []
        var actions:[[String:Any]]=[],remap:[Int:Int]=[:],variants:[String:Int]=[:],emitted:[KeyboardMacro]=[]
        for (i,action) in old.enumerated(){if try integer(action["ActionType"],"ActionType",range:0...4) != 2{remap[i]=actions.count;actions.append(action)}}
        func add(_ index:Int,_ playback:MacroPlayback)throws->Int {
            try playback.validate();let identity="\(index):\(playback.mode.rawValue):\(playback.count)"
            if let existing=variants[identity]{return existing}
            let next=actions.count;actions.append(try macroAction(profile.macros[index],playback:playback));emitted.append(profile.macros[index]);variants[identity]=next;return next
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
        var result=try HardwareProfile.fromHardware(baseline)
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
            var name=String(originalName.prefix(65));if name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty{name="导入宏"}
            let stem=name;var suffix=1
            while result.macros.contains(where:{$0.name==name}){name="\(stem) (\(suffix))";suffix+=1}
            let mode=try integer(content["ActionMacroType"],"ActionMacroType",range:0...2)
            let repeats=mode==0 ? try integer(content["ActionMacroLoopValue"] ?? 1,"ActionMacroLoopValue",range:1...255):1
            let preferred=MacroPlayback(mode:[.count,.held,.toggle][mode],count:repeats)
            let macro=KeyboardMacro(name:name,steps:steps,recordingDelay:.init(fixed:fixed==1,milliseconds:fixedMilliseconds),preferredPlayback:preferred);try macro.validate();result.macros.append(macro);importedMacros[index]=name
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
