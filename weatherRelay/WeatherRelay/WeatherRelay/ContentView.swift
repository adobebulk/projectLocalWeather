//
//  ContentView.swift
//  WeatherRelay
//
//  Created by Clayton Smith on 2026-03-13.
//

import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var bleManager = BLEManager()
    @StateObject private var locationManager = LocationManager()

    private var latitudeText: String {
        guard let latitude = locationManager.latestLatitude else {
            return "-"
        }

        return String(format: "%.5f", latitude)
    }

    private var longitudeText: String {
        guard let longitude = locationManager.latestLongitude else {
            return "-"
        }

        return String(format: "%.5f", longitude)
    }

    private var accuracyText: String {
        guard let accuracy = locationManager.latestHorizontalAccuracy else {
            return "-"
        }

        return String(format: "%.1f m", accuracy)
    }

    private var locationTimestampText: String {
        guard let timestamp = locationManager.latestTimestamp else {
            return "-"
        }

        return String(Int(timestamp.timeIntervalSince1970))
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Weather Relay")
                .font(.title2)
                .fontWeight(.semibold)

            Text(bleManager.statusText)
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Text("Scan state: \(bleManager.isScanning ? "Scanning" : "Not scanning")")
                Text("Last peripheral name: \(bleManager.lastDiscoveredPeripheralName)")
                Text("Last advertised name: \(bleManager.lastAdvertisedLocalName)")
                Text("Found target: \(bleManager.didFindDevice ? "Yes" : "No")")
                Text("Last sent packet: \(bleManager.lastSentPacketHex)")
                Text("ACK status: \(bleManager.lastAck.map { $0.status.description } ?? "-")")
                Text("ACK echoed sequence: \(bleManager.lastAck.map { String($0.sequence) } ?? "-")")
                Text("ACK weather timestamp: \(bleManager.lastAck.map { String($0.weatherTimestamp) } ?? "-")")
                Text("ACK position timestamp: \(bleManager.lastAck.map { String($0.positionTimestamp) } ?? "-")")
                Text("Location status: \(locationManager.statusText)")
                Text("Latitude: \(latitudeText)")
                Text("Longitude: \(longitudeText)")
                Text("Accuracy: \(accuracyText)")
                Text("Location timestamp: \(locationTimestampText)")
            }
            .font(.subheadline)
            .frame(maxWidth: .infinity, alignment: .leading)

            if bleManager.didDiscoverService {
                Text("Service discovered")
                    .foregroundStyle(.secondary)
            }

            if bleManager.didDiscoverCharacteristics {
                Text("RX/TX characteristics discovered")
                    .foregroundStyle(.secondary)
            }

            Button("Send Position Packet") {
                bleManager.sendPositionPacket(locationFix: locationManager.currentFix)
            }
            .buttonStyle(.bordered)
            .disabled(!bleManager.didDiscoverCharacteristics || !locationManager.hasValidLocation)
        }
        .padding()
        .onChange(of: bleManager.didDiscoverCharacteristics) { _, _ in
            bleManager.considerPositionSendIfDue(locationFix: locationManager.currentFix, trigger: "ble-ready")
        }
        .onChange(of: locationManager.currentFix?.timestamp) { _, _ in
            bleManager.considerPositionSendIfDue(locationFix: locationManager.currentFix, trigger: "location-update")
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                bleManager.considerPositionSendIfDue(locationFix: locationManager.currentFix, trigger: "scene-active")
            }
        }
    }
}
