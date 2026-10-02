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
    static func encodeEvents(_ macro:KeyboardMacro) throws -> [UInt8] {
        try macro.validate()
        return macro.steps.flatMap{step -> [UInt8] in
            let modifier=step.kind == nil && (224...231).contains(step.usage)
            let kind:UInt8=step.kind == .mouse ? 1:(modifier ? 9:10)
            let code:UInt8=modifier ? UInt8(1 << Int(step.usage-224)):step.usage
            return [UInt8(step.delayMilliseconds & 255),UInt8(step.delayMilliseconds >> 8),kind | (step.pressed ? 0x80:0),code]
        }
    }
    static func decodeEvents(_ bytes:[UInt8],name:String) throws -> KeyboardMacro {
        guard !bytes.isEmpty,bytes.count % 4==0,bytes.count<=1024 else{throw HardwareError(message:"硬件宏事件长度无效。")}
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
        let macro=KeyboardMacro(name:name,steps:steps);try macro.validate();return macro
    }
    static func encode(_ macros:[KeyboardMacro]) throws -> [UInt8] {
        guard macros.count<=32 else{throw HardwareError(message:"硬件宏数量超出范围。")}
        if macros.isEmpty{return Array(repeating:0,count:accessibleSize)}
        let events=try macros.map{try encodeEvents($0)}
        let total=16+macros.count*6+events.reduce(0){$0+$1.count}
        guard total<=accessibleSize else{throw HardwareError(message:"宏超过键盘的存储容量。")}
        var bank=[UInt8](repeating:0,count:accessibleSize)
        func word(_ offset:Int,_ value:Int){bank[offset]=UInt8(value & 255);bank[offset+1]=UInt8(value >> 8)}
        bank[0]=0xAA;bank[1]=0x55;word(2,total);word(4,macros.count)
        var cursor=16+macros.count*2
        for (index,bytes) in events.enumerated(){
            word(16+index*2,cursor);word(cursor,bytes.count/4)
            bank.replaceSubrange(cursor+4..<cursor+4+bytes.count,with:bytes);cursor += 4+bytes.count
        }
        return bank
    }
    static func decode(_ bytes:[UInt8]) throws -> [KeyboardMacro] {
        guard bytes.count==accessibleSize else{throw HardwareError(message:"宏备份长度与目标固件不符。")}
        if bytes.allSatisfy({$0==0}) || bytes.allSatisfy({$0==255}){return []}
        func word(_ offset:Int)->Int{Int(bytes[offset]) | Int(bytes[offset+1])<<8}
        guard bytes[0]==0xAA,bytes[1]==0x55 else{throw HardwareError(message:"宏存储头部尚未识别。原始备份仍保留。")}
        let length=word(2),count=word(4)
        guard count<=32,length>=16+count*2,length<=bytes.count else{throw HardwareError(message:"宏头部数量或长度无效。")}
        var cursor=16+count*2;var macros:[KeyboardMacro]=[]
        for index in 0..<count {
            let start=word(16+index*2)
            guard start>=cursor,start+4<=length else{throw HardwareError(message:"宏偏移重叠或越界。")}
            let steps=word(start),end=start+4+steps*4
            guard steps>0,steps<=256,end<=length else{throw HardwareError(message:"宏事件越界或数量无效。")}
            macros.append(try decodeEvents(Array(bytes[start+4..<end]),name:"硬件宏 \(index+1)"));cursor=end
        }
        return macros
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
