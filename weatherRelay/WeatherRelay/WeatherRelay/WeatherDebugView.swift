//
//  WeatherDebugView.swift
//  WeatherRelay
//
//  Created by Codex on 2026-03-13.
//

import SwiftUI

struct WeatherDebugView: View {
    @ObservedObject var locationManager: LocationManager
    @StateObject private var viewModel = WeatherDebugViewModel()

    private var requestCoordinateText: String {
        guard let fix = locationManager.currentFix else {
            return "-"
        }

        return String(format: "%.5f, %.5f", fix.latitude, fix.longitude)
    }

    var body: some View {
        List {
            Section("Controls") {
                Text("Developer NOAA Debug")
                Text("Field center: \(requestCoordinateText)")
                Button(viewModel.isLoading ? "Fetching..." : "Fetch NOAA 3x3 Field") {
                    Task {
                        await viewModel.fetchWeather(for: locationManager.currentFix)
                    }
                }
                .disabled(viewModel.isLoading || locationManager.currentFix == nil)
            }

            Section("Request") {
                Text("Coordinate: \(requestCoordinateText)")
                Text("Location status: \(locationManager.statusText)")
                Text("Accuracy: \(accuracyText)")
                Text("Fix timestamp: \(fixTimestampText)")
            }

            if let fieldData = viewModel.latestFieldWeatherData {
                Section("3x3 Field Summary") {
                    Text("Center latitude: \(String(format: "%.5f", fieldData.center.latitude))")
                    Text("Center longitude: \(String(format: "%.5f", fieldData.center.longitude))")
                    Text("Field anchor unix: \(Int(fieldData.fieldAnchorDate.timeIntervalSince1970))")
                    Text("Anchor ordering: r0c0 r0c1 r0c2 r1c0 r1c1 r1c2 r2c0 r2c1 r2c2")
                    Text("Anchor spacing meters: \(Int(fieldData.geometrySpacingMeters))")
                    Text("Anchor spacing miles: \(Int(Block1FieldGeometry.anchorSpacingMiles))")
                    Text("Anchors fetched: \(fieldData.anchorResults.count)")
                }

                ForEach(fieldData.anchorResults) { anchorResult in
                    Section("Anchor \(anchorResult.anchor.label)") {
                        Text("Coordinate: \(String(format: "%.5f, %.5f", anchorResult.anchor.latitude, anchorResult.anchor.longitude))")

                        if let weatherData = anchorResult.weatherData {
                            Text("CWA: \(weatherData.pointInfo.cwa)")
                            Text("Grid ID: \(weatherData.pointInfo.gridId)")
                            Text("Grid X: \(weatherData.pointInfo.gridX)")
                            Text("Grid Y: \(weatherData.pointInfo.gridY)")
                            Text("forecastGridData: \(weatherData.pointInfo.forecastGridDataURL.absoluteString)")
                            Text("Fetched at: \(Int((anchorResult.fetchedAt ?? weatherData.fetchedAt).timeIntervalSince1970))")
                            Text("Weather Summary: \(weatherData.snapshot.weatherSummary ?? "-")")
                            Text("Hazard Summary: \(weatherData.snapshot.hazardSummary ?? "-")")
                            Text("Slot anchor unix: \(Int(weatherData.threeSlotModel.anchorDate.timeIntervalSince1970))")

                            ForEach(weatherData.threeSlotModel.slots) { slot in
                                Text("Slot +\(slot.offsetMinutes)m tempC=\(formattedDouble(slot.temperatureC)) windKmh=\(formattedDouble(slot.windSpeedKmh)) gustKmh=\(formattedDouble(slot.windGustKmh)) pop=\(formattedDouble(slot.precipitationProbabilityPercent)) visM=\(formattedDouble(slot.visibilityMeters))")
                                Text("Temp rule: \(slot.temperatureSelectionNote)")
                                Text("Wind rule: \(slot.windSpeedSelectionNote)")
                                Text("Gust rule: \(slot.windGustSelectionNote)")
                                Text("PoP rule: \(slot.precipitationSelectionNote)")
                                Text("Vis rule: \(slot.visibilitySelectionNote)")
                            }
                        } else {
                            Text("Fetch error: \(anchorResult.errorMessage ?? "Unknown error")")
                        }
                    }
                }
            }

            if let lastErrorMessage = viewModel.lastErrorMessage {
                Section("Last Error") {
                    Text(lastErrorMessage)
                }
            }
        }
        .navigationTitle("Weather Debug")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            print("WeatherDebugView: appeared hasLocationFix=\(locationManager.currentFix != nil)")
        }
    }

    private var accuracyText: String {
        guard let accuracy = locationManager.latestHorizontalAccuracy else {
            return "-"
        }

        return String(format: "%.1f m", accuracy)
    }

    private var fixTimestampText: String {
        guard let timestamp = locationManager.latestTimestamp else {
            return "-"
        }

        return String(Int(timestamp.timeIntervalSince1970))
    }
    private func formattedDouble(_ value: Double?) -> String {
        guard let value else {
            return "-"
        }

        return String(format: "%.2f", value)
    }
}
