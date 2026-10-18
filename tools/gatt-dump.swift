// gatt-dump: lists every Bluetooth service and characteristic the Fitbit Air exposes, then exits.

import CoreBluetooth
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

let knownNames: [String: String] = [
    "1800": "Generic Access", "1801": "Generic Attribute", "180A": "Device Information",
    "180D": "Heart Rate", "180F": "Battery", "1822": "Pulse Oximeter (SpO2)",
    "2A37": "Heart Rate Measurement", "2A38": "Body Sensor Location", "2A39": "Heart Rate Control Point",
    "2A19": "Battery Level", "2A29": "Manufacturer Name", "2A24": "Model Number", "2A25": "Serial Number",
    "2A26": "Firmware Revision", "2A27": "Hardware Revision", "2A28": "Software Revision",
    "2A5E": "SpO2 Spot-Check Measurement", "2A5F": "SpO2 Continuous Measurement",
]

func describe(_ uuid: CBUUID) -> String {
    "\(uuid.uuidString)" + (knownNames[uuid.uuidString].map { "  (\($0))" } ?? "  (vendor-specific)")
}

func describe(_ properties: CBCharacteristicProperties) -> String {
    var names: [String] = []
    if properties.contains(.read) { names.append("read") }
    if properties.contains(.write) { names.append("write") }
    if properties.contains(.writeWithoutResponse) { names.append("write-no-response") }
    if properties.contains(.notify) { names.append("notify") }
    if properties.contains(.indicate) { names.append("indicate") }
    return names.joined(separator: ", ")
}

final class Dumper: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var central: CBCentralManager!
    var band: CBPeripheral?
    var pendingServices = 0
    var pendingReads = 0

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
            print("Timed out.")
            exit(1)
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else { return }
        // AirLock may already be connected to the band; share that connection if so.
        if let connected = central.retrieveConnectedPeripherals(withServices: [CBUUID(string: "180D")]).first {
            connect(connected)
        } else {
            central.scanForPeripherals(withServices: nil)
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? ""
        guard band == nil, name.localizedCaseInsensitiveContains("fitbit") else { return }
        central.stopScan()
        connect(peripheral)
    }

    func connect(_ peripheral: CBPeripheral) {
        band = peripheral
        peripheral.delegate = self
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("Connected to \(peripheral.name ?? "band")\n")
        peripheral.discoverServices(nil)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let services = peripheral.services ?? []
        pendingServices = services.count
        for service in services { peripheral.discoverCharacteristics(nil, for: service) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        print("Service \(describe(service.uuid))")
        for characteristic in service.characteristics ?? [] {
            print("    \(describe(characteristic.uuid))   [\(describe(characteristic.properties))]")
            if service.uuid == CBUUID(string: "180A"), characteristic.properties.contains(.read) {
                pendingReads += 1
                peripheral.readValue(for: characteristic)
            }
        }
        if let error { print("    (couldn't list characteristics: \(error.localizedDescription))") }
        pendingServices -= 1
        finishIfDone()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let text = characteristic.value.flatMap { String(data: $0, encoding: .utf8) } ?? "(unreadable)"
        print("Device info: \(knownNames[characteristic.uuid.uuidString] ?? characteristic.uuid.uuidString) = \(text)")
        pendingReads -= 1
        finishIfDone()
    }

    func finishIfDone() {
        if pendingServices == 0 && pendingReads == 0 { exit(0) }
    }
}

let dumper = Dumper()
RunLoop.main.run()
