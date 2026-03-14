//
//  RegionalSnapshotBuilder.swift
//  WeatherRelay
//
//  Created by Codex on 2026-03-13.
//

import Foundation

struct RegionalSnapshotPacketDebugData {
    let sequence: UInt32
    let packet: Data
    let fieldAnchorTimestampUnix: UInt32
    let fieldGenerationTimestampUnix: UInt32
    let centerLatE5: Int32
    let centerLonE5: Int32
    let fieldWidthMi: UInt16
    let fieldHeightMi: UInt16
    let gridRows: UInt8
    let gridCols: UInt8
    let slotCount: UInt8
    let reserved0: UInt8
    let forecastHorizonMin: UInt16
    let sourceAgeMin: UInt16
    let anchors: [RegionalSnapshotAnchorPacketDebug]
    let layoutLogLines: [String]

    var packetByteLength: Int { packet.count }
    var isPacketLengthValid: Bool { packet.count == RegionalSnapshotBuilder.regionalSnapshotPacketSize }
    var packetHexPreview: String {
        packet.prefix(96).map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}

struct RegionalSnapshotAnchorPacketDebug: Identifiable {
    let anchorLabel: String
    let anchorCoordinateText: String
    let slots: [RegionalSnapshotSlotPacketDebug]

    var id: String { anchorLabel }
}

struct RegionalSnapshotSlotPacketDebug: Identifiable {
    let offsetMinutes: Int
    let slotOffsetMin: UInt16
    let temperatureDeciC: Int16
    let windSpeedMpsTenths: UInt16
    let windGustMpsTenths: UInt16
    let precipitationProbabilityPercent: UInt8
    let precipitationKind: PrecipitationKind
    let precipitationIntensity: PrecipitationIntensity
    let reserved0: UInt8
    let visibilitySource: String
    let visibilitySourceMeters: Double?
    let visibilityM: UInt16
    let hazardFlags: HazardFlags
    let quantizationNotes: [String]

    var id: Int { offsetMinutes }
}

enum RegionalSnapshotBuilder {
    static let regionalSnapshotPacketSize = 470
    private static let payloadHeaderSize = 20
    private static let anchorCount = 9
    private static let slotCount = 3
    private static let bytesPerAnchorSlot = 16
    private static let fieldWidthMi: UInt16 = 240
    private static let fieldHeightMi: UInt16 = 240
    private static let gridRows: UInt8 = 3
    private static let gridCols: UInt8 = 3
    private static let reserved0: UInt8 = 0
    private static let forecastHorizonMin: UInt16 = 120

    private enum PacketVisibilitySource: String {
        case forecastGrid
        case observation
        case none
    }

