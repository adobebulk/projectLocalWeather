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
    @Published var isLoading = false
    @Published var lastErrorMessage: String?
    @Published var latestFieldWeatherData: ThreeByThreeWeatherFieldDebugData?

    private let noaaClient: NOAAClient

    init(noaaClient: NOAAClient? = nil) {
        self.noaaClient = noaaClient ?? NOAAClient()
    }

    func fetchWeather(for locationFix: LocationManager.LocationFix?) async {
        guard let locationFix else {
            lastErrorMessage = "No live location fix available"
            print("WeatherDebugViewModel: fetch skipped - no live location fix")
            return
        }

        isLoading = true
        lastErrorMessage = nil

        print(
            """
            WeatherDebugViewModel: starting NOAA fetch \
            lat=\(locationFix.latitude) \
            lon=\(locationFix.longitude) \
            accuracy=\(locationFix.horizontalAccuracy) \
            timestamp=\(Int(locationFix.timestamp.timeIntervalSince1970))
            """
        )

        let weatherData = await noaaClient.fetchThreeByThreeField(
            centerLatitude: locationFix.latitude,
            centerLongitude: locationFix.longitude
        )
        latestFieldWeatherData = weatherData
        print(
            """
            WeatherDebugViewModel: NOAA 3x3 fetch completed \
            centerLat=\(weatherData.center.latitude) \
            centerLon=\(weatherData.center.longitude) \
            anchors=\(weatherData.anchorResults.count)
            """
        )
        if weatherData.anchorResults.allSatisfy({ $0.weatherData == nil }) {
            lastErrorMessage = "All 9 NOAA anchor fetches failed"
        }

        isLoading = false
    }
}
