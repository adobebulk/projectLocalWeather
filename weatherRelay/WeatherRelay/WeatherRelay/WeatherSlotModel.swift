//
//  WeatherSlotModel.swift
//  WeatherRelay
//
//  Created by Codex on 2026-03-13.
//

import Foundation

struct OnePointThreeSlotWeatherModel {
    let anchorDate: Date
    let slotDurationMinutes: Int
    let slots: [OnePointWeatherSlot]
}

struct OnePointWeatherSlot: Identifiable {
    let offsetMinutes: Int
    let startDate: Date
    let endDate: Date
    let temperatureC: Double?
    let windSpeedKmh: Double?
    let windGustKmh: Double?
    let precipitationProbabilityPercent: Double?
    let visibilityMeters: Double?
    let temperatureSelectionNote: String
    let windSpeedSelectionNote: String
    let windGustSelectionNote: String
    let precipitationSelectionNote: String
    let visibilitySelectionNote: String

    var id: Int { offsetMinutes }
}
