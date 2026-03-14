//
//  WeatherFieldModel.swift
//  WeatherRelay
//
//  Created by Codex on 2026-03-13.
//

import CoreLocation
import Foundation

struct Block1FieldGeometry {
    static let anchorSpacingMiles: Double = 120
    static let anchorSpacingMeters: Double = anchorSpacingMiles * 1_609.344
    static let fieldWidthMiles: Double = 240
    static let fieldHeightMiles: Double = 240
    static let fieldHalfWidthMeters: Double = (fieldWidthMiles * 1_609.344) / 2
    static let fieldHalfHeightMeters: Double = (fieldHeightMiles * 1_609.344) / 2

    static let rowMajorOffsets: [(row: Int, column: Int, northMultiplier: Double, eastMultiplier: Double)] = [
        (0, 0, 1, -1),
        (0, 1, 1, 0),
        (0, 2, 1, 1),
        (1, 0, 0, -1),
        (1, 1, 0, 0),
        (1, 2, 0, 1),
        (2, 0, -1, -1),
        (2, 1, -1, 0),
        (2, 2, -1, 1)
    ]

    static func makeAnchorCoordinates(center: WeatherFieldCenter) -> [WeatherFieldAnchorCoordinate] {
        rowMajorOffsets.map { offset in
            let coordinate = offsetCoordinate(
                latitude: center.latitude,
                longitude: center.longitude,
                northMeters: offset.northMultiplier * anchorSpacingMeters,
                eastMeters: offset.eastMultiplier * anchorSpacingMeters
            )

            return WeatherFieldAnchorCoordinate(
                row: offset.row,
                column: offset.column,
                latitude: coordinate.latitude,
                longitude: coordinate.longitude
            )
        }
    }

    static func fieldBoundaryCoordinates(center: WeatherFieldCenter) -> [CLLocationCoordinate2D] {
        [
            offsetCoordinate(
                latitude: center.latitude,
                longitude: center.longitude,
                northMeters: fieldHalfHeightMeters,
                eastMeters: -fieldHalfWidthMeters
            ),
            offsetCoordinate(
                latitude: center.latitude,
                longitude: center.longitude,
                northMeters: fieldHalfHeightMeters,
                eastMeters: fieldHalfWidthMeters
            ),
            offsetCoordinate(
                latitude: center.latitude,
                longitude: center.longitude,
                northMeters: -fieldHalfHeightMeters,
                eastMeters: fieldHalfWidthMeters
            ),
            offsetCoordinate(
                latitude: center.latitude,
                longitude: center.longitude,
                northMeters: -fieldHalfHeightMeters,
                eastMeters: -fieldHalfWidthMeters
            )
        ].map { coordinate in
            CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude)
        }
    }

    static func offsetCoordinate(
        latitude: Double,
        longitude: Double,
        northMeters: Double,
        eastMeters: Double
    ) -> (latitude: Double, longitude: Double) {
        let latitudeDelta = northMeters / 111_320
        let longitudeMetersPerDegree = max(1, 111_320 * cos(latitude * .pi / 180))
        let longitudeDelta = eastMeters / longitudeMetersPerDegree
        return (latitude + latitudeDelta, longitude + longitudeDelta)
    }
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
