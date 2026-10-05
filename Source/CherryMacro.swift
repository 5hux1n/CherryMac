import Foundation

// Derived independently from the supplied CHERRY Utility's serializer.
// Report 14 reads up to 54 bytes; the final capacity byte is rejected by this
// firmware. None of these pure codec functions communicates with the device.
struct MacroPlayback: Codable, Equatable {
    enum Mode: String, Codable {case count, held, toggle}
    var mode:Mode = .count
    var count:Int = 1
    static let once=MacroPlayback()
    func validate() throws {
        guard (1...255).contains(count),mode == .count || count == 1 else{throw HardwareError(message:"宏执行次数须为 1–255；持续与开关模式不使用次数。")}
    }
    var label:String{mode == .held ? "按住持续":mode == .toggle ? "再次按键停止":"执行 \(count) 次"}
}

enum CherryMacroCodec {
    static let accessibleSize=3071
    static func encodeEvents(_ macro:KeyboardMacro,maximumEvents:Int = 256) throws -> [UInt8] {
        try macro.validate(maximumEvents:maximumEvents)
        return macro.steps.flatMap{step -> [UInt8] in
            let modifier=step.kind == nil && (224...231).contains(step.usage)
            let kind:UInt8=step.kind == .mouse ? 1:(modifier ? 9:10)
            let code:UInt8=modifier ? UInt8(1 << Int(step.usage-224)):step.usage
            return [UInt8(step.delayMilliseconds & 255),UInt8(step.delayMilliseconds >> 8),kind | (step.pressed ? 0x80:0),code]
        }
    }
    static func decodeEvents(_ bytes:[UInt8],name:String,maximumEvents:Int = 256) throws -> KeyboardMacro {
        guard !bytes.isEmpty,bytes.count % 4==0,(1...762).contains(maximumEvents),bytes.count<=maximumEvents*4 else{throw HardwareError(message:"硬件宏事件长度无效。")}
        let steps=try stride(from:0,to:bytes.count,by:4).map{index -> KeyboardMacro.Step in
            let kind=bytes[index+2] & 0x7F;let code=bytes[index+3];let usage:UInt8
            if kind==1 {
                guard [UInt8(1),2,4,8,16].contains(code)else{throw HardwareError(message:"鼠标宏按钮编码无效。")};usage=code
            }else if kind==10 {
                guard code<224 else{throw HardwareError(message:"普通键宏包含无效修饰键编码。")};usage=code
            }else if kind==9 {
                guard code.nonzeroBitCount==1 else{throw HardwareError(message:"修饰键宏编码必须只有一个位。")};usage=224+UInt8(code.trailingZeroBitCount)
            }else{throw HardwareError(message:"硬件宏包含尚未支持的事件类型 \(kind)。原始备份仍保留。")}
            return .init(usage:usage,pressed:bytes[index+2] & 0x80 != 0,delayMilliseconds:Int(bytes[index]) | Int(bytes[index+1])<<8,kind:kind==1 ? .mouse:nil)
        }
        let macro=KeyboardMacro(name:name,steps:steps);try macro.validate(maximumEvents:maximumEvents);return macro
    }
    static func encode(_ macros:[KeyboardMacro],headerReserved:[UInt8] = []) throws -> [UInt8] {
        guard headerReserved.isEmpty || headerReserved.count==10 else{throw HardwareError(message:"宏头部保留数据长度无效。")}
        guard macros.count<=32 else{throw HardwareError(message:"硬件宏数量超出范围。")}
        if macros.isEmpty{return Array(repeating:0,count:accessibleSize)}
        let events=try macros.map{try encodeEvents($0)}
        let total=16+macros.count*6+events.reduce(0){$0+$1.count}
        guard total<=accessibleSize else{throw HardwareError(message:"宏超过键盘的存储容量。")}
        var bank=[UInt8](repeating:0,count:accessibleSize)
        func word(_ offset:Int,_ value:Int){bank[offset]=UInt8(value & 255);bank[offset+1]=UInt8(value >> 8)}
        bank[0]=0xAA;bank[1]=0x55;word(2,total);word(4,macros.count)
        if !headerReserved.isEmpty{bank.replaceSubrange(6..<16,with:headerReserved)}
        var cursor=16+macros.count*2
        for (index,bytes) in events.enumerated(){
            word(16+index*2,cursor);word(cursor,bytes.count/4)
            if let reserved=macros[index].hardwareReserved{bank.replaceSubrange(cursor+2..<cursor+4,with:reserved)}
            bank.replaceSubrange(cursor+4..<cursor+4+bytes.count,with:bytes);cursor += 4+bytes.count
        }
        return bank
    }
    static func decode(_ bytes:[UInt8],maximumRecords:Int = 32,maximumEvents:Int = 256) throws -> [KeyboardMacro] {
        guard (1...126).contains(maximumRecords),(1...762).contains(maximumEvents) else{throw HardwareError(message:"宏解析范围无效。")}
        guard bytes.count==accessibleSize else{throw HardwareError(message:"宏备份长度与目标固件不符。")}
        if bytes.allSatisfy({$0==0}) || bytes.allSatisfy({$0==255}){return []}
        func word(_ offset:Int)->Int{Int(bytes[offset]) | Int(bytes[offset+1])<<8}
        guard bytes[0]==0xAA,bytes[1]==0x55 else{throw HardwareError(message:"宏存储头部尚未识别。原始备份仍保留。")}
        let length=word(2),count=word(4)
        guard count<=maximumRecords,length>=16+count*2,length<=bytes.count else{throw HardwareError(message:"宏头部数量或长度无效。")}
        var cursor=16+count*2;var macros:[KeyboardMacro]=[]
        for index in 0..<count {
            let start=word(16+index*2)
            guard start>=cursor,start+4<=length else{throw HardwareError(message:"宏偏移重叠或越界。")}
            let steps=word(start),end=start+4+steps*4
            guard steps>0,steps<=maximumEvents,end<=length else{throw HardwareError(message:"宏事件越界或数量无效。")}
            var macro=try decodeEvents(Array(bytes[start+4..<end]),name:"硬件宏 \(index+1)",maximumEvents:maximumEvents)
            let reserved=Array(bytes[start+2..<start+4]);if reserved.contains(where:{$0 != 0}){macro.hardwareReserved=reserved}
            macros.append(macro);cursor=end
        }
        return macros
    }
    // Nominal event-delay budget after all trigger bindings have been disabled.
    // Actual execution timing and stop behavior still require hardware testing.
    static func completionRequirements(keymap:[UInt8],macros:[KeyboardMacro])throws->MacroCompletionRequirements {
        guard keymap.count==378 else{throw HardwareError(message:"宏键位表长度无效。")}
        var result=MacroCompletionRequirements()
        for slot in 0..<126 where [UInt8(0x70),0x71].contains(keymap[slot*3]) {
            let record=Array(keymap[slot*3..<slot*3+3]),mode=try playback(record,macroCount:macros.count)
            let macro=macros[Int(record[1])];try macro.validate()
            let cycle=macro.steps.reduce(0){$0+$1.delayMilliseconds}
            if mode.mode == .count{result.finiteDurationMilliseconds=max(result.finiteDurationMilliseconds,cycle*mode.count)}
            else{result.repeatingBindings.append(.init(slot:slot,macro:macro,playback:mode,quietMilliseconds:cycle+200))}
        }
        return result
    }
    static func finiteDurationMilliseconds(keymap:[UInt8],macros:[KeyboardMacro]) throws -> Int {
        let result=try completionRequirements(keymap:keymap,macros:macros)
        guard result.repeatingBindings.isEmpty else{throw HardwareError(message:"持续与开关宏需要先确认停止，不能使用有限等待流程。")}
        return result.finiteDurationMilliseconds
    }
    static func binding(_ index:Int,playback:MacroPlayback = .once) throws -> [UInt8] {
        guard (0..<32).contains(index)else{throw HardwareError(message:"宏索引无效。")}
        try playback.validate()
        if playback.mode == .count{return playback.count==1 ? [0x70,UInt8(index),0]:[0x71,UInt8(index),UInt8(playback.count)]}
        return [0x70,UInt8(index),playback.mode == .held ? 1:2]
    }
    static func playback(_ record:[UInt8],macroCount:Int) throws -> MacroPlayback {
        guard record.count==3,Int(record[1])<macroCount else{throw HardwareError(message:"宏绑定引用无效。")}
        if record[0]==0x70,record[2]<=2{return MacroPlayback(mode:[.count,.held,.toggle][Int(record[2])],count:1)}
        if record[0]==0x71,record[2]>=2{return MacroPlayback(mode:.count,count:Int(record[2]))}
        throw HardwareError(message:"未知宏执行方式，原始数据保留。")
    }
}

