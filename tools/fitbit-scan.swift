// fitbit-scan: shows what the Fitbit Air's Bluetooth heart-rate broadcast tells a Mac.
//
//   ./fitbit-scan        connect and print heart rate, skin contact and signal strength on every update
//   ./fitbit-scan ids    don't connect; just listen and report every ID the band advertises under
//
// Needs "Share heart rate" (and "Always visible") turned on for the band in the Google Health app.

import CoreBluetooth
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

let heartRateService = CBUUID(string: "180D")
let heartRateMeasurement = CBUUID(string: "2A37")
let batteryService = CBUUID(string: "180F")
let batteryLevel = CBUUID(string: "2A19")

let clock: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f
}()

func log(_ message: String) {
    print("\(clock.string(from: Date()))  \(message)")
}

struct HeartRateReading {
    var bpm: Int
    var skin: String
    var beatGapsMillis: [Int]
}

// Heart Rate Measurement (0x2A37) layout from the Bluetooth Heart Rate Service spec.
func parseHeartRate(_ data: Data) -> HeartRateReading? {
    let bytes = [UInt8](data)
    guard bytes.count >= 2 else { return nil }
    let flags = bytes[0]
    var i = 1

    let bpm: Int
    if flags & 0x01 == 0 {
        bpm = Int(bytes[i])
        i += 1
    } else {
        guard bytes.count >= i + 2 else { return nil }
        bpm = Int(bytes[i]) | Int(bytes[i + 1]) << 8
        i += 2
    }

    // Bit 2 = sensor contact supported, bit 1 = contact detected.
    let skin: String
    switch (flags >> 1) & 0x03 {
    case 0b11: skin = "ON SKIN"
    case 0b10: skin = "OFF SKIN"
    default: skin = "not reported"
    }

    if flags & 0x08 != 0 { i += 2 }  // energy expended, not needed

    var gaps: [Int] = []
    if flags & 0x10 != 0 {
        while i + 1 < bytes.count {
            gaps.append((Int(bytes[i]) | Int(bytes[i + 1]) << 8) * 1000 / 1024)
            i += 2
        }
    }
    return HeartRateReading(bpm: bpm, skin: skin, beatGapsMillis: gaps)
}