    static func makeRegionalSnapshotV1DebugData(
        field: ThreeByThreeWeatherFieldDebugData,
        sequence: UInt32 = 1
    ) -> RegionalSnapshotPacketDebugData {
        let orderedAnchors = orderedAnchorResults(from: field)
        let fieldAnchorTimestampUnix = UInt32(max(0, field.fieldAnchorDate.timeIntervalSince1970.rounded()))
        let fieldGenerationDate = Date()
        let fieldGenerationTimestampUnix = UInt32(max(0, fieldGenerationDate.timeIntervalSince1970.rounded()))
        let sourceAgeMin = quantizeSourceAgeMinutes(referenceDate: fieldGenerationDate, anchors: orderedAnchors)
        let centerLatE5 = Int32((field.center.latitude * 100_000).rounded())
        let centerLonE5 = Int32((field.center.longitude * 100_000).rounded())
        let expectedPacketSize = PacketBuilder.headerSize + payloadHeaderSize + (anchorCount * slotCount * bytesPerAnchorSlot)
        let layoutLogLines = packetLayoutLogLines()

        if expectedPacketSize != regionalSnapshotPacketSize {
            print("RegionalSnapshotBuilder: layout constant mismatch computed=\(expectedPacketSize) expected=\(regionalSnapshotPacketSize)")
        }

        var packet = Data()
        packet.reserveCapacity(regionalSnapshotPacketSize)
        packet.appendLittleEndian(PacketBuilder.magic)
        packet.append(PacketBuilder.version)
        packet.append(PacketType.weatherSnapshot.rawValue)
        packet.appendLittleEndian(UInt16(regionalSnapshotPacketSize))
        packet.appendLittleEndian(sequence)
        packet.appendLittleEndian(fieldGenerationTimestampUnix)
        packet.appendLittleEndian(UInt32(0))

        packet.appendLittleEndian(centerLatE5)
        packet.appendLittleEndian(centerLonE5)
        packet.appendLittleEndian(fieldWidthMi)
        packet.appendLittleEndian(fieldHeightMi)
        packet.append(gridRows)
        packet.append(gridCols)
        packet.append(UInt8(slotCount))
        packet.append(reserved0)
        packet.appendLittleEndian(forecastHorizonMin)
        packet.appendLittleEndian(sourceAgeMin)

        let packetAnchors = orderedAnchors.map { anchorResult in
            makeAnchorPacketDebug(anchorResult: anchorResult, into: &packet)
        }

        if packet.count != regionalSnapshotPacketSize {
            print("RegionalSnapshotBuilder: packet size mismatch actual=\(packet.count) expected=\(regionalSnapshotPacketSize)")
        }

        let crc = PacketBuilder.crc32(packet)
        packet.replaceSubrange(PacketBuilder.crcOffset..<(PacketBuilder.crcOffset + 4), with: crc.littleEndianBytes)

        for line in layoutLogLines {
            print(line)
        }

        print(
            """
            RegionalSnapshotBuilder: built RegionalSnapshotV1 \
            sequence=\(sequence) \
            fieldAnchorUnix=\(fieldAnchorTimestampUnix) \
            fieldGenerationUnix=\(fieldGenerationTimestampUnix) \
            centerLatE5=\(centerLatE5) \
            centerLonE5=\(centerLonE5) \
            fieldWidthMi=\(fieldWidthMi) \
            fieldHeightMi=\(fieldHeightMi) \
            gridRows=\(gridRows) \
            gridCols=\(gridCols) \
            slotCount=\(slotCount) \
            forecastHorizonMin=\(forecastHorizonMin) \
            sourceAgeMin=\(sourceAgeMin) \
            bytes=\(packet.count) \
            expectedBytes=\(regionalSnapshotPacketSize) \
            hexPreview=\(packet.prefix(48).map { String(format: "%02X", $0) }.joined(separator: " "))
            """
        )
        AppLogger.shared.log(
            category: "PACKET",
            message: "regional snapshot built sequence=\(sequence) bytes=\(packet.count) sourceAgeMin=\(sourceAgeMin)"
        )

        return RegionalSnapshotPacketDebugData(
            sequence: sequence,
            packet: packet,
            fieldAnchorTimestampUnix: fieldAnchorTimestampUnix,
            fieldGenerationTimestampUnix: fieldGenerationTimestampUnix,
            centerLatE5: centerLatE5,
            centerLonE5: centerLonE5,
            fieldWidthMi: fieldWidthMi,
            fieldHeightMi: fieldHeightMi,
            gridRows: gridRows,
            gridCols: gridCols,
            slotCount: UInt8(slotCount),
            reserved0: reserved0,
            forecastHorizonMin: forecastHorizonMin,
            sourceAgeMin: sourceAgeMin,
            anchors: packetAnchors,
            layoutLogLines: layoutLogLines
        )
    }

