import Foundation

// Raw prefixes accessible through the pinned Pokémon 0104 command boundaries.
// This format is deliberately separate from editable HardwareSnapshot: no
// conversion, complete-reset authorization or current-firmware inference.
struct ExtendedHardwareBackup: Codable, Equatable {
    var format = "CherryMacExtendedHardware"
    var version = 1
    var vendorID = 0x046a
    var productID = 0x01ce
    var boundaryModel = "pokemon-0104-static"
    var createdAtMilliseconds: Double
    var deviceInfo: [UInt8]
    var parameters: [UInt8]
    var keymap: [UInt8]
    var colors: [UInt8]
    var macroData: [UInt8]

    struct Coverage: Equatable {
        let region: String
        let storedBytes: Int
        let regionBytes: Int
        var missingOffsets: Range<Int> { storedBytes..<regionBytes }
    }
    func coverage() throws -> [Coverage] {
        try validate()
        return [.init(region:"parameters",storedBytes:parameters.count,regionBytes:64),
         .init(region:"keymap",storedBytes:keymap.count,regionBytes:512),
         .init(region:"colors",storedBytes:colors.count,regionBytes:512),
         .init(region:"macroData",storedBytes:macroData.count,regionBytes:3072)]
    }
    struct InvalidBackup: LocalizedError {
        var errorDescription: String? { "扩展备份型号、边界或数据长度无效。" }
    }
    func validate() throws {
        guard format=="CherryMacExtendedHardware",version==1,vendorID==0x046a,productID==0x01ce,
              boundaryModel=="pokemon-0104-static",createdAtMilliseconds.isFinite,createdAtMilliseconds>=0,
              deviceInfo.count==34,parameters.count==63,keymap.count==511,colors.count==511,macroData.count==3071 else {
            throw InvalidBackup()
        }
    }
    // Compare a normal snapshot to the visible prefixes without dropping the
    // hidden bytes from this record. Timestamp differences do not affect data.
    func matchesVisible(deviceInfo: [UInt8], parameters: [UInt8], keymap: [UInt8],
                        colors: [UInt8], macroData: [UInt8]) throws -> Bool {
        try validate()
        guard deviceInfo.count==34,parameters.count==56,keymap.count==378,colors.count==378,macroData.count==3071 else { throw InvalidBackup() }
        return self.deviceInfo==deviceInfo && self.parameters.prefix(56).elementsEqual(parameters)
            && self.keymap.prefix(378).elementsEqual(keymap) && self.colors.prefix(378).elementsEqual(colors)
            && self.macroData==macroData
    }
    func hasSameCapturedData(as other: Self) throws -> Bool {
        try validate();try other.validate()
        return vendorID==other.vendorID && productID==other.productID && boundaryModel==other.boundaryModel
            && deviceInfo==other.deviceInfo && parameters==other.parameters && keymap==other.keymap
            && colors==other.colors && macroData==other.macroData
    }
}

extension ExtendedHardwareBackup {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case format, version, vendorID, productID, boundaryModel, createdAtMilliseconds
        case deviceInfo, parameters, keymap, colors, macroData
    }
    private struct AnyKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    init(from decoder: Decoder) throws {
        let all=try decoder.container(keyedBy:AnyKey.self)
        guard Set(all.allKeys.map(\.stringValue))==Set(CodingKeys.allCases.map(\.rawValue)) else { throw InvalidBackup() }
        let values=try decoder.container(keyedBy:CodingKeys.self)
        format=try values.decode(String.self,forKey:.format)
        version=try values.decode(Int.self,forKey:.version)
        vendorID=try values.decode(Int.self,forKey:.vendorID)
        productID=try values.decode(Int.self,forKey:.productID)
        boundaryModel=try values.decode(String.self,forKey:.boundaryModel)
        createdAtMilliseconds=try values.decode(Double.self,forKey:.createdAtMilliseconds)
        deviceInfo=try values.decode([UInt8].self,forKey:.deviceInfo)
        parameters=try values.decode([UInt8].self,forKey:.parameters)
        keymap=try values.decode([UInt8].self,forKey:.keymap)
        colors=try values.decode([UInt8].self,forKey:.colors)
        macroData=try values.decode([UInt8].self,forKey:.macroData)
        try validate()
    }
}
