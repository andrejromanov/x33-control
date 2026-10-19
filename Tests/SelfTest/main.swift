// Protocol self-test. Built and run by `make test` (no XCTest needed).
import Foundation

var failures = 0
func check(_ ok: Bool, _ what: String, file: String = #file, line: Int = #line) {
    if ok { print("  ok   \(what)") } else { failures += 1; print("  FAIL \(what)  (\(file):\(line))") }
}

print("Compx frame")
let request = Compx.frame(.battery)
check(request.count == 17 && request[0] == 0x08 && request[1] == 0x04 && request[16] == 0x49, "battery request is 08 04 00…00 49")
check(Compx.isValid(request), "battery request checksum valid")
let online = Compx.frame(.deviceOnline, length: 0, data: [1])
check(online[5] == 0 && online[6] == 1 && Compx.isValid(online), "host-control frame keeps length 0, flag at byte 6")

print("Battery reply")
let reply: [UInt8] = [0x08, 0x04, 0x00, 0x00, 0x00, 0x02, 0x5f, 0x00, 0x10, 0x22, 0, 0, 0, 0, 0, 0, 0xb6]
check(Compx.isValid(reply), "sample reply checksum valid")
check(Compx.parseBattery(reply) == BatteryStatus(percent: 95, charging: false, millivolts: 4130), "95 % / 4130 mV / discharging")

print("DPI codec")
for dpi in [50, 400, 800, 1600, 3200, 12800, 16000, 26000] {
    check(Compx.encodeDpi(dpi).flatMap(Compx.decodeDpi) == dpi, "round-trip \(dpi)")
}
check(Compx.encodeDpi(825) == nil, "rejects 825")
check(Compx.decodeDpi([1, 2, 0, 0]) == nil, "rejects corrupt record")

print("Polling rate")
check(Compx.encodePollingRate(1000) == 1 && Compx.encodePollingRate(125) == 8, "encode 1000/125")
check(Compx.encodePollingRate(2000) == nil, "rejects 2000")
check(Compx.decodePollingRate(2) == 500 && Compx.decodePollingRate(16) == 2000, "decode 2/16")

print("Settings parsing")
var flash = [UInt8](repeating: 0, count: Compx.Flash.readEnd)
flash[Compx.Flash.reportRate] = 1
flash[Compx.Flash.dpiStageCount] = 3
flash[Compx.Flash.currentDpiStage] = 1
flash[Compx.Flash.liftOffDistance] = 2
for (i, dpi) in [800, 1600, 3200].enumerated() {
    let start = Compx.Flash.dpiValues + i * 4
    flash.replaceSubrange(start..<start + 4, with: Compx.encodeDpi(dpi)!)
}
flash[Compx.Flash.sleepTime] = 30
flash[Compx.Flash.motionSync] = 1
let s = MouseSettings(flash: flash)
check(s.pollingRateHz == 1000, "polling 1000")
check(s.dpiStageCount == 3 && s.activeDpiStage == 1 && s.dpiStages == [800, 1600, 3200] && s.activeDpi == 1600, "dpi stages")
check(s.liftOffDistanceMM == 2 && s.sleepMinutes == 30 && s.motionSync && !s.angleSnapping, "lod/sleep/flags")

print("Buttons")
check(ButtonAction.mouse(.left).record == [0x01, 0x01, 0x00, 0x53], "left click record 01 01 00 53")
check(ButtonAction.fire(intervalMs: 20, times: 3).record == [0x04, 0x14, 0x03, 0x3a], "fire key record 04 14 03 3a (factory)")
check(ButtonAction(record: [0x05, 0x00, 0x00, 0x50]) == .shortcut, "type 5 is a shortcut slot")
check(ButtonAction(record: [0x0b, 0x02, 0x00, 0x48]) == .scroll(.down), "0b 02 is scroll down")
for a in ButtonAction.simpleChoices { check(ButtonAction(record: a.record) == a, "round-trip \(a.label)") }

print("Shortcuts")
let factorySlot0: [UInt8] = [0x04, 0x80, 0x01, 0x00, 0x81, 0x52, 0x00, 0x40, 0x01, 0x00, 0x41, 0x52, 0x00, 0x29]
let sc0 = Shortcut(record: factorySlot0)
check(sc0 == Shortcut(modifiers: .control, key: 0x52) && sc0?.label == "⌃↑", "factory slot 0 decodes to ⌃↑")
check(Shortcut(modifiers: .control, key: 0x52).record == factorySlot0, "⌃↑ encodes byte-for-byte like the factory")
check(Shortcut(record: [0x02, 0x81, 0x57, 0x00, 0x41, 0x57, 0x00, 0xe3]) == Shortcut(modifiers: [], key: 0x57), "single key slot (keypad +)")
check(Shortcut(media: 0x00cd).record == [0x02, 0x82, 0xcd, 0x00, 0x42, 0xcd, 0x00, 0xf5], "play/pause media record")
check(Shortcut(record: [0xff, 0xff]) == nil && Shortcut(record: [0x00]) == nil, "empty slots decode to nil")
let combo = Shortcut(modifiers: [.command, .shift], key: 0x04)
check(Shortcut(record: combo.record) == combo && combo.label == "⇧⌘A", "⇧⌘A round-trip")
check(HIDKeys.usage(forMacKeyCode: 0) == 0x04 && HIDKeys.usage(forName: "f5") == 0x3e, "key tables")

print("Lights")
var lightFlash = [UInt8](repeating: 0xff, count: Compx.Flash.readEnd)
lightFlash.replaceSubrange(0x54..<0x5e, with: [0x60, 0x19, 0x86, 0x56, 0x02, 0x53, 0xb4, 0xa1, 0x02, 0x53])
let light = LightSettings(flash: lightFlash)
check(light?.mode == 2 && light?.color == RGB(0x60, 0x19, 0x86) && light?.brightness == 0xb4 && light?.speed == 2, "factory light block parses (breathing purple)")
check(light?.record == [0x60, 0x19, 0x86, 0x56, 0x02, 0x53, 0xb4, 0xa1, 0x02, 0x53], "light record round-trips")
check(LightSettings(mode: 1, color: RGB(0, 255, 0), brightness: 0xff, speed: 3).record == [0x00, 0xff, 0x00, 0x56, 0x01, 0x54, 0xff, 0x56, 0x03, 0x52], "steady green record (verified on the mouse)")
check(RGB(hex: "#ff8000") == RGB(255, 128, 0) && RGB(255, 0, 0).record == [0xff, 0, 0, 0x56], "rgb parsing and record")
check(Compx.encodeLightBrightness(percent: 100) == 0xff && Compx.decodeLightBrightness(0x80) == 50, "brightness scale")

print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
