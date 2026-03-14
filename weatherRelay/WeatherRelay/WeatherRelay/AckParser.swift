//
//  AckParser.swift
//  WeatherRelay
//
//  Created by Codex on 2026-03-13.
//

import Foundation

enum AckParser {
    enum ParseError: LocalizedError {
        case badLength
        case badMagic
        case badVersion
        case badPacketType
        case badCRC
        case unknownAckStatus

        var errorDescription: String? {
            switch self {
            case .badLength:
                return "bad length"
            case .badMagic:
                return "bad magic"
            case .badVersion:
                return "bad version"
            case .badPacketType:
                return "bad packet type"
            case .badCRC:
                return "bad crc"
            case .unknownAckStatus:
                return "unknown ack status"
            }
        }
    }

    static func parse(_ data: Data) throws -> AckV1 {
        guard data.count == PacketBuilder.ackPacketSize else {
            throw ParseError.badLength
        }

        guard readU16(data, at: 0) == PacketBuilder.magic else {
            throw ParseError.badMagic
        }

        guard data[2] == PacketBuilder.version else {
            throw ParseError.badVersion
        }

        guard data[3] == PacketType.ack.rawValue else {
            throw ParseError.badPacketType
        }

        guard readU16(data, at: 4) == UInt16(PacketBuilder.ackPacketSize) else {
            throw ParseError.badLength
        }

        let expectedCRC = readU32(data, at: PacketBuilder.crcOffset)
        let computedCRC = PacketBuilder.crc32(data)
        guard expectedCRC == computedCRC else {
            throw ParseError.badCRC
        }

        let rawStatus = data[PacketBuilder.headerSize + 4]
        guard let status = AckStatus(rawValue: rawStatus) else {
            throw ParseError.unknownAckStatus
        }

        return AckV1(
            sequence: readU32(data, at: PacketBuilder.headerSize + 0),
            status: status,
            weatherTimestamp: readU32(data, at: PacketBuilder.headerSize + 5),
            positionTimestamp: readU32(data, at: PacketBuilder.headerSize + 9)
        )
    }

    private static func readU16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readU32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset]) |
        (UInt32(data[offset + 1]) << 8) |
        (UInt32(data[offset + 2]) << 16) |
        (UInt32(data[offset + 3]) << 24)
    }
}
