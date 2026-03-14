//
//  WeatherDebugView.swift
//  WeatherRelay
//
//  Created by Codex on 2026-03-13.
//

import SwiftUI
import UIKit

struct WeatherDebugView: View {
    @ObservedObject var locationManager: LocationManager
    @ObservedObject var bleManager: BLEManager
    @ObservedObject var viewModel: WeatherDebugViewModel
    @State private var shareItems: [Any] = []
    @State private var isShowingShareSheet = false

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

                Button("Send PositionUpdateV1") {
                    bleManager.sendPositionPacket(locationFix: locationManager.currentFix)
                    AppLogger.shared.log(category: "BLE", message: "manual position packet send requested")
                }
                .disabled(!bleManager.didDiscoverCharacteristics || !locationManager.hasValidLocation)

                Button("Send RegionalSnapshotV1") {
                    if let packetDebug = viewModel.latestRegionalSnapshotPacketDebug {
                        if packetDebug.isPacketLengthValid {
                            bleManager.sendLatestRegionalSnapshotV1Debug()
                            AppLogger.shared.log(
                                category: "BLE",
                                message: "manual weather packet send requested size=\(packetDebug.packetByteLength)"
                            )
                        } else {
                            print("WeatherDebugView: RegionalSnapshotV1 send blocked packetLength=\(packetDebug.packetByteLength) expected=\(RegionalSnapshotBuilder.regionalSnapshotPacketSize)")
                            AppLogger.shared.log(
                                category: "DEBUG",
                                message: "manual weather packet send blocked packetLength=\(packetDebug.packetByteLength)"
                            )
                        }
                    }
                }
                .disabled(!bleManager.didDiscoverCharacteristics || viewModel.latestRegionalSnapshotPacketDebug?.isPacketLengthValid != true)

                Button("Share Log") {
                    let logURL = AppLogger.shared.currentLogFileURL()
                    AppLogger.shared.log(category: "DEBUG", message: "share log requested path=\(logURL.path)")
                    shareItems = [logURL]
                    isShowingShareSheet = true
                }

                Button("Copy Log") {
                    let logText = AppLogger.shared.readCurrentLog()
                    UIPasteboard.general.string = logText
                    AppLogger.shared.log(
                        category: "DEBUG",
                        message: "copy log requested bytes=\(logText.utf8.count)"
                    )
                }

                Button("Clear Log") {
                    AppLogger.shared.clearLogs()
                    AppLogger.shared.log(category: "DEBUG", message: "clear log requested")
                }
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
                            Text("Forecast-grid visibility meters: \(formattedDouble(weatherData.snapshot.visibilityMeters))")
                            Text("Forecast-grid visibility validTime: \(weatherData.forecastGridVisibilityValidTime ?? "-")")
                            Text("Forecast-grid visibility usable: \(weatherData.forecastGridVisibilityIsUsable ? "Yes" : "No")")
                            if let observationVisibility = weatherData.observationVisibility {
                                Text("Observation station: \(observationVisibility.stationIdentifier) \(observationVisibility.stationName ?? "")")
                                Text("Observation timestamp: \(observationVisibility.observationTimestamp.map { String(Int($0.timeIntervalSince1970)) } ?? "-")")
                                Text("Observation raw visibility: \(formattedDouble(observationVisibility.rawVisibilityValue)) \(observationVisibility.rawVisibilityUnitCode ?? "-")")
                                Text("Observation raw source path: \(observationVisibility.rawSourcePath)")
                                Text("Observation raw source object: \(observationVisibility.rawSourceObjectDescription)")
                                Text("Observation visibility meters: \(formattedDouble(observationVisibility.normalizedVisibilityMeters))")
                                Text("Observation visibility miles: \(formattedMiles(observationVisibility.normalizedVisibilityMeters))")
                                Text("Observation age minutes: \(observationVisibility.observationAgeMinutes.map(String.init) ?? "-")")
                                Text("Observation visibility usable: \(observationVisibility.isUsable ? "Yes" : "No")")
                                Text("Observation station URL: \(observationVisibility.stationURL.absoluteString)")
                                Text("Latest observation URL: \(observationVisibility.latestObservationURL.absoluteString)")
                            } else {
                                Text("Observation visibility: -")
                            }
                            Text("recommendedVisibilitySourceForBlock1: \(weatherData.recommendedVisibilitySourceForBlock1.rawValue)")
                            Text("Visibility comparison note: \(weatherData.visibilityComparisonNote)")
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

            if let packetDebug = viewModel.latestRegionalSnapshotPacketDebug {
                Section("RegionalSnapshotV1 Packet") {
                    Text("Sequence: \(packetDebug.sequence)")
                    Text("Field anchor unix: \(packetDebug.fieldAnchorTimestampUnix)")
                    Text("Field generation unix: \(packetDebug.fieldGenerationTimestampUnix)")
                    Text("Center lat_e5: \(packetDebug.centerLatE5)")
                    Text("Center lon_e5: \(packetDebug.centerLonE5)")
                    Text("Field width mi: \(packetDebug.fieldWidthMi)")
                    Text("Field height mi: \(packetDebug.fieldHeightMi)")
                    Text("Grid rows: \(packetDebug.gridRows)")
                    Text("Grid cols: \(packetDebug.gridCols)")
                    Text("Slot count: \(packetDebug.slotCount)")
                    Text("Reserved0: \(packetDebug.reserved0)")
                    Text("Forecast horizon min: \(packetDebug.forecastHorizonMin)")
                    Text("Source age min: \(packetDebug.sourceAgeMin)")
                    Text("Packet byte length: \(packetDebug.packetByteLength)")
                    Text("Packet length valid: \(packetDebug.isPacketLengthValid ? "Yes" : "No")")
                    Text("Packet hex preview: \(packetDebug.packetHexPreview)")
                }

                Section("RegionalSnapshotV1 Layout") {
                    ForEach(packetDebug.layoutLogLines, id: \.self) { line in
                        Text(line)
                    }
                }

                ForEach(packetDebug.anchors) { anchor in
                    Section("Packet Anchor \(anchor.anchorLabel)") {
                        Text("Coordinate: \(anchor.anchorCoordinateText)")

                        ForEach(anchor.slots) { slot in
                            Text("Slot +\(slot.offsetMinutes)m slotOffsetMin=\(slot.slotOffsetMin) airTempCTenths=\(slot.temperatureDeciC) windSpeedMpsTenths=\(slot.windSpeedMpsTenths) windGustMpsTenths=\(slot.windGustMpsTenths) precipProbPct=\(slot.precipitationProbabilityPercent) precipKind=\(slot.precipitationKind.description) precipIntensity=\(slot.precipitationIntensity.description) reserved0=\(slot.reserved0) visibilitySource=\(slot.visibilitySource) visibilitySourceMeters=\(formattedDouble(slot.visibilitySourceMeters)) visibilityM=\(slot.visibilityM) hazardFlags=\(slot.hazardFlags.description)")
                            ForEach(slot.quantizationNotes, id: \.self) { note in
                                Text("Note: \(note)")
                            }
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
            AppLogger.shared.log(
                category: "DEBUG",
                message: "weather debug view appeared hasLocationFix=\(locationManager.currentFix != nil)"
            )
        }
        .sheet(isPresented: $isShowingShareSheet) {
            ActivityViewController(activityItems: shareItems)
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

    private func formattedMiles(_ meters: Double?) -> String {
        guard let meters else {
            return "-"
        }

        return String(format: "%.2f", meters / 1_609.344)
    }
}

private struct ActivityViewController: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
