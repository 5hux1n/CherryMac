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
    // Fixed 01CE branch: logical defaults -> first matching factory key ->
    // separate command 1B LED index. No reads or writes occur in this decoder.
    // The current 378-byte product color bank bounds accepted LED indices.
    static func resolveLightingSlots(factoryKeymap:[UInt8],ledIndices:[UInt8])throws->[Int?] {
        guard factoryKeymap.count==378,ledIndices.count==126 else{throw HardwareError(message:"灯光映射需要完整默认键位表和 126 项 LED 索引。")}
        guard ledIndices.allSatisfy({$0<126 || $0==255})else{throw HardwareError(message:"LED 索引超出当前颜色表范围，停止转换。")}
        return firmwareLogicalDefaults.enumerated().map{index,value in
            if (122...124).contains(index){return nil}
            guard let slot=(0..<126).first(where:{slot in
                let offset=slot*3
                return Int(factoryKeymap[offset])<<16 | Int(factoryKeymap[offset+1])<<8 | Int(factoryKeymap[offset+2])==value
            }),ledIndices[slot] != 255 else{return nil}
            return Int(ledIndices[slot])
        }
    }
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
    static func editHostText(_ data:Data,factoryKeymap:[UInt8],physicalSlot:Int,text:String?,name:String="文本")throws->Data {
        guard KeymapWriteAuthorization.editableSlots.contains(physicalSlot),let trigger=try resolveHostTextTrigger(eventValue:0x700+physicalSlot,factoryKeymap:factoryKeymap) else{throw HardwareError(message:"此按键没有可编辑的文本位置。")}
        var root=try templateRoot(data)
        guard var keys=root["KeyList"] as? [[String:Any]],var actions=root["ActionInfo"] as? [[String:Any]] else{throw HardwareError(message:"Windows 动作列表结构无效。")}
        var references:[Int:Int]=[:]
        for key in keys where try integer(key["ActionLink"] ?? 0,"ActionLink",range:0...1)==1 {
            let index=try integer(key["ActionLinkIndex"],"ActionLinkIndex",range:0...max(0,actions.count-1))
            guard actions.indices.contains(index) else{throw HardwareError(message:"文本配置含无效动作引用。")}
            references[index,default:0]+=1
        }
        let logical=trigger.logicalIndex,link=try integer(keys[logical]["ActionLink"] ?? 0,"ActionLink",range:0...1)
        var oldIndex:Int?
        if link==1{let index=try integer(keys[logical]["ActionLinkIndex"],"ActionLinkIndex",range:0...max(0,actions.count-1));guard actions.indices.contains(index) else{throw HardwareError(message:"文本动作引用无效。")};oldIndex=index}
        if let text {
            let normalized=name.precomposedStringWithCanonicalMapping
            guard !normalized.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,normalized.unicodeScalars.count<=80,!text.isEmpty,!text.contains("\0") else{throw HardwareError(message:"请填写有效名称和非空文本；文本不能含 NUL。")}
            let edited=text.replacingOccurrences(of:"\r\n",with:"\n").replacingOccurrences(of:"\r",with:"\n").replacingOccurrences(of:"\n",with:"\r\n")
            var action:[String:Any]=[:];var replaceIndex:Int?
            if let index=oldIndex,try integer(actions[index]["ActionType"],"ActionType",range:0...4)==3 {
                action=actions[index]
                if references[index]==1{replaceIndex=index}
            }
            var content=action["ActionContent"] as? [String:Any] ?? [:];content["ActionText"]=edited
            action["ActionType"]=3;action["ActionTextFlag"]=1;action["ActionName"]=normalized;action["ActionContent"]=content
            let index:Int
            if let replaceIndex{index=replaceIndex;actions[index]=action}else{index=actions.count;actions.append(action)}
            keys[logical]["ActionLink"]=1;keys[logical]["ActionLinkIndex"]=index;keys[logical]["Assignment"]=defaults[logical]
        }else{
            guard let index=oldIndex,try integer(actions[index]["ActionType"],"ActionType",range:0...4)==3 else{throw HardwareError(message:"此按键没有文本绑定。")}
            _ = try record(defaults[logical])
            keys[logical]["ActionLink"]=0;keys[logical]["ActionLinkIndex"] = -1;keys[logical]["Assignment"]=defaults[logical]
        }
        root["KeyList"]=keys;root["ActionInfo"]=actions
        let result=try JSONSerialization.data(withJSONObject:root,options:[.sortedKeys,.withoutEscapingSlashes]);_ = try templateRoot(result);return result
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
        let removedSlots:[Int]
        init(officialJSON:Data,factoryKeymap:[UInt8],baseline:HardwareSnapshot)throws {
            try baseline.validate()
            guard baseline.deviceInfo[6]==24,baseline.colors != nil,baseline.macroData != nil,factoryKeymap.count==378 else{throw HardwareError(message:"准备文本安装需要本型号完整配置和默认键位表。")}
            let root=try WindowsProfile.templateRoot(officialJSON)
            guard let keys=root["KeyList"] as? [[String:Any]],let actions=root["ActionInfo"] as? [[String:Any]] else{throw HardwareError(message:"Windows 动作列表结构无效。")}
            var slots:[Int:Int]=[:]
            for slot in 0..<126 {
                if let trigger=try WindowsProfile.resolveHostTextTrigger(eventValue:0x700+slot,factoryKeymap:factoryKeymap){slots[trigger.logicalIndex]=slot}
            }
            var selected:[HostTextBinding]=[],removed:[Int]=[],target=baseline
            for (logical,key) in keys.enumerated() {
                if try WindowsProfile.integer(key["ActionLink"] ?? 0,"ActionLink",range:0...1)==0 {
                    if let slot=slots[logical],Array(baseline.keymap[slot*3..<slot*3+3])==[0xA1,0,0],let assignment=key["Assignment"] {
                        guard KeymapWriteAuthorization.editableSlots.contains(slot) else{throw HardwareError(message:"隐藏或内部文本位置不能还原。")}
                        let value=try WindowsProfile.integer(assignment,"Assignment",range:0...0xFFFFFF)
                        guard value==WindowsProfile.defaults[logical] else{throw HardwareError(message:"解除文本绑定只支持还原默认键，请在按键页单独设置其他功能。")}
                        target.keymap.replaceSubrange(slot*3..<slot*3+3,with:try WindowsProfile.record(value));removed.append(slot)
                    }
                    continue
                }
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
            guard !selected.isEmpty || !removed.isEmpty else{throw HardwareError(message:"配置没有可安装的非空文本绑定或待还原文本键。")}
            before=baseline;expected=target;self.factoryKeymap=factoryKeymap;self.officialJSON=officialJSON
            bindings=selected.sorted{$0.physicalSlot<$1.physicalSlot}
            removedSlots=removed.sorted()
            changedSlots=(bindings.map{$0.physicalSlot}+removed).filter{slot in let range=slot*3..<slot*3+3;return baseline.keymap[range] != target.keymap[range]}.sorted()
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
    static let mediaNames=["媒体播放器","播放 / 暂停","停止播放","上一曲","下一曲","音量降低","音量增加","静音","浏览器主页","网页刷新","网页停止","网页返回","网页向前","网页收藏","网页搜索","我的电脑","计算器","邮件"]
    // MacroControl.xml contains all 18 entries; browser entries 8...14 are
    // initially hidden. Keep their names for imports without advertising them
    // as macOS application shortcuts.
    static let visibleMediaIndices=Array(0...7)+[15,16,17]
    static let modeCodes:[UInt8] = [0,1,2,4,5,6,7,9,10,11,12,13,14,15,16,17,18,19,20,21,3,8,22,23,24]
    // Confirmed JSON getter/setter struct order (seven UInt16 fields), not
    // offsets in the keyboard's USB parameter bank or accepted UI ranges.
    static let systemStageFields=["Repeat","RepeatDelay","Key6Flag","ReportSelectItem","RFReportSelectItem","WFlag","WinFlag"]
    static func systemStageWords(_ root:[String:Any])throws->[UInt16]? {
        guard let value=root["SystemStages"],!(value is NSNull) else{return nil}
        guard let stages=value as? [String:Any] else{throw HardwareError(message:"Windows SystemStages 结构无效。")}
        return try systemStageFields.map{UInt16(try integer(stages[$0],$0,range:0...65535))}
    }
    // KbBasicSetWnd index -> SystemStages.ReportSelectItem, file only.
    static func encodePollingDraft(_ data:Data,index:Int)throws->Data {
        guard (0...3).contains(index)else{throw HardwareError(message:"本型号官方草稿回报率只支持 125、250、500、1000 Hz。")}
        var root=try templateRoot(data)
        guard try systemStageWords(root) != nil,var stages=root["SystemStages"] as? [String:Any]else{throw HardwareError(message:"请先导入包含设备设置的 Windows 官方 JSON。")}
        stages["ReportSelectItem"]=index;root["SystemStages"]=stages
        let output=try JSONSerialization.data(withJSONObject:root,options:[.prettyPrinted,.sortedKeys])
        guard output.count<=1_000_000 else{throw HardwareError(message:"官方配置草稿超过 1 MB。")};return output
    }
    struct Imported {
        let profile:HardwareProfile
        let keyCount:Int
        let macroCount:Int
        let colorCount:Int
        let ignoredKeyCount:Int
        let deferredTextCount:Int
        var summary:String {"已导入 Windows 配置：\(keyCount) 个实体键、\(colorCount) 个颜色、\(macroCount) 个宏（含未绑定）。保留 \(ignoredKeyCount) 个内部／隐藏位置及系统参数；其他未绑定动作未迁移。尚未写入。" + (deferredTextCount>0 ? " \(deferredTextCount) 个文本绑定已分流到文本页；这些键保留当前配置，需另行安装文本。":"")}
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
    // Official bundled defaults contain all models. Extract only an unmodified
    // model47 template; template DeviceBasicInfo is never a USB identity source.
    static func extractDefaultTemplate(_ data:Data)throws->Data {
        guard data.count<=16_000_000,let document=try JSONSerialization.jsonObject(with:data) as? [String:Any],
              let devices=document["Device"] as? [[String:Any]],devices.count<=128 else{throw HardwareError(message:"需要官方 DefaultData 配置文件（不超过 16 MB）。")}
        let matches=devices.filter{$0["//"] as? String=="47"}
        guard matches.count==1 else{throw HardwareError(message:"默认文件必须包含唯一的型号 47。")}
        var root=matches[0]
        guard root["MacroInfo"]==nil || root["MacroInfo"] is NSNull,
              root["ActionInfo"]==nil || root["ActionInfo"] is NSNull || (root["ActionInfo"] as? [[String:Any]])?.isEmpty==true,
              let keys=root["KeyList"] as? [[String:Any]],keys.count==126 else{throw HardwareError(message:"默认文件包含宏或动作，不能作为原始默认配置。")}
        for key in keys {
            guard try integer(key["Assignment"],"Assignment",range:0...0xFFFFFF)==integer(key["DefaultAssignment"],"DefaultAssignment",range:0...0xFFFFFF),
                  try integer(key["ActionLink"] ?? 0,"ActionLink",range:0...1)==0 else{throw HardwareError(message:"默认文件包含修改后的键位。")}
        }
        root["ActionInfo"]=[[String:Any]]()
        let output=try JSONSerialization.data(withJSONObject:root,options:[.sortedKeys,.withoutEscapingSlashes])
        _ = try templateRoot(output)
        let parameters=try prepareOfficialLightingParameters(output,bank:0)
        guard CherryLighting.modes.contains(where:{$0.1==parameters.head[1]}) else{throw HardwareError(message:"默认灯效不在本型号已核对范围。")}
        return output
    }
    static func templateRoot(_ data:Data)throws->[String:Any] {
        guard data.count<=1_000_000,let root=try JSONSerialization.jsonObject(with:data) as? [String:Any],
              root["//"] as? String=="47",let keys=root["KeyList"] as? [[String:Any]],keys.count==126 else{throw HardwareError(message:"需要本型号的官方配置模板（不超过 1 MB）。")}
        for (i,key) in keys.enumerated(){guard try integer(key["DefaultAssignment"],"DefaultAssignment",range:0...0xFFFFFF)==defaults[i] else{throw HardwareError(message:"Windows 键盘布局不匹配。")}}
        _ = try systemStageWords(root)
        return root
    }
    // Validate a portable text draft without a factory read or installed marker.
    static func validateHostTextDefinition(_ data:Data)throws->Int {
        let root=try templateRoot(data)
        guard let actions=root["ActionInfo"] as? [[String:Any]] else{throw HardwareError(message:"文本配置缺少动作列表。")}
        var count=0
        for action in actions {
            if try integer(action["ActionType"],"ActionType",range:0...4)==3 {_ = try HostTextPlan(action:action);count+=1}
        }
        for key in root["KeyList"] as! [[String:Any]] {
            if try integer(key["ActionLink"] ?? 0,"ActionLink",range:0...1)==1 {
                let index=try integer(key["ActionLinkIndex"],"ActionLinkIndex",range:0...max(0,actions.count-1))
                guard actions.indices.contains(index) else{throw HardwareError(message:"文本配置动作引用无效。")}
            }
        }
        return count
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
    static func encodeKeysAndMacros(_ profile:HardwareProfile,template:Data,preservingTextIndices:Set<Int>=[])throws->Data {
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
            if preservingTextIndices.contains(i) || bytes==[0xA1,0,0] {
                guard try integer(keys[i]["ActionLink"] ?? 0,"ActionLink",range:0...1)==1 else{throw HardwareError(message:"文本键缺少官方文本定义，无法导出。")}
                let index=try integer(keys[i]["ActionLinkIndex"],"ActionLinkIndex",range:0...max(0,old.count-1))
                guard old.indices.contains(index),let mapped=remap[index] else{throw HardwareError(message:"文本动作索引无效，无法导出。")}
                let plan=try HostTextPlan(action:old[index])
                guard bytes != [0xA1,0,0] || plan.marker != nil else{throw HardwareError(message:"已安装文本键对应空定义，无法导出。")}
                keys[i]["ActionLinkIndex"]=mapped
            }else if [UInt8(0x70),0x71].contains(bytes[0]){
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
    // Text page definitions are authoritative only for their referenced text
    // keys. Normal edits on those keys must be resolved rather than overwritten.
    static func encodeKeysMacrosAndText(_ profile:HardwareProfile,template:Data,textConfiguration:Data,baseline:HardwareSnapshot)throws->Data {
        try baseline.validate();let snapshot=try profile.resolvedMacros()
        var root=try templateRoot(template);let text=try templateRoot(textConfiguration)
        var keys=root["KeyList"] as! [[String:Any]]
        guard let textActions=text["ActionInfo"] as? [[String:Any]] else{throw HardwareError(message:"文本配置缺少动作列表。")}
        if let value=root["ActionInfo"],!(value is NSNull),!(value is [[String:Any]]){throw HardwareError(message:"Windows 动作结构无效。")}
        var actions=root["ActionInfo"] as? [[String:Any]] ?? [],textIndices:Set<Int>=[],mapped:[Int:Int]=[:]
        for (index,action) in textActions.enumerated(){
            if try integer(action["ActionType"],"ActionType",range:0...4) != 3{continue}
            _ = try HostTextPlan(action:action)
            let canonical=try JSONSerialization.data(withJSONObject:action,options:.sortedKeys)
            if let old=try actions.firstIndex(where:{try JSONSerialization.data(withJSONObject:$0,options:.sortedKeys)==canonical}){mapped[index]=old}
            else{mapped[index]=actions.count;actions.append(action)}
        }
        for (i,key) in (text["KeyList"] as! [[String:Any]]).enumerated(){
            guard try integer(key["ActionLink"] ?? 0,"ActionLink",range:0...1)==1 else{continue}
            let index=try integer(key["ActionLinkIndex"],"ActionLinkIndex",range:0...max(0,textActions.count-1))
            guard textActions.indices.contains(index) else{throw HardwareError(message:"文本配置动作引用无效。")}
            guard let action=mapped[index] else{continue}
            guard let slot=physicalSlot(defaults[i]),![6,71].contains(slot) else{throw HardwareError(message:"内部或隐藏文本键尚不能合并导出。")}
            let bytes=Array(snapshot.keymap[slot*3..<slot*3+3])
            guard bytes==[0xA1,0,0] || bytes==Array(baseline.keymap[slot*3..<slot*3+3]) else{throw HardwareError(message:"同一个键同时有键位／宏修改和文本绑定，请先在对应页面解除冲突再导出。")}
            keys[i]["ActionLink"]=1;keys[i]["ActionLinkIndex"]=action
            keys[i]["Assignment"]=key["Assignment"] ?? key["DefaultAssignment"]
            textIndices.insert(i)
        }
        for i in keys.indices {
            if let slot=physicalSlot(defaults[i]),Array(snapshot.keymap[slot*3..<slot*3+3])==[0xA1,0,0],!textIndices.contains(i){throw HardwareError(message:"有已安装文本键缺少当前文本定义或待解除，请先核对文本页再导出。")}
        }
        root["KeyList"]=keys;root["ActionInfo"]=actions
        return try encodeKeysAndMacros(profile,template:JSONSerialization.data(withJSONObject:root,options:.sortedKeys),preservingTextIndices:textIndices)
    }
    // File-only head/tail preparation for 500790's traced 01CE branch.
    struct OfficialLightingPlan:Codable,Equatable {
        struct Write:Codable,Equatable{var command:Int;var offset:Int;var flag:Int;var data:[UInt8]}
        struct Stage:Codable,Equatable{var name:String;var beginRequired:Bool;var beginCommand:Int;var writes:[Write];var finishCommand:Int;var finishDelayMilliseconds:Int}
        var format="CherryMacOfficialLightingPlan"
        var version=2
        var hardwareReady=false
        var bank:Int;var transportSelector:Int;var chunkCapacity:Int;var stages:[Stage]
        struct Report:Codable,Equatable {
            var stage:Int;var kind:String;var delayMilliseconds:Int;var request:[UInt8]
            func validateReply(_ reply:[UInt8])throws {
                try CherryPacket.validate(reply,request:request)
                guard reply[4..<8].elementsEqual(request[4..<8])else{throw HardwareError(message:"灯效候选回复的偏移或状态不匹配。")}
            }
        }
        struct RecoveryReview:Codable,Equatable {
            var format="CherryMacLightingRecoveryReview";var version=1;var hardwareReady=false
            var matchedWritePrefixes:[Int];var requiresRecovery:Bool;var restoreData:[Write]
        }
        struct Trace:Codable {
            struct Entry:Codable {var request:[UInt8];var sentMilliseconds:Int;var endedMilliseconds:Int?;var reply:[UInt8]?;var error:String?}
            var format:String;var version:Int;var source:String;var entries:[Entry]
        }
        struct TraceReview:Codable,Equatable {
            var format="CherryMacLightingTraceReview";var version=1;var hardwareReady=false
            var source:String;var status:String;var acceptedReports:Int;var expectedReports:Int;var failedIndex:Int
        }
        struct ExecutionResult {
            var trace:Trace;var current:HardwareSnapshot?;var readbackMatches:Bool;var failure:String;var record:RecoveryRecord
        }
        // Rebuild raw restore reports from the retained original bytes. Never
        // accept caller-supplied restore blocks or run color scaling again.
        struct RecoveryPlan:Codable {
            var format="CherryMacLightingRestorePlan";var version=1;var hardwareReady=false
            var sourceRecord:RecoveryRecord;var before:HardwareSnapshot
            func reports()throws->[Report]{
                guard format=="CherryMacLightingRestorePlan",version==1,!hardwareReady else{throw HardwareError(message:"灯效恢复计划格式无效。")}
                _ = try sourceRecord.assess()
                let plan=sourceRecord.plan,review=try plan.recoveryReview(original:sourceRecord.original,current:before)
                var result:[Report]=[]
                for (index,stage) in plan.stages.enumerated(){
                    let writes=review.restoreData.filter{write in stage.writes.contains{$0.command==write.command && $0.offset==write.offset}}
                    guard !writes.isEmpty else{continue}
                    if stage.beginRequired{result.append(.init(stage:index,kind:"begin",delayMilliseconds:0,request:try CherryPacket.make(UInt8(stage.beginCommand))))}
                    for write in writes{result.append(.init(stage:index,kind:"data",delayMilliseconds:0,request:try CherryPacket.make(UInt8(write.command),payload:[UInt8(write.data.count),UInt8(write.offset&255),UInt8(write.offset>>8),UInt8(write.flag)]+write.data)))}
                    result.append(.init(stage:index,kind:"finish",delayMilliseconds:stage.finishDelayMilliseconds,request:try CherryPacket.make(UInt8(stage.finishCommand))))
                }
                return result
            }
            struct Progress:Codable {
                var format="CherryMacLightingRestoreProgress";var version=1;var hardwareReady=false
                var matchedWritePrefixes:[Int];var configurationMatchesOriginal:Bool
            }
            struct Assessment:Codable{var reports:[Report];var progress:Progress}
            struct Attempt:Codable {
                var format="CherryMacLightingRestoreAttempt";var version=1;var hardwareReady=false
                var operationID:String;var recovery:RecoveryPlan;var started:HardwareSnapshot
                var trace:Trace;var current:HardwareSnapshot?;var failure:String
                struct Assessment:Codable{var format="CherryMacLightingRestoreAssessment";var version=1;var hardwareReady=false;var traceReview:TraceReview;var configurationMatchesOriginal:Bool;var status:String;var recoveryStatus:String}
                func assess()throws->Assessment {
                    let allowed=CharacterSet(charactersIn:"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
                    guard format=="CherryMacLightingRestoreAttempt",version==1,!hardwareReady,!operationID.isEmpty,operationID.utf8.count<=128,operationID.unicodeScalars.allSatisfy({allowed.contains($0)}),failure.utf8.count<=4096 else{throw HardwareError(message:"恢复执行记录格式无效。")}
                    let initial=try recovery.reviewProgress(started),packets=initial.configurationMatchesOriginal ? []:try recovery.reports()
                    let review=try OfficialLightingPlan.reviewTrace(trace,expected:packets)
                    var matches=false,recoveryStatus="unavailable"
                    if let current {
                        try current.validate();guard current.colors != nil,current.macroData != nil else{throw HardwareError(message:"恢复记录读回不完整。")}
                        matches=recovery.sourceRecord.plan.sameConfiguration(current,recovery.sourceRecord.original)
                        do{_ = try recovery.reviewProgress(current);recoveryStatus=matches ? "unchanged":"available"}catch{recoveryStatus="unrecognized"}
                    }
                    let status = !failure.isEmpty || review.status=="failed" ? "failed":review.status != "complete" ? "incomplete":!matches ? "readbackMismatch":initial.configurationMatchesOriginal ? "alreadyMatched":"readbackMatched"
                    return .init(traceReview:review,configurationMatchesOriginal:matches,status:status,recoveryStatus:recoveryStatus)
                }
            }
            func execute(source:String,operationID:String=UUID().uuidString,assertCurrent:()throws->Void,cancelled:()->Bool,
                         read:()throws->HardwareSnapshot,backup:(HardwareSnapshot)throws->Void,persist:(Attempt)throws->Void,
                         clock:()->Int,wait:(Int)throws->Void,exchange:([UInt8])throws->[UInt8])throws->Attempt {
                func check()throws{try assertCurrent();guard !cancelled() else{throw HardwareError(message:"灯效恢复已取消。")}}
                _ = try reports();try check();let fresh=try read(),progress=try reviewProgress(fresh)
                let packets=progress.configurationMatchesOriginal ? []:try reports()
                var attempt=Attempt(operationID:operationID,recovery:self,started:fresh,trace:.init(format:"CherryMacLightingTrace",version:1,source:source,entries:[]),failure:"")
                _ = try attempt.assess();try backup(fresh);try persist(attempt);try check()
                let verified=try read();try verified.validate()
                guard sourceRecord.plan.sameConfiguration(fresh,verified) else{throw HardwareError(message:"恢复备份后配置发生变化，未发送。")}
                for packet in packets {
                    do{try check();try wait(packet.delayMilliseconds);try check()}catch{attempt.failure=error.localizedDescription;break}
                    let index=attempt.trace.entries.count
                    attempt.trace.entries.append(.init(request:packet.request,sentMilliseconds:clock()))
                    _ = try attempt.assess();try persist(attempt)
                    do{try check();attempt.trace.entries[index].reply=try exchange(packet.request)}catch{attempt.trace.entries[index].error=error.localizedDescription}
                    attempt.trace.entries[index].endedMilliseconds=clock()
                    let review=try attempt.assess();try persist(attempt)
                    if review.traceReview.status=="failed"{attempt.failure=attempt.trace.entries[index].error ?? "恢复回复校验失败。";break}
                }
                do{try assertCurrent();let value=try read();try value.validate();try assertCurrent();attempt.current=value}
                catch{if attempt.failure.isEmpty{attempt.failure=error.localizedDescription}}
                let finalReview=try attempt.assess()
                if attempt.failure.isEmpty && !finalReview.configurationMatchesOriginal{attempt.failure="恢复读回与原始备份不一致。"}
                _ = try attempt.assess();try persist(attempt);return attempt
            }
            func reviewProgress(_ current:HardwareSnapshot)throws->Progress {
                let packets=try reports();try current.validate()
                guard current.colors != nil,current.macroData != nil else{throw HardwareError(message:"恢复读回缺少完整配置。")}
                let plan=sourceRecord.plan;var state=before,matched:[Int]=[],count=0
                if plan.sameConfiguration(state,current){matched.append(0)}
                for packet in packets where packet.kind=="data"{
                    let bytes=packet.request,offset=Int(bytes[5])+Int(bytes[6])*256,length=Int(bytes[4])
                    state=plan.applying(.init(command:Int(bytes[3]),offset:offset,flag:Int(bytes[7]),data:Array(bytes[8..<8+length])),to:state);count+=1
                    if plan.sameConfiguration(state,current){matched.append(count)}
                }
                guard !matched.isEmpty else{throw HardwareError(message:"配置不是本次恢复的完整分块前缀，停止覆盖。")}
                return .init(matchedWritePrefixes:matched,configurationMatchesOriginal:plan.sameConfiguration(current,sourceRecord.original))
            }
        }
        final class CandidateAuthorization {
            private let packets:[Report]
            private var index=0
            private var invalidated=false
            init(plan:OfficialLightingPlan,baseline:HardwareSnapshot)throws{
                _ = try plan.expectedReadback(from:baseline)
                guard baseline.deviceInfo[6]==24,plan.bank==0,plan.transportSelector==0,plan.chunkCapacity==56,plan.stages.allSatisfy({$0.beginRequired}) else{throw HardwareError(message:"灯效研究仅允许指定固件、配置 0 和已打开 USB 路径的完整开始／结束布局。")}
                packets=try plan.reports()
            }
            init(recovery:RecoveryPlan)throws{
                packets=try recovery.reports()
                let plan=recovery.sourceRecord.plan
                guard recovery.before.deviceInfo[6]==24,plan.bank==0,plan.transportSelector==0,plan.chunkCapacity==56,plan.stages.allSatisfy({$0.beginRequired}) else{throw HardwareError(message:"灯效恢复研究范围或开始布局无效。")}
            }
            func validate(_ request:[UInt8])throws{
                guard !invalidated,index<packets.count,request==packets[index].request else{throw HardwareError(message:"灯效报告偏离本次计划顺序或会话已失效，停止发送。")}
            }
            func accept(_ reply:[UInt8],request:[UInt8])throws{
                do{try validate(request);try packets[index].validateReply(reply);index+=1}catch{invalidated=true;throw error}
            }
            func invalidate(){invalidated=true}
            var complete:Bool{!invalidated && index==packets.count}
        }
        struct RecoveryRecord:Codable {
            var format="CherryMacLightingRecoveryRecord";var version=1;var hardwareReady=false
            var operationID:String;var plan:OfficialLightingPlan;var original:HardwareSnapshot
            var trace:Trace;var current:HardwareSnapshot?;var failure:String
            struct Assessment:Codable {
                var format="CherryMacLightingRecordAssessment";var version=1;var hardwareReady=false
                var operationID:String;var status:String;var traceReview:TraceReview;var readbackMatches:Bool
                var recoveryStatus:String;var matchedWritePrefixes:[Int];var restoreData:[Write]
            }
            func assess()throws->Assessment {
                let allowed=CharacterSet(charactersIn:"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
                guard format=="CherryMacLightingRecoveryRecord",version==1,!hardwareReady,!operationID.isEmpty,operationID.utf8.count<=128,operationID.unicodeScalars.allSatisfy({allowed.contains($0)}),failure.utf8.count<=4096 else{throw HardwareError(message:"灯效恢复记录格式无效。")}
                let target=try plan.expectedReadback(from:original),review=try plan.reviewTrace(trace)
                var matches=false,recoveryStatus="unavailable",prefixes:[Int]=[],restore:[Write]=[]
                if let current {
                    try current.validate();guard current.colors != nil,current.macroData != nil else{throw HardwareError(message:"灯效恢复记录缺少完整读回。")}
                    matches=plan.sameConfiguration(current,target)
                    do{let recovery=try plan.recoveryReview(original:original,current:current);recoveryStatus=recovery.requiresRecovery ? "available":"unchanged";prefixes=recovery.matchedWritePrefixes;restore=recovery.restoreData}
                    catch{recoveryStatus="unrecognized"}
                }
                let status = !failure.isEmpty || review.status=="failed" ? "failed":review.status != "complete" ? "incomplete":matches ? "readbackMatched":"readbackMismatch"
                return .init(operationID:operationID,status:status,traceReview:review,readbackMatches:matches,recoveryStatus:recoveryStatus,matchedWritePrefixes:prefixes,restoreData:restore)
            }
        }
        // Injectable transport: this method installs no USB authorization itself.
        // The caller must exclusively own one current device/session. Durable
        // pending records precede exchange, so a crash cannot hide an attempt.
        func executeCandidate(baseline:HardwareSnapshot,source:String,operationID:String=UUID().uuidString,
                              assertCurrent:()throws->Void,cancelled:()->Bool,
                              read:()throws->HardwareSnapshot,
                              backup:(HardwareSnapshot)throws->Void,
                              persist:(RecoveryRecord)throws->Void,clock:()->Int,
                              wait:(Int)throws->Void,exchange:([UInt8])throws->[UInt8])throws->ExecutionResult {
            let packets=try reports(),target=try expectedReadback(from:baseline)
            var trace=Trace(format:"CherryMacLightingTrace",version:1,source:source,entries:[])
            _ = try reviewTrace(trace)
            func record(_ current:HardwareSnapshot?=nil,_ failure:String="")->RecoveryRecord{.init(operationID:operationID,plan:self,original:baseline,trace:trace,current:current,failure:failure)}
            _ = try record().assess()
            func check()throws{try assertCurrent();guard !cancelled() else{throw HardwareError(message:"灯效流程已取消。")}}
            try check();let fresh=try read();try fresh.validate()
            guard sameConfiguration(fresh,baseline) else{throw HardwareError(message:"灯效基线已改变，请重新读取。")}
            try backup(fresh);try persist(record());try check()
            let afterBackup=try read();try afterBackup.validate()
            guard sameConfiguration(afterBackup,baseline) else{throw HardwareError(message:"备份后配置发生变化，未发送灯效指令。")}
            var failure=""
            for packet in packets {
                do{try check();try wait(packet.delayMilliseconds);try check()}catch{failure=error.localizedDescription;break}
                let index=trace.entries.count
                trace.entries.append(.init(request:packet.request,sentMilliseconds:clock()))
                _ = try reviewTrace(trace);try persist(record())
                do{try check();let reply=try exchange(packet.request);trace.entries[index].reply=reply}
                catch{trace.entries[index].error=error.localizedDescription}
                trace.entries[index].endedMilliseconds=clock()
                let assessment=try reviewTrace(trace);try persist(record())
                if assessment.status=="failed"{failure=trace.entries[index].error ?? "灯效回复校验失败。";break}
            }
            var current:HardwareSnapshot?
            do{try assertCurrent();let value=try read();try value.validate();try assertCurrent();current=value}
            catch{if failure.isEmpty{failure=error.localizedDescription}}
            let matches=current.map{sameConfiguration($0,target)} ?? false
            if failure.isEmpty && !matches{failure="灯效读回与目标不一致。"}
            let final=record(current,failure);_ = try final.assess();try persist(final)
            return .init(trace:trace,current:current,readbackMatches:failure.isEmpty && matches,failure:failure,record:final)
        }
        // A trace is untrusted evidence, never permission to send or proof of
        // persistence. A pending/failed exchange must be the final entry.
        func reviewTrace(_ trace:Trace)throws->TraceReview {try Self.reviewTrace(trace,expected:reports())}
        private static func reviewTrace(_ trace:Trace,expected:[Report])throws->TraceReview {
            guard trace.format=="CherryMacLightingTrace",trace.version==1,["simulation","usbTrace"].contains(trace.source),trace.entries.count<=expected.count else{throw HardwareError(message:"灯效日志格式无效。")}
            var accepted=0,previousEnd=0,status="incomplete",failedIndex = -1
            for (index,entry) in trace.entries.enumerated(){
                let report=expected[index],last=index==trace.entries.count-1
                guard entry.request==report.request,entry.sentMilliseconds>=previousEnd,entry.sentMilliseconds<=9_007_199_254_740_991,entry.sentMilliseconds-previousEnd>=report.delayMilliseconds else{throw HardwareError(message:"灯效日志指令、顺序或结束等待时间不匹配。")}
                if let end=entry.endedMilliseconds {
                    guard end>=entry.sentMilliseconds,end<=9_007_199_254_740_991,(entry.reply != nil) != (entry.error != nil) else{throw HardwareError(message:"灯效日志回复或时钟无效。")}
                    previousEnd=end
                    if let error=entry.error {
                        guard !error.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,last else{throw HardwareError(message:"灯效日志在失败后仍继续发送。")}
                        status="failed";failedIndex=index
                    } else {
                        do{try report.validateReply(entry.reply!);accepted+=1}
                        catch{guard last else{throw HardwareError(message:"灯效日志在无效回复后仍继续发送。")};status="failed";failedIndex=index}
                    }
                } else {
                    guard entry.reply==nil,entry.error==nil,last else{throw HardwareError(message:"灯效日志缺少回复后仍继续发送。")}
                }
            }
            if accepted==expected.count{status="complete"}
            return .init(source:trace.source,status:status,acceptedReports:accepted,expectedReports:expected.count,failedIndex:failedIndex)
        }
        private func applying(_ write:Write,to snapshot:HardwareSnapshot)->HardwareSnapshot {
            var result=snapshot;let range=write.offset..<write.offset+write.data.count
            if write.command==6{result.parameters.replaceSubrange(range,with:write.data)}
            else{result.colors!.replaceSubrange(range,with:write.data)}
            return result
        }
        private func sameConfiguration(_ first:HardwareSnapshot,_ second:HardwareSnapshot)->Bool {
            var normalized=first;normalized.createdAt=second.createdAt;return normalized==second
        }
        // Current snapshots read only bank zero. Other banks need their own
        // independently read baseline; never reuse bank-zero data for them.
        func expectedReadback(from baseline:HardwareSnapshot)throws->HardwareSnapshot {
            _ = try reports();try baseline.validate()
            guard bank==0,baseline.parameters[0]==0,baseline.colors != nil,baseline.macroData != nil else{throw HardwareError(message:"读回模型仅支持有完整基线的配置 0，不能推断其他配置区。")}
            return stages.flatMap{$0.writes}.reduce(baseline){applying($1,to:$0)}
        }
        // Conservative offline review: recognize whole-data-write prefixes,
        // not arbitrary byte mixtures. It does not authorize a restore.
        func recoveryReview(original:HardwareSnapshot,current:HardwareSnapshot)throws->RecoveryReview {
            _ = try expectedReadback(from:original);try current.validate()
            let writes=stages.flatMap{$0.writes};var state=original,matched:[Int]=[]
            if sameConfiguration(current,state){matched.append(0)}
            for (index,write) in writes.enumerated(){state=applying(write,to:state);if sameConfiguration(current,state){matched.append(index+1)}}
            guard !matched.isEmpty else{throw HardwareError(message:"当前配置不是本次原表／目标或完整分块前缀，停止自动恢复分析。")}
            let restore=writes.compactMap{write->Write? in
                let range=write.offset..<write.offset+write.data.count
                let old=write.command==6 ? Array(original.parameters[range]):Array(original.colors![range])
                let now=write.command==6 ? Array(current.parameters[range]):Array(current.colors![range])
                return old==now ? nil:Write(command:write.command,offset:write.offset,flag:write.flag,data:old)
            }
            return .init(matchedWritePrefixes:matched,requiresRecovery:!sameConfiguration(current,original),restoreData:restore)
        }
        // Offline rendering only. Rebuild the bounded stage graph before
        // accepting a saved/mutable plan; never pass this to a USB sender.
        func reports()throws->[Report]{
            guard format=="CherryMacOfficialLightingPlan",version==2,!hardwareReady,(0...127).contains(bank),(0...1).contains(transportSelector),(1...56).contains(chunkCapacity),let parameters=stages.first,parameters.writes.count>=3 else{throw HardwareError(message:"灯效候选计划格式无效。")}
            let head=parameters.writes.dropLast(2).flatMap{$0.data},tail=parameters.writes[parameters.writes.count-2].data
            guard head.count==9,head[0]==UInt8(bank),CherryLighting.modes.contains(where:{$0.1==head[1]}),head[2]<=4,head[3]<=4,head[4]<=1,head[5]<=1,tail.count==1 else{throw HardwareError(message:"灯效候选参数布局无效。")}
            let begin=transportSelector==1 ? 0x81:1,finish=transportSelector==1 ? 0x82:2,flag=transportSelector==1 ? 0:0x55
            func chunks(_ command:Int,_ offset:Int,_ flag:Int,_ data:[UInt8])->[Write]{stride(from:0,to:data.count,by:chunkCapacity).map{start in .init(command:command,offset:offset+start,flag:flag,data:Array(data[start..<min(data.count,start+chunkCapacity)]))}}
            let writes=chunks(6,bank*64,flag,head)+chunks(6,bank*64+21,flag,tail)+chunks(6,bank*64+24,flag,[1])
            var expected=[Stage(name:"parameters",beginRequired:parameters.beginRequired,beginCommand:begin,writes:writes,finishCommand:finish,finishDelayMilliseconds:10)]
            if head[1]==8 {
                guard stages.count==2 else{throw HardwareError(message:"缺少独立颜色阶段。")}
                let colors=stages[1].writes.flatMap{$0.data}
                guard colors.count==378 else{throw HardwareError(message:"颜色阶段长度无效。")}
                expected.append(.init(name:"customColors",beginRequired:parameters.beginRequired,beginCommand:begin,writes:chunks(transportSelector==1 ? 0x8B:0x0B,bank*512,0,colors),finishCommand:finish,finishDelayMilliseconds:10))
            }
            guard stages==expected else{throw HardwareError(message:"灯效候选计划的指令顺序或写入范围被修改。")}
            var result:[Report]=[]
            for (index,stage) in stages.enumerated(){
                if stage.beginRequired{result.append(.init(stage:index,kind:"begin",delayMilliseconds:0,request:try CherryPacket.make(UInt8(stage.beginCommand))))}
                for write in stage.writes{result.append(.init(stage:index,kind:"data",delayMilliseconds:0,request:try CherryPacket.make(UInt8(write.command),payload:[UInt8(write.data.count),UInt8(write.offset&255),UInt8(write.offset>>8),UInt8(write.flag)]+write.data)))}
                result.append(.init(stage:index,kind:"finish",delayMilliseconds:stage.finishDelayMilliseconds,request:try CherryPacket.make(UInt8(stage.finishCommand))))
            };return result
        }
    }
    static func restorePlanFromRecord(_ data:Data)throws->OfficialLightingPlan.RecoveryPlan {
        guard data.count<=3_000_000 else{throw HardwareError(message:"灯效恢复记录超过 3 MB。")}
        let root=try JSONSerialization.jsonObject(with:data) as? [String:Any]
        let plan:OfficialLightingPlan.RecoveryPlan;let state:String
        if root?["format"] as? String=="CherryMacLightingRestoreAttempt" {
            let attempt=try JSONDecoder().decode(OfficialLightingPlan.RecoveryPlan.Attempt.self,from:data),assessment=try attempt.assess()
            state=assessment.recoveryStatus;plan=attempt.recovery
        } else {
            let record=try JSONDecoder().decode(OfficialLightingPlan.RecoveryRecord.self,from:data),assessment=try record.assess()
            state=assessment.recoveryStatus
            guard let current=record.current else{throw HardwareError(message:"记录没有完整读回，不能生成恢复计划。")}
            plan = .init(sourceRecord:record,before:current)
        }
        guard ["available","unchanged"].contains(state)else{throw HardwareError(message:state=="unrecognized" ? "记录包含范围外或无法识别的变化，不能生成恢复计划。":"记录没有完整读回，不能生成恢复计划。")}
        _ = try plan.reports();return plan
    }
    static func restorePlanFromRecord(_ data:Data,current:HardwareSnapshot)throws->OfficialLightingPlan.RecoveryPlan {
        guard data.count<=3_000_000 else{throw HardwareError(message:"灯效恢复记录超过 3 MB。")}
        let root=try JSONSerialization.jsonObject(with:data) as? [String:Any],encoder=JSONEncoder()
        let prepared:Data
        if root?["format"] as? String=="CherryMacLightingRestoreAttempt" {
            var attempt=try JSONDecoder().decode(OfficialLightingPlan.RecoveryPlan.Attempt.self,from:data)
            _ = try attempt.assess();attempt.current=current;prepared=try encoder.encode(attempt)
        } else {
            var record=try JSONDecoder().decode(OfficialLightingPlan.RecoveryRecord.self,from:data)
            _ = try record.assess();record.current=current;prepared=try encoder.encode(record)
        }
        return try restorePlanFromRecord(prepared)
    }
    // Import only the lighting section. Existing action indices must continue
    // to refer to the current template, not the selected file's action list.
    static func importLightingDraft(_ data:Data,into profile:HardwareProfile)throws->HardwareProfile {
        try profile.validate();let source=try templateRoot(data)
        guard let light=source["LightInfo"] as? [String:Any] else{throw HardwareError(message:"官方配置缺少灯效设置。")}
        let mode=modeCodes[try integer(light["SelectItem"],"SelectItem",range:0...24)]
        guard CherryLighting.modes.contains(where:{$0.1==mode})else{throw HardwareError(message:"此灯效模式尚未支持。")}
        var result=profile
        let parameters:[UInt8]=[mode,
            UInt8(try integer(light["Light"],"Light",range:0...4)),
            UInt8(4 - (try integer(light["Speed"],"Speed",range:0...4))),
            UInt8(try integer(light["Fx"],"Fx",range:0...1)),
            UInt8(try integer(light["MultiColor"],"MultiColor",range:0...1))] +
            (try ["Red","Green","Blue"].map{UInt8(try integer(light[$0],$0,range:0...255))})
        result.snapshot.parameters.replaceSubrange(1..<9,with:parameters)
        result.snapshot.parameters[21]=UInt8(try integer(light["LightOpenFlag"],"LightOpenFlag",range:0...255))
        var root=try profile.windowsTemplateJSON.map{try templateRoot(Data($0.utf8))} ?? source
        if profile.windowsTemplateJSON==nil{root.removeValue(forKey:"SystemStages")}
        root["LightInfo"]=light
        if let custom=source["CustomLightMode"] {
            guard let value=custom as? [String:Any],let groups=value["LightColorInfo"] as? [[[String:Any]]],groups.count==1,groups[0].count==126,result.snapshot.colors != nil else{throw HardwareError(message:"官方配色需要完整的 126 项颜色表和当前颜色区。")}
            let mapping=try profile.lightingMapping?.slots(for:profile.snapshot)
            for (index,entry) in groups[0].enumerated(){
                let bytes=try ["Red","Green","Blue"].map{UInt8(try integer(entry[$0],$0,range:0...255))}
                if let alpha=entry["Alpha"]{_ = try integer(alpha,"Alpha",range:0...255)}
                if let slot=(mapping == nil ? physicalSlot(defaults[index]):mapping![index]){result.snapshot.colors!.replaceSubrange(slot*3..<slot*3+3,with:bytes)}
            }
            root["CustomLightMode"]=value;result.lightingColorEncoding = .officialRGB
        }else if mode==8{throw HardwareError(message:"自定义模式缺少官方原始颜色表。")}
        let encoded=try JSONSerialization.data(withJSONObject:root,options:[.sortedKeys])
        _ = try templateRoot(encoded);result.windowsTemplateJSON=String(decoding:encoded,as:UTF8.self)
        try result.validate();return result
    }
    struct DefaultColorPlan:Codable {
        var hardwareReady=false;var logicalEntryCount=126
        var pendingTransportIntegration=true
        var redLogicalIndices=[44,64,65,66,96,113,114,115]
        var coefficient=255;var targetColors:[UInt8]
        var mappedColorSlots:[Int];var changedColorSlots:[Int]
    }
    struct DefaultConfigurationReview:Codable {
        var format="CherryMacDefaultConfigurationReview";var version=4;var hardwareReady=false
        var original:HardwareSnapshot;var candidate:HardwareSnapshot
        var officialTemplateJSON:String;var factoryKeymap:[UInt8]
        var lightingPlan:OfficialLightingPlan;var changedKeySlots:[Int]
        var defaultColorPlan:DefaultColorPlan
        var changedParameterOffsets:[Int];var protectedChangedSlots:[Int]
        var macroBindingSlots:[Int];var unsupportedFactorySlots:[Int]
        var pendingSystemFields:[String];var retainedMacroStorage=true
        var pendingColorRestore=true;var pendingMacroStorageSemantics=true
        var completeRestoreImplemented=false
    }
    // Offline candidate only. Neither this report nor read metadata grants IO.
    static func reviewDefaultConfiguration(_ data:Data,baseline:HardwareSnapshot,mapping:LightingMappingContext)throws->DefaultConfigurationReview {
        try baseline.validate();let colorSlots=try mapping.slots(for:baseline)
        guard baseline.deviceInfo[6]==24,baseline.deviceInfo[5]==126,baseline.parameters[0]==0,let originalColors=baseline.colors,baseline.macroData != nil else{throw HardwareError(message:"默认恢复核对需要本型号配置 0 的完整读取基线。")}
        let template=try extractDefaultTemplate(data)
        let plan=try planOfficialLighting(template,baseline:baseline,lightingMapping:mapping,bank:0,transportSelector:0,chunkCapacity:56,beginRequired:true)
        var candidate=try plan.expectedReadback(from:baseline)
        candidate.keymap=mapping.factoryKeymap;try candidate.validate()
        // Model 47 registers 126 entries; 541330 resizes the color vector.
        // 4FA0E0 replaces RGBA, then 501190 scales by alpha >> 8.
        // This color stage is separate from the parameter-only lightingPlan.
        let red:Set<Int>=[44,64,65,66,96,113,114,115]
        var proposedColors=[UInt8](repeating:0,count:378),mapped=Set<Int>()
        for (logical,slot) in colorSlots.enumerated(){
            guard let slot=slot else{continue};mapped.insert(slot)
            proposedColors[slot*3]=254
            proposedColors[slot*3+1]=red.contains(logical) ? 0:254
            proposedColors[slot*3+2]=red.contains(logical) ? 0:254
        }
        let colorPlan=DefaultColorPlan(targetColors:proposedColors,mappedColorSlots:mapped.sorted(),changedColorSlots:(0..<126).filter{proposedColors[$0*3..<$0*3+3] != originalColors[$0*3..<$0*3+3]})
        candidate.colors=proposedColors;try candidate.validate()
        let changed=(0..<126).filter{slot in candidate.keymap[slot*3..<slot*3+3] != baseline.keymap[slot*3..<slot*3+3]}
        let protected=changed.filter{!KeymapWriteAuthorization.editableSlots.contains($0)}
        let macros=changed.filter{[UInt8(0x70),0x71].contains(baseline.keymap[$0*3])}
        let unsupported=changed.filter{slot in
            let offset=slot*3,type=candidate.keymap[offset],usage=candidate.keymap[offset+2]
            return !(type==0x30 || (type==0x20 && (usage==0 || (4..<224).contains(usage))))
        }
        return .init(original:baseline,candidate:candidate,officialTemplateJSON:String(decoding:template,as:UTF8.self),factoryKeymap:mapping.factoryKeymap,lightingPlan:plan,changedKeySlots:changed,defaultColorPlan:colorPlan,changedParameterOffsets:(0..<56).filter{candidate.parameters[$0] != baseline.parameters[$0]},protectedChangedSlots:protected,macroBindingSlots:macros,unsupportedFactorySlots:unsupported,pendingSystemFields:systemStageFields)
    }
    struct LightingDraftReview:Codable {
        var format="CherryMacLightingDraftReview";var version=1;var hardwareReady=false
        var plan:OfficialLightingPlan;var original:HardwareSnapshot;var target:HardwareSnapshot
        var changedParameterOffsets:[Int];var changedColorSlots:[Int]
    }
    static func reviewLightingDraft(_ profile:HardwareProfile,baseline:HardwareSnapshot)throws->LightingDraftReview {
        try profile.validate();try baseline.validate();try profile.snapshot.validate()
        guard profile.snapshot.deviceInfo==baseline.deviceInfo,let template=profile.windowsTemplateJSON else{throw HardwareError(message:"请先读取键盘并导入本型号的 Windows 官方 JSON。")}
        if profile.snapshot.parameters[1]==8,profile.lightingMapping==nil{throw HardwareError(message:"逐键写入核对需要读取灯光映射。")}
        let data=try encodeProfileLightingDraft(profile,template:Data(template.utf8))
        let plan=try planOfficialLighting(data,baseline:baseline,lightingMapping:profile.lightingMapping,bank:0,transportSelector:0,chunkCapacity:56,beginRequired:true)
        let target=try plan.expectedReadback(from:baseline)
        return .init(plan:plan,original:baseline,target:target,changedParameterOffsets:(0..<56).filter{baseline.parameters[$0] != target.parameters[$0]},changedColorSlots:(0..<126).filter{slot in baseline.colors![slot*3..<slot*3+3] != target.colors![slot*3..<slot*3+3]})
    }
    // A candidate sequence for the traced parameter/custom-load methods only.
    // This is not HardwareWritePlan and cannot authorize any USB operation.
    static func planOfficialLighting(_ data:Data,baseline:HardwareSnapshot,lightingMapping:LightingMappingContext?,bank:Int,transportSelector:Int,chunkCapacity:Int,beginRequired:Bool)throws->OfficialLightingPlan {
        try baseline.validate()
        guard baseline.colors != nil,baseline.macroData != nil,(0...127).contains(bank),(0...1).contains(transportSelector),(1...56).contains(chunkCapacity)else{throw HardwareError(message:"需要完整基线，且配置地址、传输分支和报告容量须在离线计划范围内。")}
        if let lightingMapping{_ = try lightingMapping.slots(for:baseline)}
        let parameters=try prepareOfficialLightingParameters(data,bank:bank)
        guard CherryLighting.modes.contains(where:{$0.1==parameters.head[1]})else{throw HardwareError(message:"此灯效不在本型号已核对的模式列表中。")}
        let finish=transportSelector==1 ? 0x82:2,flag=transportSelector==1 ? 0:0x55
        func chunks(_ command:Int,_ offset:Int,_ flag:Int,_ bytes:[UInt8])->[OfficialLightingPlan.Write]{
            stride(from:0,to:bytes.count,by:chunkCapacity).map{start in .init(command:command,offset:offset+start,flag:flag,data:Array(bytes[start..<min(bytes.count,start+chunkCapacity)]))}
        }
        var writes=chunks(6,bank*64,flag,parameters.head)
        writes+=chunks(6,bank*64+21,flag,[parameters.lightOpenFlag])
        writes+=chunks(6,bank*64+24,flag,[1])
        let begin=transportSelector==1 ? 0x81:1
        var stages=[OfficialLightingPlan.Stage(name:"parameters",beginRequired:beginRequired,beginCommand:begin,writes:writes,finishCommand:finish,finishDelayMilliseconds:10)]
        if parameters.head[1]==8 {
            guard let lightingMapping else{throw HardwareError(message:"官方逐键颜色计划需要有效 LED 映射。")}
            let colors=try prepareOfficialCustomColors(data,baseline:baseline,lightingMapping:lightingMapping)
            stages.append(.init(name:"customColors",beginRequired:beginRequired,beginCommand:begin,writes:chunks(transportSelector==1 ? 0x8B:0x0B,bank*512,0,colors),finishCommand:finish,finishDelayMilliseconds:10))
        }
        return .init(bank:bank,transportSelector:transportSelector,chunkCapacity:chunkCapacity,stages:stages)
    }
    // Bank is an explicit caller input, not an inference from a read-back bank.
    static func prepareOfficialLightingParameters(_ data:Data,bank:Int)throws->(head:[UInt8],lightOpenFlag:UInt8){
        let root=try templateRoot(data)
        guard (0...255).contains(bank),let light=root["LightInfo"] as? [String:Any]else{throw HardwareError(message:"需要完整官方灯效参数和可表示为单字节的配置编号。")}
        let selected=try integer(light["SelectItem"],"SelectItem",range:0...24)
        let brightness=try integer(light["Light"],"Light",range:0...4),speed=try integer(light["Speed"],"Speed",range:0...4)
        let direction=try integer(light["Fx"],"Fx",range:0...1),multi=try integer(light["MultiColor"],"MultiColor",range:0...1)
        let colors=try ["Red","Green","Blue"].map{UInt8(try integer(light[$0],$0,range:0...255))}
        let flag=UInt8(try integer(light["LightOpenFlag"],"LightOpenFlag",range:0...255))
        return ([UInt8(bank),modeCodes[selected],UInt8(brightness),UInt8(4-speed),UInt8(direction),UInt8(multi)]+colors,flag)
    }
    // Offline preparation for the specifically traced custom-color load path.
    // Existing read-back colors are never globally rescaled. The traced official
    // method starts with a zeroed buffer, including unmapped LED positions.
    static func prepareOfficialCustomColors(_ data:Data,baseline:HardwareSnapshot,lightingMapping:LightingMappingContext)throws->[UInt8]{
        try baseline.validate();let root=try templateRoot(data)
        guard let light=root["LightInfo"] as? [String:Any],try integer(light["SelectItem"],"SelectItem",range:0...24)==21,
              let custom=root["CustomLightMode"] as? [String:Any],let groups=custom["LightColorInfo"] as? [[[String:Any]]],groups.count==1,groups[0].count==126,
              baseline.colors != nil else{throw HardwareError(message:"官方颜色准备仅支持完整的自定义颜色配置和当前颜色表。")}
        var result=Array(repeating:UInt8(0),count:378)
        let level=try integer(light["Light"],"Light",range:0...4),coefficient=CherryLighting.officialBrightnessCoefficients[level]
        let slots=try lightingMapping.slots(for:baseline)
        for (index,color) in groups[0].enumerated(){
            let raw=try ["Red","Green","Blue"].map{try integer(color[$0],$0,range:0...255)}
            if let alpha=color["Alpha"]{_ = try integer(alpha,"Alpha",range:0...255)}
            guard let slot=slots[index]else{continue}
            result.replaceSubrange(slot*3..<slot*3+3,with:raw.map{UInt8(($0*coefficient)>>8)})
        };return result
    }
    // File-only draft export. Parameters outside 1...8 and unmapped logical
    // template colors remain untouched; this does not authorize a lighting write.
    // Product exports must never reinterpret brightness-scaled readback RGB as raw RGB.
    static func encodeProfileLightingDraft(_ profile:HardwareProfile,template:Data)throws->Data {
        try profile.validate();var root=try templateRoot(template)
        if profile.lightingColorEncoding == .officialRGB,root["CustomLightMode"] is [String:Any] {
            return try encodeLightingDraft(profile.snapshot,template:template,lightingMapping:profile.lightingMapping)
        }
        let p=profile.snapshot.parameters
        guard p[1] != 8 else{throw HardwareError(message:"自定义配色需要先导入 Windows 官方原始配色；读回或来源未知的 RGB 不能直接导出，以免重复降低亮度。")}
        guard var light=root["LightInfo"] as? [String:Any],CherryLighting.modes.contains(where:{$0.1==p[1]}),let selected=modeCodes.firstIndex(of:p[1]),p[2]<=4,p[3]<=4,p[4]<=1,p[5]<=1 else{throw HardwareError(message:"当前灯效参数或官方模板无效，不能导出。")}
        light["SelectItem"]=selected;light["Light"]=Int(p[2]);light["Speed"]=4-Int(p[3]);light["Fx"]=Int(p[4]);light["MultiColor"]=Int(p[5])
        light["LightOpenFlag"]=Int(p[21])
        for (offset,name) in ["Red","Green","Blue"].enumerated(){light[name]=Int(p[6+offset])}
        root["LightInfo"]=light
        let output=try JSONSerialization.data(withJSONObject:root,options:[.prettyPrinted,.sortedKeys])
        guard output.count<=1_000_000 else{throw HardwareError(message:"导出的官方配置文件过大。")};return output
    }
    static func encodeLightingDraft(_ snapshot:HardwareSnapshot,template:Data,lightingMapping:LightingMappingContext?=nil)throws->Data {
        try snapshot.validate();var root=try templateRoot(template)
        guard var light=root["LightInfo"] as? [String:Any],var custom=root["CustomLightMode"] as? [String:Any],
              var groups=custom["LightColorInfo"] as? [[[String:Any]]],groups.count==1,groups[0].count==126,
              let colors=snapshot.colors else{throw HardwareError(message:"导出灯效需要完整读取配色和带 126 项颜色表的官方模板。")}
        let mapping=try lightingMapping?.slots(for:snapshot)
        let p=snapshot.parameters
        guard CherryLighting.modes.contains(where:{$0.1==p[1]}),let selected=modeCodes.firstIndex(of:p[1]),p[2]<=4,p[3]<=4,p[4]<=1,p[5]<=1 else{throw HardwareError(message:"当前灯效参数超出本型号已核对范围，不能导出。")}
        light["SelectItem"]=selected;light["Light"]=Int(p[2]);light["Speed"]=4-Int(p[3]);light["Fx"]=Int(p[4]);light["MultiColor"]=Int(p[5])
        light["LightOpenFlag"]=Int(p[21])
        for (offset,name) in ["Red","Green","Blue"].enumerated(){light[name]=Int(p[6+offset])}
        for i in groups[0].indices {
            for name in ["Red","Green","Blue"]{_ = try integer(groups[0][i][name],name,range:0...255)}
            if let alpha=groups[0][i]["Alpha"]{_ = try integer(alpha,"Alpha",range:0...255)}
            guard let slot=(mapping == nil ? physicalSlot(defaults[i]):mapping![i]) else{continue}
            for (offset,name) in ["Red","Green","Blue"].enumerated(){groups[0][i][name]=Int(colors[slot*3+offset])}
        }
        custom["LightColorInfo"]=groups;root["LightInfo"]=light;root["CustomLightMode"]=custom
        let output=try JSONSerialization.data(withJSONObject:root,options:[.prettyPrinted,.sortedKeys])
        guard output.count<=1_000_000 else{throw HardwareError(message:"导出的官方配置文件过大。")};return output
    }
    static func decode(_ data:Data,baseline:HardwareSnapshot,deferHostText:Bool=false,lightingMapping:LightingMappingContext?=nil)throws->Imported {
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
        let lightingSlots=try lightingMapping?.slots(for:baseline)
        var result=try HardwareProfile.fromHardware(baseline)
        result.lightingMapping=lightingMapping
        result.windowsTemplateJSON=String(decoding:try JSONSerialization.data(withJSONObject:root,options:.sortedKeys),as:UTF8.self)
        let oldBindings=result.macroBindings ?? [:],oldModes=result.macroModes ?? [:]
        if deferHostText,try validateHostTextDefinition(data)>0 {result.hostTextJSON=result.windowsTemplateJSON}
        let physicalSlots=Set(defaults.compactMap{physicalSlot($0)})
        // Replace the imported physical bindings while preserving any raw hidden data.
        result.macroBindings=oldBindings.filter{!physicalSlots.contains($0.key)}
        result.macroModes=(result.macroModes ?? [:]).filter{!physicalSlots.contains($0.key)}
        var importedMacros:[Int:String]=[:];var keyCount=0;var colorCount=0;var ignored=0;var deferredTextCount=0
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
                    if deferHostText {
                        // Keep the live binding until the separate text installer owns it.
                        if let name=oldBindings[slot]{result.macroBindings![slot]=name}
                        if let mode=oldModes[slot]{result.macroModes![slot]=mode}
                        deferredTextCount += 1;continue
                    }
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
            // Preserve the current byte when an older file omits the field.
            // Its representation is known; physical on/off semantics are not.
            if let flag=lighting["LightOpenFlag"]{result.snapshot.parameters[21]=UInt8(try integer(flag,"LightOpenFlag",range:0...255))}
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
                let bytes=try ["Red","Green","Blue"].map{UInt8(try integer(entry[$0],$0,range:0...255))}
                if let alpha=entry["Alpha"]{_ = try integer(alpha,"Alpha",range:0...255)}
                guard let slot=(lightingSlots == nil ? physicalSlot(defaults[index]):lightingSlots![index])else{continue}
                result.snapshot.colors!.replaceSubrange(slot*3..<slot*3+3,with:bytes);colorCount+=1
            }
            result.lightingColorEncoding = .officialRGB
        }
        // Rebuild only when bindings changed; an import without macros must
        // preserve the original bank and its reserved bytes byte-for-byte.
        if result.macroBindings != oldBindings || !importedMacros.isEmpty {result.snapshot=try result.resolvedMacros()}
        try result.validate()
        return Imported(profile:result,keyCount:keyCount,macroCount:importedMacros.count,colorCount:colorCount,ignoredKeyCount:ignored,deferredTextCount:deferredTextCount)
    }
}
