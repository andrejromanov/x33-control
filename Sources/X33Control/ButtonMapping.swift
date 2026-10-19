import Foundation

// Button assignments and keyboard shortcuts, as stored in the mouse's flash.
//
// Each of the 16 button slots is a 4-byte record at 0x60 + 4·slot:
//
//     [type] [param hi] [param lo] [checksum]
//
// Type 5 ("shortcut") keeps the actual keys in a 32-byte slot at
// 0x100 + 0x20·slot holding an event list:
//
//     [2n] ([kind|0x80] [lo] [hi]) × n  ([kind|0x40] [lo] [hi]) × n  [checksum]
//
// presses then releases, both in order. kind: 0 modifier bitmask,
// 1 keyboard usage, 2 consumer (media) usage.
//
// Sources: the Compx "Control Hub" web driver (MouseKeyFunction table and
// ShortcutKey writer) and open-m711pro's hardware captures of a mouse with the
// same vendor id as the X-33.

public enum ButtonAction: Equatable {
    case disabled
    case mouse(MouseButton)
    case dpi(DpiAction)
    case scroll(ScrollDirection)
    case fire(intervalMs: Int, times: Int)
    /// Keys live in the shortcut slot of the same index.
    case shortcut
    case macro(cycles: Int)
    case pollingRateSwitch
    case lightSwitch
    case profileSwitch
    case dpiLock(raw: UInt8)
    case unknown(type: UInt8, param: UInt16)

    public enum MouseButton: UInt8, CaseIterable {
        case left = 0x01, right = 0x02, middle = 0x04, back = 0x08, forward = 0x10
        public var label: String {
            switch self {
            case .left: return "Left Click"
            case .right: return "Right Click"
            case .middle: return "Middle Click"
            case .back: return "Back"
            case .forward: return "Forward"
            }
        }
    }

    public enum DpiAction: UInt8, CaseIterable {
        case loop = 1, up = 2, down = 3
        public var label: String {
            switch self {
            case .loop: return "DPI Loop"
            case .up: return "DPI +"
            case .down: return "DPI −"
            }
        }
    }

    public enum ScrollDirection: CaseIterable {
        case left, right, up, down
        public var label: String {
            switch self {
            case .left: return "Scroll Left"
            case .right: return "Scroll Right"
            case .up: return "Scroll Up"
            case .down: return "Scroll Down"
            }
        }
    }

    public static let typeDisabled: UInt8 = 0x00
    public static let typeMouse: UInt8 = 0x01
    public static let typeDpi: UInt8 = 0x02
    public static let typeScrollHorizontal: UInt8 = 0x03
    public static let typeFire: UInt8 = 0x04
    public static let typeShortcut: UInt8 = 0x05
    public static let typeMacro: UInt8 = 0x06
    public static let typePollingRateSwitch: UInt8 = 0x07
    public static let typeLightSwitch: UInt8 = 0x08
    public static let typeProfileSwitch: UInt8 = 0x09
    public static let typeDpiLock: UInt8 = 0x0a
    public static let typeScrollVertical: UInt8 = 0x0b

    /// The three payload bytes (type, param hi, param lo).
    public var bytes: [UInt8] {
        switch self {
        case .disabled: return [Self.typeDisabled, 0, 0]
        case .mouse(let b): return [Self.typeMouse, b.rawValue, 0]
        case .dpi(let a): return [Self.typeDpi, a.rawValue, 0]
        case .scroll(.left): return [Self.typeScrollHorizontal, 1, 0]
        case .scroll(.right): return [Self.typeScrollHorizontal, 2, 0]
        case .scroll(.up): return [Self.typeScrollVertical, 1, 0]
        case .scroll(.down): return [Self.typeScrollVertical, 2, 0]
        case .fire(let interval, let times):
            return [Self.typeFire, UInt8(min(max(interval, 10), 255)), UInt8(min(max(times, 0), 3))]
        case .shortcut: return [Self.typeShortcut, 0, 0]
        case .macro(let cycles): return [Self.typeMacro, 0, UInt8(min(max(cycles, 0), 255))]
        case .pollingRateSwitch: return [Self.typePollingRateSwitch, 0, 0]
        case .lightSwitch: return [Self.typeLightSwitch, 0, 0]
        case .profileSwitch: return [Self.typeProfileSwitch, 0, 0]
        case .dpiLock(let raw): return [Self.typeDpiLock, raw, 0]
        case .unknown(let type, let param): return [type, UInt8(param >> 8), UInt8(param & 0xff)]
        }
    }

    /// The 4-byte flash record.
    public var record: [UInt8] {
        let b = bytes
        return b + [Compx.checksum(b)]
    }

