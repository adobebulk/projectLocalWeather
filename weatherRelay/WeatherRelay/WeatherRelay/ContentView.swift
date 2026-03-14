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

            if bleManager.didDiscoverService {
                Text("Service discovered")
                    .foregroundStyle(.secondary)
            }

            if bleManager.didDiscoverCharacteristics {
                Text("RX/TX characteristics discovered")
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }
}
