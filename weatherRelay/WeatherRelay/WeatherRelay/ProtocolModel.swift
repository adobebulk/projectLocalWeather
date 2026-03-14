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
