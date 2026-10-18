import Foundation

@propertyWrapper
struct Stored<Value> {
    let key: String

    var wrappedValue: Value {
        get { UserDefaults.standard.object(forKey: key) as! Value }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

/// User preferences, kept in UserDefaults and changed from the menu.
enum Settings {
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            "enabled": true,
            "autoUnlock": true,
            "unlockOnTouch": true,
            "requireHeartbeat": true,
            "lockWhenTakenOff": true,
            "lockSignal": -64,
            "unlockSignal": -58,
            "lockDelay": 5,
            "lostTimeout": 4,
            "offWristAfter": 75,
            "sleepAfterMinutes": 15,
        ])
    }

    @Stored(key: "enabled") static var enabled: Bool
    @Stored(key: "autoUnlock") static var autoUnlock: Bool
    @Stored(key: "unlockOnTouch") static var unlockOnTouch: Bool
    @Stored(key: "requireHeartbeat") static var requireHeartbeat: Bool
    @Stored(key: "lockWhenTakenOff") static var lockWhenTakenOff: Bool
    @Stored(key: "lockSignal") static var lockSignal: Int
    @Stored(key: "unlockSignal") static var unlockSignal: Int
    @Stored(key: "lockDelay") static var lockDelay: Int
    @Stored(key: "lostTimeout") static var lostTimeout: Int
    @Stored(key: "offWristAfter") static var offWristAfter: Int
    @Stored(key: "sleepAfterMinutes") static var sleepAfterMinutes: Int

    static var bandIdentifier: UUID? {
        get { UserDefaults.standard.string(forKey: "bandIdentifier").flatMap(UUID.init(uuidString:)) }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: "bandIdentifier") }
    }
}