    private static func packetLayoutLogLines() -> [String] {
        [
            "RegionalSnapshotBuilder: layout header offsets=0..17 size=18",
            "RegionalSnapshotBuilder: layout metadata field_center_lat_e5 offsets=18..21 size=4",
            "RegionalSnapshotBuilder: layout metadata field_center_lon_e5 offsets=22..25 size=4",
            "RegionalSnapshotBuilder: layout metadata field_width_mi offsets=26..27 size=2",
            "RegionalSnapshotBuilder: layout metadata field_height_mi offsets=28..29 size=2",
            "RegionalSnapshotBuilder: layout metadata grid_rows offsets=30..30 size=1",
            "RegionalSnapshotBuilder: layout metadata grid_cols offsets=31..31 size=1",
            "RegionalSnapshotBuilder: layout metadata slot_count offsets=32..32 size=1",
            "RegionalSnapshotBuilder: layout metadata reserved0 offsets=33..33 size=1",
            "RegionalSnapshotBuilder: layout metadata forecast_horizon_min offsets=34..35 size=2",
            "RegionalSnapshotBuilder: layout metadata source_age_min offsets=36..37 size=2",
            "RegionalSnapshotBuilder: layout cells offsets=38..469 size=432",
            "RegionalSnapshotBuilder: cell layout slot_offset_min offsets=0..1 size=2",
            "RegionalSnapshotBuilder: cell layout air_temp_c_tenths offsets=2..3 size=2",
            "RegionalSnapshotBuilder: cell layout wind_speed_mps_tenths offsets=4..5 size=2",
            "RegionalSnapshotBuilder: cell layout wind_gust_mps_tenths offsets=6..7 size=2",
            "RegionalSnapshotBuilder: cell layout precip_prob_pct offset=8 size=1",
            "RegionalSnapshotBuilder: cell layout precip_kind offset=9 size=1",
            "RegionalSnapshotBuilder: cell layout precip_intensity offset=10 size=1",
            "RegionalSnapshotBuilder: cell layout reserved0 offset=11 size=1",
            "RegionalSnapshotBuilder: cell layout visibility_m offsets=12..13 size=2",
            "RegionalSnapshotBuilder: cell layout hazard_flags offsets=14..15 size=2",
            "RegionalSnapshotBuilder: layout totals header=18 metadata=20 cells=432 total=470"
        ]
    }

    private static func makeAnchorPacketDebug(
        anchorResult: WeatherFieldAnchorResult,
        into packet: inout Data
    ) -> RegionalSnapshotAnchorPacketDebug {
        let slots = anchorResult.weatherData?.threeSlotModel.slots ?? []
        let packetSlots = [0, 60, 120].map { offsetMinutes -> RegionalSnapshotSlotPacketDebug in
            let slot = slots.first(where: { $0.offsetMinutes == offsetMinutes })
            let debugSlot = quantizeSlot(anchorResult: anchorResult, offsetMinutes: offsetMinutes, slot: slot)

            packet.appendLittleEndian(debugSlot.slotOffsetMin)
            packet.appendLittleEndian(debugSlot.temperatureDeciC)
            packet.appendLittleEndian(debugSlot.windSpeedMpsTenths)
            packet.appendLittleEndian(debugSlot.windGustMpsTenths)
            packet.append(debugSlot.precipitationProbabilityPercent)
            packet.append(debugSlot.precipitationKind.rawValue)
            packet.append(debugSlot.precipitationIntensity.rawValue)
            packet.append(debugSlot.reserved0)
            packet.appendLittleEndian(debugSlot.visibilityM)
            packet.appendLittleEndian(debugSlot.hazardFlags.rawValue)

            return debugSlot
        }

        return RegionalSnapshotAnchorPacketDebug(
            anchorLabel: anchorResult.anchor.label,
            anchorCoordinateText: String(format: "%.5f, %.5f", anchorResult.anchor.latitude, anchorResult.anchor.longitude),
            slots: packetSlots
        )
    }

