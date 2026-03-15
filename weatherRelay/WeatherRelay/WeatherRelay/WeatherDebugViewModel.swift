//
//  WeatherDebugViewModel.swift
//  WeatherRelay
//
//  Created by Codex on 2026-03-13.
//

import Foundation
import Combine

@MainActor
final class WeatherDebugViewModel: ObservableObject {
    static let fieldWidthOptionsMiles: [Int] = [10, 25, 50, 100, 240, 400]

    @Published var isLoading = false
    @Published var lastErrorMessage: String?
    @Published var latestFieldWeatherData: ThreeByThreeWeatherFieldDebugData?
    @Published var latestRegionalSnapshotPacketDebug: RegionalSnapshotPacketDebugData?
    @Published var latestPacketRevision = 0
    @Published private(set) var selectedFieldWidthMiles = Block1FieldGeometry.defaultFieldWidthMiles

    private let noaaClient: NOAAClient

    init(noaaClient: NOAAClient? = nil) {
        self.noaaClient = noaaClient ?? NOAAClient()
    }

    func setFieldWidthMiles(_ widthMiles: Int) {
        let normalizedWidth = Self.fieldWidthOptionsMiles.contains(widthMiles)
            ? widthMiles
            : Block1FieldGeometry.defaultFieldWidthMiles
        guard selectedFieldWidthMiles != normalizedWidth else {
            return
        }

        selectedFieldWidthMiles = normalizedWidth
        AppLogger.shared.log(category: "NOAA", message: "field width selected widthMi=\(normalizedWidth)")
    }

    func fetchWeather(for locationFix: LocationManager.LocationFix?) async {
        guard let locationFix else {
            lastErrorMessage = "No live location fix available"
            print("WeatherDebugViewModel: fetch skipped - no live location fix")
            AppLogger.shared.log(category: "NOAA", message: "fetch skipped - no live location fix")
            return
        }

        isLoading = true
        lastErrorMessage = nil

        print(
            """
            WeatherDebugViewModel: starting NOAA fetch \
            lat=\(locationFix.latitude) \
            lon=\(locationFix.longitude) \
            fieldWidthMi=\(selectedFieldWidthMiles) \
            accuracy=\(locationFix.horizontalAccuracy) \
            timestamp=\(Int(locationFix.timestamp.timeIntervalSince1970))
            """
        )
        AppLogger.shared.log(
            category: "NOAA",
            message: "starting 3x3 fetch lat=\(locationFix.latitude) lon=\(locationFix.longitude) widthMi=\(selectedFieldWidthMiles) accuracy=\(locationFix.horizontalAccuracy)"
        )

        let weatherData = await noaaClient.fetchThreeByThreeField(
            centerLatitude: locationFix.latitude,
            centerLongitude: locationFix.longitude,
            fieldWidthMiles: selectedFieldWidthMiles
        )
        latestFieldWeatherData = weatherData
        let packetDebug = RegionalSnapshotBuilder.makeRegionalSnapshotV1DebugData(field: weatherData)
        latestRegionalSnapshotPacketDebug = packetDebug
        latestPacketRevision += 1
        print(
            """
            WeatherDebugViewModel: NOAA 3x3 fetch completed \
            centerLat=\(weatherData.center.latitude) \
            centerLon=\(weatherData.center.longitude) \
            fieldWidthMi=\(Int(weatherData.fieldWidthMiles.rounded())) \
            anchors=\(weatherData.anchorResults.count) \
            packetRevision=\(latestPacketRevision)
            """
        )
        AppLogger.shared.log(
            category: "NOAA",
            message: "3x3 fetch completed centerLat=\(weatherData.center.latitude) centerLon=\(weatherData.center.longitude) widthMi=\(Int(weatherData.fieldWidthMiles.rounded())) anchors=\(weatherData.anchorResults.count)"
        )
        if packetDebug.isPacketLengthValid {
            print("WeatherDebugViewModel: RegionalSnapshotV1 packet length validated bytes=\(packetDebug.packetByteLength)")
            AppLogger.shared.log(category: "PACKET", message: "regional snapshot packet length validated bytes=\(packetDebug.packetByteLength)")
        } else {
            print("WeatherDebugViewModel: RegionalSnapshotV1 packet length invalid bytes=\(packetDebug.packetByteLength) expected=\(RegionalSnapshotBuilder.regionalSnapshotPacketSize)")
            AppLogger.shared.log(
                category: "PACKET",
                message: "regional snapshot packet length invalid bytes=\(packetDebug.packetByteLength) expected=\(RegionalSnapshotBuilder.regionalSnapshotPacketSize)"
            )
        }
        if weatherData.anchorResults.allSatisfy({ $0.weatherData == nil }) {
            lastErrorMessage = "All 9 NOAA anchor fetches failed"
        }

        isLoading = false
    }
}
