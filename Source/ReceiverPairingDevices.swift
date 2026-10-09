import Foundation
// IOKit handles are retained across queued callbacks but used only on the main loop.
@preconcurrency import IOKit.hid

// Explicit, main-thread discovery lifecycle. No discovery occurs at construction.
// This manager never sends reports; candidate admission uses descriptor checks.
@MainActor
final class ReceiverPairingDevices {
    @MainActor private final class Context {
        weak var owner: ReceiverPairingDevices?
        let generation: UUID
        init(owner: ReceiverPairingDevices, generation: UUID) {
            self.owner = owner; self.generation = generation
        }
    }
    private var manager: IOHIDManager?
    private var context: Context?
    private var generation = UUID()
    private var removedDevices: [IOHIDDevice] = []
    private let discovery = ReceiverPairingDiscovery()
    var onChange: ([ReceiverPairingCandidate]) -> Void = { _ in }
    var onError: (Error) -> Void = { _ in }
    var candidates: [ReceiverPairingCandidate] { discovery.candidates }

    struct DiscoveryError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    func start() throws {
        guard manager == nil else { refresh(); return }
        let created = IOHIDManagerCreate(kCFAllocatorDefault, 0)
        let matches = [0x01ce, 0x01cf].map { product in
            [kIOHIDVendorIDKey: 0x046a, kIOHIDProductIDKey: product,
             kIOHIDTransportKey: "USB"] as [String: Any]
        }
        IOHIDManagerSetDeviceMatchingMultiple(created, matches as CFArray)
        generation = UUID()
        let box = Context(owner: self, generation: generation)
        context = box; manager = created
        let pointer = Unmanaged.passUnretained(box).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(created, { raw, result, _, device in
            ReceiverPairingDevices.deliver(raw, result: result, device: device, removed: false)
        }, pointer)
        IOHIDManagerRegisterDeviceRemovalCallback(created, { raw, result, _, device in
            ReceiverPairingDevices.deliver(raw, result: result, device: device, removed: true)
        }, pointer)
        IOHIDManagerScheduleWithRunLoop(created, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let result = IOHIDManagerOpen(created, 0)
        guard result == kIOReturnSuccess else {
            stop()
            throw DiscoveryError(message: "无法读取配对设备列表（\(result)），请检查 USB 连接和系统权限。")
        }
        refresh()
    }

    func refresh() {
        guard let manager else { return }
        let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []
        discovery.update(devices.filter { device in !removedDevices.contains(where: { CFEqual($0, device) }) })
        onChange(candidates)
    }

    func resolve(keyboardToken: String? = nil, receiverToken: String? = nil) throws
        -> (keyboard: IOHIDDevice, receiver: IOHIDDevice, selection: ReceiverPairingSelection) {
        guard manager != nil else { throw DiscoveryError(message: "配对设备列表已关闭，请重新选择。") }
        return try discovery.resolve(keyboardToken: keyboardToken, receiverToken: receiverToken)
    }

    func stop() {
        generation = UUID()
        if let manager { Self.close(manager) }
        manager = nil; context = nil; removedDevices.removeAll()
        discovery.clear()
        onChange(candidates)
    }

    private nonisolated static func deliver(_ raw: UnsafeMutableRawPointer?, result: IOReturn,
                                            device: IOHIDDevice, removed: Bool) {
        guard let raw else { return }
        // Retain the callback context before queuing. Stop invalidates generation;
        // queued work keeps only a weak owner and cannot revive a closed session.
        let box = Unmanaged<Context>.fromOpaque(raw).takeUnretainedValue()
        DispatchQueue.main.async {
            guard let owner = box.owner, owner.manager != nil, owner.generation == box.generation else { return }
            if result != kIOReturnSuccess {
                owner.stop()
                owner.onError(DiscoveryError(message: "配对设备监听发生错误（\(result)），请重新打开设备列表。"))
                return
            }
            if removed {
                if !owner.removedDevices.contains(where: { CFEqual($0, device) }) { owner.removedDevices.append(device) }
                owner.discovery.remove(device)
                owner.onChange(owner.candidates)
            } else {
                owner.removedDevices.removeAll(where: { CFEqual($0, device) })
                owner.refresh()
            }
        }
    }

    private nonisolated static func close(_ manager: IOHIDManager) {
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerRegisterDeviceMatchingCallback(manager, nil, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
        IOHIDManagerClose(manager, 0)
    }

    deinit {
        // Keep context alive until callbacks have been unregistered on their loop.
        if let manager {
            let retainedContext = context
            DispatchQueue.main.async {
                Self.close(manager)
                withExtendedLifetime(retainedContext) {}
            }
        }
    }
}
