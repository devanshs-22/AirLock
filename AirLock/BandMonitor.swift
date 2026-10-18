import CoreBluetooth
import Foundation

enum WristState {
    case on, off, unknown
}

/// Stays connected to the Fitbit Air's heart-rate broadcast and tracks its signal strength and heart rate.
final class BandMonitor: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private let heartRateService = CBUUID(string: "180D")
    private let heartRateMeasurement = CBUUID(string: "2A37")

    private var central: CBCentralManager!
    private var band: CBPeripheral?
    private var signalSamples: [(at: Date, value: Int)] = []
    private var firstReadingAt: Date?

    private(set) var bluetoothState: CBManagerState = .unknown
    private(set) var bandName: String?
    private(set) var isConnected = false
    private(set) var heardSinceWake = false
    private(set) var lastHeardAt: Date?
    private(set) var heartRate: Int?
    private(set) var lastReadingAt: Date?
    private(set) var lastChangeAt: Date?
    /// Why the last connection attempt failed, cleared once connected.
    private(set) var connectError: String?
    /// The band erased its pairing with this Mac (for example after being removed from the phone).
    private(set) var pairingLost = false

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let band = self?.band, band.state == .connected else { return }
            band.readRSSI()
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Median of the last 3 seconds of readings, so one noisy sample can't lock or unlock the Mac.
    var signal: Int? {
        let now = Date()
        let recent = signalSamples.filter { now.timeIntervalSince($0.at) <= 3 }.map { $0.value }.sorted()
        return recent.isEmpty ? nil : recent[recent.count / 2]
    }

    /// Off a wrist the band keeps repeating its last reading, so "on wrist" means the number moved recently.
    func wristState(now: Date = Date(), window: TimeInterval) -> WristState {
        guard let bpm = heartRate, let last = lastReadingAt, now.timeIntervalSince(last) < 10 else { return .unknown }
        if bpm == 0 { return .off }
        if let changed = lastChangeAt, now.timeIntervalSince(changed) < window { return .on }
        if let since = lastChangeAt ?? firstReadingAt, now.timeIntervalSince(since) >= window { return .off }
        return .unknown
    }

    var secondsSinceHeartRateChanged: Int? {
        (lastChangeAt ?? firstReadingAt).map { Int(Date().timeIntervalSince($0)) }
    }

    func macDidWake() {
        heardSinceWake = false
        signalSamples.removeAll()
    }

    // MARK: Connection

    private func isBand(_ peripheral: CBPeripheral, advertisement: [String: Any]) -> Bool {
        let name = peripheral.name ?? advertisement[CBAdvertisementDataLocalNameKey] as? String ?? ""
        return name.localizedCaseInsensitiveContains("fitbit")
    }

    private func connect(_ peripheral: CBPeripheral) {
        if let band, band.identifier != peripheral.identifier {
            central.cancelPeripheralConnection(band)
        }
        band = peripheral
        peripheral.delegate = self
        central.connect(peripheral)
    }

    private func startScanning() {
        guard central.state == .poweredOn, !central.isScanning else { return }
        central.scanForPeripherals(withServices: nil)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state != bluetoothState {
            let names: [CBManagerState: String] = [.poweredOn: "on", .poweredOff: "off", .unauthorized: "not allowed",
                                                   .unsupported: "unsupported", .resetting: "resetting"]
            Log.write("Bluetooth: \(names[central.state] ?? "unknown")")
        }
        bluetoothState = central.state
        guard central.state == .poweredOn else {
            isConnected = false
            return
        }
        if let id = Settings.bandIdentifier, let known = central.retrievePeripherals(withIdentifiers: [id]).first {
            connect(known)
        }
        startScanning()
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard !isConnected, isBand(peripheral, advertisement: advertisementData) else { return }
        if band?.identifier != peripheral.identifier || band?.state == .disconnected {
            connect(peripheral)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        isConnected = true
        connectError = nil
        pairingLost = false
        bandName = peripheral.name ?? "Fitbit band"
        Settings.bandIdentifier = peripheral.identifier
        central.stopScan()
        Log.write("Connected to \(bandName ?? "band")")
        peripheral.discoverServices([heartRateService])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let message = error?.localizedDescription ?? "unknown error"
        if message != connectError { Log.write("Couldn't connect to band: \(message)") }
        connectError = message
        pairingLost = (error as? CBError)?.code == .peerRemovedPairingInformation
        // Wait before retrying; a failing band otherwise gets hammered several times a second.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.band?.identifier == peripheral.identifier, peripheral.state == .disconnected else { return }
            central.connect(peripheral)
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral.identifier == band?.identifier else { return }
        isConnected = false
        signalSamples.removeAll()
        Log.write("Band disconnected")
        central.connect(peripheral)  // completes whenever the band is back in range
        startScanning()  // in case it comes back under a new Bluetooth address
    }

    // MARK: Heart rate and signal

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for service in peripheral.services ?? [] where service.uuid == heartRateService {
            peripheral.discoverCharacteristics([heartRateMeasurement], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for characteristic in service.characteristics ?? [] where characteristic.uuid == heartRateMeasurement {
            peripheral.setNotifyValue(true, for: characteristic)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == heartRateMeasurement, let data = characteristic.value,
              let bpm = Self.parseBPM(data) else { return }
        let now = Date()
        if firstReadingAt == nil { firstReadingAt = now }
        // Compared with the last reading even across a disconnect, so a band that was worn
        // while away usually counts as "on wrist" from the first reading after it returns.
        if let previous = heartRate, previous != bpm { lastChangeAt = now }
        heartRate = bpm
        lastReadingAt = now
        lastHeardAt = now
        heardSinceWake = true
    }

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        guard error == nil, RSSI.intValue < 0 else { return }
        let now = Date()
        signalSamples.append((at: now, value: RSSI.intValue))
        signalSamples.removeAll { now.timeIntervalSince($0.at) > 3 }
        lastHeardAt = now
    }

    /// Heart Rate Measurement (0x2A37): a flags byte, then an 8- or 16-bit bpm value.
    static func parseBPM(_ data: Data) -> Int? {
        let bytes = [UInt8](data)
        guard bytes.count >= 2 else { return nil }
        if bytes[0] & 0x01 == 0 { return Int(bytes[1]) }
        guard bytes.count >= 3 else { return nil }
        return Int(bytes[1]) | Int(bytes[2]) << 8
    }
}