// Focused recorder state only: callers supply observed events and a monotonic
// millisecond clock. No hooks, HID writes, or synthesized release events.
struct MacroRecorder {
    enum Timing:String {case actual,fixed,ignore}
    let timing:Timing
    let fixedMilliseconds:Int
    private(set) var active=true
    private(set) var steps:[KeyboardMacro.Step]=[]
    private var held=Set<Int>()
    private var lastMilliseconds:Int
    init(timing:Timing,fixedMilliseconds:Int=0,startedMilliseconds:Int)throws{
        guard (0...60000).contains(fixedMilliseconds),startedMilliseconds>=0 else{throw HardwareError(message:"录制间隔或时钟无效。")}
        self.timing=timing;self.fixedMilliseconds=fixedMilliseconds;lastMilliseconds=startedMilliseconds
    }
    mutating func observe(usage:UInt8,kind:KeyboardMacro.Step.Kind?=nil,pressed:Bool,milliseconds:Int,repeatEvent:Bool=false)throws{
        guard active else{throw HardwareError(message:"录制已停止。")}
        guard milliseconds>=lastMilliseconds,(kind == .mouse ? [UInt8(1),2,4,8,16].contains(usage):(4...231).contains(usage)) else{throw HardwareError(message:"录制事件或时钟无效。")}
        let identity=Int(usage)+(kind == .mouse ? 256:0)
        if repeatEvent || (pressed ? held.contains(identity):!held.contains(identity)){return}
        guard steps.count<256 else{throw HardwareError(message:"录制最多 256 个事件，请取消或缩短操作。")}
        let delay=timing == .fixed ? fixedMilliseconds:timing == .ignore ? 0:min(60000,milliseconds-lastMilliseconds)
        // USB execution captures associate the delay with the preceding event.
        // Ignore recorder startup latency and leave the final event at zero.
        if !steps.isEmpty{steps[steps.count-1].delayMilliseconds=delay}
        steps.append(.init(usage:usage,pressed:pressed,delayMilliseconds:0,kind:kind))
        if pressed{held.insert(identity)}else{held.remove(identity)}
        lastMilliseconds=milliseconds
    }
    mutating func finish(name:String,originalSteps:[KeyboardMacro.Step]=[],insertionIndex:Int?=nil)throws->KeyboardMacro{
        guard active,held.isEmpty else{throw HardwareError(message:"请先松开全部录制按键，再停止录制。")}
        guard !steps.isEmpty else{throw HardwareError(message:"请先录制至少一个操作。")}
        var merged=steps
        if let insertionIndex{guard (0...originalSteps.count).contains(insertionIndex) else{throw HardwareError(message:"录制插入位置无效。")};merged=originalSteps;merged.insert(contentsOf:steps,at:insertionIndex)}
        let result=KeyboardMacro(name:name,steps:merged,recordingDelay:.init(fixed:timing == .fixed,milliseconds:fixedMilliseconds))
        try result.validate();active=false;return result
    }
    mutating func cancel(){active=false;steps=[];held=[]}
}

