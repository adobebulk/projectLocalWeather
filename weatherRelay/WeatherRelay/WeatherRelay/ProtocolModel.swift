//
//  ProtocolModel.swift
//  WeatherRelay
//
//  Created by Codex on 2026-03-13.
//

import Foundation

enum PacketType: UInt8 {
    case weatherSnapshot = 1
    case positionUpdate = 2
    case ack = 3
    case displayControl = 4
}

enum AckStatus: UInt8, CustomStringConvertible {
    case ok = 0
    case badCrc = 1
    case badLength = 2
    case unsupportedPacket = 3
    case internalError = 4

    var description: String {
        switch self {
        case .ok:
            return "ok"
        case .badCrc:
            return "badCrc"
        case .badLength:
            return "badLength"
        case .unsupportedPacket:
            return "unsupportedPacket"
        case .internalError:
            return "internalError"
        }
    }
}

struct AckV1 {
    let sequence: UInt32
    let status: AckStatus
    let weatherTimestamp: UInt32
    let positionTimestamp: UInt32
}

enum PrecipitationKind: UInt8, CustomStringConvertible {
    case noneOrUnknown = 0
    case rain = 1
    case snow = 2
    case ice = 3
    case mixed = 4

    var description: String {
        switch self {
        case .noneOrUnknown:
            return "noneOrUnknown"
        case .rain:
            return "rain"
        case .snow:
            return "snow"
        case .ice:
            return "ice"
        case .mixed:
            return "mixed"
        }
    }
}

enum PrecipitationIntensity: UInt8, CustomStringConvertible {
    case noneOrUnknown = 0
    case light = 1
    case moderate = 2
    case heavy = 3

    var description: String {
        switch self {
        case .noneOrUnknown:
            return "noneOrUnknown"
        case .light:
            return "light"
        case .moderate:
            return "moderate"
        case .heavy:
            return "heavy"
        }
    }
}

struct HazardFlags: OptionSet, CustomStringConvertible {
    let rawValue: UInt16

    static let thunderRisk = HazardFlags(rawValue: 1 << 0)
    static let severeThunderstormRisk = HazardFlags(rawValue: 1 << 1)
    static let winterPrecipitationRisk = HazardFlags(rawValue: 1 << 2)
    static let strongWindRisk = HazardFlags(rawValue: 1 << 3)
    static let lowVisibilityRisk = HazardFlags(rawValue: 1 << 4)
    static let freezingSurfaceRisk = HazardFlags(rawValue: 1 << 5)

    var description: String {
        if isEmpty {
            return "none"
        }

        var parts: [String] = []
        if contains(.thunderRisk) { parts.append("thunderRisk") }
        if contains(.severeThunderstormRisk) { parts.append("severeThunderstormRisk") }
        if contains(.winterPrecipitationRisk) { parts.append("winterPrecipitationRisk") }
        if contains(.strongWindRisk) { parts.append("strongWindRisk") }
        if contains(.lowVisibilityRisk) { parts.append("lowVisibilityRisk") }
        if contains(.freezingSurfaceRisk) { parts.append("freezingSurfaceRisk") }
        return parts.joined(separator: ",")
    }
}
