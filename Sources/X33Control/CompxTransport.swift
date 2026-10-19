import Foundation
import IOKit.hid

public enum CompxError: Error, LocalizedError {
    case notPermitted
    case noDevice
    case writeFailed(IOReturn)
    case timeout(UInt8)
    case rejected(command: UInt8, status: UInt8)
    case receiverBusy
    case mouseOffline
    case badResponse
    case unsupportedValue(String)
    case verifyFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notPermitted:
            return "macOS denied access to the receiver. Allow this app under System Settings → Privacy & Security → Input Monitoring."
        case .noDevice:
            return "The 2.4G receiver is not plugged in."
        case .writeFailed(let r):
            return String(format: "Could not write to the receiver (IOKit 0x%08x).", r)
        case .timeout(let c):
            return String(format: "The mouse did not answer command 0x%02x. Is it switched on?", c)
        case .rejected(let c, let s):
            return String(format: "The receiver rejected command 0x%02x (status %d).", c, s)
        case .receiverBusy:
            return "The receiver stayed busy. Try again."
        case .mouseOffline:
            return "The mouse is asleep or off. Move it or click a button, then retry."
        case .badResponse:
            return "The receiver sent a malformed reply."
        case .unsupportedValue(let s):
            return "Unsupported value: \(s)."
        case .verifyFailed(let s):
            return "The mouse did not confirm the new \(s)."
        }
    }
}

/// Keep one instance alive for the process lifetime: the IOHIDManager is bound
/// to a dispatch queue and IOKit aborts if it is released while active.
///
/// Opens the receiver's vendor HID collection (usage page 0xff02) and runs
/// request/response exchanges: a feature report 8 goes out, the mouse answers
/// on input report 9. Hot-plug is handled through IOHIDManager callbacks.
public enum CompxLink: Equatable {
    case receiver
    case cable

    public var label: String {
        switch self {
        case .receiver: return "2.4G receiver"
        case .cable: return "USB cable"
        }
    }
}

public final class CompxTransport {
    public var onConnectionChange: ((Bool) -> Void)?
    public var onDeviceEvent: (([UInt8]) -> Void)?

    public static let replyTimeout: TimeInterval = 1.2

    private let manager: IOHIDManager
    private let hidQueue = DispatchQueue(label: "x33.hid")
    private let lock = NSLock()
    private var device: IOHIDDevice?
    private var devices: [IOHIDDevice] = []
    private var waiter: Waiter?
    private var started = false
    private var configured = false

    private final class Waiter {
        let command: UInt8
        /// Flash address the reply must echo (read/write commands), so a reply
        /// meant for another process talking to the same mouse is not taken.
        let address: (UInt8, UInt8)?
        let semaphore = DispatchSemaphore(value: 0)
        var response: [UInt8]?
        init(frame: [UInt8]) {
            command = frame[1]
            let flash = [Compx.Command.readFlash.rawValue, Compx.Command.writeFlash.rawValue]
            address = flash.contains(frame[1]) ? (frame[3], frame[4]) : nil
        }
        func matches(_ reply: [UInt8]) -> Bool {
            guard reply[1] == command else { return false }
            if let a = address { return reply[3] == a.0 && reply[4] == a.1 }
            return true
        }
    }

    public init() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    public var isConnected: Bool {
        lock.lock(); defer { lock.unlock() }
        return device != nil
    }

    /// How the mouse is currently reached, nil when nothing is plugged in.
    public var link: CompxLink? {
        lock.lock(); defer { lock.unlock() }
        return device.map(Self.link(of:))
    }

    private static func link(of device: IOHIDDevice) -> CompxLink {
        let pid = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int
        return pid == Compx.wiredProductID ? .cable : .receiver
    }

    // MARK: Permission (Input Monitoring)

    public static func hasPermission() -> Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    /// Shows the system prompt once; returns true when already granted.
    @discardableResult
    public static func requestPermission() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    // MARK: Lifecycle