// Passive execution evidence. It observes no devices, synthesizes no input,
// and grants no write permission. Timing is diagnostic until firmware semantics
// are measured; an elapsed delay alone can never produce a passing result.
struct MacroExecutionEvidence {
    enum Source:String,Codable {case hid,focusedBrowser,simulation}
    enum StopSource:String,Codable {case physicalTriggerObserved,userAcknowledged,simulation}
    enum Interruption:String,Codable {case observerDisconnected,focusLost,loggingFailed,cancelled,reportRejected}
    struct Observation:Codable,Equatable {
        var usage:UInt8
        var pressed:Bool
        var milliseconds:Int
        var kind:KeyboardMacro.Step.Kind? = nil
        var identity:String{"\(kind == .mouse ? "mouse":"key"):\(usage)"}
    }
    struct Assessment:Codable,Equatable {
        let status:String
        let passed:Bool
        let source:Source
        let stopSource:StopSource?
        let scope:String
        let completedCycles:Int
        let matchedEvents:Int
        let observedEvents:Int
        let eventsAfterStop:Int
        let held:[String]
        let quietMilliseconds:Int
        let requiredQuietMilliseconds:Int
        let failure:String?
    }
    let macro:KeyboardMacro
    let playback:MacroPlayback
    let source:Source
    let requiredQuietMilliseconds:Int
    private(set) var observations:[Observation]=[]
    private var held=Set<String>()
    private var lastMilliseconds:Int
    private var matchedEvents=0,observedEvents=0,eventsAfterStop=0
    private var stopMilliseconds:Int?,stopSource:StopSource?
    private var failure:String?
    init(macro:KeyboardMacro,playback:MacroPlayback,source:Source,startedMilliseconds:Int)throws {
        try macro.validate();try playback.validate()
        guard startedMilliseconds>=0 else{throw HardwareError(message:"执行观察时钟无效。")}
        self.macro=macro;self.playback=playback;self.source=source;lastMilliseconds=startedMilliseconds
        requiredQuietMilliseconds=max(200,macro.steps.reduce(0){$0+$1.delayMilliseconds}+200)
    }
    private mutating func fail(_ reason:String){if failure==nil{failure=reason}}
    mutating func invalidate(_ reason:Interruption){fail(reason.rawValue)}
    mutating func observe(_ event:Observation)throws {
        guard event.milliseconds>=lastMilliseconds,(event.kind == .mouse ? [UInt8(1),2,4,8,16].contains(event.usage):(4...231).contains(event.usage)) else {
            fail("invalidObservation");throw HardwareError(message:"执行观察事件或时钟无效。")
        }
        lastMilliseconds=event.milliseconds;observedEvents+=1
        if observations.count<65536{observations.append(event)}else{fail("captureOverflow")}
        let wasHeld=held.contains(event.identity)
        if event.pressed ? wasHeld:!wasHeld{fail("unbalancedObservation")}
        if stopMilliseconds != nil{eventsAfterStop+=1;if event.pressed{fail("pressAfterStop")}}
        if failure==nil {
            let expected=macro.steps[matchedEvents % macro.steps.count]
            let matches=expected.usage==event.usage && expected.kind==event.kind && expected.pressed==event.pressed
            let beyondCount=playback.mode == .count && matchedEvents>=macro.steps.count*playback.count
            if beyondCount{fail("extraEvent")}
            else if matches{matchedEvents+=1}
            else if stopMilliseconds==nil{fail("unexpectedEvent")}
            // After a stop marker, a release of an actually held key is allowed
            // even when firmware aborts mid-cycle rather than finishing it.
        }
        if event.pressed{held.insert(event.identity)}else{held.remove(event.identity)}
    }
    mutating func requestStop(milliseconds:Int,source:StopSource)throws {
        guard playback.mode != .count,stopMilliseconds==nil,milliseconds>=lastMilliseconds else {
            fail("invalidStopMarker");throw HardwareError(message:"停止标记无效或重复。")
        }
        stopMilliseconds=milliseconds;stopSource=source;lastMilliseconds=milliseconds
    }
    func assessment(milliseconds:Int)throws -> Assessment {
        guard milliseconds>=lastMilliseconds else{throw HardwareError(message:"评估时钟早于最后观察。")}
        let cycles=matchedEvents/macro.steps.count,quiet=milliseconds-lastMilliseconds
        let complete=playback.mode == .count ? matchedEvents==macro.steps.count*playback.count:cycles>=2
        let status:String
        if failure != nil{status="failed"}
        else if !complete{status="waitingOutput"}
        else if playback.mode != .count && stopMilliseconds==nil{status="waitingStop"}
        else if !held.isEmpty{status="waitingRelease"}
        else if quiet<requiredQuietMilliseconds{status="waitingQuiet"}
        else{status="passed"}
        return Assessment(status:status,passed:status=="passed",source:source,stopSource:stopSource,
            scope:"observed events only; no hardware write or power-cycle proof",completedCycles:cycles,
            matchedEvents:matchedEvents,observedEvents:observedEvents,eventsAfterStop:eventsAfterStop,
            held:held.sorted(),quietMilliseconds:quiet,requiredQuietMilliseconds:requiredQuietMilliseconds,failure:failure)
    }
}

