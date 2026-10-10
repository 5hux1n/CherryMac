import Foundation
import CryptoKit

// Fixed comparisons derived from the old0104 RAM layout. No arbitrary offsets,
// keymap negative-offset wrap, device I/O, backup promotion or write authority.
enum LegacyStatusAliasReadFrames {
    struct Window:Equatable {
        let region:String,segment:String
        let ordinaryCommand:UInt8
        let ordinaryOffset:Int,ordinaryLength:Int,statusOffset:Int,statusLength:Int
        var ordinaryRequest:[UInt8]{Self.frame(ordinaryCommand,ordinaryOffset,ordinaryLength)}
        var statusRequest:[UInt8]{Self.frame(0x1d,statusOffset,statusLength)}
        private static func frame(_ command:UInt8,_ offset:Int,_ count:Int)->[UInt8]{
            var bytes=[UInt8](repeating:0,count:64)
            bytes[0]=4;bytes[3]=command;bytes[4]=UInt8(count)
            bytes[5]=UInt8(offset&255);bytes[6]=UInt8(offset>>8)
            let sum=bytes[3...].reduce(0){$0+Int($1)}
            bytes[1]=UInt8(sum&255);bytes[2]=UInt8(sum>>8)
            return bytes
        }
        func compare(ordinary:[UInt8],candidate:[UInt8])throws{
            guard ordinary.count==ordinaryLength,candidate.count==statusLength,
                  ordinary.elementsEqual(candidate.prefix(ordinaryLength)) else{
                throw LegacyStatusTailReadFrames.FrameError(message:"候选接口与正常读取的已知内容不同；停止，不生成完整备份。")
            }
        }
    }
    static func windows(vendorID:Int,productID:Int,deviceInfo:[UInt8])throws->[Window]{
        // Reuse the exact model/info gate without expanding the old tail API.
        _ = try LegacyStatusTailReadFrames.plan(region:.parameters,vendorID:vendorID,productID:productID,observedDeviceInfo:deviceInfo)
        return [
            .init(region:"parameters",segment:"front",ordinaryCommand:5,ordinaryOffset:0,ordinaryLength:56,statusOffset:64,statusLength:56),
            .init(region:"parameters",segment:"tail",ordinaryCommand:5,ordinaryOffset:56,ordinaryLength:7,statusOffset:120,statusLength:8),
            .init(region:"colors",segment:"front",ordinaryCommand:10,ordinaryOffset:0,ordinaryLength:56,statusOffset:128,statusLength:56),
            .init(region:"colors",segment:"tail",ordinaryCommand:10,ordinaryOffset:456,ordinaryLength:55,statusOffset:584,statusLength:56),
            .init(region:"macroData",segment:"front",ordinaryCommand:20,ordinaryOffset:0,ordinaryLength:54,statusOffset:18516,statusLength:54),
            .init(region:"macroData",segment:"tail",ordinaryCommand:20,ordinaryOffset:3018,ordinaryLength:53,statusOffset:21534,statusLength:54)
        ]
    }
}
