import Foundation

/// High-level operations on the mouse. Every call blocks until the mouse
/// answers, so use `perform` from UI code.
public final class MouseController {
    public let transport = CompxTransport()
    private let io = DispatchQueue(label: "x33.io", qos: .userInitiated)

    public init() {}

    public func start() throws {
        try transport.start()
    }

    /// Runs `work` on the controller's serial queue and delivers the result on main.
    public func perform<T>(_ work: @escaping () throws -> T, completion: @escaping (Result<T, Error>) -> Void) {
        io.async {
            let result = Result { try work() }
            DispatchQueue.main.async { completion(result) }
        }
    }

    // MARK: Reads

    public func readBattery() throws -> BatteryStatus {
        let reply = try query(.battery)
        guard let battery = Compx.parseBattery(reply) else { throw CompxError.badResponse }
        return battery
    }

    public func readSettings() throws -> MouseSettings {
        try withHostControl {
            MouseSettings(flash: try readFlash(address: 0, length: Compx.Flash.readEnd))
        }
    }

    public func readFirmware() -> (mouse: String?, dongle: String?) {
        let mouse = (try? query(.readVersion)).flatMap(Compx.parseVersion)
        let dongle = (try? query(.dongleVersion)).flatMap(Compx.parseVersion)
        return (mouse, dongle)
    }

    public func dumpFlash(length: Int = 0x100) throws -> [UInt8] {
        try withHostControl { try readFlash(address: 0, length: length) }
    }

    // MARK: Writes (each one is verified by reading the byte back)

    public func setPollingRate(_ hz: Int) throws {
        guard let encoded = Compx.encodePollingRate(hz) else { throw CompxError.unsupportedValue("\(hz) Hz") }
        try setVerifiedByte(Compx.Flash.reportRate, encoded, label: "polling rate")
    }

    public func setActiveDpiStage(_ stage: Int) throws {
        guard (0..<Compx.Flash.maxDpiStages).contains(stage) else { throw CompxError.unsupportedValue("stage \(stage + 1)") }
        try setVerifiedByte(Compx.Flash.currentDpiStage, UInt8(stage), label: "DPI stage")
    }

    public func setDpiStageCount(_ count: Int) throws {
        guard (1...Compx.Flash.maxDpiStages).contains(count) else { throw CompxError.unsupportedValue("\(count) stages") }
        try setVerifiedByte(Compx.Flash.dpiStageCount, UInt8(count), label: "DPI stage count")
    }

    public func setDpi(stage: Int, dpi: Int) throws {
        guard (0..<Compx.Flash.maxDpiStages).contains(stage) else { throw CompxError.unsupportedValue("stage \(stage + 1)") }
        guard let record = Compx.encodeDpi(dpi) else { throw CompxError.unsupportedValue("\(dpi) DPI") }
        let address = Compx.Flash.dpiValues + stage * Compx.Flash.dpiRecordSize
        try withHostControl {
            try writeFlash(address: address, data: record)
            let confirmed = try readFlash(address: address, length: Compx.Flash.dpiRecordSize)
            guard Compx.decodeDpi(confirmed) == dpi else { throw CompxError.verifyFailed("DPI") }
        }
    }

    public func setLiftOffDistance(mm: Int) throws {
        guard Compx.liftOffDistancesMM.contains(mm) else { throw CompxError.unsupportedValue("\(mm) mm") }
        try setVerifiedByte(Compx.Flash.liftOffDistance, UInt8(mm), label: "lift-off distance")
    }

    public func setSleepMinutes(_ minutes: Int) throws {
        guard Compx.sleepMinutes.contains(minutes) else { throw CompxError.unsupportedValue("\(minutes) min") }
        try setVerifiedByte(Compx.Flash.sleepTime, UInt8(minutes), label: "sleep timer")
    }

    public func setDebounce(ms: Int) throws {
        guard (0...15).contains(ms) else { throw CompxError.unsupportedValue("\(ms) ms") }
        try setVerifiedByte(Compx.Flash.debounceTime, UInt8(ms), label: "debounce time")
    }

    public func setMotionSync(_ on: Bool) throws {
        try setVerifiedByte(Compx.Flash.motionSync, on ? 1 : 0, label: "motion sync")
    }

    public func setAngleSnapping(_ on: Bool) throws {
        try setVerifiedByte(Compx.Flash.angleSnapping, on ? 1 : 0, label: "angle snapping")
    }

    public func setRippleControl(_ on: Bool) throws {
        try setVerifiedByte(Compx.Flash.rippleControl, on ? 1 : 0, label: "ripple control")
    }

    public func restoreDefaults() throws {
        try withHostControl { _ = try query(.restoreDefaults) }
    }

    // MARK: Protocol helpers

    @discardableResult
    private func query(_ command: Compx.Command, address: Int = 0, length: Int? = nil, data: [UInt8] = []) throws -> [UInt8] {
        let reply = try transport.exchange(Compx.frame(command, address: address, length: length, data: data))
        guard Compx.isValid(reply) else { throw CompxError.badResponse }
        guard reply[2] == 0 else { throw CompxError.rejected(command: command.rawValue, status: reply[2]) }
        return reply
    }

    /// Tells the receiver the host is configuring the mouse, runs `body`, then releases.
    private func withHostControl<T>(_ body: () throws -> T) throws -> T {
        try setHostControl(true)
        defer { try? setHostControl(false) }
        return try body()
    }

    /// The "online" flag in the reply is unreliable right after the mouse wakes
    /// or after a previous host-control session, so poll it briefly and carry
    /// on regardless: a flash read then fails with a clear timeout if the mouse
    /// really is asleep.
    private func setHostControl(_ enabled: Bool) throws {
        var reply: [UInt8] = []
        for attempt in 0..<12 {
            reply = try query(.deviceOnline, length: 0, data: [enabled ? 1 : 0])
            let busy = reply[10] == 1
            let online = reply[6] == 1
            if !busy && (!enabled || online) { return }
            if attempt < 11 { Thread.sleep(forTimeInterval: busy ? 0.01 : 0.1) }
        }
        if reply[10] == 1 { throw CompxError.receiverBusy }
    }

    private func readFlash(address: Int, length: Int) throws -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(length)
        var offset = 0
        while offset < length {
            let count = min(Compx.maxPayload, length - offset)
            let reply = try query(.readFlash, address: address + offset, length: count)
            out.append(contentsOf: reply[6..<6 + count])
            offset += count
        }
        return out
    }

    private func writeFlash(address: Int, data: [UInt8]) throws {
        var offset = 0
        while offset < data.count {
            let chunk = Array(data[offset..<min(offset + Compx.maxPayload, data.count)])
            try query(.writeFlash, address: address + offset, data: chunk)
            offset += chunk.count
        }
    }

    private func setVerifiedByte(_ address: Int, _ value: UInt8, label: String) throws {
        try withHostControl {
            try writeFlash(address: address, data: [value, Compx.checksum([value])])
            let confirmed = try readFlash(address: address, length: 2)
            guard confirmed[0] == value else { throw CompxError.verifyFailed(label) }
        }
    }
}