struct MacroExecutionLog:Codable {
    struct Stop:Codable {let milliseconds:Int;let source:MacroExecutionEvidence.StopSource}
    let format:String
    let version:Int
    let macro:KeyboardMacro
    let playback:MacroPlayback
    let source:MacroExecutionEvidence.Source
    let startedMilliseconds:Int
    let events:[MacroExecutionEvidence.Observation]
    let stop:Stop?
    let assessedMilliseconds:Int
    let interruptions:[MacroExecutionEvidence.Interruption]?
    func replay()throws -> MacroExecutionEvidence.Assessment {
        guard format=="CherryMacMacroExecution",version==1,events.count<=65536 else{throw HardwareError(message:"宏执行日志格式或长度无效。")}
        var evidence=try MacroExecutionEvidence(macro:macro,playback:playback,source:source,startedMilliseconds:startedMilliseconds)
        guard (interruptions?.count ?? 0)<=16 else{throw HardwareError(message:"执行日志中断标记过多。")}
        for interruption in interruptions ?? []{evidence.invalidate(interruption)}
        var marked=false
        for event in events {
            if let stop,!marked,stop.milliseconds<=event.milliseconds{try evidence.requestStop(milliseconds:stop.milliseconds,source:stop.source);marked=true}
            try evidence.observe(event)
        }
        if let stop,!marked{try evidence.requestStop(milliseconds:stop.milliseconds,source:stop.source)}
        return try evidence.assessment(milliseconds:assessedMilliseconds)
    }
}


