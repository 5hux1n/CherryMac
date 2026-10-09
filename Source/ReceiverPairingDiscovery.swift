import Foundation
import IOKit.hid

// Main-thread snapshot adapter. The caller supplies already discovered devices;
// no manager is created, no device is opened, and no HID report is sent here.
// Candidate admission requires the expected input/output report layout.
@MainActor
final class ReceiverPairingDiscovery {
    private struct Entry {
        let device: IOHIDDevice
        let candidate: ReceiverPairingCandidate
    }
    private var entries: [UInt64: Entry] = [:]
    var candidates: [ReceiverPairingCandidate] {
        entries.keys.sorted().compactMap { entries[$0]?.candidate }
    }

    @discardableResult
    func update(_ devices: [IOHIDDevice]) -> [ReceiverPairingCandidate] {
        var next: [UInt64: Entry] = [:]
        for device in devices {
            guard let transport = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String,
                  transport == "USB" else { continue }
            func number(_ key: String) -> Int? {
                guard let value=IOHIDDeviceGetProperty(device,key as CFString) as? NSNumber,
                      CFGetTypeID(value) != CFBooleanGetTypeID(),value.doubleValue.isFinite,
                      value.doubleValue.rounded()==value.doubleValue,value.doubleValue>=0,value.doubleValue<=65535 else{return nil}
                return value.intValue
            }
            guard let vendor = number(kIOHIDVendorIDKey), let product = number(kIOHIDProductIDKey),
                  let page = number(kIOHIDPrimaryUsagePageKey), let usage = number(kIOHIDPrimaryUsageKey) else { continue }
            var registryID: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &registryID) == KERN_SUCCESS,
                  registryID != 0 else { continue }
            let candidate = ReceiverPairingCandidate(token: entries[registryID]?.candidate.token ?? UUID().uuidString,
                vendorID: vendor, productID: product, usagePage: page, usage: usage)
            guard candidate.role != nil,
                  let descriptor = IOHIDDeviceGetProperty(device, kIOHIDReportDescriptorKey as CFString) as? Data,
                  ReceiverPairingReports.supportsConfiguration(descriptor) else { continue }
            next[registryID] = Entry(device: device, candidate: candidate)
        }
        entries = next
        return candidates
    }

    func remove(_ device: IOHIDDevice) {
        // Removal callbacks may run after the registry service has disappeared.
        let keys = entries.compactMap { CFEqual($0.value.device, device) ? $0.key : nil }
        for key in keys { entries.removeValue(forKey: key) }
    }
    func clear() { entries.removeAll() }

    func resolve(keyboardToken: String? = nil, receiverToken: String? = nil) throws
        -> (keyboard: IOHIDDevice, receiver: IOHIDDevice, selection: ReceiverPairingSelection) {
        let selection = try ReceiverPairingSelection.resolve(candidates, keyboardToken: keyboardToken, receiverToken: receiverToken)
        guard let keyboard = entries.values.first(where: { $0.candidate.token == selection.keyboard.token }),
              let receiver = entries.values.first(where: { $0.candidate.token == selection.receiver.token }) else {
            throw ReceiverPairingSelection.SelectionError.staleSelection
        }
        return (keyboard.device, receiver.device, selection)
    }
}
