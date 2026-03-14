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
                Text("Current fix: \(requestCoordinateText)")
                Button(viewModel.isLoading ? "Fetching..." : "Fetch NOAA Weather") {
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

            if let weatherData = viewModel.latestWeatherData {
                Section("NOAA Point Resolution") {
                    Text("CWA: \(weatherData.pointInfo.cwa)")
                    Text("Grid ID: \(weatherData.pointInfo.gridId)")
                    Text("Grid X: \(weatherData.pointInfo.gridX)")
                    Text("Grid Y: \(weatherData.pointInfo.gridY)")
                    Text("forecastGridData: \(weatherData.pointInfo.forecastGridDataURL.absoluteString)")
                    Text("Fetched at: \(Int(weatherData.fetchedAt.timeIntervalSince1970))")
                }

                Section("Selected Raw NOAA Values") {
                    rawQuantitativeRow(title: "Temperature", value: weatherData.rawTemperature)
                    rawQuantitativeRow(title: "Wind Speed", value: weatherData.rawWindSpeed)
                    rawQuantitativeRow(title: "Wind Gust", value: weatherData.rawWindGust)
                    rawQuantitativeRow(title: "PoP", value: weatherData.rawProbabilityOfPrecipitation)
                    rawQuantitativeRow(title: "Visibility", value: weatherData.rawVisibility)
                    rawTextRow(title: "Weather", value: weatherData.rawWeather)
                    rawTextRow(title: "Hazards", value: weatherData.rawHazards)
                }

                Section("Normalized Snapshot") {
                    Text("Temperature C: \(formattedDouble(weatherData.snapshot.temperatureC))")
                    Text("Wind Speed km/h: \(formattedDouble(weatherData.snapshot.windSpeedKmh))")
                    Text("Wind Gust km/h: \(formattedDouble(weatherData.snapshot.windGustKmh))")
                    Text("Precip %: \(formattedDouble(weatherData.snapshot.precipitationProbabilityPercent))")
                    Text("Visibility m: \(formattedDouble(weatherData.snapshot.visibilityMeters))")
                    Text("Weather Summary: \(weatherData.snapshot.weatherSummary ?? "-")")
                    Text("Hazard Summary: \(weatherData.snapshot.hazardSummary ?? "-")")
                }

                Section("Derived 3-Slot Model") {
                    Text("Anchor Unix: \(Int(weatherData.threeSlotModel.anchorDate.timeIntervalSince1970))")
                    Text("Slot duration minutes: \(weatherData.threeSlotModel.slotDurationMinutes)")
                }

                ForEach(weatherData.threeSlotModel.slots) { slot in
                    Section("Slot +\(slot.offsetMinutes) min") {
                        Text("Start Unix: \(Int(slot.startDate.timeIntervalSince1970))")
                        Text("End Unix: \(Int(slot.endDate.timeIntervalSince1970))")
                        Text("Temperature C: \(formattedDouble(slot.temperatureC))")
                        Text("Temperature rule: \(slot.temperatureSelectionNote)")
                        Text("Wind Speed km/h: \(formattedDouble(slot.windSpeedKmh))")
                        Text("Wind Speed rule: \(slot.windSpeedSelectionNote)")
                        Text("Wind Gust km/h: \(formattedDouble(slot.windGustKmh))")
                        Text("Wind Gust rule: \(slot.windGustSelectionNote)")
                        Text("Precip %: \(formattedDouble(slot.precipitationProbabilityPercent))")
                        Text("Precip rule: \(slot.precipitationSelectionNote)")
                        Text("Visibility m: \(formattedDouble(slot.visibilityMeters))")
                        Text("Visibility rule: \(slot.visibilitySelectionNote)")
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

    @ViewBuilder
    private func rawQuantitativeRow(title: String, value: NOAASelectedQuantitativeValue?) -> some View {
        if let value {
            Text("\(title): value=\(formattedDouble(value.value)) unit=\(value.unitCode ?? "-") validTime=\(value.validTime)")
        } else {
            Text("\(title): -")
        }
    }

    @ViewBuilder
    private func rawTextRow(title: String, value: NOAASelectedTextValue?) -> some View {
        if let value {
            Text("\(title): \(value.summary) validTime=\(value.validTime)")
        } else {
            Text("\(title): -")
        }
    }

    private func formattedDouble(_ value: Double?) -> String {
        guard let value else {
            return "-"
        }

        return String(format: "%.2f", value)
    }
}