    private static func quantizeSlot(
        anchorResult: WeatherFieldAnchorResult,
        offsetMinutes: Int,
        slot: OnePointWeatherSlot?
    ) -> RegionalSnapshotSlotPacketDebug {
        let anchorLabel = anchorResult.anchor.label
        var notes: [String] = []

        if let slot {
            notes.append("weatherSummary=\(slot.weatherSummary ?? "nil")")
            notes.append("weatherRule=\(slot.weatherSelectionNote)")
            notes.append("hazardSummary=\(slot.hazardSummary ?? "nil")")
            notes.append("hazardRule=\(slot.hazardSelectionNote)")
        } else {
            notes.append("slot missing/offshore -> slot_offset_min encoded and remaining fields serialized as 0 by current protocol convention")
        }

        let slotOffsetMin = UInt16(offsetMinutes)
        let temperatureDeciC = quantizeSignedTenths(
            slot?.temperatureC,
            min: Int16.min,
            max: Int16.max,
            fieldName: "temperature",
            anchorLabel: anchorLabel,
            offsetMinutes: offsetMinutes,
            notes: &notes
        )

        let windSpeedMpsTenths = quantizeWindMpsTenths(
            slot?.windSpeedKmh,
            fieldName: "windSpeed",
            anchorLabel: anchorLabel,
            offsetMinutes: offsetMinutes,
            notes: &notes
        )

        let windGustMpsTenths = quantizeWindMpsTenths(
            slot?.windGustKmh,
            fieldName: "windGust",
            anchorLabel: anchorLabel,
            offsetMinutes: offsetMinutes,
            notes: &notes
        )

        let precipitationProbabilityPercent = quantizePercent(
            slot?.precipitationProbabilityPercent,
            fieldName: "precipitationProbability",
            anchorLabel: anchorLabel,
            offsetMinutes: offsetMinutes,
            notes: &notes
        )

        let precipitationKindResult = derivePrecipitationKind(
            slot: slot,
            anchorLabel: anchorLabel,
            offsetMinutes: offsetMinutes,
            notes: &notes
        )
        let precipitationKind = precipitationKindResult.kind

        let precipitationIntensityResult = derivePrecipitationIntensity(
            slot: slot,
            anchorLabel: anchorLabel,
            offsetMinutes: offsetMinutes,
            notes: &notes
        )
        let precipitationIntensity = precipitationIntensityResult.intensity
        let reserved0: UInt8 = 0

        let visibilitySelection = selectVisibilityForPacket(
            anchorResult: anchorResult,
            slot: slot,
            offsetMinutes: offsetMinutes,
            notes: &notes
        )
        let visibilityM = quantizeVisibilityMeters(
            visibilitySelection.visibilityMeters,
            anchorLabel: anchorLabel,
            offsetMinutes: offsetMinutes,
            notes: &notes
        )

        let hazardFlagsResult = deriveHazardFlags(
            slot: slot,
            precipitationKind: precipitationKind,
            anchorLabel: anchorLabel,
            offsetMinutes: offsetMinutes,
            notes: &notes
        )
        let hazardFlags = hazardFlagsResult.flags

        print(
            """
            RegionalSnapshotBuilder: packet-ready slot \
            anchor=\(anchorLabel) \
            offsetMinutes=\(offsetMinutes) \
            slotOffsetMin=\(slotOffsetMin) \
            temperatureDeciC=\(temperatureDeciC) \
            windSpeedMpsTenths=\(windSpeedMpsTenths) \
            windGustMpsTenths=\(windGustMpsTenths) \
            precipitationProbabilityPercent=\(precipitationProbabilityPercent) \
            precipitationKind=\(precipitationKind.description) \
            precipitationIntensity=\(precipitationIntensity.description) \
            visibilitySource=\(visibilitySelection.source.rawValue) \
            visibilitySourceMeters=\(visibilitySelection.visibilityMeters.map { String(format: "%.2f", $0) } ?? "nil") \
            visibilityM=\(visibilityM) \
            hazardFlags=\(hazardFlags.description)
            """
        )

        return RegionalSnapshotSlotPacketDebug(
            offsetMinutes: offsetMinutes,
            slotOffsetMin: slotOffsetMin,
            temperatureDeciC: temperatureDeciC,
            windSpeedMpsTenths: windSpeedMpsTenths,
            windGustMpsTenths: windGustMpsTenths,
            precipitationProbabilityPercent: precipitationProbabilityPercent,
            precipitationKind: precipitationKind,
            precipitationIntensity: precipitationIntensity,
            reserved0: reserved0,
            visibilitySource: visibilitySelection.source.rawValue,
            visibilitySourceMeters: visibilitySelection.visibilityMeters,
            visibilityM: visibilityM,
            hazardFlags: hazardFlags,
            quantizationNotes: notes
        )
    }

