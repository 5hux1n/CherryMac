import Foundation

// HID 1.11 short items, Global Push/Pop and report bit accounting.
// https://www.usb.org/sites/default/files/hid1_11.pdf (6.2.2)
// This is a bounded capability check, not a complete descriptor validator.
enum ReceiverPairingReports {
    private struct Globals {
        var size = 0
        var count = 0
        var reportID = 0
        var usagePage = 0
    }
    static func supportsConfiguration(_ descriptor: Data) -> Bool {
        guard !descriptor.isEmpty, descriptor.count <= 65_536 else { return false }
        let bytes = Array(descriptor)
        var cursor = 0, depth = 0
        var globals = Globals(), stack: [Globals] = []
        var inputBits = 0, outputBits = 0
        var localUsages: [(page:Int,usage:Int)] = []
        var collections: [Bool] = []
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
                case 0:
                    guard length > 0, value <= 65_535 else { return false }
                    globals.usagePage = value
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
                case 1...6: break
                default: return false
                }
            case 0:
                switch tag {
                case 10:
                    guard length == 1, depth < 64 else { return false }
                    let usage = localUsages.first
                    let configuration = depth == 0 && value == 1 && usage?.page == 0xff1c && usage?.usage == 0x92
                    collections.append(configuration || (collections.last ?? false))
                    depth += 1
                case 12:
                    guard length == 0, depth > 0 else { return false }
                    depth -= 1
                    collections.removeLast()
                case 8, 9, 11:
                    guard length > 0, depth > 0 else { return false }
                    if globals.reportID == 4 && tag != 11 {
                        guard collections.last == true else { return false }
                        let bits = globals.size * globals.count
                        guard bits > 0, bits <= 504 else { return false }
                        if tag == 8 { inputBits += bits } else { outputBits += bits }
                        guard inputBits <= 504, outputBits <= 504 else { return false }
                    }
                default: return false
                }
                // Local items apply to one Main item, including Collection.
                localUsages.removeAll()
            case 2:
                if tag == 0 {
                    guard length > 0, localUsages.count < 256 else { return false }
                    localUsages.append((page:length == 4 ? value >> 16:globals.usagePage,
                                        usage:length == 4 ? value & 65535:value))
                } else if ![1,2,3,4,5,7,8,9].contains(tag) {
                    // Delimiter sets/reserved local tags are outside this model.
                    return false
                }
            default: return false
            }
        }
        // Report ID is outside the 63-byte payload described by Size/Count.
        return depth == 0 && stack.isEmpty && inputBits == 504 && outputBits == 504
    }
}
