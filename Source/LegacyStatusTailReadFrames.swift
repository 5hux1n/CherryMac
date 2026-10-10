import Foundation
import CryptoKit

// Pure candidate frames from fixed0104 code; live observations are recorded separately.
// Matching ROM info is not
// running-firmware identity. No I/O, general memory read, keymap alias or grant.
enum LegacyStatusTailReadFrames {
    enum Region:String {case parameters,colors,macroData}
    struct Plan:Equatable {
        let region:Region
        let regionOffset:Int
        let statusOffset:Int
        let request:[UInt8]
        let imageSHA256:String
        let deviceInfoSHA256:String
    }
    struct FrameError:LocalizedError {
        let message:String
        var errorDescription:String?{message}
    }
    static let imageSHA256="31d0a07361ad531fa16867412d46e496737b126efc90482f86baa7e6bd5051bd"
    static let deviceInfoSHA256="df2355e97afdcb63f8485c1dcf8719615b7ad52c2e190230f1e8125da918c7fa"
    static func plan(region:Region,vendorID:Int,productID:Int,observedDeviceInfo:[UInt8])throws->Plan{
        guard vendorID==0x046a,productID==0x01ce,observedDeviceInfo.count==34,
              SHA256.hash(data:Data(observedDeviceInfo)).map({String(format:"%02x",$0)}).joined()==deviceInfoSHA256 else{
            throw FrameError(message:"候选读取需要目标键盘及匹配的设备信息；它不证明运行固件相同。")
        }
        return canonical(region)
    }
    private static func canonical(_ region:Region)->Plan{
        let regionOffset:Int,statusOffset:Int
        switch region{
        case .parameters:regionOffset=63;statusOffset=127
        case .colors:regionOffset=511;statusOffset=639
        case .macroData:regionOffset=3071;statusOffset=21587
        }
        var request=[UInt8](repeating:0,count:64)
        request[0]=4;request[3]=0x1d;request[4]=1
        request[5]=UInt8(statusOffset&255);request[6]=UInt8(statusOffset>>8)
        let sum=request[3...63].reduce(0){$0+Int($1)}
        request[1]=UInt8(sum&255);request[2]=UInt8(sum>>8)
        return .init(region:region,regionOffset:regionOffset,statusOffset:statusOffset,request:request,
            imageSHA256:imageSHA256,deviceInfoSHA256:deviceInfoSHA256)
    }
    static func byte(reply:[UInt8],for plan:Plan)throws->UInt8{
        guard plan==canonical(plan.region),reply.count==64,reply[0]==4 else{throw FrameError(message:"候选读取请求或回复长度无效。")}
        guard ![0xff,0xfe].contains(reply[7]) else{throw FrameError(message:"设备拒绝候选读取；不得重试或补造末字节。")}
        guard reply[0...7].elementsEqual(plan.request[0...7]) else{throw FrameError(message:"候选读取回复头与请求不一致。")}
        return reply[8]
    }
}
