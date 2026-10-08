import Foundation

struct LightRGB: Equatable {
    let red:UInt8
    let green:UInt8
    let blue:UInt8
    var bytes:[UInt8] {[red,green,blue]}
    var hex:String {String(format:"#%02X%02X%02X",red,green,blue)}
    var strength:Double {Double(max(red,green,blue))*100/255}
    init(_ red:UInt8,_ green:UInt8,_ blue:UInt8){self.red=red;self.green=green;self.blue=blue}
    init(hex:String)throws{
        var text=hex.trimmingCharacters(in:.whitespacesAndNewlines)
        if text.hasPrefix("#"){text.removeFirst()}
        guard text.count==6,text.unicodeScalars.allSatisfy({CharacterSet(charactersIn:"0123456789abcdefABCDEF").contains($0)}),let value=UInt32(text,radix:16)else{throw HardwareError(message:"颜色格式应为六位十六进制，例如 #FFD600。")}
        self.init(UInt8((value>>16)&255),UInt8((value>>8)&255),UInt8(value&255))
    }
    static func hsv(_ hue:Double,_ saturation:Double,_ value:Double)->LightRGB{
        let h=(hue-floor(hue))*6;let s=max(0,min(1,saturation));let v=max(0,min(1,value))
        let c=v*s;let x=c*(1-abs(h.truncatingRemainder(dividingBy:2)-1));let m=v-c
        let values:[Double]
        switch Int(h){case 0:values=[c,x,0];case 1:values=[x,c,0];case 2:values=[0,c,x];case 3:values=[0,x,c];case 4:values=[x,0,c];default:values=[c,0,x]}
        let b=values.map{UInt8(max(0,min(255,(($0+m)*255).rounded())))};return LightRGB(b[0],b[1],b[2])
    }
    func withStrength(_ percent:Double)->LightRGB{
        let peak=Double(max(red,green,blue));let scale=max(0,min(100,percent))/100*255
        if peak==0 {let v=UInt8(scale.rounded());return LightRGB(v,v,v)}
        let b=bytes.map{UInt8(max(0,min(255,(Double($0)/peak*scale).rounded())))};return LightRGB(b[0],b[1],b[2])
    }
    func mix(_ other:LightRGB,_ fraction:Double)->LightRGB{
        let t=max(0,min(1,fraction));let b=zip(bytes,other.bytes).map{UInt8((Double($0)*(1-t)+Double($1)*t).rounded())};return LightRGB(b[0],b[1],b[2])
    }
}

struct LightingColorLibrary:Codable {
    var format="CherryMacLightingColorLibrary";var version=1
    var colors:[String]
    static let defaultColors:[String]=["#FF0000", "#FF7200", "#FFF005", "#00D70F", "#0099FF", "#3153FF", "#5E01D2", "#FF16A9", "#FF008A", "#FFA800", "#8DFF8D", "#3DEFFF", "#004891", "#FFFFFF", "#FFFFFF", "#3153FF", "#5E01D2", "#EE00F1", "#FF008A", "#FFA800"]
    static var defaults:Self{Self(colors:defaultColors)}
    func validate()throws{
        guard format=="CherryMacLightingColorLibrary",version==1,colors.count==20 else{throw HardwareError(message:"颜色收藏必须包含 20 个色卡。")}
        for value in colors{guard value.count==7,value.first=="#",value.dropFirst().unicodeScalars.allSatisfy({CharacterSet(charactersIn:"0123456789ABCDEF").contains($0)}) else{throw HardwareError(message:"收藏颜色格式无效。")}}
    }
    static func decode(_ data:Data)throws->Self{
        guard data.count<=4096 else{throw HardwareError(message:"颜色收藏资料过大。")}
        let value=try JSONDecoder().decode(Self.self,from:data);try value.validate();return value
    }
    func encoded()throws->Data{
        try validate();let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        let data=try encoder.encode(self);guard data.count<=4096 else{throw HardwareError(message:"颜色收藏资料过大。")};return data
    }
    static func load()throws->Self{
        guard let data=UserDefaults.standard.data(forKey:"hardware.lightingColorLibrary")else{return defaults}
        return try decode(data)
    }
    func save()throws{
        try validate();let data=try JSONEncoder().encode(self);let key="hardware.lightingColorLibrary"
        UserDefaults.standard.set(data,forKey:key)
        guard UserDefaults.standard.data(forKey:key)==data else{throw HardwareError(message:"颜色收藏保存核对失败。")}
    }
}

