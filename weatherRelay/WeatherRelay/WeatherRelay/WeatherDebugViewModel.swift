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
    @Published var latestWeatherData: NOAAOnePointWeatherDebugData?

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

        do {
            let weatherData = try await noaaClient.fetchOnePointWeather(
                latitude: locationFix.latitude,
                longitude: locationFix.longitude
            )
            latestWeatherData = weatherData
            print(
                """
                WeatherDebugViewModel: NOAA fetch completed \
                fetchedAtUnix=\(Int(weatherData.fetchedAt.timeIntervalSince1970)) \
                gridId=\(weatherData.pointInfo.gridId) \
                gridX=\(weatherData.pointInfo.gridX) \
                gridY=\(weatherData.pointInfo.gridY)
                """
            )
        } catch {
            lastErrorMessage = error.localizedDescription
            print("WeatherDebugViewModel: NOAA fetch failed error=\(error.localizedDescription)")
        }

        isLoading = false
    }
}
