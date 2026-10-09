import Foundation
import IOKit
import IOKit.hid
import CryptoKit

// System descriptor inventory only. No IOHID manager/device opening, report
// exchange, pairing, keyboard writes or serial-number collection.
@main enum ReceiverInterfaceInventory {
    struct Interface:Codable,Equatable {
        let registryID:String
        let vendorID:Int
        let productID:Int
        let usbRevision:Int?
        let transport:String?
        let primaryUsagePage:Int?
        let primaryUsage:Int?
        let configurationUsagePage:Int?
        let configurationUsage:Int?
        let descriptorBytes:Int
        let descriptorSHA256:String?
        let descriptorHex:String?
        let role:String?
        let configurationReportSupported:Bool
        let eligible:Bool
    }
    struct Inventory:Encodable {
        let format="CherryMacReceiverInterfaceInventory"
        let version=1
        let capturedAt:String
        let source="IORegistry descriptor properties only"
        let opensDevice=false
        let sendsReports=false
        let interfaces:[Interface]
        let stableAcrossSnapshots:Bool
        let eligibleKeyboardCount:Int
        let eligibleReceiverCount:Int
        let selectionStatus:String
    }
    struct InventoryError:LocalizedError {
        let message:String
        var errorDescription:String?{message}
    }
    static func snapshot()throws->[Interface]{
        let matching:[String:Any]=[kIOProviderClassKey:"IOHIDDevice",
                                  "IOPropertyMatch":[kIOHIDVendorIDKey:0x046a]]
        var iterator:io_iterator_t=0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,matching as CFDictionary,&iterator)==KERN_SUCCESS else{
            throw InventoryError(message:"无法枚举CHERRY接口。")
        }
        defer{IOObjectRelease(iterator)}
        var interfaces:[Interface]=[]
        while true {
            let service=IOIteratorNext(iterator);if service==0{break}
            defer{IOObjectRelease(service)}
            func property(_ key:String)->Any?{
                IORegistryEntryCreateCFProperty(service,key as CFString,kCFAllocatorDefault,0)?.takeRetainedValue()
            }
            func number(_ key:String)->Int?{
                guard let value=property(key) as? NSNumber,CFGetTypeID(value) != CFBooleanGetTypeID(),
                      value.doubleValue.isFinite,value.doubleValue.rounded()==value.doubleValue,
                      value.doubleValue>=0,value.doubleValue<=65535 else{return nil}
                return value.intValue
            }
            var registryID:UInt64=0
            guard IORegistryEntryGetRegistryEntryID(service,&registryID)==KERN_SUCCESS,registryID != 0,
                  let vendor=number(kIOHIDVendorIDKey),vendor==0x046a,
                  let product=number(kIOHIDProductIDKey) else{
                throw InventoryError(message:"枚举期间设备身份缺失；不使用不完整快照。")
            }
            let page=number(kIOHIDPrimaryUsagePageKey),usage=number(kIOHIDPrimaryUsageKey)
            let transport=property(kIOHIDTransportKey) as? String
            let descriptor=property(kIOHIDReportDescriptorKey) as? Data
            guard descriptor==nil || descriptor!.count<=65536 else{
                throw InventoryError(message:"HID描述符超过范围。")
            }
            let supported=descriptor.map{ReceiverPairingReports.supportsConfiguration($0)} ?? false
            let candidate=ReceiverPairingCandidate(token:String(registryID),vendorID:vendor,
                productID:product,usagePage:supported ? 0xff1c:-1,usage:supported ? 0x92:-1)
            let role:String?=candidate.role.map{$0 == .keyboard ? "keyboard":"receiver"}
            interfaces.append(.init(registryID:String(registryID),vendorID:vendor,productID:product,
                usbRevision:number(kIOHIDVersionNumberKey),transport:transport,primaryUsagePage:page,primaryUsage:usage,
                configurationUsagePage:supported ? 0xff1c:nil,configurationUsage:supported ? 0x92:nil,
                descriptorBytes:descriptor?.count ?? 0,
                descriptorSHA256:descriptor.map{SHA256.hash(data:$0).map{String(format:"%02x",$0)}.joined()},
                descriptorHex:descriptor.map{$0.map{String(format:"%02x",$0)}.joined()},role:role,
                configurationReportSupported:supported,eligible:transport=="USB" && role != nil && supported))
            guard interfaces.count<=128 else{throw InventoryError(message:"CHERRY接口数量超过范围。")}
        }
        guard IOIteratorIsValid(iterator) != 0 else{throw InventoryError(message:"枚举期间设备连接变化。")}
        guard Set(interfaces.map(\.registryID)).count==interfaces.count else{
            throw InventoryError(message:"枚举出现重复接口身份。")
        }
        return interfaces.sorted{$0.registryID<$1.registryID}
    }
    static func main()throws{
        let first=try snapshot(),second=try snapshot()
        guard first==second else{throw InventoryError(message:"两次系统描述快照不同，请在连接稳定后重新读取。")}
        let keyboards=second.filter{$0.eligible && $0.role=="keyboard"}.count
        let receivers=second.filter{$0.eligible && $0.role=="receiver"}.count
        let status=keyboards==1 && receivers==1 ? "unique descriptor candidates; no pairing or wireless write proven":
            keyboards==0 ? "missing eligible wired keyboard":receivers==0 ? "missing eligible receiver":"ambiguous endpoint candidates"
        let result=Inventory(capturedAt:ISO8601DateFormatter().string(from:Date()),interfaces:second,
            stableAcrossSnapshots:true,eligibleKeyboardCount:keyboards,eligibleReceiverCount:receivers,selectionStatus:status)
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.prettyPrinted]
        let data=try encoder.encode(result)
        try FileHandle.standardOutput.write(contentsOf:data)
        try FileHandle.standardOutput.write(contentsOf:Data("\n".utf8))
    }
}
