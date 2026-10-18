import AppKit
import ServiceManagement

/// A menu item that runs a closure when chosen.
private final class ActionItem: NSMenuItem {
    private var handler: () -> Void = {}

    convenience init(_ title: String, checked: Bool = false, handler: @escaping () -> Void) {
        self.init(title: title, action: #selector(run), keyEquivalent: "")
        self.handler = handler
        target = self
        state = checked ? .on : .off
    }

    @objc private func run() {
        handler()
    }
}

/// The menu bar icon and its menu.
final class MenuBar: NSObject, NSMenuDelegate {
    private let controller: AirLockController
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let bandLine = NSMenuItem()
    private let signalLine = NSMenuItem()
    private let heartLine = NSMenuItem()
    private let noteLine = NSMenuItem()

    init(controller: AirLockController) {
        self.controller = controller
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        controller.onTick = { [weak self] in self?.refresh() }
        refresh()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for line in [bandLine, signalLine, heartLine, noteLine] {
            line.isEnabled = false
            menu.addItem(line)
        }
        refresh()

        menu.addItem(.separator())
        menu.addItem(ActionItem("Enabled", checked: Settings.enabled) { Settings.enabled.toggle() })
        menu.addItem(ActionItem("Unlock when I come back wearing it", checked: Settings.autoUnlock) {
            Settings.autoUnlock.toggle()
        })
        menu.addItem(ActionItem("Wait until I touch the Mac to unlock", checked: Settings.unlockOnTouch) {
            Settings.unlockOnTouch.toggle()
        })
        menu.addItem(ActionItem("Only unlock if the heartbeat is live", checked: Settings.requireHeartbeat) {
            Settings.requireHeartbeat.toggle()
        })
        menu.addItem(ActionItem("Lock when I take the band off", checked: Settings.lockWhenTakenOff) {
            Settings.lockWhenTakenOff.toggle()
        })

        menu.addItem(.separator())
        menu.addItem(choice("Lock when signal drops to \(Settings.lockSignal)", current: Settings.lockSignal,
                            options: [-60, -63, -65, -70, -75, -80, -85].map { ("\($0)", $0) }) { Settings.lockSignal = $0 })
        menu.addItem(choice("Unlock when signal reaches \(Settings.unlockSignal)", current: Settings.unlockSignal,
                            options: [-50, -55, -58, -60, -65, -70].map { ("\($0)", $0) }) { Settings.unlockSignal = $0 })
        menu.addItem(choice("Lock delay when signal drops: \(Settings.lockDelay) s", current: Settings.lockDelay,
                            options: [1, 2, 3, 5, 10, 20].map { ("\($0) seconds", $0) }) { Settings.lockDelay = $0 })
        menu.addItem(choice("Lock when band goes silent for \(Settings.lostTimeout) s", current: Settings.lostTimeout,
                            options: [3, 4, 5, 10, 15].map { ("\($0) seconds", $0) }) { Settings.lostTimeout = $0 })
        menu.addItem(choice("Off wrist after no change for \(Settings.offWristAfter) s", current: Settings.offWristAfter,
                            options: [45, 60, 75, 90, 120].map { ("\($0) seconds", $0) }) { Settings.offWristAfter = $0 })
        menu.addItem(choice("Sleep Mac after away: " + minutes(Settings.sleepAfterMinutes), current: Settings.sleepAfterMinutes,
                            options: [0, 5, 15, 30, 60].map { (minutes($0), $0) }) { Settings.sleepAfterMinutes = $0 })

        menu.addItem(.separator())
        menu.addItem(ActionItem(controller.hasPassword ? "Change Saved Mac Password…" : "Save Mac Password…") { [weak self] in
            self?.askForPassword()
        })
        if !Mac.canTypePassword {
            menu.addItem(ActionItem("Allow Accessibility (needed to unlock)…") { Mac.requestAccessibility() })
        }
        let testTitle = Settings.unlockOnTouch ? "Test: Lock Now (then touch the trackpad)" : "Test: Lock, Then Auto-Unlock"
        menu.addItem(ActionItem(testTitle) { [weak self] in self?.runTest() })
        menu.addItem(ActionItem("Show Log") { NSWorkspace.shared.open(Log.url) })
        let login = SMAppService.mainApp
        menu.addItem(ActionItem("Open at Login", checked: login.status == .enabled) { [weak self] in
            do {
                if login.status == .enabled { try login.unregister() } else { try login.register() }
            } catch {
                self?.showMessage("Couldn't change Open at Login", error.localizedDescription)
            }
        })

        menu.addItem(.separator())
        menu.addItem(ActionItem("Quit AirLock") { NSApp.terminate(nil) })
    }

