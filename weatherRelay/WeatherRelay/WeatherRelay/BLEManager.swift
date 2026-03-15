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
    static let restorationIdentifier = "com.ctsmith.WeatherRelay.central"

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
    private var pendingWeatherSequence: UInt32?
    private var pendingWeatherChunkQueue: [Data] = []
    private var pendingWeatherChunkWriteType: CBCharacteristicWriteType?
    private var pendingWeatherChunkIndex = 0
    private var pendingWeatherChunkTotal = 0
    private var latestWeatherField: ThreeByThreeWeatherFieldDebugData?
    private var latestWeatherRevision = 0
    private var lastAcceptedWeatherRevision = 0
    private var nextWeatherSequenceNumber: UInt32 = 1
    private var lastSuccessfulWeatherSendDate: Date?
    private var lastSuccessfulWeatherSequence: UInt32?
    private var pendingWeatherRevision: Int?
    private var queuedPositionAfterWeatherFix: LocationManager.LocationFix?
    private var queuedPositionAfterWeatherTrigger: String?
    private var restoredPeripheralPendingPoweredOn: CBPeripheral?
    private var restoredPeripheralWasConnected = false

    private let positionSendInterval: TimeInterval = 10 * 60
    private let autoSendMaximumFixAge: TimeInterval = 60
    private let lastSuccessfulPositionSendDefaultsKey = "lastSuccessfulPositionSendTimeInterval"
    private let userDefaults = UserDefaults.standard

    override init() {
        super.init()
        centralManager = CBCentralManager(
            delegate: self,
            queue: nil,
            options: [CBCentralManagerOptionRestoreIdentifierKey: Self.restorationIdentifier]
        )
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
            print("BLEManager: scan skipped - already scanning")
            return
        }

        guard !isConnected else {
            print("BLEManager: scan skipped - already connected")
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
        if let pendingPositionSequence {
            print(
                """
                BLEManager: clearing pending position state for new scan \
                sequence=\(pendingPositionSequence) \
                trigger=\(pendingPositionTrigger ?? "unknown")
                """
            )
        }
        if let pendingWeatherSequence {
            print(
                """
                BLEManager: clearing pending weather state for new scan \
                sequence=\(pendingWeatherSequence) \
                remainingChunks=\(pendingWeatherChunkQueue.count)
                """
            )
        }
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
        pendingWeatherSequence = nil
        pendingWeatherChunkQueue = []
        pendingWeatherChunkWriteType = nil
        pendingWeatherChunkIndex = 0
        pendingWeatherChunkTotal = 0
        pendingWeatherRevision = nil
        queuedPositionAfterWeatherFix = nil
        queuedPositionAfterWeatherTrigger = nil
        restoredPeripheralPendingPoweredOn = nil
        restoredPeripheralWasConnected = false
    }

    func sendPositionPacket(locationFix: LocationManager.LocationFix?) {
        sendPositionPacket(locationFix: locationFix, trigger: "manual")
    }

    func sendDisplayOn() {
        sendDisplayControl(command: .on)
    }

    func sendDisplayOff() {
        sendDisplayControl(command: .off)
    }

    func sendLatestRegionalSnapshotV1Debug() {
        guard hasNewerWeatherToSend || latestWeatherField != nil else {
            print("BLEManager: manual RegionalSnapshotV1 send skipped - no weather field available")
            return
        }

        _ = sendLatestRegionalSnapshotV1(trigger: "manual")
    }

    func updateLatestWeatherField(_ field: ThreeByThreeWeatherFieldDebugData?, revision: Int) {
        latestWeatherField = field
        latestWeatherRevision = revision
        print(
            """
            BLEManager: updated latest weather field \
            revision=\(revision) \
            hasField=\(field != nil) \
            lastAcceptedWeatherRevision=\(lastAcceptedWeatherRevision)
            """
        )
    }

    func sendRegionalSnapshotV1Debug(_ packetDebug: RegionalSnapshotPacketDebugData) {
        guard packetDebug.isPacketLengthValid else {
            print("BLEManager: RegionalSnapshotV1 send skipped - packetLength=\(packetDebug.packetByteLength) expected=\(RegionalSnapshotBuilder.regionalSnapshotPacketSize)")
            return
        }

        guard isConnected && didDiscoverCharacteristics else {
            print("BLEManager: RegionalSnapshotV1 send skipped - BLE not ready")
            return
        }

        guard pendingWeatherChunkQueue.isEmpty else {
            print("BLEManager: RegionalSnapshotV1 send skipped - weather transfer already in progress sequence=\(pendingWeatherSequence.map(String.init) ?? "none")")
            return
        }

        guard pendingPositionSequence == nil else {
            print("BLEManager: RegionalSnapshotV1 send skipped - position packet awaiting ACK sequence=\(pendingPositionSequence.map(String.init) ?? "none")")
            return
        }

        guard let peripheral = targetPeripheral, let rxCharacteristic else {
            print("BLEManager: RegionalSnapshotV1 send skipped - peripheral or RX characteristic unavailable")
            return
        }

        let writeType: CBCharacteristicWriteType =
            rxCharacteristic.properties.contains(.write) ? .withResponse : .withoutResponse
        let writeTypeDescription = writeType == .withResponse ? "withResponse" : "withoutResponse"
        let peripheralMax = peripheral.maximumWriteValueLength(for: writeType)
        let chunkSize = max(1, min(peripheralMax, 180))
        let chunks = packetDebug.packet.chunked(into: chunkSize)

        pendingWeatherSequence = packetDebug.sequence
        pendingWeatherChunkQueue = chunks
        pendingWeatherChunkWriteType = writeType
        pendingWeatherChunkIndex = 0
        pendingWeatherChunkTotal = chunks.count
        lastSentPacketHex = packetDebug.packetHexPreview

        print(
            """
            BLEManager: starting RegionalSnapshotV1 send \
            sequence=\(packetDebug.sequence) \
            totalLength=\(packetDebug.packet.count) \
            chunkCount=\(chunks.count) \
            chunkSize=\(chunkSize) \
            peripheralMaxWriteLength=\(peripheralMax) \
            writeType=\(writeTypeDescription)
            """
        )
        AppLogger.shared.log(
            category: "BLE",
            message: "weather packet send start size=\(packetDebug.packet.count) chunks=\(chunks.count) chunkSize=\(chunkSize)"
        )

        if writeType == .withResponse {
            writeNextWeatherChunk()
        } else {
            for chunkIndex in chunks.indices {
                let chunk = chunks[chunkIndex]
                print("BLEManager: sending RegionalSnapshotV1 chunk \(chunkIndex + 1)/\(chunks.count) bytes=\(chunk.count)")
                peripheral.writeValue(chunk, for: rxCharacteristic, type: writeType)
            }
            pendingWeatherChunkQueue = []
            pendingWeatherChunkWriteType = nil
            pendingWeatherChunkIndex = chunks.count
            print("BLEManager: RegionalSnapshotV1 chunks queued withoutResponse awaiting ACK sequence=\(packetDebug.sequence)")
        }
    }

    func considerPositionSendIfDue(locationFix: LocationManager.LocationFix?, trigger: String) {
        let nowUnix = Int(Date().timeIntervalSince1970)
        let fixAgeDescription: String
        if let locationFix {
            fixAgeDescription = String(Int(Date().timeIntervalSince(locationFix.timestamp)))
        } else {
            fixAgeDescription = "none"
        }
        let lastSuccessfulDescription = lastSuccessfulPositionSendDate.map { String(Int($0.timeIntervalSince1970)) } ?? "none"

        print(
            """
            BLEManager: send-if-due evaluating \
            trigger=\(trigger) \
            nowUnix=\(nowUnix) \
            bleReady=\(isConnected && didDiscoverCharacteristics) \
            hasFix=\(locationFix != nil) \
            fixAgeSeconds=\(fixAgeDescription) \
            pendingSequence=\(pendingPositionSequence.map(String.init) ?? "none") \
            pendingWeatherSequence=\(pendingWeatherSequence.map(String.init) ?? "none") \
            pendingWeatherChunks=\(pendingWeatherChunkQueue.count) \
            latestWeatherRevision=\(latestWeatherRevision) \
            lastAcceptedWeatherRevision=\(lastAcceptedWeatherRevision) \
            lastSuccessfulSendUnix=\(lastSuccessfulDescription)
            """
        )

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

        guard pendingWeatherSequence == nil, pendingWeatherChunkQueue.isEmpty else {
            print("BLEManager: send-if-due skipped - weather transfer in progress trigger=\(trigger)")
            return
        }

        guard let lastSuccessfulPositionSendDate else {
            runNormalSendCycle(locationFix: locationFix, trigger: "initial/\(trigger)")
            return
        }

        let secondsSinceLastSuccessfulSend = Date().timeIntervalSince(lastSuccessfulPositionSendDate)
        guard secondsSinceLastSuccessfulSend >= positionSendInterval else {
            print("BLEManager: send-if-due skipped - interval not reached secondsSinceLastSuccessfulSend=\(Int(secondsSinceLastSuccessfulSend)) trigger=\(trigger)")
            return
        }

        runNormalSendCycle(locationFix: locationFix, trigger: "periodic/\(trigger)")
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

    private func sendDisplayControl(command: PacketBuilder.DisplayControlCommand) {
        let commandLabel = command == .on ? "display_on" : "display_off"
        let sequence = nextSequenceNumber
        nextSequenceNumber += 1
        let timestampUnix = UInt32(max(0, Date().timeIntervalSince1970.rounded()))
        let values = PacketBuilder.DisplayControlValues(
            sequence: sequence,
            timestampUnix: timestampUnix,
            command: command
        )
        let packet = PacketBuilder.makeDisplayControlV1(values: values)
        lastSentPacketHex = packet.hexString

        print(
            """
            BLEManager: sending DisplayControlV1 \
            sequence=\(sequence) \
            timestampUnix=\(timestampUnix) \
            command=\(commandLabel) \
            hex=\(packet.hexString)
            """
        )
        AppLogger.shared.log(category: "BLE", message: "DISPLAY_CMD: sending \(commandLabel)")
        writeToRX(packet, label: "DisplayControlV1 \(commandLabel)")
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

        guard pendingWeatherChunkQueue.isEmpty else {
            print("BLEManager: \(label) write skipped - RX busy with RegionalSnapshotV1 chunk transfer")
            return
        }

        let writeType: CBCharacteristicWriteType =
            rxCharacteristic.properties.contains(.write) ? .withResponse : .withoutResponse
        let writeTypeDescription = writeType == .withResponse ? "withResponse" : "withoutResponse"

        print("BLEManager: writing \(label) hex=\(payload.hexString) using \(writeTypeDescription)")
        AppLogger.shared.log(
            category: "BLE",
            message: "packet sent label=\(label) size=\(payload.count) writeType=\(writeTypeDescription)"
        )
        peripheral.writeValue(payload, for: rxCharacteristic, type: writeType)
    }

    private func writeNextWeatherChunk() {
        guard let peripheral = targetPeripheral, let rxCharacteristic else {
            print("BLEManager: RegionalSnapshotV1 chunk send aborted - peripheral or RX characteristic unavailable")
            pendingWeatherChunkQueue = []
            pendingWeatherChunkWriteType = nil
            return
        }

        guard let writeType = pendingWeatherChunkWriteType, !pendingWeatherChunkQueue.isEmpty else {
            return
        }

        let chunk = pendingWeatherChunkQueue.removeFirst()
        pendingWeatherChunkIndex += 1
        print("BLEManager: sending RegionalSnapshotV1 chunk \(pendingWeatherChunkIndex)/\(pendingWeatherChunkTotal) bytes=\(chunk.count)")
        peripheral.writeValue(chunk, for: rxCharacteristic, type: writeType)
    }

    private func runNormalSendCycle(locationFix: LocationManager.LocationFix, trigger: String) {
        if hasNewerWeatherToSend {
            print("BLEManager: normal send cycle = weather+position trigger=\(trigger)")
            queuedPositionAfterWeatherFix = locationFix
            queuedPositionAfterWeatherTrigger = trigger
            let startedWeatherSend = sendLatestRegionalSnapshotV1(trigger: "normal/\(trigger)")
            if !startedWeatherSend {
                print("BLEManager: weather send could not start, falling back to position-only trigger=\(trigger)")
                queuedPositionAfterWeatherFix = nil
                queuedPositionAfterWeatherTrigger = nil
                sendPositionPacket(locationFix: locationFix, trigger: trigger)
            }
        } else {
            print("BLEManager: normal send cycle = position-only trigger=\(trigger)")
            print("BLEManager: weather skipped on normal send - no newer field trigger=\(trigger)")
            sendPositionPacket(locationFix: locationFix, trigger: trigger)
        }
    }

    private var hasNewerWeatherToSend: Bool {
        latestWeatherField != nil && latestWeatherRevision > lastAcceptedWeatherRevision
    }

    private func sendLatestRegionalSnapshotV1(trigger: String) -> Bool {
        guard let latestWeatherField else {
            print("BLEManager: RegionalSnapshotV1 send skipped - no latest weather field trigger=\(trigger)")
            return false
        }

        let sequence = nextWeatherSequenceNumber
        nextWeatherSequenceNumber += 1
        let packetDebug = RegionalSnapshotBuilder.makeRegionalSnapshotV1DebugData(
            field: latestWeatherField,
            sequence: sequence
        )

        guard packetDebug.isPacketLengthValid else {
            print("BLEManager: RegionalSnapshotV1 send skipped - built packet invalid trigger=\(trigger) bytes=\(packetDebug.packetByteLength)")
            return false
        }

        pendingWeatherRevision = latestWeatherRevision
        sendRegionalSnapshotV1Debug(packetDebug)
        return true
    }

    private func continueQueuedPositionAfterWeather(reason: String) {
        guard let queuedPositionAfterWeatherFix, let queuedPositionAfterWeatherTrigger else {
            return
        }

        self.queuedPositionAfterWeatherFix = nil
        self.queuedPositionAfterWeatherTrigger = nil
        print("BLEManager: continuing queued position send after weather reason=\(reason) trigger=\(queuedPositionAfterWeatherTrigger)")
        sendPositionPacket(locationFix: queuedPositionAfterWeatherFix, trigger: "after-weather/\(queuedPositionAfterWeatherTrigger)")
    }

    private func resumeRestoredPeripheralIfNeeded() {
        guard bluetoothPoweredOn else {
            return
        }

        guard let restoredPeripheral = restoredPeripheralPendingPoweredOn else {
            return
        }

        restoredPeripheralPendingPoweredOn = nil

        guard restoredPeripheralWasConnected else {
            print("BLEManager: poweredOn reached, restored peripheral was not connected - waiting for normal reconnect path")
            restoredPeripheralWasConnected = false
            return
        }

        restoredPeripheralWasConnected = false
        targetPeripheral = restoredPeripheral
        restoredPeripheral.delegate = self
        isConnected = true
        print(
            """
            BLEManager: poweredOn reached, resuming restored peripheral flow \
            name=\(restoredPeripheral.name ?? "nil") \
            id=\(restoredPeripheral.identifier)
            """
        )
        print("BLEManager: restored connected peripheral, rediscovering services after poweredOn")
        restoredPeripheral.discoverServices([Self.serviceUUID])
    }
}