    public init(record: [UInt8]) {
        guard record.count >= 3 else { self = .disabled; return }
        let type = record[0], hi = record[1], lo = record[2]
        switch type {
        case Self.typeDisabled: self = .disabled
        case Self.typeMouse:
            if let b = MouseButton(rawValue: hi) { self = .mouse(b) } else { self = .unknown(type: type, param: UInt16(hi) << 8 | UInt16(lo)) }
        case Self.typeDpi:
            if let a = DpiAction(rawValue: hi) { self = .dpi(a) } else { self = .unknown(type: type, param: UInt16(hi) << 8 | UInt16(lo)) }
        case Self.typeScrollHorizontal where hi == 1: self = .scroll(.left)
        case Self.typeScrollHorizontal where hi == 2: self = .scroll(.right)
        case Self.typeScrollVertical where hi == 1: self = .scroll(.up)
        case Self.typeScrollVertical where hi == 2: self = .scroll(.down)
        case Self.typeFire: self = .fire(intervalMs: Int(hi), times: Int(lo))
        case Self.typeShortcut: self = .shortcut
        case Self.typeMacro: self = .macro(cycles: Int(lo))
        case Self.typePollingRateSwitch: self = .pollingRateSwitch
        case Self.typeLightSwitch: self = .lightSwitch
        case Self.typeProfileSwitch: self = .profileSwitch
        case Self.typeDpiLock: self = .dpiLock(raw: hi)
        default: self = .unknown(type: type, param: UInt16(hi) << 8 | UInt16(lo))
        }
    }

    public var label: String {
        switch self {
        case .disabled: return "Disabled"
        case .mouse(let b): return b.label
        case .dpi(let a): return a.label
        case .scroll(let d): return d.label
        case .fire(let interval, let times):
            return times == 0 ? "Fire Key (hold, every \(interval) ms)" : "Fire Key (\(times)× every \(interval) ms)"
        case .shortcut: return "Keyboard Shortcut"
        case .macro(let cycles): return "Macro ×\(cycles)"
        case .pollingRateSwitch: return "Polling Rate Switch"
        case .lightSwitch: return "Light On/Off"
        case .profileSwitch: return "Profile Switch"
        case .dpiLock(let raw): return "DPI Lock (\(raw))"
        case .unknown(let type, let param): return String(format: "Unknown (%02x %04x)", type, param)
        }
    }

    /// Menu choices that need no extra parameters.
    public static let simpleChoices: [ButtonAction] =
        MouseButton.allCases.map { .mouse($0) }
        + DpiAction.allCases.map { .dpi($0) }
        + ScrollDirection.allCases.map { .scroll($0) }
        + [.fire(intervalMs: 20, times: 3), .fire(intervalMs: 50, times: 0), .pollingRateSwitch, .lightSwitch, .disabled]
}

/// A key combination or media key, as stored in a shortcut slot.
public struct Shortcut: Equatable {
    public enum Event: Equatable {
        case modifiers(UInt8)   // HID modifier bitmask, see `Modifier`
        case key(UInt8)         // HID keyboard usage
        case media(UInt16)      // HID consumer usage

        var kind: UInt8 {
            switch self {
            case .modifiers: return 0
            case .key: return 1
            case .media: return 2
            }
        }
        var value: UInt16 {
            switch self {
            case .modifiers(let m): return UInt16(m)
            case .key(let k): return UInt16(k)
            case .media(let u): return u
            }
        }
    }

    public struct Modifier: OptionSet {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let control = Modifier(rawValue: 0x01)
        public static let shift = Modifier(rawValue: 0x02)
        public static let option = Modifier(rawValue: 0x04)
        public static let command = Modifier(rawValue: 0x08)
        public static let rightControl = Modifier(rawValue: 0x10)
        public static let rightShift = Modifier(rawValue: 0x20)
        public static let rightOption = Modifier(rawValue: 0x40)
        public static let rightCommand = Modifier(rawValue: 0x80)
    }

    public static let slotSize = 0x20
    public static let maxEvents = 5   // 2 + 3·2·5 = 32 bytes

    /// Presses, in order. Releases are generated in the same order.
    public var presses: [Event]

    public init(presses: [Event]) { self.presses = presses }

    public init(modifiers: Modifier, key: UInt8) {
        presses = modifiers.isEmpty ? [.key(key)] : [.modifiers(modifiers.rawValue), .key(key)]
    }

    public init(media: UInt16) { presses = [.media(media)] }