    private static func selectVisibilityForPacket(
        anchorResult: WeatherFieldAnchorResult,
        slot: OnePointWeatherSlot?,
        offsetMinutes: Int,
        notes: inout [String]
    ) -> (source: PacketVisibilitySource, visibilityMeters: Double?) {
        let anchorLabel = anchorResult.anchor.label
        let forecastGridVisibility = slot?.visibilityMeters
        let forecastGridUsable = isSaneVisibility(forecastGridVisibility)
        let observationVisibility = anchorResult.weatherData?.observationVisibility
        let observationMeters = observationVisibility?.normalizedVisibilityMeters
        let observationUsable = observationVisibility?.isUsable ?? false
        let observationAgeMinutes = observationVisibility?.observationAgeMinutes

        let source: PacketVisibilitySource
        let selectedMeters: Double?

        if anchorLabel == "r1c1", observationUsable {
            source = .observation
            selectedMeters = observationMeters
        } else if forecastGridUsable {
            source = .forecastGrid
            selectedMeters = forecastGridVisibility
        } else {
            source = .none
            selectedMeters = nil
        }

        notes.append(
            """
            visibility source chosen=\(source.rawValue) \
            forecastGridMeters=\(forecastGridVisibility.map { String(format: "%.2f", $0) } ?? "nil") \
            forecastGridUsable=\(forecastGridUsable) \
            observationMeters=\(observationMeters.map { String(format: "%.2f", $0) } ?? "nil") \
            observationUsable=\(observationUsable) \
            observationAgeMinutes=\(observationAgeMinutes.map(String.init) ?? "nil") \
            packetVisibilityPreSerializationMeters=\(selectedMeters.map { String(format: "%.2f", $0) } ?? "nil")
            """
        )

        print(
            """
            RegionalSnapshotBuilder: visibility source chosen \
            anchor=\(anchorLabel) \
            offsetMinutes=\(offsetMinutes) \
            source=\(source.rawValue) \
            forecastGridMeters=\(forecastGridVisibility.map { String(format: "%.2f", $0) } ?? "nil") \
            forecastGridUsable=\(forecastGridUsable) \
            observationMeters=\(observationMeters.map { String(format: "%.2f", $0) } ?? "nil") \
            observationUsable=\(observationUsable) \
            observationAgeMinutes=\(observationAgeMinutes.map(String.init) ?? "nil") \
            packetVisibilityPreSerializationMeters=\(selectedMeters.map { String(format: "%.2f", $0) } ?? "nil")
            """
        )
        AppLogger.shared.log(
            category: "PACKET",
            message: "\(anchorLabel) slot=\(offsetMinutes) visibility source=\(source.rawValue) meters=\(selectedMeters.map { String(format: "%.2f", $0) } ?? "nil")"
        )

        return (source, selectedMeters)
    }

    private static func isSaneVisibility(_ visibilityMeters: Double?) -> Bool {
        guard let visibilityMeters else {
            return false
        }

        return visibilityMeters > 0 && visibilityMeters <= 200_000
    }

    private static func orderedAnchorResults(from field: ThreeByThreeWeatherFieldDebugData) -> [WeatherFieldAnchorResult] {
        let expectedOrder = [
            "r0c0", "r0c1", "r0c2",
            "r1c0", "r1c1", "r1c2",
            "r2c0", "r2c1", "r2c2"
        ]

        let ordered = expectedOrder.compactMap { expected in
            field.anchorResults.first(where: { $0.anchor.label == expected })
        }

        if ordered.count != anchorCount {
            print("RegionalSnapshotBuilder: expected \(anchorCount) anchors but found \(ordered.count)")
        }

        return ordered
    }

    private static func latestFetchedAt(from anchors: [WeatherFieldAnchorResult]) -> Date {
        anchors.compactMap { $0.fetchedAt ?? $0.weatherData?.fetchedAt }.max() ?? Date()
    }

    private static func earliestFetchedAt(from anchors: [WeatherFieldAnchorResult]) -> Date? {
        anchors.compactMap { $0.fetchedAt ?? $0.weatherData?.fetchedAt }.min()
    }

    private static func quantizeSourceAgeMinutes(referenceDate: Date, anchors: [WeatherFieldAnchorResult]) -> UInt16 {
        guard let earliestFetchedAt = earliestFetchedAt(from: anchors) else {
            print("RegionalSnapshotBuilder: sourceAgeMin defaulted to 0 because no fetchedAt timestamps were available")
            return 0
        }

        let minutes = max(0, Int((referenceDate.timeIntervalSince(earliestFetchedAt) / 60.0).rounded(.down)))
        return UInt16(min(minutes, Int(UInt16.max)))
    }