    private func refresh() {
        let band = controller.band
        let symbol: String
        if !Settings.enabled {
            symbol = "pause.circle"
        } else if band.isConnected {
            symbol = controller.screenLocked ? "lock.fill" : "lock.open"
        } else {
            symbol = "antenna.radiowaves.left.and.right.slash"
        }
        // Live heart rate beside the padlock, hidden when there's no fresh reading.
        let fresh = band.lastReadingAt.map { Date().timeIntervalSince($0) < 10 } ?? false
        let heart = band.isConnected && fresh ? band.heartRate.map { " ♥ \($0)" } : nil
        if let button = statusItem.button {
            if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "AirLock") {
                image.isTemplate = true
                button.image = image
                button.imagePosition = .imageLeft
                button.title = heart ?? ""
            } else {
                button.title = "AirLock" + (heart ?? "")
            }
            // Fixed-width digits so the icon doesn't shift as the number changes.
            button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        }

        switch band.bluetoothState {
        case .unauthorized:
            bandLine.title = "Bluetooth not allowed: System Settings → Privacy & Security → Bluetooth"
        case .poweredOff:
            bandLine.title = "Bluetooth is off"
        default:
            if band.isConnected {
                bandLine.title = "\(band.bandName ?? "Band") · connected"
            } else if band.pairingLost {
                bandLine.title = "Band forgot this Mac. Fix: System Settings → Bluetooth → Google Fitbit Air ⓘ → Forget This Device"
            } else if let error = band.connectError {
                bandLine.title = "Can't connect to band: \(error)"
            } else {
                bandLine.title = "Looking for your Fitbit…"
            }
        }

        signalLine.title = "Signal: \(band.signal.map(String.init) ?? "–")   (unlock at \(Settings.unlockSignal) or higher, lock at \(Settings.lockSignal) or lower)"

        let wrist: String
        switch band.wristState(window: Double(Settings.offWristAfter)) {
        case .on: wrist = "on wrist"
        case .off: wrist = "off wrist"
        case .unknown: wrist = "checking wrist…"
        }
        let steady = band.secondsSinceHeartRateChanged.map { " (same for \($0) s)" } ?? ""
        heartLine.title = "Heart rate: \(band.heartRate.map { "\($0) bpm" } ?? "–") · \(wrist)\(steady)"

        noteLine.title = controller.statusNote
            ?? (controller.hasPassword ? "Mac password saved" : "No Mac password saved, so auto-unlock is off")
    }

    private func choice(_ title: String, current: Int, options: [(String, Int)], set: @escaping (Int) -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for (label, value) in options {
            submenu.addItem(ActionItem(label, checked: value == current) { set(value) })
        }
        item.submenu = submenu
        return item
    }

    private func minutes(_ value: Int) -> String {
        value == 0 ? "never" : "\(value) min"
    }

    /// Only locks if every auto-unlock condition already holds, so the test can't leave you locked out.
    private func runTest() {
        let band = controller.band
        guard controller.hasPassword else {
            showMessage("Save your Mac password first",
                        "AirLock unlocks by typing your password, so without it the test would just lock you out. Choose Save Mac Password… first.")
            return
        }
        guard Mac.canTypePassword else {
            Mac.requestAccessibility()
            showMessage("Allow Accessibility first",
                        "Turn on AirLock in System Settings → Privacy & Security → Accessibility, then run the test again.\n\nIf it's already on, it belongs to an older build: select AirLock, click –, then add it back with + (it's in your Applications folder in your home folder).")
            return
        }
        guard Settings.autoUnlock else {
            showMessage("Auto-unlock is off", "Turn on \"Unlock when I come back wearing it\", then run the test again.")
            return
        }
        guard band.isConnected, let signal = band.signal, signal >= Settings.unlockSignal else {
            showMessage("Band isn't close enough yet",
                        "The signal needs to be \(Settings.unlockSignal) or higher (now \(band.signal.map(String.init) ?? "none")). Sit closer or lower the unlock level.")
            return
        }
        if Settings.requireHeartbeat, band.wristState(window: Double(Settings.offWristAfter)) != .on {
            showMessage("Wrist check isn't ready yet",
                        "Wait until the menu says \"on wrist\". It needs to see your heart rate change once.")
            return
        }
        controller.testLockAndUnlock()
    }

    private func askForPassword() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Save your Mac login password"
        alert.informativeText = "AirLock keeps it in your login keychain and types it at the lock screen only when your band is close and on your wrist."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let password = field.stringValue
        guard PasswordStore.isMacPassword(password) else {
            showMessage("That isn't your Mac password", "Nothing was saved. Try again from the menu.")
            return
        }
        guard controller.setPassword(password) else {
            showMessage("Couldn't save to the keychain", "Nothing was saved. Try again from the menu.")
            return
        }
        if !Mac.canTypePassword { Mac.requestAccessibility() }
    }

    private func showMessage(_ title: String, _ detail: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.runModal()
    }
}
