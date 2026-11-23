import Foundation
import CoreBluetooth

/// Keeps a Bluetooth LE subscription to the Android phone. iOS wakes the app (bluetooth-central
/// background mode) whenever the phone rings this "doorbell", and we then fetch new SMS/calls over Wi-Fi.
final class BLEWaker: NSObject {
    static let serviceUUID = CBUUID(string: "5B1E0001-7A1C-4F5E-9D2A-51B8B1D6E0A1")
    static let wakeUUID = CBUUID(string: "5B1E0002-7A1C-4F5E-9D2A-51B8B1D6E0A1")
    static let idUUID = CBUUID(string: "5B1E0003-7A1C-4F5E-9D2A-51B8B1D6E0A1")
    private static let restoreId = "app.simbridge.ble"
    private static let knownKey = "ble.knownPeripheral"

    var onWake: (() -> Void)?
    var onConnectedChange: ((Bool) -> Void)?

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var ignored = Set<UUID>()
    private var expectedId = Data()
    private(set) var connected = false {
        didSet { if connected != oldValue { onConnectedChange?(connected) } }
    }

    func start(serverId: String) {
        expectedId = WireCrypto.bleId(serverId: serverId)
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main, options: [
                CBCentralManagerOptionRestoreIdentifierKey: Self.restoreId,
                CBCentralManagerOptionShowPowerAlertKey: false,
            ])
        } else if central?.state == .poweredOn {
            begin()
        }
    }

    func stop() {
        if let p = peripheral { central?.cancelPeripheralConnection(p) }
        central?.stopScan()
        peripheral = nil
        connected = false
        UserDefaults.standard.removeObject(forKey: Self.knownKey)
    }

    var isPoweredOn: Bool { central?.state == .poweredOn }

    private func begin() {
        guard let central, central.state == .poweredOn, !expectedId.isEmpty else { return }
        if let p = peripheral, p.state == .connected || p.state == .connecting { return }
        if let s = UserDefaults.standard.string(forKey: Self.knownKey), let id = UUID(uuidString: s),
           let p = central.retrievePeripherals(withIdentifiers: [id]).first {
            connect(p)
        }
        // Android rotates its BLE address, so also scan by service UUID (works in background too).
        central.scanForPeripherals(withServices: [Self.serviceUUID], options: nil)
    }

    private func connect(_ p: CBPeripheral) {
        peripheral = p
        p.delegate = self
        central?.connect(p, options: nil)
    }
}

extension BLEWaker: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn { begin() } else { connected = false }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        if let ps = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral], let p = ps.first {
            peripheral = p
            p.delegate = self
            if p.state == .connected { connected = true; p.discoverServices([Self.serviceUUID]) }
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard !ignored.contains(peripheral.identifier) else { return }
        if let cur = self.peripheral, cur.state == .connected || cur.state == .connecting, cur.identifier != peripheral.identifier { return }
        connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        if peripheral === self.peripheral { self.peripheral = nil }
        begin()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral === self.peripheral else { return }
        connected = false
        // A pending connect never times out on iOS: it completes whenever the phone is back in range.
        central.connect(peripheral, options: nil)
        central.scanForPeripherals(withServices: [Self.serviceUUID], options: nil)
    }
}

extension BLEWaker: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let svc = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
            reject(peripheral); return
        }
        peripheral.discoverCharacteristics([Self.wakeUUID, Self.idUUID], for: svc)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let idChar = service.characteristics?.first(where: { $0.uuid == Self.idUUID }) else { reject(peripheral); return }
        peripheral.readValue(for: idChar)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if characteristic.uuid == Self.idUUID {
            guard characteristic.value == expectedId else { reject(peripheral); return }
            UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: Self.knownKey)
            central?.stopScan()
            connected = true
            if let wake = characteristic.service?.characteristics?.first(where: { $0.uuid == Self.wakeUUID }) {
                peripheral.setNotifyValue(true, for: wake)
            }
        } else if characteristic.uuid == Self.wakeUUID, error == nil, connected {
            onWake?()
        }
    }

    private func reject(_ p: CBPeripheral) {
        ignored.insert(p.identifier)
        central?.cancelPeripheralConnection(p)
        if p === peripheral { peripheral = nil }
        begin()
    }
}