    private static func derivePrecipitationKind(
        slot: OnePointWeatherSlot?,
        anchorLabel: String,
        offsetMinutes: Int,
        notes: inout [String]
    ) -> (kind: PrecipitationKind, isPresent: Bool) {
        guard let slot else {
            notes.append("precipitationKind missing/offshore -> encoded noneOrUnknown (0) by current protocol convention")
            print(
                """
                RegionalSnapshotBuilder: precipitationKind missing \
                anchor=\(anchorLabel) \
                offsetMinutes=\(offsetMinutes) \
                encoded=noneOrUnknown(0) \
                reason=missing-source
                """
            )
            return (.noneOrUnknown, false)
        }

        let summary = [slot.weatherSummary, slot.hazardSummary]
            .compactMap { $0?.lowercased() }
            .joined(separator: " | ")

        guard !summary.isEmpty else {
            notes.append("precipitationKind unavailable -> encoded noneOrUnknown (0) by current protocol convention")
            print(
                """
                RegionalSnapshotBuilder: precipitationKind unavailable \
                anchor=\(anchorLabel) \
                offsetMinutes=\(offsetMinutes) \
                encoded=noneOrUnknown(0) \
                reason=no-mappable-source-text
                """
            )
            return (.noneOrUnknown, false)
        }

        let candidates: [PrecipitationKind] = [
            containsIce(summary) ? .ice : nil,
            containsSnow(summary) ? .snow : nil,
            containsMixed(summary) ? .mixed : nil,
            containsRain(summary) ? .rain : nil
        ].compactMap { $0 }

        let prioritized = candidates.sorted { precipitationPriority($0) > precipitationPriority($1) }.first ?? .noneOrUnknown
        let isPresent = prioritized != .noneOrUnknown

        if isPresent {
            notes.append("precipitationKind derived from slot weather/hazard text summary")
        } else {
            notes.append("precipitationKind text had no mappable precipitation kind -> encoded noneOrUnknown (0) by current protocol convention")
        }

        print("RegionalSnapshotBuilder: precip kind anchor=\(anchorLabel) offsetMinutes=\(offsetMinutes) kind=\(prioritized.description) summary=\(summary)")
        return (prioritized, isPresent)
    }

    private static func derivePrecipitationIntensity(
        slot: OnePointWeatherSlot?,
        anchorLabel: String,
        offsetMinutes: Int,
        notes: inout [String]
    ) -> (intensity: PrecipitationIntensity, isPresent: Bool) {
        guard let slot, let weatherSummary = slot.weatherSummary?.lowercased(), !weatherSummary.isEmpty else {
            notes.append("precipitationIntensity unavailable -> encoded noneOrUnknown (0) by current protocol convention")
            print(
                """
                RegionalSnapshotBuilder: precipitationIntensity unavailable \
                anchor=\(anchorLabel) \
                offsetMinutes=\(offsetMinutes) \
                encoded=noneOrUnknown(0) \
                reason=missing-or-empty-weather-summary
                """
            )
            return (.noneOrUnknown, false)
        }

        let intensity: PrecipitationIntensity
        if weatherSummary.contains("heavy") {
            intensity = .heavy
        } else if weatherSummary.contains("moderate") {
            intensity = .moderate
        } else if weatherSummary.contains("light") || weatherSummary.contains("very_light") {
            intensity = .light
        } else {
            intensity = .noneOrUnknown
        }

        let isPresent = intensity != .noneOrUnknown
        if isPresent {
            notes.append("precipitationIntensity derived from NOAA weather intensity text")
        } else {
            notes.append("precipitationIntensity not derivable from NOAA weather text -> encoded noneOrUnknown (0) by current protocol convention")
        }

        print("RegionalSnapshotBuilder: precip intensity anchor=\(anchorLabel) offsetMinutes=\(offsetMinutes) intensity=\(intensity.description) weatherSummary=\(weatherSummary)")
        return (intensity, isPresent)
    }