struct MacroExecutionReport:Encodable {
    let format="CherryMacMacroExecutionAssessment"
    let version=1
    let inputSHA256:String
    let assessment:MacroExecutionEvidence.Assessment
}

// Normalizes state changes from a device-filtered IOHID value stream. Neutral
// and repeated report values are not new presses; no expected events are
// deleted or rearranged to make the evidence pass.
struct MacroHIDObservationAdapter {
    private var held=Set<String>()
    var allReleased:Bool{held.isEmpty}
    mutating func receive(page:UInt32,usage:UInt32,value:Int,milliseconds:Int)throws -> MacroExecutionEvidence.Observation? {
        let key=page==7 && (4...231).contains(usage)
        let mouse=page==9 && (1...5).contains(usage)
        guard key || mouse else {
            if value != 0 && (page==7 || page==9 || page==12 || (page==1 && [UInt32(0x30),0x31,0x38].contains(usage))) {
                throw HardwareError(message:"观察到尚未支持的 HID 输出，不能按普通键事件通过。")
            }
            return nil
        }
        guard value==0 || value==1,milliseconds>=0 else{throw HardwareError(message:"HID 按钮值或时钟无效。")}
        let code:UInt8=mouse ? UInt8(1 << (usage-1)):UInt8(usage)
        let identity="\(mouse ? "mouse":"key"):\(code)",pressed=value==1
        guard pressed != held.contains(identity) else{return nil}
        if pressed{held.insert(identity)}else{held.remove(identity)}
        return .init(usage:code,pressed:pressed,milliseconds:milliseconds,kind:mouse ? .mouse:nil)
    }
}


