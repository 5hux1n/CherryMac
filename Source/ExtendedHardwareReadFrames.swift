import Foundation

// Raw report adapter for the bounded capture executor. No default transport,
// device opening, retry or write permission. The live adapter must separately
// bind exchange to the same session returned by capture's identity callback.
enum ExtendedHardwareReadFrames {
    struct FrameError: LocalizedError {
        let message:String
        var errorDescription:String?{message}
    }
    static func request(command:UInt8,offset:Int,length:Int)throws->[UInt8]{
        guard let region=ExtendedHardwareCapture.regions.first(where:{$0.command==command}),
              offset>=0,offset<region.count,length>0,length<=region.chunkCapacity,
              length<=region.count-offset else{throw FrameError(message:"扩展只读请求超出捕获范围。")}
        var frame=[UInt8](repeating:0,count:64)
        frame[0]=4;frame[3]=command;frame[4]=UInt8(length)
        frame[5]=UInt8(offset&255);frame[6]=UInt8(offset>>8)
        let checksum=frame[3..<8].reduce(UInt16(0)){$0+UInt16($1)}
        frame[1]=UInt8(checksum&255);frame[2]=UInt8(checksum>>8)
        return frame
    }
    static func payload(reply:[UInt8],request frame:[UInt8])throws->[UInt8]{
        guard frame.count==64 else{throw FrameError(message:"扩展只读请求报告长度无效。")}
        let canonical=try request(command:frame[3],offset:Int(frame[5])+Int(frame[6])*256,length:Int(frame[4]))
        guard frame==canonical else{throw FrameError(message:"扩展只读请求必须是无数据的读取报告。")}
        guard reply.count==64,reply[0]==4,reply[3]==frame[3],
              reply[4..<7].elementsEqual(frame[4..<7]),reply[7]==0,
              reply[1]==frame[1],reply[2]==frame[2] else{
            throw FrameError(message:"扩展只读回复报告、偏移、状态或校验不一致。")
        }
        return Array(reply[8..<8+Int(frame[4])])
    }
    static func read(command:UInt8,offset:Int,length:Int,
                     exchange:([UInt8])throws->[UInt8])throws->[UInt8]{
        let frame=try request(command:command,offset:offset,length:length)
        return try payload(reply:exchange(frame),request:frame)
    }
}
