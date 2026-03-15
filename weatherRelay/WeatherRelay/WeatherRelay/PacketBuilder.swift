//
//  PacketBuilder.swift
//  WeatherRelay
//
//  Created by Codex on 2026-03-13.
//

import Foundation

enum PacketBuilder {
    static let magic: UInt16 = 0x5743
    static let version: UInt8 = 1
    static let headerSize = 18
    static let positionPacketSize = 32
    static let ackPacketSize = 32
    static let crcOffset = 14

    struct PositionValues {
        let sequence: UInt32
        let timestampUnix: UInt32
        let latE5: Int32
        let lonE5: Int32
        let accuracyM: UInt16
        let fixTimestampUnix: UInt32
    }

    enum DisplayControlCommand: UInt8 {
        case off = 0
        case on = 1
    }

    static func makePositionUpdateV1(values: PositionValues) -> Data {
        var packet = Data()
        packet.reserveCapacity(positionPacketSize)

        packet.appendLittleEndian(magic)
        packet.append(version)
        packet.append(PacketType.positionUpdate.rawValue)
        packet.appendLittleEndian(UInt16(positionPacketSize))
        packet.appendLittleEndian(values.sequence)
        packet.appendLittleEndian(values.timestampUnix)
        packet.appendLittleEndian(UInt32(0))
        packet.appendLittleEndian(values.latE5)
        packet.appendLittleEndian(values.lonE5)
        packet.appendLittleEndian(values.accuracyM)
        packet.appendLittleEndian(values.fixTimestampUnix)

        let crc = crc32(packet)
        packet.replaceSubrange(crcOffset..<(crcOffset + 4), with: crc.littleEndianBytes)
        return packet
    }

    static func crc32(_ packet: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF

        for (offset, byte) in packet.enumerated() {
            let dataByte: UInt8 = (crcOffset..<(crcOffset + 4)).contains(offset) ? 0 : byte
            crc = crc32Update(crc: crc, dataByte: dataByte)
        }

        return crc ^ 0xFFFF_FFFF
    }

    private static func crc32Update(crc: UInt32, dataByte: UInt8) -> UInt32 {
        var updated = crc ^ UInt32(dataByte)

        for _ in 0..<8 {
            if (updated & 1) != 0 {
                updated = (updated >> 1) ^ 0xEDB8_8320
            } else {
                updated >>= 1
            }
        }

        return updated
    }

    static func makeDisplayControlV1(command: DisplayControlCommand) -> Data {
        var packet = Data()
        packet.reserveCapacity(2)
        packet.append(PacketType.displayControl.rawValue)
        packet.append(command.rawValue)
        return packet
    }
}

private extension Data {
    mutating func appendLittleEndian(_ value: UInt16) {
        var littleEndianValue = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndianValue) { bytes in
            append(contentsOf: bytes)
        }
    }

    mutating func appendLittleEndian(_ value: UInt32) {
        var littleEndianValue = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndianValue) { bytes in
            append(contentsOf: bytes)
        }
    }

    mutating func appendLittleEndian(_ value: Int32) {
        appendLittleEndian(UInt32(bitPattern: value))
    }
}

private extension UInt32 {
    var littleEndianBytes: [UInt8] {
        let value = littleEndian
        return [
            UInt8((value >> 0) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF),
        ]
    }
}
