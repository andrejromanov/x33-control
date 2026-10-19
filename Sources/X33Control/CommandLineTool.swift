import Foundation

/// Headless mode. Usage:
///   X33Control --battery [--json]
///   X33Control --settings [--json]
///   X33Control --dump
///   X33Control --raw <hex bytes>          send one frame: command byte first, report id and checksum added
///   X33Control --set <setting> <value…>   polling|stage|stages|dpi <stage> <dpi>|lod|sleep|debounce|motionsync|anglesnap|ripple|restore
///   X33Control --measure [seconds]        count real mouse reports to verify the polling rate (move the mouse)
///   --output <path>                       write stdout/stderr to a file (for launching through `open`)
enum CommandLineTool {
    static let modes = ["--battery", "--settings", "--dump", "--raw", "--write", "--set", "--measure"]
    private static var keepAlive: MouseController?
    private static var keepAliveMeter: PollingMeter?

    static func run(_ args: [String]) -> Int32 {
        var args = args
        if let i = args.firstIndex(of: "--output"), i + 1 < args.count {
            let path = args[i + 1]
            args.removeSubrange(i...i + 1)
            freopen(path, "w", stdout)
            freopen(path, "a", stderr)
            setvbuf(stdout, nil, _IONBF, 0)
            setvbuf(stderr, nil, _IONBF, 0)
        }
        defer { fflush(stdout); fflush(stderr) }
        let json = args.contains("--json")
        guard let modeIndex = args.firstIndex(where: modes.contains) else { return 1 }
        let mode = args[modeIndex]
        let params = Array(args[(modeIndex + 1)...]).filter { $0 != "--json" }

        // The transport's IOHIDManager runs on a dispatch queue and must stay alive until exit.
        if mode == "--measure" {
            let meter = PollingMeter()
            keepAliveMeter = meter
            do { try meter.start() } catch { fputs("error: \(error.localizedDescription)\n", stderr); return 2 }
            let seconds = params.first.flatMap(Double.init) ?? 5
            let r = meter.measure(seconds: seconds)
            print("reports: \(r.count) in \(Int(seconds)) s, peak \(r.peakPerSecond)/s, median interval → \(r.hz.map { "\($0) Hz" } ?? "n/a (move the mouse)")")
            return r.count > 10 ? 0 : 5
        }

        let controller = MouseController()
        keepAlive = controller
        do {
            try controller.start()
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            return 2
        }
        let deadline = Date().addingTimeInterval(2)
        while !controller.transport.isConnected && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        guard controller.transport.isConnected else {
            fputs("error: \(CompxError.noDevice.localizedDescription)\n", stderr)
            return 3
        }
        do {
            switch mode {
            case "--battery":
                let b = try controller.readBattery()
                let via = controller.transport.link?.label ?? "?"
                if json {
                    print(#"{"percent": \#(b.percent), "charging": \#(b.charging), "millivolts": \#(b.millivolts)}"#)
                } else {
                    print("Battery: \(b.percent)% (\(String(format: "%.2f", b.volts)) V) \(b.charging ? "charging" : "discharging") via \(via)")
                }
            case "--settings":
                printSettings(try controller.readSettings(), controller.readFirmware(), json: json)
            case "--dump":
                let start = params.count > 0 ? Int(params[0].replacingOccurrences(of: "0x", with: ""), radix: 16) ?? 0 : 0
                let length = params.count > 1 ? Int(params[1].replacingOccurrences(of: "0x", with: ""), radix: 16) ?? 0x100 : 0x100
                let flash = try controller.dumpFlash(address: start, length: length)
                for row in stride(from: 0, to: flash.count, by: 16) {
                    print(String(format: "%04x: ", start + row) + hex(flash[row..<min(row + 16, flash.count)]))
                }
            case "--raw":
                var frame = params.joined().replacingOccurrences(of: " ", with: "").hexBytes
                guard !frame.isEmpty, frame.count <= 15 else { fputs("error: give 1–15 hex bytes, starting with the command\n", stderr); return 1 }
                frame.insert(Compx.commandReportID, at: 0)  // input starts at the command byte
                frame += [UInt8](repeating: 0, count: 16 - frame.count)
                frame.append(Compx.checksum(frame))
                print("send: " + hex(frame))
                let reply = try controller.transport.exchange(frame)
                print("recv: " + hex(reply) + (Compx.isValid(reply) ? "" : "  (bad checksum)"))
            case "--write":
                // --write <hex address> <hex bytes…>: writes under host control, commits, reads back.
                guard params.count >= 2, let address = Int(params[0].replacingOccurrences(of: "0x", with: ""), radix: 16) else {
                    fputs("usage: --write <hex address> <hex bytes>\n", stderr); return 1
                }
                let data = params[1...].joined().replacingOccurrences(of: " ", with: "").hexBytes
                guard !data.isEmpty else { fputs("error: no bytes\n", stderr); return 1 }
                let back = try controller.writeRaw(address: address, data: data)
                print(String(format: "%04x: ", address) + hex(back))
            case "--set":
                try applySetting(controller, params)
                print("ok")
                printSettings(try controller.readSettings(), (nil, nil), json: json)
            default:
                return 1
            }
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            return 4
        }
        return 0
    }

    private static func applySetting(_ c: MouseController, _ p: [String]) throws {
        func int(_ i: Int) throws -> Int {
            guard i < p.count, let v = Int(p[i]) else { throw CompxError.unsupportedValue(p.joined(separator: " ")) }
            return v
        }
        func flag(_ i: Int) throws -> Bool {
            guard i < p.count else { throw CompxError.unsupportedValue(p.joined(separator: " ")) }
            return ["on", "1", "true", "yes"].contains(p[i].lowercased())
        }
        switch p.first {
        case "polling": try c.setPollingRate(try int(1))
        case "stage": try c.setActiveDpiStage(try int(1) - 1)
        case "stages": try c.setDpiStageCount(try int(1))
        case "dpi": try c.setDpi(stage: try int(1) - 1, dpi: try int(2))
        case "lod": try c.setLiftOffDistance(mm: try int(1))
        case "sleep": try c.setSleepMinutes(try int(1))
        case "debounce": try c.setDebounce(ms: try int(1))
        case "motionsync": try c.setMotionSync(try flag(1))
        case "anglesnap": try c.setAngleSnapping(try flag(1))
        case "ripple": try c.setRippleControl(try flag(1))
        case "restore": try c.restoreDefaults()
        case "button":
            let slot = try int(1) - 1
            guard p.count > 2 else { throw CompxError.unsupportedValue("button needs an action") }
            switch p[2].lowercased() {
            case "key":
                guard p.count > 3, let sc = parseShortcut(p[3]) else { throw CompxError.unsupportedValue("key combination \(p.count > 3 ? p[3] : "")") }
                try c.setShortcut(slot: slot, sc)
            case "media":
                guard p.count > 3, let m = HIDKeys.media.first(where: { $0.name.lowercased().replacingOccurrences(of: " ", with: "") == p[3].lowercased() }) else {
                    throw CompxError.unsupportedValue("media key \(p.count > 3 ? p[3] : ""). Known: " + HIDKeys.media.map { $0.name.replacingOccurrences(of: " ", with: "") }.joined(separator: ", "))
                }
                try c.setShortcut(slot: slot, Shortcut(media: m.usage))
            default:
                guard let a = parseAction(Array(p[2...])) else { throw CompxError.unsupportedValue("button action \(p[2])") }
                try c.setButton(slot: slot, action: a)
            }
        case "light":
            // light <mode> [rrggbb|name] [brightness %] [speed 1-5]
            guard p.count > 1 else { throw CompxError.unsupportedValue("light needs a mode") }
            var light = try c.readSettings().light ?? LightSettings(mode: 1, color: RGB(255, 0, 0), brightness: 0xff, speed: 3)
            if let m = LightSettings.Mode.allCases.first(where: { $0.label.lowercased().replacingOccurrences(of: " ", with: "") == p[1].lowercased() }) {
                light.mode = m.rawValue
            } else if let n = UInt8(p[1]) {
                light.mode = n
            } else { throw CompxError.unsupportedValue("light mode \(p[1])") }
            if p.count > 2 { guard let c = parseColor(p[2]) else { throw CompxError.unsupportedValue("colour \(p[2])") }; light.color = c }
            if p.count > 3 { light.brightness = Compx.encodeLightBrightness(percent: try int(3)) }
            if p.count > 4 { light.speed = UInt8(min(max(try int(4), 1), 5)) }
            try c.setLight(light)
        case "dpilight":
            guard p.count > 1, let m = DpiLightSettings.Mode.allCases.first(where: { $0.label.lowercased() == p[1].lowercased() }) else {
                throw CompxError.unsupportedValue("dpilight off|steady|breathing")
            }
            try c.setDpiLight(mode: m)
        case "dpicolor":
            guard p.count > 2, let color = parseColor(p[2]) else { throw CompxError.unsupportedValue("dpicolor <stage> <rrggbb|name>") }
            try c.setDpiColor(stage: try int(1) - 1, color)
        default: throw CompxError.unsupportedValue("setting \(p.first ?? "")")
        }
    }

    static func parseColor(_ text: String) -> RGB? {
        RGB.presets.first { $0.name.lowercased() == text.lowercased() }?.color ?? RGB(hex: text)
    }

    static func parseAction(_ p: [String]) -> ButtonAction? {
        func n(_ i: Int, _ fallback: Int) -> Int { i < p.count ? Int(p[i]) ?? fallback : fallback }
        switch p[0].lowercased() {
        case "left": return .mouse(.left)
        case "right": return .mouse(.right)
        case "middle": return .mouse(.middle)
        case "back": return .mouse(.back)
        case "forward": return .mouse(.forward)
        case "dpiloop": return .dpi(.loop)
        case "dpi+", "dpiup": return .dpi(.up)
        case "dpi-", "dpidown": return .dpi(.down)
        case "scrollleft": return .scroll(.left)
        case "scrollright": return .scroll(.right)
        case "scrollup": return .scroll(.up)
        case "scrolldown": return .scroll(.down)
        case "fire": return .fire(intervalMs: n(1, 20), times: n(2, 3))
        case "polling": return .pollingRateSwitch
        case "light": return .lightSwitch
        case "profile": return .profileSwitch
        case "disable", "off": return .disabled
        default: return nil
        }
    }

    /// "cmd+shift+a", "ctrl+up", "f5", "playpause" (media names without spaces).
    static func parseShortcut(_ text: String) -> Shortcut? {
        var mods = Shortcut.Modifier()
        var key: UInt8?
        for part in text.lowercased().split(separator: "+").map(String.init) {
            switch part {
            case "cmd", "command", "gui", "win", "super": mods.insert(.command)
            case "ctrl", "control": mods.insert(.control)
            case "alt", "option", "opt": mods.insert(.option)
            case "shift": mods.insert(.shift)
            default:
                guard key == nil, let u = HIDKeys.usage(forName: part) else { return nil }
                key = u
            }
        }
        if let key { return Shortcut(modifiers: mods, key: key) }
        if let m = HIDKeys.media.first(where: { $0.name.lowercased().replacingOccurrences(of: " ", with: "") == text.lowercased() }) {
            return Shortcut(media: m.usage)
        }
        return nil
    }

    private static func printSettings(_ s: MouseSettings, _ fw: (mouse: String?, dongle: String?), json: Bool) {
        if json {
            let stages = s.dpiStages.map { $0.map(String.init) ?? "null" }.joined(separator: ", ")
            print("""
            {"pollingRateHz": \(s.pollingRateHz.map(String.init) ?? "null"), "dpiStageCount": \(s.dpiStageCount), \
            "activeDpiStage": \(s.activeDpiStage + 1), "dpiStages": [\(stages)], \
            "liftOffDistanceMM": \(s.liftOffDistanceMM.map(String.init) ?? "null"), "debounceMs": \(s.debounceMs.map(String.init) ?? "null"), \
            "sleepMinutes": \(s.sleepMinutes.map(String.init) ?? "null"), "motionSync": \(s.motionSync), \
            "angleSnapping": \(s.angleSnapping), "rippleControl": \(s.rippleControl), \
            "firmwareMouse": \(fw.mouse.map { "\"\($0)\"" } ?? "null"), "firmwareDongle": \(fw.dongle.map { "\"\($0)\"" } ?? "null"), \
            "buttons": [\((0..<s.buttons.count).map { "\"\(s.buttonLabel($0))\"" }.joined(separator: ", "))], \
            "light": \(s.light.map { "{\"on\": \($0.isOn), \"mode\": \($0.mode), \"color\": \"\($0.color.hex)\", \"speed\": \($0.speed), \"brightness\": \($0.brightness)}" } ?? "null")}
            """)
            return
        }
        print("Polling rate: \(s.pollingRateHz.map { "\($0) Hz" } ?? "unknown")")
        print("DPI stages (\(s.dpiStageCount)), active \(s.activeDpiStage + 1):")
        for (i, dpi) in s.dpiStages.enumerated() {
            print("  \(i == s.activeDpiStage ? "*" : " ") stage \(i + 1): \(dpi.map(String.init) ?? "unknown")")
        }
        print("Lift-off distance: \(s.liftOffDistanceMM.map { "\($0) mm" } ?? "unknown")")
        print("Debounce: \(s.debounceMs.map { "\($0) ms" } ?? "unknown")")
        print("Sleep after: \(s.sleepMinutes.map { "\($0) min" } ?? "unknown")")
        print("Motion sync: \(s.motionSync)  Angle snapping: \(s.angleSnapping)  Ripple control: \(s.rippleControl)")
        if let l = s.light {
            print("Light: \(l.modeLabel) (mode \(l.mode)) colour \(l.color.name) brightness \(Compx.decodeLightBrightness(l.brightness))% speed \(l.speed)")
        }
        if let d = s.dpiLight {
            print("DPI indicator: \(d.effectiveMode.label) (mode \(d.mode), brightness \(d.brightness), speed \(d.speed)); stage colours " + s.dpiColors.map { $0.name }.joined(separator: ", "))
        }
        print("Buttons:")
        for slot in 0..<s.buttons.count {
            print("  \(slot + 1): \(s.buttonLabel(slot))")
        }
        if fw.mouse != nil || fw.dongle != nil {
            print("Firmware: mouse \(fw.mouse ?? "?"), dongle \(fw.dongle ?? "?")")
        }
        print("Raw flash 0x00–0x1f: " + hex(s.raw.prefix(32)))
    }

    private static func hex<C: Collection>(_ bytes: C) -> String where C.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
    }
}

private extension String {
    var hexBytes: [UInt8] {
        var out: [UInt8] = []
        var chars = Array(self)
        if chars.count % 2 == 1 { chars.insert("0", at: 0) }
        for i in stride(from: 0, to: chars.count, by: 2) {
            guard let b = UInt8(String(chars[i...i + 1]), radix: 16) else { return [] }
            out.append(b)
        }
        return out
    }
}