    private static func deriveHazardFlags(
        slot: OnePointWeatherSlot?,
        precipitationKind: PrecipitationKind,
        anchorLabel: String,
        offsetMinutes: Int,
        notes: inout [String]
    ) -> (flags: HazardFlags, isPresent: Bool) {
        guard let slot else {
            notes.append("hazardFlags unavailable/offshore -> serialized as 0 by current protocol convention")
            print(
                """
                RegionalSnapshotBuilder: hazardFlags missing \
                anchor=\(anchorLabel) \
                offsetMinutes=\(offsetMinutes) \
                encoded=0 \
                reason=missing-source
                """
            )
            return ([], false)
        }

        let combinedSummary = [slot.weatherSummary, slot.hazardSummary]
            .compactMap { $0?.lowercased() }
            .joined(separator: " | ")

        var flags: HazardFlags = []
        var hadEvidence = false

        if !combinedSummary.isEmpty {
            hadEvidence = true
            if combinedSummary.contains("thunder") || combinedSummary.contains("lightning") {
                flags.insert(.thunderRisk)
            }
            if combinedSummary.contains("severe thunderstorm") || combinedSummary.contains("severe_tstms") || combinedSummary.contains("tornado") {
                flags.insert(.severeThunderstormRisk)
            }
        }

        if precipitationKind == .snow || precipitationKind == .ice || precipitationKind == .mixed {
            flags.insert(.winterPrecipitationRisk)
            hadEvidence = true
        }

        if let gust = slot.windGustKmh {
            hadEvidence = true
            if gust >= 50 {
                flags.insert(.strongWindRisk)
            }
        }

        if let visibility = slot.visibilityMeters {
            hadEvidence = true
            if visibility <= 1_600 {
                flags.insert(.lowVisibilityRisk)
            }
        }

        if let temperature = slot.temperatureC {
            hadEvidence = true
            if temperature <= 1.0 && (precipitationKind == .snow || precipitationKind == .ice || precipitationKind == .mixed) {
                flags.insert(.freezingSurfaceRisk)
            }
        }

        if hadEvidence {
            notes.append("hazardFlags derived conservatively from slot weather/hazard text plus metric thresholds")
        } else {
            notes.append("hazardFlags unavailable -> serialized as 0 by current protocol convention")
            print(
                """
                RegionalSnapshotBuilder: hazardFlags unavailable \
                anchor=\(anchorLabel) \
                offsetMinutes=\(offsetMinutes) \
                encoded=0 \
                reason=no-usable-source-evidence
                """
            )
        }

        print("RegionalSnapshotBuilder: hazard flags anchor=\(anchorLabel) offsetMinutes=\(offsetMinutes) flags=\(flags.description) summary=\(combinedSummary)")
        return (flags, hadEvidence)
    }

    private static func precipitationPriority(_ kind: PrecipitationKind) -> Int {
        switch kind {
        case .ice:
            return 5
        case .snow:
            return 4
        case .mixed:
            return 3
        case .rain:
            return 2
        case .noneOrUnknown:
            return 1
        }
    }

    private static func containsIce(_ text: String) -> Bool {
        ["freezing rain", "freezing_rain", "freezing drizzle", "freezing_drizzle", "sleet", "ice pellets", "ice_pellets", "glaze"].contains { text.contains($0) }
    }

    private static func containsSnow(_ text: String) -> Bool {
        guard !containsMixed(text) else {
            return false
        }

        return ["snow", "blowing snow", "snow_showers", "blizzard"].contains { text.contains($0) }
    }

    private static func containsMixed(_ text: String) -> Bool {
        ["mixed", "rain_snow", "rain/snow", "rain and snow", "rain_sleet", "snow_freezing_rain", "wintry mix", "wintry_mix"].contains { text.contains($0) }
    }

    private static func containsRain(_ text: String) -> Bool {
        guard !containsMixed(text), !containsIce(text) else {
            return false
        }

        return ["rain", "drizzle", "showers", "thunderstorms", "thunderstorm", "rain_showers"].contains { text.contains($0) }
    }

