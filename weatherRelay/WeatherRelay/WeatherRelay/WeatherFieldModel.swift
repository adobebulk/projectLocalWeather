//
//  WeatherFieldModel.swift
//  WeatherRelay
//
//  Created by Codex on 2026-03-13.
//

import Foundation

struct Block1FieldGeometry {
    static let anchorSpacingMiles: Double = 120
    static let anchorSpacingMeters: Double = anchorSpacingMiles * 1_609.344
}

struct WeatherFieldCenter {
    let latitude: Double
    let longitude: Double
}

struct WeatherFieldAnchorCoordinate: Identifiable {
    let row: Int
    let column: Int
    let latitude: Double
    let longitude: Double

    nonisolated var id: String { "\(row)-\(column)" }
    nonisolated var label: String { "r\(row)c\(column)" }
}

struct WeatherFieldAnchorResult: Identifiable {
    let anchor: WeatherFieldAnchorCoordinate
    let fetchedAt: Date?
    let weatherData: NOAAOnePointWeatherDebugData?
    let errorMessage: String?

    nonisolated var id: String { anchor.id }
}

struct ThreeByThreeWeatherFieldDebugData {
    let center: WeatherFieldCenter
    let geometrySpacingMeters: Double
    let fieldAnchorDate: Date
    let anchorResults: [WeatherFieldAnchorResult]
}