    /// The event list with its checksum, ready to write at the slot address.
    public var record: [UInt8] {
        var out: [UInt8] = [UInt8(presses.count * 2)]
        for e in presses { out += [e.kind | 0x80, UInt8(e.value & 0xff), UInt8(e.value >> 8)] }
        // Releases follow in the same order: that is how the factory firmware fills its own slots.
        for e in presses { out += [e.kind | 0x40, UInt8(e.value & 0xff), UInt8(e.value >> 8)] }
        out.append(Compx.checksum(out))
        return out
    }

    /// Parses a slot. Returns nil for an empty or malformed slot.
    public init?(record: [UInt8]) {
        guard let count = record.first, count >= 2, count % 2 == 0 else { return nil }
        let n = Int(count) / 2
        guard record.count >= 1 + Int(count) * 3 + 1 else { return nil }
        var presses: [Event] = []
        for i in 0..<n {
            let base = 1 + i * 3
            let kind = record[base] & 0x0f
            let value = UInt16(record[base + 2]) << 8 | UInt16(record[base + 1])
            switch kind {
            case 0: presses.append(.modifiers(UInt8(value & 0xff)))
            case 1: presses.append(.key(UInt8(value & 0xff)))
            case 2: presses.append(.media(value))
            default: return nil
            }
        }
        self.presses = presses
    }

    public var label: String {
        var parts: [String] = []
        for e in presses {
            switch e {
            case .modifiers(let m): parts.append(Modifier(rawValue: m).label)
            case .key(let k): parts.append(HIDKeys.name(forUsage: k))
            case .media(let u): parts.append(HIDKeys.mediaName(forUsage: u))
            }
        }
        return parts.joined()
    }
}

extension Shortcut.Modifier {
    /// macOS-style glyphs, in the conventional order.
    public var label: String {
        var s = ""
        if contains(.control) || contains(.rightControl) { s += "⌃" }
        if contains(.option) || contains(.rightOption) { s += "⌥" }
        if contains(.shift) || contains(.rightShift) { s += "⇧" }
        if contains(.command) || contains(.rightCommand) { s += "⌘" }
        return s
    }
}

/// HID usage tables for the keys a mouse button can emit.
public enum HIDKeys {
    public struct Key: Equatable {
        public let usage: UInt8
        public let name: String
        /// macOS virtual key code (Carbon kVK_*), or nil when the key has no Mac equivalent.
        public let macKeyCode: UInt16?
    }