enum CherryLighting {
    // Official DefaultLightName entry 47 for the supplied Pokémon model.
    // Names/codes come from the mode table, not this device's previous mode.
    static let modes:[(String,UInt8)] = [("自定义逐键颜色",8),("波纹",0),("光谱",1),("呼吸",2),("霓虹",10),("曲线",12),("折返",15),("放射",18),("扩散",19),("单点亮",21),("常亮",3),("闪电",23)]
    struct ModeOptions {
        let speed:Bool;let direction:Bool;let rainbow:Bool;let color:Bool
    }
    // Model47 DefaultLightName index -> hardware code, paired with layout 1
    // (443E50) UI branches. Inactive parameters remain in the draft unchanged.
    static func options(for code:UInt8)->ModeOptions? {
        switch code {
        case 0,10,12,18:return .init(speed:true,direction:true,rainbow:true,color:true)
        case 2,19,21:return .init(speed:true,direction:false,rainbow:true,color:true)
        case 15:return .init(speed:false,direction:false,rainbow:true,color:true)
        case 1:return .init(speed:true,direction:false,rainbow:false,color:false)
        case 3,23:return .init(speed:false,direction:false,rainbow:false,color:true)
        case 8:return .init(speed:false,direction:false,rainbow:false,color:false)
        default:return nil
        }
    }
    // Fixed Utility loading paths 505900 / 5059F0 and color method 501190.
    // Use with raw draft RGB only. A read-back bank may already be scaled.
    static let officialBrightnessCoefficients=[0,65,135,195,255]
    static func officialCustomColors(_ raw:[UInt8],brightness:Int)throws->[UInt8]{
        guard raw.count==378,(0...4).contains(brightness)else{throw HardwareError(message:"官方亮度转换需要完整 RGB 表和 0～4 档亮度。")}
        let coefficient=officialBrightnessCoefficients[brightness]
        return raw.map{UInt8((Int($0)*coefficient)>>8)}
    }
    // Returning a range makes the information loss explicit: do not pretend
    // that stored RGB uniquely recovers the original Windows editor color.
    static func officialRawChannelRange(_ stored:UInt8,brightness:Int)throws->ClosedRange<Int>{
        guard (0...4).contains(brightness)else{throw HardwareError(message:"亮度须为 0～4。")}
        let coefficient=officialBrightnessCoefficients[brightness]
        if coefficient==0{guard stored==0 else{throw HardwareError(message:"该颜色无法由零亮度生成。")};return 0...255}
        let lower=(Int(stored)*256+coefficient-1)/coefficient
        let upper=min(255,((Int(stored)+1)*256+coefficient-1)/coefficient-1)
        guard lower<=upper else{throw HardwareError(message:"该颜色超出此档官方亮度能生成的范围。")}
        return lower...upper
    }
    static let patterns=["自定义颜色","横向渐变","纵向渐变","彩虹配色（静态）","皮卡丘配色","喷火龙配色"]
    static let regions=["当前选择","全部按键","主键区","功能键区","数字区","方向键","WASD"]
    static func region(_ index:Int,keys:[KeySpec])->Set<String>{
        let filtered=keys.filter{key in
            switch index {
            case 1:return true
            case 2:return key.rect.minX<576 && key.rect.minY>55
            case 3:return key.rect.minY<55
            case 4:return key.id.hasPrefix("num")
            case 5:return ["up","down","left","right"].contains(key.id)
            case 6:return ["7:26","7:4","7:22","7:7"].contains(key.usage ?? "")
            default:return false
            }
        };return Set(filtered.map{$0.id})
    }
    static func paint(_ source:[UInt8],keys:[KeySpec],selected:Set<String>,pattern:Int,start:LightRGB,end:LightRGB,lightingMapping:LightingMappingContext?=nil)throws->[UInt8]{
        guard source.count==378,(0..<patterns.count).contains(pattern),!selected.isEmpty else{throw HardwareError(message:"请选择按键与配色方式。")}
        let targets=keys.filter{selected.contains($0.id)}
        guard targets.count==selected.count,targets.allSatisfy({CherryMatrix.slot($0) != nil}) else{throw HardwareError(message:"配色选择包含未知按键。")}
        if let lightingMapping{_ = try WindowsProfile.resolveLightingSlots(factoryKeymap:lightingMapping.factoryKeymap,ledIndices:lightingMapping.ledIndices)}
        func slotFor(_ key:KeySpec)->Int?{guard let slot=CherryMatrix.slot(key)else{return nil};if let lightingMapping{return lightingMapping.colorSlot(slot)};return slot}
        guard targets.allSatisfy({slotFor($0) != nil})else{throw HardwareError(message:"所选按键没有有效 LED 映射。")}
        let xs=targets.map{$0.rect.midX},ys=targets.map{$0.rect.midY}
        let minX=xs.min()!,maxX=xs.max()!,minY=ys.min()!,maxY=ys.max()!
        var result=source
        for key in targets {
            let x=Double(maxX==minX ? 0:(key.rect.midX-minX)/(maxX-minX))
            let y=Double(maxY==minY ? 0:(key.rect.midY-minY)/(maxY-minY))
            let rgb:LightRGB
            switch pattern {
            case 1:rgb=start.mix(end,x)
            case 2:rgb=start.mix(end,y)
            case 3:rgb=LightRGB.hsv(x*0.83,1,1)
            case 4:rgb=["esc","calculator"].contains(key.id) ? LightRGB(255,54,44):(key.id.hasPrefix("mod") ? LightRGB(78,54,18):LightRGB(255,214,0))
            case 5:rgb=LightRGB(255,55,0).mix(LightRGB(255,202,32),1-y)
            default:rgb=start
            }
            let slot=slotFor(key)!;result.replaceSubrange(slot*3..<slot*3+3,with:rgb.bytes)
        };return result
    }
}