    private static func quantizeSignedTenths(
        _ value: Double?,
        min: Int16,
        max: Int16,
        fieldName: String,
        anchorLabel: String,
        offsetMinutes: Int,
        notes: inout [String]
    ) -> Int16 {
        guard let value else {
            notes.append("\(fieldName) missing/offshore -> serialized as 0 by current protocol convention")
            print(
                """
                RegionalSnapshotBuilder: \(fieldName) missing \
                anchor=\(anchorLabel) \
                offsetMinutes=\(offsetMinutes) \
                encoded=0 \
                reason=missing-source
                """
            )
            return 0
        }

        let raw = Int((value * 10).rounded())
        let clamped = Swift.max(Int(min), Swift.min(Int(max), raw))
        if clamped != raw {
            print("RegionalSnapshotBuilder: \(fieldName) clamped anchor=\(anchorLabel) offsetMinutes=\(offsetMinutes) raw=\(raw) clamped=\(clamped)")
            notes.append("\(fieldName) clamped from \(raw) to \(clamped)")
        }

        return Int16(clamped)
    }

    private static func quantizeWindMpsTenths(
        _ value: Double?,
        fieldName: String,
        anchorLabel: String,
        offsetMinutes: Int,
        notes: inout [String]
    ) -> UInt16 {
        guard let value else {
            notes.append("\(fieldName) missing/offshore -> serialized as 0 by current protocol convention")
            print(
                """
                RegionalSnapshotBuilder: \(fieldName) missing \
                anchor=\(anchorLabel) \
                offsetMinutes=\(offsetMinutes) \
                encoded=0 \
                reason=missing-source
                """
            )
            return 0
        }

        let metersPerSecond = value / 3.6
        let raw = Int((Swift.max(0, metersPerSecond) * 10).rounded())
        let clamped = Swift.max(0, Swift.min(Int(UInt16.max), raw))
        if clamped != raw {
            print("RegionalSnapshotBuilder: \(fieldName) clamped anchor=\(anchorLabel) offsetMinutes=\(offsetMinutes) raw=\(raw) clamped=\(clamped)")
            notes.append("\(fieldName) clamped from \(raw) to \(clamped)")
        }

        notes.append("\(fieldName) encoded as tenths of m/s from internal km/h")
        return UInt16(clamped)
    }

    private static func quantizePercent(
        _ value: Double?,
        fieldName: String,
        anchorLabel: String,
        offsetMinutes: Int,
        notes: inout [String]
    ) -> UInt8 {
        guard let value else {
            notes.append("\(fieldName) missing/offshore -> serialized as 0 by current protocol convention")
            print(
                """
                RegionalSnapshotBuilder: \(fieldName) missing \
                anchor=\(anchorLabel) \
                offsetMinutes=\(offsetMinutes) \
                encoded=0 \
                reason=missing-source
                """
            )
            return 0
        }

        let raw = Int(value.rounded())
        let clamped = Swift.max(0, Swift.min(100, raw))
        if clamped != raw {
            print("RegionalSnapshotBuilder: \(fieldName) clamped anchor=\(anchorLabel) offsetMinutes=\(offsetMinutes) raw=\(raw) clamped=\(clamped)")
            notes.append("\(fieldName) clamped from \(raw) to \(clamped)")
        }

        return UInt8(clamped)
    }

    private static func quantizeVisibilityMeters(
        _ value: Double?,
        anchorLabel: String,
        offsetMinutes: Int,
        notes: inout [String]
    ) -> UInt16 {
        guard let value else {
            notes.append("visibility missing/offshore -> serialized as 0 by current protocol convention")
            print(
                """
                RegionalSnapshotBuilder: visibility missing \
                anchor=\(anchorLabel) \
                offsetMinutes=\(offsetMinutes) \
                encoded=0 \
                reason=missing-source
                """
            )
            return 0
        }

        let raw = Int(Swift.max(0, value).rounded())
        let clamped = Swift.max(0, Swift.min(Int(UInt16.max), raw))
        if clamped != raw {
            print("RegionalSnapshotBuilder: visibility clamped anchor=\(anchorLabel) offsetMinutes=\(offsetMinutes) raw=\(raw) clamped=\(clamped)")
            notes.append("visibility clamped from \(raw) to \(clamped)")
        }

        notes.append("visibility encoded as whole meters")
        return UInt16(clamped)
    }
}

private extension Data {
    mutating func appendLittleEndian(_ value: Int16) {
        var littleEndianValue = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndianValue) { bytes in
            append(contentsOf: bytes)
        }
    }

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