// Requirements describe what the stop provider must handle. A nominal budget
// never substitutes for explicit stopping of an unbounded binding.
struct MacroCompletionRequirements:Codable {
    struct RepeatingBinding:Codable {
        let slot:Int
        let macro:KeyboardMacro
        let playback:MacroPlayback
        let quietMilliseconds:Int
    }
    var finiteDurationMilliseconds=0
    var repeatingBindings:[RepeatingBinding]=[]
}
struct MacroStopRequest:Codable {
    enum Phase:String,Codable{case beforeWrite,recovery}
    let phase:Phase
    let configurations:[HardwareSnapshot]
    let requirements:[MacroCompletionRequirements]
}

// Official per-binding layout, deliberately separate from the current shared
// library writer. A layout is data, never an authorization to send HID reports.
struct OfficialMacroStorageLayout:Codable,Equatable {
    struct Record:Codable,Equatable {
        let logicalIndex:Int
        let physicalSlot:Int
        let libraryIndex:Int
        let ordinal:Int
        let offset:Int
        let eventCount:Int
        let binding:[UInt8]
    }
    let hardwareReady:Bool
    let editorEventLimit:Int
    let usedBytes:Int
    let records:[Record]
    // nil means the official sender would return without sending a macro bank.
    let bank:[UInt8]?
    enum CodingKeys:String,CodingKey {case hardwareReady,editorEventLimit,usedBytes,records,bank}
    func encode(to encoder:Encoder)throws {
        var container=encoder.container(keyedBy:CodingKeys.self)
        try container.encode(hardwareReady,forKey:.hardwareReady)
        try container.encode(editorEventLimit,forKey:.editorEventLimit)
        try container.encode(usedBytes,forKey:.usedBytes)
        try container.encode(records,forKey:.records)
        // Match Web's explicit null: it means no macro-bank send, not omission
        // of an unknown bank or a request to clear the original storage.
        if let bank{try container.encode(bank,forKey:.bank)}else{try container.encodeNil(forKey:.bank)}
    }
    static func prepare(macros:[KeyboardMacro],bindings:[Int:String],modes:[Int:MacroPlayback],
                        factoryKeymap:[UInt8],deviceInfo:[UInt8],headerReserved:[UInt8]=[])throws->Self {
        guard factoryKeymap.count==378,deviceInfo.count==34,deviceInfo[6]==24,
              headerReserved.isEmpty || headerReserved.count==10 else {
            throw HardwareError(message:"官方宏布局需要本型号完整默认键位表、容量信息和有效保留数据。")
        }
        let editorLimit=(Int(deviceInfo[6])*128-22)/4
        guard Set(macros.map{$0.name}).count==macros.count else{throw HardwareError(message:"宏名称不能重复。")}
        for macro in macros{try macro.validate(maximumEvents:editorLimit)}
        guard modes.keys.allSatisfy({bindings[$0] != nil}) else{throw HardwareError(message:"宏执行方式缺少对应绑定。")}
        var slots:[Int:Int]=[:]
        for (logical,value) in WindowsProfile.firmwareLogicalDefaults.enumerated() {
            if let slot=(0..<126).first(where:{slot in
                let offset=slot*3
                return Int(factoryKeymap[offset])<<16 | Int(factoryKeymap[offset+1])<<8 | Int(factoryKeymap[offset+2])==value
            }) {
                // Ambiguous logical aliases cannot receive a single physical binding.
                if slots[slot] != nil && bindings[slot] != nil{throw HardwareError(message:"默认键位映射含重复逻辑位置，停止宏转换。")}
                if slots[slot]==nil{slots[slot]=logical}
            }
        }
        for (slot,name) in bindings {
            guard (0..<126).contains(slot),![6,71].contains(slot),slots[slot] != nil,
                  macros.contains(where:{$0.name==name}) else{throw HardwareError(message:"宏绑定在固件默认表中没有唯一可配置位置。")}
            try (modes[slot] ?? .once).validate()
        }
        let ordered=bindings.keys.sorted{slots[$0]!<slots[$1]!}
        if ordered.isEmpty{return .init(hardwareReady:false,editorEventLimit:editorLimit,usedBytes:0,records:[],bank:nil)}
        let indices=ordered.map{slot in macros.firstIndex{$0.name==bindings[slot]!}!}
        let events=try indices.map{try CherryMacroCodec.encodeEvents(macros[$0],maximumEvents:editorLimit)}
        let total=16+ordered.count*6+events.reduce(0){$0+$1.count}
        guard total<=CherryMacroCodec.accessibleSize else{throw HardwareError(message:"已绑定宏超过存储容量；同一宏绑定多个键会分别占用空间。")}
        var bank=[UInt8](repeating:0,count:CherryMacroCodec.accessibleSize)
        func word(_ offset:Int,_ value:Int){bank[offset]=UInt8(value & 255);bank[offset+1]=UInt8(value >> 8)}
        bank[0]=0xAA;bank[1]=0x55;word(2,total);word(4,ordered.count)
        if !headerReserved.isEmpty{bank.replaceSubrange(6..<16,with:headerReserved)}
        var cursor=16+ordered.count*2;var records:[Record]=[]
        for (ordinal,slot) in ordered.enumerated(){
            let index=indices[ordinal],macro=macros[index],eventBytes=events[ordinal],mode=modes[slot] ?? .once
            let binding:[UInt8]=mode.mode == .count ? (mode.count==1 ? [0x70,UInt8(ordinal),0]:[0x71,UInt8(ordinal),UInt8(mode.count)]) : [0x70,UInt8(ordinal),mode.mode == .held ? 1:2]
            word(16+ordinal*2,cursor);word(cursor,macro.steps.count)
            if let reserved=macro.hardwareReserved{bank.replaceSubrange(cursor+2..<cursor+4,with:reserved)}
            bank.replaceSubrange(cursor+4..<cursor+4+eventBytes.count,with:eventBytes)
            records.append(.init(logicalIndex:slots[slot]!,physicalSlot:slot,libraryIndex:index,ordinal:ordinal,offset:cursor,eventCount:macro.steps.count,binding:binding))
            cursor += 4+eventBytes.count
        }
        return .init(hardwareReady:false,editorEventLimit:editorLimit,usedBytes:total,records:records,bank:bank)
    }
}

