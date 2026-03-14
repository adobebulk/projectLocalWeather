//
//  ContentView.swift
//  WeatherRelay
//
//  Created by Clayton Smith on 2026-03-13.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var bleManager = BLEManager()

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

            Button("Send Test Payload") {
                bleManager.sendTestPayload()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!bleManager.didDiscoverCharacteristics)

            Button("Send Position Packet") {
                bleManager.sendPositionPacket()
            }
            .buttonStyle(.bordered)
            .disabled(!bleManager.didDiscoverCharacteristics)
        }
        .padding()
    }
}
