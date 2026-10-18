import AppKit
import ApplicationServices
import IOKit.pwr_mgt
import OpenDirectory
import Security

/// Locking, unlocking and sleeping the Mac.
enum Mac {
    static var isScreenLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (session["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue ?? false
    }

    static func lockScreen() {
        // SACLockScreenImmediate (private, in login.framework) locks right away whatever the
        // "require password" delay is; sleeping the display is the fallback.
        typealias LockNow = @convention(c) () -> Int32
        if let framework = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY),
           let lockNow = dlsym(framework, "SACLockScreenImmediate") {
            _ = unsafeBitCast(lockNow, to: LockNow.self)()
        } else {
            run("/usr/bin/pmset", "displaysleepnow")
        }
    }

    static func sleep() {
        run("/usr/bin/pmset", "sleepnow")
    }

    /// Seconds since the keyboard, trackpad or mouse was last used. Works on the lock screen too.
    static var secondsSinceInput: TimeInterval? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? NSNumber
        return value.map { $0.doubleValue / 1_000_000_000 }
    }

    static var canTypePassword: Bool {
        AXIsProcessTrusted()
    }

    static func requestAccessibility() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    /// Wakes the display and types the password into the lock screen.
    /// `screenAwake`: you just touched the Mac, so the lock screen is already showing and there's no need to wait.
    static func unlock(with password: String, screenAwake: Bool) {
        let typePassword = {
            // Never type the password anywhere except the lock screen.
            guard isScreenLocked else { return }
            // Clear anything already in the password box, like the key you pressed to wake the Mac.
            for _ in 0..<40 { press(key: 51) }  // Delete
            type(password)
            press(key: 36)  // Return
        }
        if screenAwake {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: typePassword)
            return
        }
        var assertion = IOPMAssertionID(0)
        IOPMAssertionDeclareUserActivity("AirLock unlock" as CFString, kIOPMUserActiveLocal, &assertion)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            nudgeMouse()  // dismisses a screen saver without typing anything
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: typePassword)
        }
    }

    private static func type(_ text: String) {
        let source = CGEventSource(stateID: .hidSystemState)
        let units = Array(text.utf16)
        // One key event carries at most 20 characters.
        for start in stride(from: 0, to: units.count, by: 20) {
            var chunk = Array(units[start..<min(start + 20, units.count)])
            let down = CGEvent(keyboardEventSource: source, virtualKey: 49, keyDown: true)
            down?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
            down?.post(tap: .cghidEventTap)
            CGEvent(keyboardEventSource: source, virtualKey: 49, keyDown: false)?.post(tap: .cghidEventTap)
        }
    }

    private static func press(key: CGKeyCode) {
        let source = CGEventSource(stateID: .hidSystemState)
        CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)?.post(tap: .cghidEventTap)
    }

    private static func nudgeMouse() {
        let location = CGEvent(source: nil)?.location ?? .zero
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: location, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }

    private static func run(_ tool: String, _ arguments: String...) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        try? process.run()
    }
}

/// The Mac login password, kept in the login keychain so AirLock can type it at the lock screen.
enum PasswordStore {
    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "AirLock",
            kSecAttrAccount as String: NSUserName(),
        ]
    }

    static func save(_ password: String) -> Bool {
        SecItemDelete(baseQuery as CFDictionary)
        var item = baseQuery
        item[kSecValueData as String] = Data(password.utf8)
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func load() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Checks the password against your account, so a typo never gets typed at the lock screen.
    static func isMacPassword(_ password: String) -> Bool {
        guard let node = try? ODNode(session: ODSession.default(), type: ODNodeType(kODNodeTypeAuthentication)),
              let record = try? node.record(withRecordType: kODRecordTypeUsers, name: NSUserName(), attributes: nil)
        else { return false }
        return (try? record.verifyPassword(password)) != nil
    }
}
