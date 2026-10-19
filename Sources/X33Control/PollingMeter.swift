import Foundation
import IOKit.hid

/// Measures the real report rate of the mouse by timestamping input reports on
/// the receiver's mouse collection (usage page 1, usage 2). Needs the mouse to
/// move during the window; a still mouse sends nothing.
final class PollingMeter {
    private let manager: IOHIDManager
    private let queue = DispatchQueue(label: "x33.meter")
    private let lock = NSLock()
    private var stamps: [TimeInterval] = []

    init() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    func start() throws {
        let matching: [[String: Any]] = Compx.productIDs.map { pid in
            [kIOHIDVendorIDKey: Compx.vendorID, kIOHIDProductIDKey: pid, kIOHIDDeviceUsagePageKey: 1, kIOHIDDeviceUsageKey: 2]
        }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputReportCallback(manager, { context, _, _, _, _, _, _ in
            guard let context else { return }
            let meter = Unmanaged<PollingMeter>.fromOpaque(context).takeUnretainedValue()
            meter.lock.lock()
            meter.stamps.append(ProcessInfo.processInfo.systemUptime)
            meter.lock.unlock()
        }, context)
        IOHIDManagerSetDispatchQueue(manager, queue)
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if result == kIOReturnNotPermitted { throw CompxError.notPermitted }
        guard result == kIOReturnSuccess else { throw CompxError.writeFailed(result) }
        IOHIDManagerActivate(manager)
    }

    /// Samples for `seconds` and returns (report count, estimated Hz from the median interval, peak reports in any 1 s).
    func measure(seconds: TimeInterval) -> (count: Int, hz: Int?, peakPerSecond: Int) {
        lock.lock(); stamps.removeAll(); lock.unlock()
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
        lock.lock(); let samples = stamps; lock.unlock()
        guard samples.count > 10 else { return (samples.count, nil, samples.count) }
        let gaps = zip(samples.dropFirst(), samples).map { $0 - $1 }.filter { $0 > 0 }.sorted()
        let median = gaps[gaps.count / 2]
        var peak = 0
        var start = 0
        for end in samples.indices {
            while samples[end] - samples[start] > 1 { start += 1 }
            peak = max(peak, end - start + 1)
        }
        return (samples.count, median > 0 ? Int((1 / median).rounded()) : nil, peak)
    }
}
