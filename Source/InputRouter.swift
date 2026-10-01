import Cocoa
import IOKit.hid
import Darwin

// CGEvent does not expose a keyboard device identifier. Correlate its exact
// timestamp and keycode with input from the vendor-filtered IOHIDManager.
// An unmatched event is always passed through. Never guess by keycode alone.
struct RawKeyRecord {
    let signal: String
    let nanoseconds: UInt64
    let keyCode: UInt16
    let down: Bool
}

let hidToMacKey: [UInt32: UInt16] = [
    4: 0, 5: 11, 6: 8, 7: 2, 8: 14, 9: 3, 10: 5, 11: 4, 12: 34,
    13: 38, 14: 40, 15: 37, 16: 46, 17: 45, 18: 31, 19: 35, 20: 12,
    21: 15, 22: 1, 23: 17, 24: 32, 25: 9, 26: 13, 27: 7, 28: 16, 29: 6,
    30: 18, 31: 19, 32: 20, 33: 21, 34: 23, 35: 22, 36: 26, 37: 28,
    38: 25, 39: 29, 40: 36, 41: 53, 42: 51, 43: 48, 44: 49, 45: 27,
    46: 24, 47: 33, 48: 30, 49: 42, 50: 10, 51: 41, 52: 39, 53: 50,
    54: 43, 55: 47, 56: 44, 57: 57, 58: 122, 59: 120, 60: 99, 61: 118,
    62: 96, 63: 97, 64: 98, 65: 100, 66: 101, 67: 109, 68: 103, 69: 111,
    70: 105, 71: 107, 72: 113, 73: 114, 74: 115, 75: 116, 76: 117,
    77: 119, 78: 121, 79: 124, 80: 123, 81: 125, 82: 126, 83: 71,
    84: 75, 85: 67, 86: 78, 87: 69, 88: 76, 89: 83, 90: 84, 91: 85,
    92: 86, 93: 87, 94: 88, 95: 89, 96: 91, 97: 92, 98: 82, 99: 65,
    100: 10, 101: 110, 103: 81, 104: 105, 105: 107, 106: 113, 107: 106,
    108: 64, 109: 79, 110: 80, 111: 90
]

final class RawInputLedger {
    private let condition = NSCondition()
    private var records: [RawKeyRecord] = []
    private let numerator: UInt64
    private let denominator: UInt64

    init() {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        numerator = UInt64(info.numer)
        denominator = max(1, UInt64(info.denom))
    }
    func nanoseconds(_ absolute: UInt64) -> UInt64 {
        (absolute / denominator) * numerator + ((absolute % denominator) * numerator) / denominator
    }
    func insert(signal: String, timestamp: UInt64, keyCode: UInt16, down: Bool) {
        condition.lock()
        records.append(RawKeyRecord(signal: signal, nanoseconds: timestamp, keyCode: keyCode, down: down))
        if records.count > 512 { records.removeFirst(records.count - 512) }
        condition.broadcast()
        condition.unlock()
    }
    func record(page: UInt32, usage: UInt32, value: Int, absoluteTimestamp: UInt64) {
        guard page == 7, value == 0 || value == 1, let code = hidToMacKey[usage] else { return }
        insert(signal: "\(page):\(usage)", timestamp: nanoseconds(absoluteTimestamp), keyCode: code, down: value == 1)
    }
    func take(timestamp: UInt64, keyCode: UInt16, down: Bool, wait: TimeInterval = 0.005) -> RawKeyRecord? {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(wait)
        while true {
            if let index = records.firstIndex(where: { $0.nanoseconds == timestamp && $0.keyCode == keyCode && $0.down == down }) {
                return records.remove(at: index)
            }
            guard wait > 0, condition.wait(until: deadline) else { return nil }
        }
    }
    func clear() {
        condition.lock(); records.removeAll(); condition.unlock()
    }
}

final class KeyboardEventRouter {
    let ledger: RawInputLedger
    var handle: ((RawKeyRecord, CGEvent) -> Bool)?
    var monitoredCodes = Set<UInt16>()
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var suppressedCodes = Set<UInt16>()
    var running: Bool { tap != nil }
    var allowTestInput = false
    static let testInputTag: Int64 = 0x4348544553

    init(ledger: RawInputLedger) { self.ledger = ledger }
    func start() -> Bool {
        if tap != nil { return true }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                               eventsOfInterest: CGEventMask(mask), callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let router = Unmanaged<KeyboardEventRouter>.fromOpaque(context).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = router.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            return router.consume(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else { return false }
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        guard let runLoopSource else { stop(); return false }
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }
    func consume(type: CGEventType, event: CGEvent, wait: TimeInterval = 0.005) -> Bool {
        let tag = event.getIntegerValueField(.eventSourceUserData)
        // All synthesized input, including our own shortcut output, passes
        // through. The special test tag is enabled only by --system-test.
        guard tag == 0 || (allowTestInput && tag == Self.testInputTag) else { return false }
        guard type == .keyDown || type == .keyUp else { return false }
        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        guard monitoredCodes.contains(code) || suppressedCodes.contains(code) else { return false }
        let down = type == .keyDown
        if down, event.getIntegerValueField(.keyboardEventAutorepeat) != 0, suppressedCodes.contains(code) { return true }
        guard let raw = ledger.take(timestamp: event.timestamp, keyCode: code, down: down, wait: wait) else {
            // An uncorrelated press could be from another keyboard. Clear any
            // repeat ownership before passing it through.
            suppressedCodes.remove(code)
            return false
        }
        if !down {
            let consumed = suppressedCodes.remove(code) != nil
            return consumed
        }
        let consumed = handle?(raw, event) ?? false
        if consumed { suppressedCodes.insert(code) } else { suppressedCodes.remove(code) }
        return consumed
    }
    func reset() { ledger.clear(); suppressedCodes.removeAll() }
    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil; runLoopSource = nil
        reset()
    }
    deinit { stop() }
}
