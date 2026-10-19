import Foundation

/// Wire protocol spoken by Compx-based 2.4 GHz mice (E-Yooso X-33, Pulsar X2,
/// VGN, Attack Shark, ...). Every exchange is a 17-byte HID frame:
///
///     [0]  report id (0x08 request, 0x09 reply)
///     [1]  command
///     [2]  status in replies (0 = accepted)
///     [3]  flash address, high byte
///     [4]  flash address, low byte
///     [5]  payload length
///     [6…15] payload (10 bytes)
///     [16] checksum: (0x55 - sum(bytes 0…15)) & 0xff
public enum Compx {
    public static let vendorID = 0x25a7
    /// 2.4G receiver dongle.
    public static let receiverProductID = 0xfa07
    /// The mouse itself when plugged in by cable ("2.4G Dual Mode Mouse").
    public static let wiredProductID = 0xfa08
    public static let productIDs = [receiverProductID, wiredProductID]
    public static let configUsagePage = 0xff02
    public static let configUsage = 2
    public static let commandReportID: UInt8 = 0x08
    public static let responseReportID: UInt8 = 0x09
    public static let frameLength = 17
    public static let maxPayload = 10

    public enum Command: UInt8 {
        case deviceOnline = 0x03
        case battery = 0x04
        case writeFlash = 0x07
        case readFlash = 0x08
        case restoreDefaults = 0x09
        case deviceEvent = 0x0a
        case getCurrentConfig = 0x0e
        case setCurrentConfig = 0x0f
        case readVersion = 0x12
        case dongleVersion = 0x1d
        case rssi = 0x2b
    }

    /// Flash (settings memory) layout. Each setting byte is followed by its
    /// own checksum byte `(0x55 - value) & 0xff`; DPI stages are 4-byte records.
    public enum Flash {
        public static let reportRate = 0x00
        public static let dpiStageCount = 0x02
        public static let currentDpiStage = 0x04
        public static let liftOffDistance = 0x0a
        public static let dpiValues = 0x0c
        public static let dpiRecordSize = 4
        public static let maxDpiStages = 8
        public static let debounceTime = 0xa9
        public static let motionSync = 0xab
        public static let sleepTime = 0xad
        public static let angleSnapping = 0xaf
        public static let rippleControl = 0xb1
        public static let performanceState = 0xb5
        public static let performanceTime = 0xb7
        /// Exclusive end of the region the app reads to build `MouseSettings`.
        public static let readEnd = 0xb9
    }

    public static let pollingRates = [125, 250, 500, 1000]
    public static let sleepMinutes = [1, 3, 6, 12, 30, 60, 180]
    public static let liftOffDistancesMM = [1, 2]
    public static let dpiMin = 50
    public static let dpiMax = 26000
    public static let dpiStep = 50

    public static func checksum<C: Collection>(_ bytes: C) -> UInt8 where C.Element == UInt8 {
        let sum = bytes.reduce(0) { $0 &+ Int($1) }
        return UInt8((0x55 - (sum & 0xff)) & 0xff)
    }

    public static func isValid(_ frame: [UInt8]) -> Bool {
        frame.count == frameLength && checksum(frame[0..<16]) == frame[16]
    }

    /// Builds a request frame. `length` defaults to `data.count`; a few
    /// commands (host control) carry a flag byte without declaring a length.
    public static func frame(_ command: Command, address: Int = 0, length: Int? = nil, data: [UInt8] = []) -> [UInt8] {
        precondition(data.count <= maxPayload, "payload too long")
        var f = [UInt8](repeating: 0, count: frameLength)
        f[0] = commandReportID
        f[1] = command.rawValue
        f[3] = UInt8((address >> 8) & 0xff)
        f[4] = UInt8(address & 0xff)
        f[5] = UInt8(length ?? data.count)
        for (i, b) in data.enumerated() { f[6 + i] = b }
        f[16] = checksum(f[0..<16])
        return f
    }

    // MARK: Polling rate

    public static func decodePollingRate(_ encoded: UInt8) -> Int? {
        if encoded == 0 { return nil }
        if encoded >= 16 { return Int(encoded) / 16 * 2000 }
        return 1000 / Int(encoded)
    }

    public static func encodePollingRate(_ hz: Int) -> UInt8? {
        guard pollingRates.contains(hz) else { return nil }
        return UInt8(1000 / hz)
    }

    // MARK: DPI (flat 50-step encoding used by Areson/VGN receivers)

