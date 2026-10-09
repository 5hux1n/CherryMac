import Foundation

// Storage schema for all bytes of the four known configuration regions.
// No capture implementation, prefix conversion, tail inference or identity
// record coverage. A valid file alone is never permission to reset/pair/restore.
struct ReceiverPairingConfigurationRegions:Codable,Equatable {
    let format:String
    let version:Int
    let scope:String
    let vendorID:Int
    let productID:Int
    let createdAtMilliseconds:Double
    let deviceInfo:[UInt8]
    let parameters:[UInt8]
    let keymap:[UInt8]
    let colors:[UInt8]
    let macroData:[UInt8]
    struct RegionError:LocalizedError {
        var errorDescription:String?{"完整配置区记录的型号、范围或数据长度无效。"}
    }
    var includesWirelessIdentityRecords:Bool{false}
    var authorizesPairing:Bool{false}
    func validate()throws{
        guard format=="CherryMacFullConfigurationRegions",version==1,scope=="keyboard-configuration-regions",
              vendorID==0x046a,productID==0x01ce,createdAtMilliseconds.isFinite,createdAtMilliseconds>=0,
              deviceInfo.count==34,parameters.count==64,keymap.count==512,colors.count==512,macroData.count==3072 else{
            throw RegionError()
        }
    }
    func hasSameRegionData(as other:Self)throws->Bool{
        try validate();try other.validate()
        return deviceInfo==other.deviceInfo && parameters==other.parameters && keymap==other.keymap
            && colors==other.colors && macroData==other.macroData
    }
    private enum CodingKeys:String,CodingKey,CaseIterable{
        case format,version,scope,vendorID,productID,createdAtMilliseconds,deviceInfo,parameters,keymap,colors,macroData
    }
    private struct AnyKey:CodingKey{
        let stringValue:String
        var intValue:Int?{nil}
        init?(stringValue:String){self.stringValue=stringValue}
        init?(intValue:Int){return nil}
    }
    init(format:String,version:Int,scope:String,vendorID:Int,productID:Int,createdAtMilliseconds:Double,
         deviceInfo:[UInt8],parameters:[UInt8],keymap:[UInt8],colors:[UInt8],macroData:[UInt8])throws{
        self.format=format;self.version=version;self.scope=scope;self.vendorID=vendorID;self.productID=productID
        self.createdAtMilliseconds=createdAtMilliseconds;self.deviceInfo=deviceInfo;self.parameters=parameters
        self.keymap=keymap;self.colors=colors;self.macroData=macroData;try validate()
    }
    init(from decoder:Decoder)throws{
        let all=try decoder.container(keyedBy:AnyKey.self),c=try decoder.container(keyedBy:CodingKeys.self)
        guard Set(all.allKeys.map(\.stringValue))==Set(CodingKeys.allCases.map(\.rawValue)) else{throw RegionError()}
        try self.init(format:c.decode(String.self,forKey:.format),version:c.decode(Int.self,forKey:.version),
            scope:c.decode(String.self,forKey:.scope),vendorID:c.decode(Int.self,forKey:.vendorID),productID:c.decode(Int.self,forKey:.productID),
            createdAtMilliseconds:c.decode(Double.self,forKey:.createdAtMilliseconds),deviceInfo:c.decode([UInt8].self,forKey:.deviceInfo),
            parameters:c.decode([UInt8].self,forKey:.parameters),keymap:c.decode([UInt8].self,forKey:.keymap),
            colors:c.decode([UInt8].self,forKey:.colors),macroData:c.decode([UInt8].self,forKey:.macroData))
    }
    func encode(to encoder:Encoder)throws{
        try validate();var c=encoder.container(keyedBy:CodingKeys.self)
        try c.encode(format,forKey:.format);try c.encode(version,forKey:.version);try c.encode(scope,forKey:.scope)
        try c.encode(vendorID,forKey:.vendorID);try c.encode(productID,forKey:.productID)
        try c.encode(createdAtMilliseconds,forKey:.createdAtMilliseconds);try c.encode(deviceInfo,forKey:.deviceInfo)
        try c.encode(parameters,forKey:.parameters);try c.encode(keymap,forKey:.keymap)
        try c.encode(colors,forKey:.colors);try c.encode(macroData,forKey:.macroData)
    }
}
