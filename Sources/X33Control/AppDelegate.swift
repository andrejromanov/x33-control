import AppKit
import ServiceManagement
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let controller = MouseController()
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var actions: [MenuAction] = []

    private var connected = false
    private var battery: BatteryStatus?
    private var settings: MouseSettings?
    private var firmware: (mouse: String?, dongle: String?) = (nil, nil)
    private var lastError: String?
    private var permissionDenied = false
    private var busy = false

    private var batteryTimer: Timer?
    private var eventRefresh: DispatchWorkItem?
    private var lowBatteryWarned = Set<Int>()

    private let batteryInterval: TimeInterval = 60
    private let lowBatteryThresholds = [20, 10, 5]
    private let defaults = UserDefaults.standard
    private let alertsKey = "lowBatteryAlerts"

    private var lowBatteryAlerts: Bool {
        get { defaults.object(forKey: alertsKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: alertsKey) }
    }

    // MARK: Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageLeading
        menu.delegate = self
        statusItem.menu = menu
        updateStatusItem()

        controller.transport.onConnectionChange = { [weak self] connected in
            DispatchQueue.main.async {
                self?.connected = connected
                self?.lastError = nil
                if connected { self?.refreshAll() } else { self?.updateStatusItem() }
            }
        }
        controller.transport.onDeviceEvent = { [weak self] _ in
            DispatchQueue.main.async { self?.scheduleEventRefresh() }
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(systemWoke), name: NSWorkspace.didWakeNotification, object: nil)

        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }

        startTransport()
        batteryTimer = Timer.scheduledTimer(withTimeInterval: batteryInterval, repeats: true) { [weak self] _ in
            self?.refreshBattery()
        }
    }

    private func startTransport() {
        if !CompxTransport.hasPermission() {
            CompxTransport.requestPermission()
        }
        do {
            try controller.start()
            permissionDenied = false
        } catch CompxError.notPermitted {
            permissionDenied = true
            updateStatusItem()
            // Keep retrying: the grant takes effect without relaunching once the user flips the switch.
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.startTransport() }
        } catch {
            lastError = error.localizedDescription
            updateStatusItem()
        }
    }

    @objc private func systemWoke() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.refreshBattery() }
    }

    private func scheduleEventRefresh() {
        eventRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refreshAll() }
        eventRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    // MARK: Refresh

    private func refreshAll() {
        refreshBattery()
        refreshSettings()
    }

    private func refreshBattery() {
        guard connected else { return }
        controller.perform({ try self.controller.readBattery() }) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let b):
                self.battery = b
                self.lastError = nil
                self.checkLowBattery(b)
            case .failure(let error):
                self.lastError = error.localizedDescription
            }
            self.updateStatusItem()
        }
    }

    private func refreshSettings() {
        guard connected else { return }
        controller.perform({ () -> (MouseSettings, (mouse: String?, dongle: String?)) in
            let s = try self.controller.readSettings()
            return (s, self.controller.readFirmware())
        }) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let (s, fw)):
                self.settings = s
                self.firmware = fw
                self.lastError = nil
            case .failure(let error):
                self.lastError = error.localizedDescription
            }
            if self.menu.highlightedItem != nil || self.menuIsOpen { self.rebuildMenu() }
        }
    }

    private var menuIsOpen = false

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
        rebuildMenu()
        refreshAll()
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
    }

    // MARK: Status item

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        if permissionDenied {
            button.image = symbol("exclamationmark.triangle")
            button.title = ""
            button.toolTip = "Input Monitoring permission needed"
        } else if !connected {
            button.image = symbol("computermouse")
            button.title = ""
            button.toolTip = "E-Yooso X-33: not plugged in (receiver or cable)"
        } else if let b = battery {
            button.image = symbol(batterySymbol(for: b))
            button.title = " \(b.percent)%"
            button.toolTip = "E-Yooso X-33: \(b.percent)% · \(String(format: "%.2f", b.volts)) V · \(b.charging ? "charging" : "discharging")"
        } else {
            button.image = symbol("computermouse")
            button.title = lastError == nil ? " …" : " ?"
            button.toolTip = lastError ?? "Reading battery…"
        }
        if menuIsOpen { rebuildMenu() }
    }

    private func batterySymbol(for b: BatteryStatus) -> String {
        let level: Int
        switch b.percent {
        case ..<10: level = 0
        case ..<40: level = 25
        case ..<65: level = 50
        case ..<90: level = 75
        default: level = 100
        }
        return "battery.\(level)percent" + (b.charging ? ".bolt" : "")
    }

    private func symbol(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "computermouse", accessibilityDescription: nil)
        image?.isTemplate = true
        return image
    }

    // MARK: Menu

    private func rebuildMenu() {
        menu.removeAllItems()
        actions.removeAll()

        let title: String
        if permissionDenied {
            title = "Input Monitoring permission needed"
        } else if !connected {
            title = "Neither receiver nor cable plugged in"
        } else {
            title = "E-Yooso X-33 · " + (controller.transport.link?.label ?? "connected")
        }
        menu.addItem(label(title))

        if let b = battery, connected {
            menu.addItem(label("Battery \(b.percent)% · \(String(format: "%.2f", b.volts)) V · \(b.charging ? "Charging" : "Discharging")"))
        }
        if let error = lastError {
            menu.addItem(label(error))
        }
        if permissionDenied {
            menu.addItem(item("Open Input Monitoring Settings…") { Self.openInputMonitoringSettings() })
        }
        menu.addItem(.separator())

        if connected, let s = settings {
            addSettingsItems(s)
            menu.addItem(.separator())
        } else if connected {
            menu.addItem(label(lastError == nil ? "Reading settings…" : "Settings unavailable"))
            menu.addItem(.separator())
        }

        menu.addItem(item("Refresh", key: "r") { [weak self] in self?.refreshAll() })
        if connected {
            menu.addItem(item("Restore Factory Defaults…") { [weak self] in self?.confirmRestore() })
        }
        menu.addItem(item("Low Battery Alerts", state: lowBatteryAlerts) { [weak self] in
            guard let self else { return }
            self.lowBatteryAlerts.toggle()
        })
        if Bundle.main.bundleIdentifier != nil {
            let enabled = SMAppService.mainApp.status == .enabled
            menu.addItem(item("Launch at Login", state: enabled) { [weak self] in self?.toggleLaunchAtLogin() })
        }
        if firmware.mouse != nil || firmware.dongle != nil {
            menu.addItem(label("Firmware: mouse \(firmware.mouse ?? "?") · dongle \(firmware.dongle ?? "?")"))
        }
        menu.addItem(.separator())
        menu.addItem(item("Quit", key: "q") { NSApp.terminate(nil) })
    }

    private func addSettingsItems(_ s: MouseSettings) {
        let polling = submenu("Polling Rate" + (s.pollingRateHz.map { " · \($0) Hz" } ?? ""))
        for hz in Compx.pollingRates {
            polling.addItem(item("\(hz) Hz", state: s.pollingRateHz == hz) { [weak self] in
                self?.apply("polling rate") { try self?.controller.setPollingRate(hz) }
            })
        }

        let stage = submenu("DPI Stage · \(s.activeDpiStage + 1) (\(s.activeDpi.map(String.init) ?? "?"))")
        for (i, dpi) in s.dpiStages.enumerated() {
            stage.addItem(item("Stage \(i + 1) · \(dpi.map(String.init) ?? "?") DPI", state: i == s.activeDpiStage) { [weak self] in
                self?.apply("DPI stage") { try self?.controller.setActiveDpiStage(i) }
            })
        }

        let values = submenu("DPI Values")
        let presets = [400, 600, 800, 1000, 1200, 1600, 2000, 2400, 3200, 4000, 4800, 6400, 8000, 12000, 16000]
        for (i, dpi) in s.dpiStages.enumerated() {
            let per = NSMenu()
            for preset in presets {
                per.addItem(item("\(preset)", state: dpi == preset) { [weak self] in
                    self?.apply("DPI") { try self?.controller.setDpi(stage: i, dpi: preset) }
                })
            }
            per.addItem(.separator())
            per.addItem(item("Custom…") { [weak self] in self?.promptCustomDpi(stage: i, current: dpi) })
            let entry = NSMenuItem(title: "Stage \(i + 1) · \(dpi.map(String.init) ?? "?")", action: nil, keyEquivalent: "")
            entry.submenu = per
            values.addItem(entry)
        }
        values.addItem(.separator())
        let count = NSMenu()
        for n in 1...6 {
            count.addItem(item("\(n)", state: s.dpiStageCount == n) { [weak self] in
                self?.apply("DPI stage count") { try self?.controller.setDpiStageCount(n) }
            })
        }
        let countEntry = NSMenuItem(title: "Number of Stages · \(s.dpiStageCount)", action: nil, keyEquivalent: "")
        countEntry.submenu = count
        values.addItem(countEntry)

        if s.supportsLiftOff {
            let lod = submenu("Lift-off Distance" + (s.liftOffDistanceMM.map { " · \($0) mm" } ?? " · default"))
            for mm in Compx.liftOffDistancesMM {
                lod.addItem(item("\(mm) mm", state: s.liftOffDistanceMM == mm) { [weak self] in
                    self?.apply("lift-off distance") { try self?.controller.setLiftOffDistance(mm: mm) }
                })
            }
        }

        if s.supportsSleepTimer {
            let sleep = submenu("Sleep After" + (s.sleepMinutes.map { " · \($0) min" } ?? ""))
            for minutes in Compx.sleepMinutes {
                sleep.addItem(item("\(minutes) min", state: s.sleepMinutes == minutes) { [weak self] in
                    self?.apply("sleep timer") { try self?.controller.setSleepMinutes(minutes) }
                })
            }
        }

        if s.supportsDebounce {
            let debounce = submenu("Debounce" + (s.debounceMs.map { " · \($0) ms" } ?? ""))
            for ms in 0...15 {
                debounce.addItem(item("\(ms) ms", state: s.debounceMs == ms) { [weak self] in
                    self?.apply("debounce") { try self?.controller.setDebounce(ms: ms) }
                })
            }
        }

        menu.addItem(item("Motion Sync", state: s.motionSync) { [weak self] in
            self?.apply("motion sync") { try self?.controller.setMotionSync(!s.motionSync) }
        })
        menu.addItem(item("Angle Snapping", state: s.angleSnapping) { [weak self] in
            self?.apply("angle snapping") { try self?.controller.setAngleSnapping(!s.angleSnapping) }
        })
        menu.addItem(item("Ripple Control", state: s.rippleControl) { [weak self] in
            self?.apply("ripple control") { try self?.controller.setRippleControl(!s.rippleControl) }
        })
    }

    // MARK: Actions

    private func apply(_ what: String, _ work: @escaping () throws -> Void) {
        guard !busy else { return }
        busy = true
        controller.perform(work) { [weak self] result in
            guard let self else { return }
            self.busy = false
            if case .failure(let error) = result {
                self.showError("Could not change \(what)", error)
            }
            self.refreshSettings()
        }
    }

    private func promptCustomDpi(stage: Int, current: Int?) {
        let alert = NSAlert()
        alert.messageText = "DPI for stage \(stage + 1)"
        alert.informativeText = "50 – 26000 in steps of 50."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        field.stringValue = current.map(String.init) ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "Set")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn, let dpi = Int(field.stringValue.trimmingCharacters(in: .whitespaces)) else { return }
        let rounded = max(Compx.dpiMin, min(Compx.dpiMax, (dpi / Compx.dpiStep) * Compx.dpiStep))
        apply("DPI") { [weak self] in try self?.controller.setDpi(stage: stage, dpi: rounded) }
    }

    private func confirmRestore() {
        let alert = NSAlert()
        alert.messageText = "Restore factory defaults?"
        alert.informativeText = "All DPI stages, polling rate and other settings stored in the mouse will be reset."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        apply("factory defaults") { [weak self] in try self?.controller.restoreDefaults() }
    }

    private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            showError("Could not change Launch at Login", error)
        }
    }

    private func showError(_ title: String, _ error: Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private static func openInputMonitoringSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Low battery

    private func checkLowBattery(_ b: BatteryStatus) {
        if b.charging || b.percent > lowBatteryThresholds[0] {
            lowBatteryWarned.removeAll()
            return
        }
        guard lowBatteryAlerts, Bundle.main.bundleIdentifier != nil else { return }
        guard let threshold = lowBatteryThresholds.first(where: { b.percent <= $0 }), !lowBatteryWarned.contains(threshold) else { return }
        lowBatteryWarned.insert(threshold)
        let content = UNMutableNotificationContent()
        content.title = "Mouse battery low"
        content.body = "E-Yooso X-33 is at \(b.percent)%. Plug in the cable."
        content.sound = .default
        let request = UNNotificationRequest(identifier: "x33-low-\(threshold)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: Menu helpers

    private func label(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func submenu(_ title: String) -> NSMenu {
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu()
        entry.submenu = sub
        menu.addItem(entry)
        return sub
    }

    private func item(_ title: String, key: String = "", state: Bool = false, _ handler: @escaping () -> Void) -> NSMenuItem {
        let action = MenuAction(handler)
        actions.append(action)
        let item = NSMenuItem(title: title, action: #selector(MenuAction.run), keyEquivalent: key)
        item.target = action
        item.state = state ? .on : .off
        return item
    }
}

final class MenuAction: NSObject {
    private let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func run() { handler() }
}
