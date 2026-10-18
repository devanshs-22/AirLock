import AppKit

enum LockReason: String {
    case away = "walked away"
    case lost = "band out of range"
    case offWrist = "band taken off"
    case test = "test from the menu"
}

/// Decides four times a second whether to lock, unlock or sleep the Mac.
final class AirLockController {
    let band = BandMonitor()
    var onTick: (() -> Void)?

    private(set) var screenLocked = Mac.isScreenLocked
    private(set) var lockedBy: LockReason?
    private(set) var statusNote: String?
    private var password = PasswordStore.load()
    private var tooFarSince: Date?
    private var suppressed: Set<LockReason> = []
    private var lockBeganAt: Date?
    private var touchesCountAfter: Date?
    private var lastWakeAt: Date?
    private var lastLockAttemptAt: Date?
    private var lastUnlockAttemptAt: Date?
    private var lastTouchAt: Date?
    private var unlockAttempts = 0
    private var sleptWhileAway = false

    private let maxUnlockAttempts = 2

    init() {
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.lastWakeAt = Date()
            self?.band.macDidWake()
            Log.write("Mac woke up")
        }
        workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.lastWakeAt = Date()
        }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
    }

    var hasPassword: Bool { password != nil }

    func setPassword(_ newPassword: String) -> Bool {
        guard PasswordStore.save(newPassword) else { return false }
        password = newPassword
        return true
    }

    /// Locks now and lets the normal auto-unlock rules bring you straight back in.
    func testLockAndUnlock() {
        lockedBy = .test
        Log.write("Locking: \(LockReason.test.rawValue)")
        Mac.lockScreen()
    }

    private func tick() {
        let now = Date()
        if let idle = Mac.secondsSinceInput { lastTouchAt = now.addingTimeInterval(-idle) }
        let reasons = currentReasons(now: now)

        noteLockChanges(now: now, reasons: reasons)
        suppressed.formIntersection(reasons)

        if Settings.enabled {
            if screenLocked {
                unlockIfPossible(now: now)
                sleepIfStillAway(now: now, reasons: reasons)
            } else {
                lockIfNeeded(now: now, reasons: reasons)
            }
        }
        onTick?()
    }

    private func currentReasons(now: Date) -> Set<LockReason> {
        if band.isConnected, let signal = band.signal, signal <= Settings.lockSignal {
            tooFarSince = tooFarSince ?? now
        } else {
            tooFarSince = nil
        }

        var reasons: Set<LockReason> = []
        if let since = tooFarSince, now.timeIntervalSince(since) >= Double(Settings.lockDelay) {
            reasons.insert(.away)
        }
        // Only once the band has been heard since the last wake, so a Mac that wakes without it nearby isn't locked.
        if band.heardSinceWake, let heard = band.lastHeardAt, now.timeIntervalSince(heard) >= Double(Settings.lostTimeout) {
            reasons.insert(.lost)
        }
        if Settings.lockWhenTakenOff, band.wristState(now: now, window: Double(Settings.offWristAfter)) == .off {
            reasons.insert(.offWrist)
        }
        return reasons
    }

    private func noteLockChanges(now: Date, reasons: Set<LockReason>) {
        let locked = Mac.isScreenLocked
        guard locked != screenLocked else { return }
        screenLocked = locked

        if locked {
            // After a sleep the lock is only noticed once the Mac wakes; it really began before that wake.
            if let wake = lastWakeAt, now.timeIntervalSince(wake) < 10 {
                lockBeganAt = wake.addingTimeInterval(-1)
                touchesCountAfter = lockBeganAt
            } else {
                lockBeganAt = now
                // Ignore the keys or button you used to lock (⌃⌘Q, power button) as they're released.
                touchesCountAfter = now.addingTimeInterval(1)
            }
            unlockAttempts = 0
            sleptWhileAway = false
            Log.write("Screen locked" + (lockedBy.map { " by AirLock (\($0.rawValue))" } ?? ""))
        } else {
            let byAirLock = lastUnlockAttemptAt.map { now.timeIntervalSince($0) < 10 } ?? false
            Log.write(byAirLock ? "Unlocked by AirLock" : "Unlocked manually")
            lockedBy = nil
            lockBeganAt = nil
            statusNote = nil
            // Don't lock again for something that was already true when you unlocked, like the band on its charger.
            suppressed = reasons
        }
    }

    private func lockIfNeeded(now: Date, reasons: Set<LockReason>) {
        let order: [LockReason] = [.lost, .away, .offWrist]
        guard let reason = order.first(where: { reasons.contains($0) && !suppressed.contains($0) }) else { return }
        if let last = lastLockAttemptAt, now.timeIntervalSince(last) < 5 { return }
        lastLockAttemptAt = now
        lockedBy = reason
        Log.write("Locking: \(reason.rawValue) (signal \(band.signal.map(String.init) ?? "none"), heart rate \(band.heartRate.map(String.init) ?? "none"))")
        Mac.lockScreen()
    }

    private func unlockIfPossible(now: Date) {
        guard Settings.autoUnlock, let password else { return }

        if unlockAttempts >= maxUnlockAttempts {
            if let last = lastUnlockAttemptAt, now.timeIntervalSince(last) > 8 {
                statusNote = "Auto-unlock failed twice. Unlock by hand, then re-save your Mac password."
            }
            return
        }

        if Settings.unlockOnTouch {
            // Any lock, including one you made yourself: your touch plus the worn band is enough.
            // The touch must come after the lock began, and be recent enough to cover the band
            // reconnecting after a sleep.
            guard let touch = lastTouchAt, let after = touchesCountAfter, touch > after,
                  now.timeIntervalSince(touch) <= 30 else { return }
        } else {
            // Without a touch, only reopen locks AirLock made, or ones the Mac woke from.
            let wokeSinceLock = lastWakeAt.flatMap { wake in lockBeganAt.map { wake > $0 } } ?? false
            guard lockedBy != nil || wokeSinceLock else { return }
        }
        guard band.isConnected, let signal = band.signal, signal >= Settings.unlockSignal else { return }
        if Settings.requireHeartbeat, band.wristState(now: now, window: Double(Settings.offWristAfter)) != .on { return }
        if let last = lastUnlockAttemptAt, now.timeIntervalSince(last) < 8 { return }
        guard Mac.canTypePassword else {
            if statusNote == nil { Log.write("Can't unlock: AirLock doesn't have Accessibility permission") }
            statusNote = "Auto-unlock needs Accessibility permission (if it's on, remove AirLock with – and add it again)."
            return
        }

        unlockAttempts += 1
        lastUnlockAttemptAt = now
        let touched = Settings.unlockOnTouch ? ", Mac touched" : ""
        Log.write("Unlocking: band near (signal \(signal)), heart rate \(band.heartRate ?? 0) and moving\(touched)")
        let justTouched = lastTouchAt.map { now.timeIntervalSince($0) < 2 } ?? false
        Mac.unlock(with: password, screenAwake: justTouched)
    }

    private func sleepIfStillAway(now: Date, reasons: Set<LockReason>) {
        guard Settings.sleepAfterMinutes > 0, !sleptWhileAway,
              lockedBy == .away || lockedBy == .lost,
              !reasons.isDisjoint(with: [.away, .lost]),
              let began = lockBeganAt, now.timeIntervalSince(began) >= Double(Settings.sleepAfterMinutes * 60)
        else { return }
        sleptWhileAway = true
        Log.write("Still away after \(Settings.sleepAfterMinutes) min: putting the Mac to sleep")
        Mac.sleep()
    }
}
