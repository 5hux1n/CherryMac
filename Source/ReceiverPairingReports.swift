import Foundation

// HID 1.11 short items, Global Push/Pop and report bit accounting.
// https://www.usb.org/sites/default/files/hid1_11.pdf (6.2.2)
// This is a bounded capability check, not a complete descriptor validator.
enum ReceiverPairingReports {
    private struct Globals {
        var size = 0
        var count = 0
        var reportID = 0
    }
    static func supportsConfiguration(_ descriptor: Data) -> Bool {
        guard !descriptor.isEmpty, descriptor.count <= 65_536 else { return false }
        let bytes = Array(descriptor)
        var cursor = 0, depth = 0
        var globals = Globals(), stack: [Globals] = []
        var inputBits = 0, outputBits = 0
        while cursor < bytes.count {
            let prefix = Int(bytes[cursor]); cursor += 1
            // No long-item semantics are needed by this model; do not guess.
            guard prefix != 0xfe else { return false }
            let encodedSize = prefix & 3
            let length = encodedSize == 3 ? 4 : encodedSize
            guard cursor + length <= bytes.count else { return false }
            var value = 0
            for index in 0..<length { value |= Int(bytes[cursor + index]) << (index * 8) }
            cursor += length
            let type = (prefix >> 2) & 3, tag = prefix >> 4
            switch type {
            case 1:
                switch tag {
                case 7, 9:
                    guard length > 0, value <= 65_535 else { return false }
                    if tag == 7 { globals.size = value } else { globals.count = value }
                case 8:
                    guard length == 1, value > 0 else { return false }
                    globals.reportID = value
                case 10:
                    guard length == 0, stack.count < 64 else { return false }
                    stack.append(globals)
                case 11:
                    guard length == 0, let saved = stack.popLast() else { return false }
                    globals = saved
                case 0...6: break
                default: return false
                }
            case 0:
                switch tag {
                case 10:
                    guard length == 1, depth < 64 else { return false }
                    depth += 1
                case 12:
                    guard length == 0, depth > 0 else { return false }
                    depth -= 1
                case 8, 9, 11:
                    guard length > 0, depth > 0 else { return false }
                    if globals.reportID == 4 && tag != 11 {
                        let bits = globals.size * globals.count
                        guard bits > 0, bits <= 504 else { return false }
                        if tag == 8 { inputBits += bits } else { outputBits += bits }
                        guard inputBits <= 504, outputBits <= 504 else { return false }
                    }
                default: return false
                }
            case 2: break // Local usage metadata does not change report length.
            default: return false
            }
        }
        // Report ID is outside the 63-byte payload described by Size/Count.
        return depth == 0 && stack.isEmpty && inputBits == 504 && outputBits == 504
    }
}