    public func start() throws {
        if started { return }
        if !configured {
            let matching: [[String: Any]] = Compx.productIDs.map { pid in
                [
                    kIOHIDVendorIDKey: Compx.vendorID,
                    kIOHIDProductIDKey: pid,
                    kIOHIDDeviceUsagePageKey: Compx.configUsagePage,
                    kIOHIDDeviceUsageKey: Compx.configUsage,
                ]
            }
            IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)
            let context = Unmanaged.passUnretained(self).toOpaque()
            IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
                guard let context else { return }
                Unmanaged<CompxTransport>.fromOpaque(context).takeUnretainedValue().deviceMatched(device)
            }, context)
            IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
                guard let context else { return }
                Unmanaged<CompxTransport>.fromOpaque(context).takeUnretainedValue().deviceRemoved(device)
            }, context)
            // Devices matched by a dispatch-queue manager arrive already activated,
            // so the input report callback must be registered on the manager, up front.
            IOHIDManagerRegisterInputReportCallback(manager, { context, _, _, _, reportID, report, length in
                guard let context else { return }
                let bytes = Array(UnsafeBufferPointer(start: report, count: length))
                Unmanaged<CompxTransport>.fromOpaque(context).takeUnretainedValue().inputReport(id: reportID, bytes: bytes)
            }, context)
            IOHIDManagerSetDispatchQueue(manager, hidQueue)
            configured = true
        }
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if result == kIOReturnNotPermitted {
            throw CompxError.notPermitted
        }
        IOHIDManagerActivate(manager)
        started = true
    }

    // Both the receiver and the cable may be plugged in at once; the cable wins
    // because it answers even when the radio link is asleep.
    private func deviceMatched(_ dev: IOHIDDevice) {
        lock.lock()
        if !devices.contains(dev) { devices.append(dev) }
        device = devices.first { Self.link(of: $0) == .cable } ?? devices.first
        lock.unlock()
        onConnectionChange?(true)
    }

    private func deviceRemoved(_ dev: IOHIDDevice) {
        lock.lock()
        devices.removeAll { $0 == dev }
        let wasActive = device == dev
        if wasActive {
            device = devices.first { Self.link(of: $0) == .cable } ?? devices.first
        }
        let pending = wasActive ? waiter : nil
        if wasActive { waiter = nil }
        let stillConnected = device != nil
        lock.unlock()
        pending?.semaphore.signal()
        onConnectionChange?(stillConnected)
    }

    private func inputReport(id: UInt32, bytes: [UInt8]) {
        guard id == UInt32(Compx.responseReportID), bytes.count >= Compx.frameLength else { return }
        let frame = Array(bytes[0..<Compx.frameLength])
        if frame[1] == Compx.Command.deviceEvent.rawValue {
            onDeviceEvent?(frame)
        }
        lock.lock()
        if let pending = waiter, pending.matches(frame) {
            pending.response = frame
            waiter = nil
            lock.unlock()
            pending.semaphore.signal()
        } else {
            lock.unlock()
        }
    }

    // MARK: Exchange

    /// Sends one request frame and waits for the matching reply. Calls block;
    /// run it off the main thread.
    public func exchange(_ frame: [UInt8], timeout: TimeInterval = CompxTransport.replyTimeout) throws -> [UInt8] {
        precondition(frame.count == Compx.frameLength)
        lock.lock()
        guard let dev = device else {
            lock.unlock()
            throw CompxError.noDevice
        }
        let pending = Waiter(frame: frame)
        waiter = pending
        lock.unlock()
        defer {
            lock.lock()
            if waiter === pending { waiter = nil }
            lock.unlock()
        }

        let result = frame.withUnsafeBufferPointer { buf in
            IOHIDDeviceSetReport(dev, kIOHIDReportTypeFeature, CFIndex(frame[0]), buf.baseAddress!, buf.count)
        }
        if result == kIOReturnNotPermitted { throw CompxError.notPermitted }
        guard result == kIOReturnSuccess else { throw CompxError.writeFailed(result) }

        if pending.semaphore.wait(timeout: .now() + timeout) == .success, let reply = pending.response {
            return reply
        }
        if !isConnected { throw CompxError.noDevice }

        // Some firmware answers through the feature report instead of input report 9.
        var buffer = [UInt8](repeating: 0, count: Compx.frameLength)
        var length = CFIndex(Compx.frameLength)
        let got = IOHIDDeviceGetReport(dev, kIOHIDReportTypeFeature, CFIndex(Compx.commandReportID), &buffer, &length)
        if got == kIOReturnSuccess, length == Compx.frameLength, buffer[1] == frame[1], Compx.isValid(buffer) {
            return buffer
        }
        throw CompxError.timeout(frame[1])
    }
}
