//
//  BLEManager.swift
//  WeatherRelay
//
//  Created by Codex on 2026-03-13.
//

import Combine
import CoreBluetooth
import Foundation

final class BLEManager: NSObject, ObservableObject {
    static let targetPeripheralName = "WeatherComputer"
    static let serviceUUID = CBUUID(string: "19B10010-E8F2-537E-4F6C-D104768A1214")
    static let rxCharacteristicUUID = CBUUID(string: "19B10011-E8F2-537E-4F6C-D104768A1214")
    static let txCharacteristicUUID = CBUUID(string: "19B10012-E8F2-537E-4F6C-D104768A1214")

    @Published var bluetoothPoweredOn = false
    @Published var isScanning = false
    @Published var didFindDevice = false
    @Published var isConnected = false
    @Published var didDiscoverService = false
    @Published var didDiscoverCharacteristics = false

    var statusText: String {
        if !bluetoothPoweredOn {
            return "Bluetooth Off"
        }

        if didDiscoverCharacteristics {
            return "Ready"
        }

        if isConnected {
            return "Connected"
        }

        if didFindDevice {
            return "Found WeatherComputer"
        }

        if isScanning {
            return "Scanning"
        }

        return "Starting Bluetooth..."
    }

    private var centralManager: CBCentralManager!
    private var targetPeripheral: CBPeripheral?

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
        print("BLEManager: initialized")
    }

    private func startScanningIfNeeded() {
        guard bluetoothPoweredOn else {
            print("BLEManager: Bluetooth is not powered on, cannot scan")
            return
        }

        guard !isScanning else {
            return
        }

        guard !isConnected else {
            return
        }

        print("BLEManager: starting scan for \(Self.targetPeripheralName)")
        isScanning = true
        centralManager.scanForPeripherals(withServices: [Self.serviceUUID], options: nil)
    }

    private func resetDiscoveryStateForNewScan() {
        didFindDevice = false
        isConnected = false
        didDiscoverService = false
        didDiscoverCharacteristics = false
        targetPeripheral = nil
    }
}

extension BLEManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        bluetoothPoweredOn = central.state == .poweredOn
        print("BLEManager: central state changed to \(central.state.description)")

        switch central.state {
        case .poweredOn:
            startScanningIfNeeded()
        case .poweredOff, .resetting, .unauthorized, .unsupported, .unknown:
            isScanning = false
            resetDiscoveryStateForNewScan()
        @unknown default:
            isScanning = false
            resetDiscoveryStateForNewScan()
            print("BLEManager: encountered unknown Bluetooth state")
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = peripheral.name ?? advertisedName ?? "Unnamed"
        print("BLEManager: discovered peripheral name=\(name) id=\(peripheral.identifier) RSSI=\(RSSI)")

        guard name == Self.targetPeripheralName else {
            return
        }

        print("BLEManager: found target peripheral \(Self.targetPeripheralName)")
        didFindDevice = true
        isScanning = false
        targetPeripheral = peripheral
        peripheral.delegate = self
        central.stopScan()

        print("BLEManager: connecting to \(Self.targetPeripheralName)")
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("BLEManager: connected to \(peripheral.name ?? Self.targetPeripheralName)")
        isConnected = true
        didDiscoverService = false
        didDiscoverCharacteristics = false

        print("BLEManager: discovering services")
        peripheral.discoverServices([Self.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        print("BLEManager: failed to connect to \(peripheral.name ?? Self.targetPeripheralName) error=\(error?.localizedDescription ?? "none")")
        resetDiscoveryStateForNewScan()
        startScanningIfNeeded()
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        print("BLEManager: disconnected from \(peripheral.name ?? Self.targetPeripheralName) error=\(error?.localizedDescription ?? "none")")
        isConnected = false
        didDiscoverService = false
        didDiscoverCharacteristics = false
        targetPeripheral = nil
        startScanningIfNeeded()
    }
}

extension BLEManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            print("BLEManager: service discovery failed error=\(error.localizedDescription)")
            return
        }

        guard let services = peripheral.services, !services.isEmpty else {
            print("BLEManager: no services discovered")
            return
        }

        for service in services {
            print("BLEManager: discovered service \(service.uuid.uuidString)")
        }

        if let weatherService = services.first(where: { $0.uuid == Self.serviceUUID }) {
            didDiscoverService = true
            print("BLEManager: discovering characteristics for service \(weatherService.uuid.uuidString)")
            peripheral.discoverCharacteristics([Self.rxCharacteristicUUID, Self.txCharacteristicUUID], for: weatherService)
        } else {
            print("BLEManager: target service not found")
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        if let error {
            print("BLEManager: characteristic discovery failed error=\(error.localizedDescription)")
            return
        }

        guard let characteristics = service.characteristics, !characteristics.isEmpty else {
            print("BLEManager: no characteristics discovered for service \(service.uuid.uuidString)")
            return
        }

        for characteristic in characteristics {
            print("BLEManager: discovered characteristic \(characteristic.uuid.uuidString) properties=\(characteristic.properties.description)")
        }

        let characteristicUUIDs = Set(characteristics.map(\.uuid))
        let hasRX = characteristicUUIDs.contains(Self.rxCharacteristicUUID)
        let hasTX = characteristicUUIDs.contains(Self.txCharacteristicUUID)
        didDiscoverCharacteristics = hasRX && hasTX

        if didDiscoverCharacteristics {
            print("BLEManager: ready - RX and TX characteristics discovered")
        } else {
            print("BLEManager: characteristic discovery incomplete")
        }
    }
}

private extension CBManagerState {
    var description: String {
        switch self {
        case .unknown:
            return "unknown"
        case .resetting:
            return "resetting"
        case .unsupported:
            return "unsupported"
        case .unauthorized:
            return "unauthorized"
        case .poweredOff:
            return "poweredOff"
        case .poweredOn:
            return "poweredOn"
        @unknown default:
            return "unknownDefault"
        }
    }
}

private extension CBCharacteristicProperties {
    var description: String {
        var names: [String] = []

        if contains(.broadcast) { names.append("broadcast") }
        if contains(.read) { names.append("read") }
        if contains(.writeWithoutResponse) { names.append("writeWithoutResponse") }
        if contains(.write) { names.append("write") }
        if contains(.notify) { names.append("notify") }
        if contains(.indicate) { names.append("indicate") }
        if contains(.authenticatedSignedWrites) { names.append("authenticatedSignedWrites") }
        if contains(.extendedProperties) { names.append("extendedProperties") }
        if contains(.notifyEncryptionRequired) { names.append("notifyEncryptionRequired") }
        if contains(.indicateEncryptionRequired) { names.append("indicateEncryptionRequired") }

        return names.isEmpty ? "[]" : names.joined(separator: ", ")
    }
}
