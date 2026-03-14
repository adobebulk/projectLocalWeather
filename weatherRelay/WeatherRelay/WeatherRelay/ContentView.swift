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
    @StateObject private var weatherDebugViewModel = WeatherDebugViewModel()

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
        NavigationStack {
            ScrollView {
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

                    NavigationLink("Weather Debug") {
                        WeatherDebugView(
                            locationManager: locationManager,
                            bleManager: bleManager,
                            viewModel: weatherDebugViewModel
                        )
                    }
                    .buttonStyle(.bordered)

                    NavigationLink("Weather Field Map") {
                        WeatherFieldMapView(viewModel: weatherDebugViewModel)
                    }
                    .buttonStyle(.bordered)

                    if locationManager.canRequestAlwaysAuthorization {
                        Button("Enable Background Location") {
                            locationManager.requestAlwaysAuthorizationIfPossible()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding()
            }
        }
        .onAppear {
            print("ContentView: appeared scenePhase=\(scenePhase.description)")
        }
        .onChange(of: bleManager.didDiscoverCharacteristics) { _, _ in
            print(
                """
                ContentView: BLE readiness changed \
                didDiscoverCharacteristics=\(bleManager.didDiscoverCharacteristics) \
                scenePhase=\(scenePhase.description)
                """
            )
            bleManager.considerPositionSendIfDue(locationFix: locationManager.currentFix, trigger: "ble-ready")
        }
        .onChange(of: locationManager.currentFix?.timestamp) { _, _ in
            print(
                """
                ContentView: location fix changed \
                hasFix=\(locationManager.currentFix != nil) \
                scenePhase=\(scenePhase.description)
                """
            )
            bleManager.considerPositionSendIfDue(locationFix: locationManager.currentFix, trigger: "location-update")
        }
        .onChange(of: weatherDebugViewModel.latestPacketRevision) { _, newRevision in
            bleManager.updateLatestWeatherField(
                weatherDebugViewModel.latestFieldWeatherData,
                revision: newRevision
            )
        }
        .onChange(of: scenePhase) { _, newPhase in
            print("ContentView: scenePhase changed to \(newPhase.description)")
            if newPhase == .active {
                bleManager.considerPositionSendIfDue(locationFix: locationManager.currentFix, trigger: "scene-active")
            }
        }
    }
}

private extension ScenePhase {
    var description: String {
        switch self {
        case .active:
            return "active"
        case .inactive:
            return "inactive"
        case .background:
            return "background"
        @unknown default:
            return "unknownDefault"
        }
    }
}
