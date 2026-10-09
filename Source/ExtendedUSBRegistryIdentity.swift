import Foundation
import IOKit
import IOKit.hid

// Descriptor metadata only: no IOHIDManager/device opening, callbacks or report
// exchange. The authenticated loopback bridge exposes this metadata; a future
// browser capture adapter must also bind its selected HID endpoint.
enum ExtendedUSBRegistryIdentity {
    struct IdentityError:LocalizedError {
        let message:String
        var errorDescription:String?{message}
    }
    static func read()throws->ExtendedHardwareCapture.Identity{
        let matching:[String:Any]=[kIOProviderClassKey:"IOHIDDevice",
            "IOPropertyMatch":[kIOHIDVendorIDKey:0x046a,kIOHIDProductIDKey:0x01ce]]
        var iterator:io_iterator_t=0
        let result=IOServiceGetMatchingServices(kIOMainPortDefault,matching as CFDictionary,&iterator)
        guard result==KERN_SUCCESS else{throw IdentityError(message:"无法读取目标键盘的系统描述信息。")}
        defer{IOObjectRelease(iterator)}
        var selected:ExtendedHardwareCapture.Identity?
        while true{
            let service=IOIteratorNext(iterator);if service==0{break}
            defer{IOObjectRelease(service)}
            // Any second matching endpoint, including Bluetooth/virtual HID,
            // makes the browser-to-registry binding ambiguous. Do not guess.
            guard selected==nil else{throw IdentityError(message:"存在多个同型号接口，无法唯一核对USB身份。")}
            func property(_ key:String)->Any?{
                IORegistryEntryCreateCFProperty(service,key as CFString,kCFAllocatorDefault,0)?.takeRetainedValue()
            }
            func integer(_ key:String)throws->Int{
                guard let value=property(key) as? NSNumber,CFGetTypeID(value) != CFBooleanGetTypeID(),
                      value.doubleValue.isFinite,value.doubleValue.rounded()==value.doubleValue,
                      value.doubleValue>=0,value.doubleValue<=65535 else{throw IdentityError(message:"目标USB描述字段缺失或无效。")}
                return value.intValue
            }
            var registryID:UInt64=0
            guard IORegistryEntryGetRegistryEntryID(service,&registryID)==KERN_SUCCESS,
                  let transport=property(kIOHIDTransportKey) as? String else{throw IdentityError(message:"目标USB连接标识无法读取。")}
            let identity=ExtendedHardwareCapture.Identity(sessionToken:String(registryID),
                vendorID:try integer(kIOHIDVendorIDKey),productID:try integer(kIOHIDProductIDKey),
                usbRevision:try integer(kIOHIDVersionNumberKey),transport:transport)
            try identity.validate();selected=identity
        }
        guard IOIteratorIsValid(iterator) != 0 else{throw IdentityError(message:"USB枚举期间连接已变化，请重新核对。")}
        guard let selected else{throw IdentityError(message:"没有唯一连接的目标USB键盘。")}
        return selected
    }
}