extension BLEManager: CBCentralManagerDelegate {
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let restoredPeripherals = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral]) ?? []
        let restoredScanServices = (dict[CBCentralManagerRestoredStateScanServicesKey] as? [CBUUID]) ?? []

        print(
            """
            BLEManager: willRestoreState \
            peripherals=\(restoredPeripherals.count) \
            scanServices=\(restoredScanServices.map(\.uuidString).joined(separator: ", "))
            """
        )

        if let restoredPeripheral = restoredPeripherals.first(where: {
            $0.name == Self.targetPeripheralName || $0.identifier == targetPeripheral?.identifier
        }) ?? restoredPeripherals.first {
            restoredPeripheralPendingPoweredOn = restoredPeripheral
            restoredPeripheralWasConnected = restoredPeripheral.state == .connected
            targetPeripheral = restoredPeripheral
            restoredPeripheral.delegate = self
            print(
                """
                BLEManager: restored peripheral \
                name=\(restoredPeripheral.name ?? "nil") \
                id=\(restoredPeripheral.identifier) \
                state=\(restoredPeripheral.state.description)
                """
            )
            print(
                """
                BLEManager: restored peripheral stored pending poweredOn \
                wasConnected=\(restoredPeripheralWasConnected)
                """
            )
        } else {
            print("BLEManager: willRestoreState found no peripheral to restore")
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        bluetoothPoweredOn = central.state == .poweredOn
        print("BLEManager: central state changed to \(central.state.description)")

        switch central.state {
        case .poweredOn:
            resumeRestoredPeripheralIfNeeded()
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

        print("BLEManager: connecting to \(Self.targetPeripheralName) id=\(peripheral.identifier)")
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("BLEManager: connected to \(peripheral.name ?? Self.targetPeripheralName) id=\(peripheral.identifier)")
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
        print("BLEManager: reconnect path - resetting discovery state and resuming scan")
        resetDiscoveryStateForNewScan()
        startScanningIfNeeded()
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        print("BLEManager: disconnected from \(peripheral.name ?? Self.targetPeripheralName) error=\(error?.localizedDescription ?? "none")")
        print(
            """
            BLEManager: reconnect path triggered after disconnect \
            pendingSequence=\(pendingPositionSequence.map(String.init) ?? "none") \
            pendingTrigger=\(pendingPositionTrigger ?? "none")
            """
        )
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
            } else if ack.status == .ok, ack.sequence == pendingWeatherSequence {
                let acceptedAt = Date()
                lastSuccessfulWeatherSendDate = acceptedAt
                lastSuccessfulWeatherSequence = ack.sequence
                if let pendingWeatherRevision {
                    lastAcceptedWeatherRevision = pendingWeatherRevision
                }
                print(
                    """
                    BLEManager: RegionalSnapshotV1 send accepted \
                    sequence=\(ack.sequence) \
                    activeWeatherTimestamp=\(ack.weatherTimestamp) \
                    acceptedAtUnix=\(Int(acceptedAt.timeIntervalSince1970)) \
                    acceptedWeatherRevision=\(lastAcceptedWeatherRevision)
                    """
                )
                pendingWeatherSequence = nil
                pendingWeatherChunkQueue = []
                pendingWeatherChunkWriteType = nil
                pendingWeatherChunkIndex = 0
                pendingWeatherChunkTotal = 0
                pendingWeatherRevision = nil
                continueQueuedPositionAfterWeather(reason: "weather-ack-ok")
            } else if ack.sequence == pendingPositionSequence {
                print(
                    """
                    BLEManager: position send not accepted \
                    status=\(ack.status) \
                    sequence=\(ack.sequence) \
                    trigger=\(pendingPositionTrigger ?? "unknown")
                    """
                )
                pendingPositionSequence = nil
                pendingPositionTrigger = nil
            } else if ack.sequence == pendingWeatherSequence {
                print(
                    """
                    BLEManager: RegionalSnapshotV1 send not accepted \
                    status=\(ack.status) \
                    sequence=\(ack.sequence)
                    """
                )
                pendingWeatherSequence = nil
                pendingWeatherChunkQueue = []
                pendingWeatherChunkWriteType = nil
                pendingWeatherChunkIndex = 0
                pendingWeatherChunkTotal = 0
                pendingWeatherRevision = nil
                continueQueuedPositionAfterWeather(reason: "weather-ack-not-ok")
            } else {
                print(
                    """
                    BLEManager: ack sequence does not match pending send \
                    ackSequence=\(ack.sequence) \
                    pendingPositionSequence=\(pendingPositionSequence.map(String.init) ?? "none") \
                    pendingPositionTrigger=\(pendingPositionTrigger ?? "none") \
                    pendingWeatherSequence=\(pendingWeatherSequence.map(String.init) ?? "none")
                    """
                )
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
            if !pendingWeatherChunkQueue.isEmpty || pendingWeatherChunkIndex > 0 {
                print("BLEManager: RegionalSnapshotV1 chunk send aborted after write failure")
                pendingWeatherChunkQueue = []
                pendingWeatherChunkWriteType = nil
                pendingWeatherChunkIndex = 0
                pendingWeatherChunkTotal = 0
                pendingWeatherSequence = nil
                pendingWeatherRevision = nil
            }
            return
        }

        print(
            """
            BLEManager: write completed \
            characteristic=\(characteristic.uuid.uuidString) \
            pendingSequence=\(pendingPositionSequence.map(String.init) ?? "none") \
            pendingTrigger=\(pendingPositionTrigger ?? "none") \
            pendingWeatherSequence=\(pendingWeatherSequence.map(String.init) ?? "none") \
            weatherChunkProgress=\(pendingWeatherChunkIndex)/\(pendingWeatherChunkTotal)
            """
        )

        if pendingWeatherChunkWriteType == .withResponse, characteristic.uuid == Self.rxCharacteristicUUID {
            if !pendingWeatherChunkQueue.isEmpty {
                writeNextWeatherChunk()
            } else if pendingWeatherChunkTotal > 0 {
                print("BLEManager: RegionalSnapshotV1 chunk transfer complete awaiting ACK sequence=\(pendingWeatherSequence.map(String.init) ?? "none")")
                pendingWeatherChunkWriteType = nil
                pendingWeatherChunkIndex = 0
                pendingWeatherChunkTotal = 0
            }
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

private extension CBPeripheralState {
    var description: String {
        switch self {
        case .disconnected:
            return "disconnected"
        case .connecting:
            return "connecting"
        case .connected:
            return "connected"
        case .disconnecting:
            return "disconnecting"
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

    func chunked(into chunkSize: Int) -> [Data] {
        guard chunkSize > 0 else {
            return [self]
        }

        var chunks: [Data] = []
        var offset = startIndex

        while offset < endIndex {
            let nextOffset = index(offset, offsetBy: chunkSize, limitedBy: endIndex) ?? endIndex
            chunks.append(self[offset..<nextOffset])
            offset = nextOffset
        }

        return chunks
    }
}
