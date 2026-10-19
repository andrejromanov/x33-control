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
            var s = MouseSettings(flash: try readFlash(address: 0, length: Compx.Flash.readEnd))
            for (slot, action) in s.buttons.enumerated() where action == .shortcut {
                // A sleeping mouse would cost one timeout per slot, so stop at the first failure.
                let read: Shortcut?
                do { read = try readShortcutRaw(slot: slot) } catch { break }
                if let sc = read { s.shortcuts[slot] = sc }
            }
            return s
        }
    }

    public func readFirmware() -> (mouse: String?, dongle: String?) {
        let mouse = (try? query(.readVersion)).flatMap(Compx.parseVersion)
        let dongle = (try? query(.dongleVersion)).flatMap(Compx.parseVersion)
        return (mouse, dongle)
    }

    public func dumpFlash(address: Int = 0, length: Int = 0x100) throws -> [UInt8] {
        try withHostControl { try readFlash(address: address, length: length) }
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

    // MARK: Buttons and shortcuts

    public func readShortcut(slot: Int) throws -> Shortcut? {
        try withHostControl { try readShortcutRaw(slot: slot) }
    }

    public func setButton(slot: Int, action: ButtonAction) throws {
        try checkSlot(slot)
        try withHostControl {
            try ensureLeftClickRemains(after: slot, action: action)
            try writeButtonRecord(slot: slot, action: action)
        }
    }

    public func setShortcut(slot: Int, _ shortcut: Shortcut) throws {
        try checkSlot(slot)
        guard !shortcut.presses.isEmpty, shortcut.presses.count <= Shortcut.maxEvents else {
            throw CompxError.unsupportedValue("shortcut with \(shortcut.presses.count) keys")
        }
        try withHostControl {
            try ensureLeftClickRemains(after: slot, action: .shortcut)
            let base = Compx.Flash.shortcutBase + slot * Compx.Flash.shortcutStride
            try writeFlash(address: base, data: shortcut.record)
            guard try readShortcutRaw(slot: slot) == shortcut else { throw CompxError.verifyFailed("shortcut keys") }
            try writeButtonRecord(slot: slot, action: .shortcut)
        }
    }

    private func checkSlot(_ slot: Int) throws {
        guard (0..<Compx.Flash.buttonSlots).contains(slot) else { throw CompxError.unsupportedValue("button \(slot + 1)") }
    }

    private func writeButtonRecord(slot: Int, action: ButtonAction) throws {
        let address = Compx.Flash.keyFunction + slot * 4
        try writeFlash(address: address, data: action.record)
        let back = try readFlash(address: address, length: 4)
        guard Array(back[0..<3]) == action.bytes else { throw CompxError.verifyFailed("button \(slot + 1)") }
    }

    /// The official software refuses a layout with no Left Click; so does this one.
    private func ensureLeftClickRemains(after slot: Int, action: ButtonAction) throws {
        if action == .mouse(.left) { return }
        let table = try readFlash(address: Compx.Flash.keyFunction, length: Compx.Flash.buttonSlots * 4)
        for i in 0..<Compx.Flash.buttonSlots where i != slot {
            if ButtonAction(record: Array(table[i * 4..<i * 4 + 4])) == .mouse(.left) { return }
        }
        throw CompxError.unsupportedValue("removing the last Left Click")
    }

    private func readShortcutRaw(slot: Int) throws -> Shortcut? {
        let base = Compx.Flash.shortcutBase + slot * Compx.Flash.shortcutStride
        var bytes = try readFlash(address: base, length: Compx.maxPayload)
        let needed = 1 + Int(bytes[0]) * 3 + 1
        if bytes[0] != 0xff, needed > bytes.count, needed <= Compx.Flash.shortcutStride {
            bytes += try readFlash(address: base + bytes.count, length: needed - bytes.count)
        }
        return Shortcut(record: bytes)
    }

    // MARK: Lights

    public func setLight(_ light: LightSettings) throws {
        try withHostControl {
            let state: UInt8 = light.enabled ? 1 : 0
            try writeFlash(address: Compx.Flash.light, data: light.record)
            try writeFlash(address: Compx.Flash.lightState, data: [state, Compx.checksum([state])])
            let back = try readFlash(address: Compx.Flash.light, length: 8)
            guard Array(back[0..<7]) == light.record, back[7] == state else { throw CompxError.verifyFailed("lighting") }
        }
    }

    public func setDpiLight(mode: DpiLightSettings.Mode, brightness: UInt8? = nil, speed: UInt8? = nil) throws {
        try withHostControl {
            let current = try readFlash(address: Compx.Flash.dpiLightMode, length: 8)
            let b = brightness ?? (current[2] == 0xff ? 0x80 : current[2])
            let sp = speed ?? (current[4] == 0xff ? 3 : current[4])
            let state: UInt8 = mode == .off ? 0 : 1
            var data: [UInt8] = []
            for v in [mode.rawValue, b, sp, state] { data += [v, Compx.checksum([v])] }
            try writeFlash(address: Compx.Flash.dpiLightMode, data: data)
            let back = try readFlash(address: Compx.Flash.dpiLightMode, length: 8)
            guard back == data else { throw CompxError.verifyFailed("DPI indicator") }
        }
    }

    public func setDpiColor(stage: Int, _ color: RGB) throws {
        guard (0..<Compx.Flash.maxDpiStages).contains(stage) else { throw CompxError.unsupportedValue("stage \(stage + 1)") }
        try withHostControl {
            let address = Compx.Flash.dpiColors + stage * 4
            try writeFlash(address: address, data: color.record)
            let back = try readFlash(address: address, length: 4)
            guard back == color.record else { throw CompxError.verifyFailed("DPI colour") }
        }
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
