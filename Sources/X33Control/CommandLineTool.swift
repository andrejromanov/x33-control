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
    static let modes = ["--battery", "--settings", "--dump", "--raw", "--set", "--measure"]
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
                let flash = try controller.dumpFlash()
                for row in stride(from: 0, to: flash.count, by: 16) {
                    print(String(format: "%04x: ", row) + hex(flash[row..<min(row + 16, flash.count)]))
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
        default: throw CompxError.unsupportedValue("setting \(p.first ?? "")")
        }
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
            "firmwareMouse": \(fw.mouse.map { "\"\($0)\"" } ?? "null"), "firmwareDongle": \(fw.dongle.map { "\"\($0)\"" } ?? "null")}
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
