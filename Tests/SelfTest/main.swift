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

print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
