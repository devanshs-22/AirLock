import AppKit

Settings.registerDefaults()
Log.write("AirLock started")

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = AirLockController()
let menuBar = MenuBar(controller: controller)
app.run()
