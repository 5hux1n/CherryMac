import Foundation
import IOKit
import IOKit.hid
import CryptoKit

// Descriptor-only inventory. No IOHID manager/device opening or reports.
enum ReceiverUSBInventory {
    struct Entry:Encodable,Equatable {
        let role:String
        let sessionToken:String
        let vendorID:Int
        let productID:Int
        let usbRevision:Int
        let transport:String
        let configurationReportSupported:Bool
        let descriptorBytes:Int
        let descriptorSHA256:String?
        private enum CodingKeys:String,CodingKey{case role,sessionToken,vendorID,productID,usbRevision,transport,configurationReportSupported,descriptorBytes,descriptorSHA256}
        func encode(to encoder:Encoder)throws{
            var c=encoder.container(keyedBy:CodingKeys.self)
            try c.encode(role,forKey:.role);try c.encode(sessionToken,forKey:.sessionToken)
            try c.encode(vendorID,forKey:.vendorID);try c.encode(productID,forKey:.productID)
            try c.encode(usbRevision,forKey:.usbRevision);try c.encode(transport,forKey:.transport)
            try c.encode(configurationReportSupported,forKey:.configurationReportSupported)
            try c.encode(descriptorBytes,forKey:.descriptorBytes);try c.encode(descriptorSHA256,forKey:.descriptorSHA256)
        }
    }
    struct Inventory:Encodable,Equatable {
        let format="CherryMacUSBReceiverInventory"
        let version=1
        let opensDevice=false
        let sendsReports=false
        let entries:[Entry]
    }
    struct InventoryError:LocalizedError {
        let message:String
        var errorDescription:String?{message}
    }
    static func read()throws->Inventory{
        let first=try snapshot(),second=try snapshot()
        guard first==second else{throw InventoryError(message:"查询期间 USB 连接发生变化，请重新查看。")}
        return .init(entries:second)
    }
    private static func snapshot()throws->[Entry]{
        let matching:[String:Any]=[kIOProviderClassKey:"IOHIDDevice","IOPropertyMatch":[kIOHIDVendorIDKey:0x046a]]
        var iterator:io_iterator_t=0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,matching as CFDictionary,&iterator)==KERN_SUCCESS else{
            throw InventoryError(message:"无法读取键盘与接收器的 USB 描述信息。")
        }
        defer{IOObjectRelease(iterator)}
        var entries:[Entry]=[]
        while true{
            let service=IOIteratorNext(iterator);if service==0{break}
            defer{IOObjectRelease(service)}
            func property(_ key:String)->Any?{IORegistryEntryCreateCFProperty(service,key as CFString,kCFAllocatorDefault,0)?.takeRetainedValue()}
            func number(_ key:String)throws->Int{
                guard let value=property(key) as? NSNumber,CFGetTypeID(value) != CFBooleanGetTypeID(),
                      value.doubleValue.isFinite,value.doubleValue.rounded()==value.doubleValue,
                      value.doubleValue>=0,value.doubleValue<=65535 else{throw InventoryError(message:"USB 描述字段缺失或无效。")}
                return value.intValue
            }
            guard property(kIOHIDTransportKey) as? String=="USB" else{continue}
            let vendor=try number(kIOHIDVendorIDKey),product=try number(kIOHIDProductIDKey)
            guard vendor==0x046a,[0x01ce,0x01cf].contains(product) else{continue}
            var id:UInt64=0
            guard IORegistryEntryGetRegistryEntryID(service,&id)==KERN_SUCCESS,id != 0 else{throw InventoryError(message:"USB 接口身份无法读取。")}
            let descriptor=property(kIOHIDReportDescriptorKey) as? Data
            guard descriptor==nil || descriptor!.count<=65536 else{throw InventoryError(message:"USB 配置描述超过范围。")}
            entries.append(.init(role:product==0x01ce ? "keyboard":"receiver",sessionToken:String(id),vendorID:vendor,productID:product,
                usbRevision:try number(kIOHIDVersionNumberKey),transport:"USB",
                configurationReportSupported:descriptor.map{ReceiverPairingReports.supportsConfiguration($0)} ?? false,
                descriptorBytes:descriptor?.count ?? 0,descriptorSHA256:descriptor.map{SHA256.hash(data:$0).map{String(format:"%02x",$0)}.joined()}))
            guard entries.count<=16 else{throw InventoryError(message:"目标 USB 接口过多，无法核对。")}
        }
        guard IOIteratorIsValid(iterator) != 0,Set(entries.map(\.sessionToken)).count==entries.count else{
            throw InventoryError(message:"枚举期间 USB 接口发生变化。")
        }
        return entries.sorted{$0.sessionToken<$1.sessionToken}
    }
}
