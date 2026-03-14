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
    @Published var notificationsEnabled = false
    @Published var lastDiscoveredPeripheralName = "-"
    @Published var lastAdvertisedLocalName = "-"
    @Published var lastDiscoveredRSSI = "-"
    @Published var lastDiscoveredServiceUUIDs = "-"
    @Published var lastSentPacketHex = "-"
    @Published var lastAck: AckV1?

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
    private var rxCharacteristic: CBCharacteristic?
    private var txCharacteristic: CBCharacteristic?
    private var nextSequenceNumber: UInt32 = 202
    private var pendingPositionSequence: UInt32?
    private var pendingPositionTrigger: String?

    private let positionSendInterval: TimeInterval = 10 * 60
    private let autoSendMaximumFixAge: TimeInterval = 60
    private let lastSuccessfulPositionSendDefaultsKey = "lastSuccessfulPositionSendTimeInterval"
    private let userDefaults = UserDefaults.standard

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
        if let lastSuccessfulPositionSendDate {
            print("BLEManager: initialized with last successful position send at \(Int(lastSuccessfulPositionSendDate.timeIntervalSince1970))")
        } else {
            print("BLEManager: initialized with no successful position send history")
        }
    }

    private var lastSuccessfulPositionSendDate: Date? {
        get {
            guard let storedTimeInterval = userDefaults.object(forKey: lastSuccessfulPositionSendDefaultsKey) as? TimeInterval else {
                return nil
            }

            return Date(timeIntervalSince1970: storedTimeInterval)
        }
        set {
            if let newValue {
                userDefaults.set(newValue.timeIntervalSince1970, forKey: lastSuccessfulPositionSendDefaultsKey)
            } else {
                userDefaults.removeObject(forKey: lastSuccessfulPositionSendDefaultsKey)
            }
        }
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
        centralManager.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        print("BLEManager: scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])")
    }

    private func resetDiscoveryStateForNewScan() {
        didFindDevice = false
        isConnected = false
        didDiscoverService = false
        didDiscoverCharacteristics = false
        notificationsEnabled = false
        lastDiscoveredPeripheralName = "-"
        lastAdvertisedLocalName = "-"
        lastDiscoveredRSSI = "-"
        lastDiscoveredServiceUUIDs = "-"
        lastSentPacketHex = "-"
        lastAck = nil
        targetPeripheral = nil
        rxCharacteristic = nil
        txCharacteristic = nil
        pendingPositionSequence = nil
        pendingPositionTrigger = nil
    }

    func sendPositionPacket(locationFix: LocationManager.LocationFix?) {
        sendPositionPacket(locationFix: locationFix, trigger: "manual")
    }

    func considerPositionSendIfDue(locationFix: LocationManager.LocationFix?, trigger: String) {
        guard isConnected && didDiscoverCharacteristics else {
            print("BLEManager: send-if-due skipped - BLE not ready trigger=\(trigger)")
            return
        }

        guard let locationFix else {
            print("BLEManager: send-if-due skipped - no live location trigger=\(trigger)")
            return
        }

        guard locationFix.horizontalAccuracy >= 0 else {
            print("BLEManager: send-if-due skipped - invalid accuracy trigger=\(trigger)")
            return
        }

        let fixAge = Date().timeIntervalSince(locationFix.timestamp)
        guard fixAge <= autoSendMaximumFixAge else {
            print("BLEManager: send-if-due skipped - stale fix ageSeconds=\(Int(fixAge)) trigger=\(trigger)")
            return
        }

        guard pendingPositionSequence == nil else {
            print("BLEManager: send-if-due skipped - awaiting ack for sequence=\(pendingPositionSequence ?? 0) trigger=\(trigger)")
            return
        }

        guard let lastSuccessfulPositionSendDate else {
            print("BLEManager: send-if-due allowed - no successful send yet trigger=\(trigger)")
            sendPositionPacket(locationFix: locationFix, trigger: "initial/\(trigger)")
            return
        }

        let secondsSinceLastSuccessfulSend = Date().timeIntervalSince(lastSuccessfulPositionSendDate)
        guard secondsSinceLastSuccessfulSend >= positionSendInterval else {
            print("BLEManager: send-if-due skipped - interval not reached secondsSinceLastSuccessfulSend=\(Int(secondsSinceLastSuccessfulSend)) trigger=\(trigger)")
            return
        }

        print("BLEManager: send-if-due allowed - 10 minute interval elapsed secondsSinceLastSuccessfulSend=\(Int(secondsSinceLastSuccessfulSend)) trigger=\(trigger)")
        sendPositionPacket(locationFix: locationFix, trigger: "periodic/\(trigger)")
    }

    private func sendPositionPacket(locationFix: LocationManager.LocationFix?, trigger: String) {
        guard let locationFix else {
            print("BLEManager: PositionUpdateV1 skipped - no live location available trigger=\(trigger)")
            return
        }

        let latitudeE5 = Int32((locationFix.latitude * 100_000).rounded())
        let longitudeE5 = Int32((locationFix.longitude * 100_000).rounded())
        let accuracyMeters = UInt16(max(0, min(locationFix.horizontalAccuracy.rounded(), Double(UInt16.max))))
        let fixTimestampUnix = UInt32(max(0, locationFix.timestamp.timeIntervalSince1970.rounded()))

        let sequence = nextSequenceNumber
        let values = PacketBuilder.PositionValues(
            sequence: sequence,
            timestampUnix: fixTimestampUnix,
            latE5: latitudeE5,
            lonE5: longitudeE5,
            accuracyM: accuracyMeters,
            fixTimestampUnix: fixTimestampUnix
        )
        nextSequenceNumber += 1
        pendingPositionSequence = sequence
        pendingPositionTrigger = trigger

        let packet = PacketBuilder.makePositionUpdateV1(values: values)
        lastSentPacketHex = packet.hexString
        print(
            """
            BLEManager: built PositionUpdateV1 packet \
            trigger=\(trigger) \
            sequence=\(sequence) \
            latE5=\(latitudeE5) \
            lonE5=\(longitudeE5) \
            accuracyM=\(accuracyMeters) \
            fixTimestampUnix=\(fixTimestampUnix) \
            hex=\(packet.hexString)
            """
        )
        writeToRX(packet, label: "PositionUpdateV1 packet")
    }

    private func writeToRX(_ payload: Data, label: String) {
        guard let peripheral = targetPeripheral else {
            print("BLEManager: \(label) write skipped - no connected peripheral")
            return
        }

        guard let rxCharacteristic else {
            print("BLEManager: \(label) write skipped - RX characteristic not available")
            return
        }

        let writeType: CBCharacteristicWriteType =
            rxCharacteristic.properties.contains(.write) ? .withResponse : .withoutResponse
        let writeTypeDescription = writeType == .withResponse ? "withResponse" : "withoutResponse"

        print("BLEManager: writing \(label) hex=\(payload.hexString) using \(writeTypeDescription)")
        peripheral.writeValue(payload, for: rxCharacteristic, type: writeType)
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
        let peripheralName = peripheral.name
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let serviceUUIDs = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]
        let serviceUUIDDescription = serviceUUIDs?.map(\.uuidString).joined(separator: ", ") ?? "none"

        lastDiscoveredPeripheralName = peripheralName ?? "-"
        lastAdvertisedLocalName = advertisedName ?? "-"
        lastDiscoveredRSSI = RSSI.stringValue
        lastDiscoveredServiceUUIDs = serviceUUIDDescription

        print(
            """
            BLEManager: discovered peripheral \
            peripheral.name=\(peripheralName ?? "nil") \
            advertisedLocalName=\(advertisedName ?? "nil") \
            RSSI=\(RSSI) \
            serviceUUIDs=\(serviceUUIDDescription) \
            id=\(peripheral.identifier)
            """
        )

        let isTargetMatch =
            peripheralName == Self.targetPeripheralName ||
            advertisedName == Self.targetPeripheralName

        guard isTargetMatch else {
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
        notificationsEnabled = false
        rxCharacteristic = nil
        txCharacteristic = nil

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

        rxCharacteristic = characteristics.first(where: { $0.uuid == Self.rxCharacteristicUUID })
        txCharacteristic = characteristics.first(where: { $0.uuid == Self.txCharacteristicUUID })
        didDiscoverCharacteristics = rxCharacteristic != nil && txCharacteristic != nil

        if didDiscoverCharacteristics {
            print("BLEManager: ready - RX and TX characteristics discovered")

            if let txCharacteristic {
                print("BLEManager: enabling notifications for TX characteristic \(txCharacteristic.uuid.uuidString)")
                peripheral.setNotifyValue(true, for: txCharacteristic)
            }
        } else {
            print("BLEManager: characteristic discovery incomplete")
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error {
            print("BLEManager: notification state update failed for \(characteristic.uuid.uuidString) error=\(error.localizedDescription)")
            return
        }

        notificationsEnabled = characteristic.uuid == Self.txCharacteristicUUID && characteristic.isNotifying
        print("BLEManager: notifications \(characteristic.isNotifying ? "enabled" : "disabled") for \(characteristic.uuid.uuidString)")
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error {
            print("BLEManager: notification receive failed for \(characteristic.uuid.uuidString) error=\(error.localizedDescription)")
            return
        }

        let data = characteristic.value ?? Data()
        print("BLEManager: received notification on \(characteristic.uuid.uuidString) hex=\(data.hexString)")

        guard characteristic.uuid == Self.txCharacteristicUUID else {
            return
        }

        do {
            let ack = try AckParser.parse(data)
            lastAck = ack

            print(
                """
                BLEManager: parsed AckV1 \
                status=\(ack.status) \
                echoedSequence=\(ack.sequence) \
                activeWeatherTimestamp=\(ack.weatherTimestamp) \
                activePositionTimestamp=\(ack.positionTimestamp)
                """
            )

            if ack.status == .ok, ack.sequence == pendingPositionSequence {
                let acceptedAt = Date()
                lastSuccessfulPositionSendDate = acceptedAt
                print(
                    """
                    BLEManager: position send accepted \
                    sequence=\(ack.sequence) \
                    trigger=\(pendingPositionTrigger ?? "unknown") \
                    acceptedAtUnix=\(Int(acceptedAt.timeIntervalSince1970))
                    """
                )
                pendingPositionSequence = nil
                pendingPositionTrigger = nil
            } else if ack.sequence == pendingPositionSequence {
                print("BLEManager: position send not accepted status=\(ack.status) sequence=\(ack.sequence)")
                pendingPositionSequence = nil
                pendingPositionTrigger = nil
            } else {
                print("BLEManager: ack sequence does not match pending position send ackSequence=\(ack.sequence) pendingSequence=\(pendingPositionSequence.map(String.init) ?? "none")")
            }
        } catch {
            print("BLEManager: AckV1 parse failed error=\(error.localizedDescription)")
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error {
            print("BLEManager: write failed for \(characteristic.uuid.uuidString) error=\(error.localizedDescription)")
            return
        }

        print("BLEManager: write completed for \(characteristic.uuid.uuidString)")
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

private extension Data {
    var hexString: String {
        map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}