    public static let keys: [Key] = {
        var k: [Key] = []
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        let letterCodes: [UInt16] = [0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46, 45, 31, 35, 12, 15, 1, 17, 32, 9, 13, 7, 16, 6]
        for (i, c) in letters.enumerated() { k.append(Key(usage: 0x04 + UInt8(i), name: String(c), macKeyCode: letterCodes[i])) }
        let digitCodes: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25, 29]
        for i in 0..<9 { k.append(Key(usage: 0x1e + UInt8(i), name: "\(i + 1)", macKeyCode: digitCodes[i])) }
        k.append(Key(usage: 0x27, name: "0", macKeyCode: 29))
        k += [
            Key(usage: 0x28, name: "↩", macKeyCode: 36), Key(usage: 0x29, name: "⎋", macKeyCode: 53),
            Key(usage: 0x2a, name: "⌫", macKeyCode: 51), Key(usage: 0x2b, name: "⇥", macKeyCode: 48),
            Key(usage: 0x2c, name: "Space", macKeyCode: 49), Key(usage: 0x2d, name: "-", macKeyCode: 27),
            Key(usage: 0x2e, name: "=", macKeyCode: 24), Key(usage: 0x2f, name: "[", macKeyCode: 33),
            Key(usage: 0x30, name: "]", macKeyCode: 30), Key(usage: 0x31, name: "\\", macKeyCode: 42),
            Key(usage: 0x33, name: ";", macKeyCode: 41), Key(usage: 0x34, name: "'", macKeyCode: 39),
            Key(usage: 0x35, name: "`", macKeyCode: 50), Key(usage: 0x36, name: ",", macKeyCode: 43),
            Key(usage: 0x37, name: ".", macKeyCode: 47), Key(usage: 0x38, name: "/", macKeyCode: 44),
            Key(usage: 0x39, name: "Caps Lock", macKeyCode: 57),
        ]
        let fCodes: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
        for i in 0..<12 { k.append(Key(usage: 0x3a + UInt8(i), name: "F\(i + 1)", macKeyCode: fCodes[i])) }
        k += [
            Key(usage: 0x46, name: "Print Screen", macKeyCode: nil), Key(usage: 0x47, name: "Scroll Lock", macKeyCode: nil),
            Key(usage: 0x48, name: "Pause", macKeyCode: nil), Key(usage: 0x49, name: "Insert", macKeyCode: 114),
            Key(usage: 0x4a, name: "Home", macKeyCode: 115), Key(usage: 0x4b, name: "Page Up", macKeyCode: 116),
            Key(usage: 0x4c, name: "⌦", macKeyCode: 117), Key(usage: 0x4d, name: "End", macKeyCode: 119),
            Key(usage: 0x4e, name: "Page Down", macKeyCode: 121), Key(usage: 0x4f, name: "→", macKeyCode: 124),
            Key(usage: 0x50, name: "←", macKeyCode: 123), Key(usage: 0x51, name: "↓", macKeyCode: 125),
            Key(usage: 0x52, name: "↑", macKeyCode: 126), Key(usage: 0x53, name: "Num Lock", macKeyCode: 71),
            Key(usage: 0x54, name: "Keypad /", macKeyCode: 75), Key(usage: 0x55, name: "Keypad *", macKeyCode: 67),
            Key(usage: 0x56, name: "Keypad -", macKeyCode: 78), Key(usage: 0x57, name: "Keypad +", macKeyCode: 69),
            Key(usage: 0x58, name: "Keypad ↩", macKeyCode: 76),
        ]
        let kpCodes: [UInt16] = [83, 84, 85, 86, 87, 88, 89, 91, 92]
        for i in 0..<9 { k.append(Key(usage: 0x59 + UInt8(i), name: "Keypad \(i + 1)", macKeyCode: kpCodes[i])) }
        k += [
            Key(usage: 0x62, name: "Keypad 0", macKeyCode: 82), Key(usage: 0x63, name: "Keypad .", macKeyCode: 65),
            Key(usage: 0x67, name: "Keypad =", macKeyCode: 81),
            Key(usage: 0x68, name: "F13", macKeyCode: 105), Key(usage: 0x69, name: "F14", macKeyCode: 107),
            Key(usage: 0x6a, name: "F15", macKeyCode: 113), Key(usage: 0x6b, name: "F16", macKeyCode: 106),
            Key(usage: 0x6c, name: "F17", macKeyCode: 64), Key(usage: 0x6d, name: "F18", macKeyCode: 79),
            Key(usage: 0x6e, name: "F19", macKeyCode: 80), Key(usage: 0x6f, name: "F20", macKeyCode: 90),
        ]
        return k
    }()

    public static func name(forUsage usage: UInt8) -> String {
        keys.first { $0.usage == usage }?.name ?? String(format: "Key %02x", usage)
    }

    public static func usage(forMacKeyCode code: UInt16) -> UInt8? {
        keys.first { $0.macKeyCode == code }?.usage
    }

    /// Case-insensitive lookup by the names above, plus a few aliases for the CLI.
    public static func usage(forName name: String) -> UInt8? {
        let n = name.lowercased()
        let aliases: [String: UInt8] = [
            "enter": 0x28, "return": 0x28, "esc": 0x29, "escape": 0x29, "backspace": 0x2a, "tab": 0x2b,
            "space": 0x2c, "delete": 0x4c, "del": 0x4c, "left": 0x50, "right": 0x4f, "up": 0x52, "down": 0x51,
            "pageup": 0x4b, "pagedown": 0x4e, "capslock": 0x39,
        ]
        if let u = aliases[n] { return u }
        return keys.first { $0.name.lowercased() == n }?.usage
    }

    public struct Media: Equatable {
        public let usage: UInt16
        public let name: String
    }

    public static let media: [Media] = [
        Media(usage: 0x00cd, name: "Play/Pause"), Media(usage: 0x00b5, name: "Next Track"),
        Media(usage: 0x00b6, name: "Previous Track"), Media(usage: 0x00b7, name: "Stop"),
        Media(usage: 0x00e2, name: "Mute"), Media(usage: 0x00e9, name: "Volume Up"),
        Media(usage: 0x00ea, name: "Volume Down"), Media(usage: 0x006f, name: "Brightness Up"),
        Media(usage: 0x0070, name: "Brightness Down"), Media(usage: 0x0183, name: "Media Player"),
        Media(usage: 0x018a, name: "Email"), Media(usage: 0x0192, name: "Calculator"),
        Media(usage: 0x0194, name: "File Browser"), Media(usage: 0x0223, name: "Browser Home"),
        Media(usage: 0x0221, name: "Search"), Media(usage: 0x0224, name: "Browser Back"),
        Media(usage: 0x0225, name: "Browser Forward"), Media(usage: 0x0226, name: "Browser Stop"),
        Media(usage: 0x0227, name: "Browser Refresh"), Media(usage: 0x022a, name: "Bookmarks"),
    ]

    public static func mediaName(forUsage usage: UInt16) -> String {
        media.first { $0.usage == usage }?.name ?? String(format: "Media %04x", usage)
    }
}