    public static func decodeDpi(_ record: [UInt8]) -> Int? {
        guard record.count >= 4 else { return nil }
        let low = record[0], dup = record[1], flags = record[2], sum = record[3]
        guard low == dup, (Int(low) + Int(dup) + Int(flags) + Int(sum)) & 0xff == 0x55 else { return nil }
        let high = Int((flags >> 2) & 0x03)
        return ((high << 8) + Int(low) + 1) * dpiStep
    }

    public static func encodeDpi(_ dpi: Int) -> [UInt8]? {
        guard dpi >= dpiMin, dpi <= dpiMax, dpi % dpiStep == 0 else { return nil }
        let encoded = dpi / dpiStep - 1
        let low = UInt8(encoded & 0xff)
        let high = UInt8((encoded >> 8) & 0x03)
        let flags = (high << 2) | (high << 6)
        return [low, low, flags, checksum([low, low, flags])]
    }

    // MARK: Battery

    public static func parseBattery(_ reply: [UInt8]) -> BatteryStatus? {
        guard reply.count >= 10, reply[1] == Command.battery.rawValue else { return nil }
        return BatteryStatus(
            percent: min(Int(reply[6]), 100),
            charging: reply[7] == 1,
            millivolts: Int(reply[8]) << 8 | Int(reply[9])
        )
    }

    public static func parseVersion(_ reply: [UInt8]) -> String? {
        guard reply.count >= 8, reply[2] == 0 else { return nil }
        return String(format: "v%d.%02x", reply[6], reply[7])
    }
}

public struct BatteryStatus: Equatable {
    public var percent: Int
    public var charging: Bool
    public var millivolts: Int

    public init(percent: Int, charging: Bool, millivolts: Int) {
        self.percent = percent
        self.charging = charging
        self.millivolts = millivolts
    }

    public var volts: Double { Double(millivolts) / 1000 }
}

public struct MouseSettings: Equatable {
    public var pollingRateHz: Int?
    public var dpiStageCount: Int
    public var activeDpiStage: Int
    public var dpiStages: [Int?]
    public var liftOffDistanceMM: Int?
    public var debounceMs: Int?
    public var motionSync: Bool
    public var sleepMinutes: Int?
    public var angleSnapping: Bool
    public var rippleControl: Bool
    public var supportsSleepTimer = true
    public var supportsDebounce = true
    public var supportsLiftOff = true
    public var raw: [UInt8]

    public init(flash: [UInt8]) {
        func byte(_ i: Int) -> UInt8? { i < flash.count ? flash[i] : nil }
        raw = flash
        pollingRateHz = byte(Compx.Flash.reportRate).flatMap(Compx.decodePollingRate)
        dpiStageCount = min(max(Int(byte(Compx.Flash.dpiStageCount) ?? 1), 1), Compx.Flash.maxDpiStages)
        activeDpiStage = min(Int(byte(Compx.Flash.currentDpiStage) ?? 0), dpiStageCount - 1)
        dpiStages = (0..<dpiStageCount).map { stage in
            let start = Compx.Flash.dpiValues + stage * Compx.Flash.dpiRecordSize
            guard start + 4 <= flash.count else { return nil }
            return Compx.decodeDpi(Array(flash[start..<start + 4]))
        }
        let lod = Int(byte(Compx.Flash.liftOffDistance) ?? 0)
        liftOffDistanceMM = Compx.liftOffDistancesMM.contains(lod) ? lod : nil
        // 0xff means the firmware never programmed that byte: the setting does not exist on this model.
        debounceMs = byte(Compx.Flash.debounceTime).flatMap { $0 == 0xff ? nil : Int($0) }
        motionSync = byte(Compx.Flash.motionSync) == 1
        let sleep = Int(byte(Compx.Flash.sleepTime) ?? 0)
        sleepMinutes = (sleep > 0 && sleep != 0xff) ? sleep : nil
        supportsSleepTimer = byte(Compx.Flash.sleepTime) != 0xff
        supportsDebounce = byte(Compx.Flash.debounceTime) != 0xff
        supportsLiftOff = byte(Compx.Flash.liftOffDistance) != 0xff
        angleSnapping = byte(Compx.Flash.angleSnapping) == 1
        rippleControl = byte(Compx.Flash.rippleControl) == 1
    }

    public var activeDpi: Int? {
        activeDpiStage < dpiStages.count ? dpiStages[activeDpiStage] : nil
    }
}