func looksLikeBand(name: String?, advertisement: [String: Any]) -> Bool {
    let services = advertisement[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
    if services.contains(heartRateService) { return true }
    return name?.localizedCaseInsensitiveContains("fitbit") ?? false
}

struct Sighting {
    var name: String
    var first: Date
    var last: Date
    var rssi: Int
}

final class Scanner: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    let idsOnly: Bool
    var central: CBCentralManager!
    var band: CBPeripheral?
    var lastReadingAt: Date?
    var lastRSSI: Int?
    var warnedSilent = false
    var scanStarted = Date()
    var hintShown = false
    var ticks = 0
    var nearby: [UUID: (name: String, rssi: Int)] = [:]
    var bandIDs: [UUID: Sighting] = [:]

    init(idsOnly: Bool) {
        self.idsOnly = idsOnly
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            log(idsOnly
                ? "Listening for the band's broadcast. Leave this running ~30 min, then press Ctrl+C."
                : "Looking for the band. Make sure Share heart rate is on in Google Health.")
            scanStarted = Date()
            central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        case .unauthorized:
            log("Bluetooth permission denied. Allow it in System Settings → Privacy & Security → Bluetooth.")
            exit(1)
        case .poweredOff:
            log("Bluetooth is off. Turn it on.")
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let rssi = RSSI.intValue
        guard rssi < 0 else { return }  // 127 means "unavailable"
        nearby[peripheral.identifier] = (name ?? "(no name)", rssi)
        guard looksLikeBand(name: name, advertisement: advertisementData) else { return }

        if idsOnly {
            let now = Date()
            if var known = bandIDs[peripheral.identifier] {
                known.last = now
                known.rssi = rssi
                bandIDs[peripheral.identifier] = known
            } else {
                bandIDs[peripheral.identifier] = Sighting(name: name ?? "(no name)", first: now, last: now, rssi: rssi)
                let changed = bandIDs.count > 1 ? "   <-- NEW ID #\(bandIDs.count): the band's address changed" : ""
                log("Band seen as ID \(peripheral.identifier)  name: \(name ?? "(none)")  signal: \(rssi)\(changed)")
            }
            return
        }

        guard band == nil else { return }
        log("Found \(name ?? "a heart-rate device")  ID \(peripheral.identifier)  signal: \(rssi). Connecting…")
        band = peripheral
        peripheral.delegate = self
        central.stopScan()
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        log("Connected. If macOS asks to pair, accept.")
        log("Test: wear it 1 min → take it off and set it down 1 min → put it back on 1 min.")
        peripheral.discoverServices([heartRateService, batteryService])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        log("Couldn't connect: \(error?.localizedDescription ?? "unknown error"). Retrying…")
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        log("Disconnected\(error.map { ": \($0.localizedDescription)" } ?? ""). Reconnecting…")
        central.connect(peripheral)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let services = peripheral.services ?? []
        if !services.contains(where: { $0.uuid == heartRateService }) {
            log("This device has no heart-rate service. Is Share heart rate on?")
        }
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for characteristic in service.characteristics ?? [] {
            if characteristic.uuid == heartRateMeasurement { peripheral.setNotifyValue(true, for: characteristic) }
            if characteristic.uuid == batteryLevel { peripheral.readValue(for: characteristic) }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error {
            log("Couldn't subscribe to heart rate: \(error.localizedDescription)")
        } else {
            log("Subscribed to heart rate.")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        if characteristic.uuid == batteryLevel, let level = data.first {
            log("Battery: \(level)%")
            return
        }
        guard characteristic.uuid == heartRateMeasurement, let reading = parseHeartRate(data) else { return }
        if warnedSilent { log("Heart-rate data is back.") }
        lastReadingAt = Date()
        warnedSilent = false
        let gaps = reading.beatGapsMillis.isEmpty
            ? "" : "   beat gap: " + reading.beatGapsMillis.map { "\($0)ms" }.joined(separator: ",")
        let raw = data.map { String(format: "%02x", $0) }.joined(separator: " ")
        log("HR \(String(format: "%3d", reading.bpm)) bpm   skin: \(reading.skin)   signal: \(lastRSSI.map(String.init) ?? "?")\(gaps)   raw: \(raw)")
    }

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        if error == nil { lastRSSI = RSSI.intValue }
    }

    func tick() {
        ticks += 1
        let now = Date()

        if idsOnly {
            guard ticks % 60 == 0, !bandIDs.isEmpty else { return }
            let current = bandIDs.max { $0.value.last < $1.value.last }!
            let ago = Int(now.timeIntervalSince(current.value.last))
            let minutes = Int(now.timeIntervalSince(scanStarted) / 60)
            log("\(minutes) min: \(bandIDs.count) ID(s) so far. Latest \(current.key) seen \(ago)s ago, signal \(current.value.rssi)")
            return
        }

        if let band, band.state == .connected { band.readRSSI() }

        if let last = lastReadingAt, !warnedSilent, now.timeIntervalSince(last) > 5 {
            log("No heart-rate data for 5+ seconds.")
            warnedSilent = true
        }

        if band == nil, !hintShown, now.timeIntervalSince(scanStarted) > 20 {
            hintShown = true
            log("No heart-rate broadcast found yet. Strongest Bluetooth devices nearby:")
            for (id, device) in nearby.sorted(by: { $0.value.rssi > $1.value.rssi }).prefix(8) {
                print("            \(device.rssi)  \(device.name)  \(id)")
            }
            log("Check Share heart rate + Always visible in Google Health, and keep the band near the Mac.")
        }
    }
}

let scanner = Scanner(idsOnly: CommandLine.arguments.dropFirst().first == "ids")
RunLoop.main.run()