// Portable draft identity. Strict comparison is configuration matching only;
// callers still need an actual USB transaction, backup and physical acceptance.
struct OfficialMacroDraftReceipt:Codable,Equatable {
    let format:String
    let version:Int
    let hardwareReady:Bool
    let before:HardwareSnapshot
    let factoryKeymap:[UInt8]
    let macros:[KeyboardMacro]
    let bindings:[Int:String]
    let modes:[Int:MacroPlayback]
    let layout:OfficialMacroStorageLayout
    let expected:HardwareSnapshot
    static func prepare(before:HardwareSnapshot,factoryKeymap:[UInt8],macros:[KeyboardMacro],
                        bindings:[Int:String],modes:[Int:MacroPlayback])throws->Self {
        try before.validate()
        guard let originalBank=before.macroData else{throw HardwareError(message:"保存宏草稿对应关系需要完整原始宏区。")}
        let header=originalBank[0]==0xAA && originalBank[1]==0x55 ? Array(originalBank[6..<16]):[]
        let layout=try OfficialMacroStorageLayout.prepare(macros:macros,bindings:bindings,modes:modes,
            factoryKeymap:factoryKeymap,deviceInfo:before.deviceInfo,headerReserved:header)
        var expected=before
        // Explicitly removed macro bindings become disabled keys. Ordinary
        // keys remain the baseline; this is a macro-only target, not all drafts.
        for slot in 0..<126 where [UInt8(0x70),0x71].contains(before.keymap[slot*3]) && bindings[slot]==nil {
            guard ![6,71].contains(slot) else{throw HardwareError(message:"原宏覆盖内部键，停止转换。")}
            expected.keymap.replaceSubrange(slot*3..<slot*3+3,with:[UInt8(0x20),0,0])
        }
        for record in layout.records {
            expected.keymap.replaceSubrange(record.physicalSlot*3..<record.physicalSlot*3+3,with:record.binding)
        }
        if let bank=layout.bank{
            var target=originalBank;target.replaceSubrange(0..<layout.usedBytes,with:bank.prefix(layout.usedBytes));expected.macroData=target
        }
        return .init(format:"CherryMacOfficialMacroDraftReceipt",version:1,hardwareReady:false,
            before:before,factoryKeymap:factoryKeymap,macros:macros,bindings:bindings,modes:modes,layout:layout,expected:expected)
    }
    func validate()throws {
        guard format=="CherryMacOfficialMacroDraftReceipt",version==1,!hardwareReady else{throw HardwareError(message:"官方宏草稿记录格式或版本无效。")}
        let rebuilt=try Self.prepare(before:before,factoryKeymap:factoryKeymap,macros:macros,bindings:bindings,modes:modes)
        guard rebuilt==self else{throw HardwareError(message:"宏草稿记录与重新生成的绑定、存储数据不一致。")}
    }
    struct Readback:Codable,Equatable {
        let hardwareReady:Bool
        let configurationMatches:Bool
        let snapshot:HardwareSnapshot
        let macros:[KeyboardMacro]
        let bindings:[Int:String]
        let modes:[Int:MacroPlayback]
        let records:[OfficialMacroStorageLayout.Record]
    }
    func reconcile(observed:HardwareSnapshot,factoryKeymap observedFactory:[UInt8])throws->Readback {
        try validate();try observed.validate()
        guard observedFactory==factoryKeymap,observed.deviceInfo==expected.deviceInfo,
              observed.keymap==expected.keymap,observed.macroData==expected.macroData else {
            throw HardwareError(message:"读回配置与官方宏草稿记录不一致，未采用宏名称或合并草稿。")
        }
        if layout.bank != nil {
            let decoded=try CherryMacroCodec.decode(observed.macroData!,maximumRecords:126,maximumEvents:layout.editorEventLimit)
            guard decoded.count==layout.records.count else{throw HardwareError(message:"宏读回记录数量不一致。")}
            for (index,record) in layout.records.enumerated() {
                guard decoded[index].steps==macros[record.libraryIndex].steps,
                      (decoded[index].hardwareReserved ?? [0,0])==(macros[record.libraryIndex].hardwareReserved ?? [0,0]) else {
                    throw HardwareError(message:"宏事件或保留数据读回不一致。")
                }
            }
        }
        return .init(hardwareReady:false,configurationMatches:true,snapshot:observed,macros:macros,
            bindings:bindings,modes:modes,records:layout.records)
    }
}
