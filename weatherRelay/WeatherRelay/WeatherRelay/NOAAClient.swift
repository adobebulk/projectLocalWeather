//
//  NOAAClient.swift
//  WeatherRelay
//
//  Created by Codex on 2026-03-13.
//

import Foundation

struct NOAAResolvedPointInfo {
    let requestLatitude: Double
    let requestLongitude: Double
    let cwa: String
    let gridId: String
    let gridX: Int
    let gridY: Int
    let forecastGridDataURL: URL
}

struct NOAASelectedQuantitativeValue {
    let fieldName: String
    let validTime: String
    let unitCode: String?
    let value: Double?
}

struct NOAASelectedTextValue {
    let fieldName: String
    let validTime: String
    let summary: String
}

struct NOAAQuantitativeSeriesValue {
    let fieldName: String
    let validTime: String
    let unitCode: String?
    let startDate: Date
    let endDate: Date
    let normalizedValue: Double
}

struct NOAATextSeriesValue {
    let fieldName: String
    let validTime: String
    let startDate: Date
    let endDate: Date
    let summary: String
}

struct OnePointWeatherSnapshot {
    let temperatureC: Double?
    let windSpeedKmh: Double?
    let windGustKmh: Double?
    let precipitationProbabilityPercent: Double?
    let visibilityMeters: Double?
    let weatherSummary: String?
    let hazardSummary: String?
}

struct NOAAOnePointWeatherDebugData {
    let pointInfo: NOAAResolvedPointInfo
    let fetchedAt: Date
    let rawTemperature: NOAASelectedQuantitativeValue?
    let rawWindSpeed: NOAASelectedQuantitativeValue?
    let rawWindGust: NOAASelectedQuantitativeValue?
    let rawProbabilityOfPrecipitation: NOAASelectedQuantitativeValue?
    let rawVisibility: NOAASelectedQuantitativeValue?
    let rawWeather: NOAASelectedTextValue?
    let rawHazards: NOAASelectedTextValue?
    let snapshot: OnePointWeatherSnapshot
    let threeSlotModel: OnePointThreeSlotWeatherModel
}

enum NOAAClientError: LocalizedError {
    case invalidResponse
    case httpStatus(Int)
    case invalidJSON
    case missingPointsProperties
    case missingForecastGridDataURL
    case missingGridIdentifiers

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "NOAA returned an invalid response"
        case .httpStatus(let code):
            return "NOAA returned HTTP \(code)"
        case .invalidJSON:
            return "NOAA returned invalid JSON"
        case .missingPointsProperties:
            return "NOAA /points response was missing properties"
        case .missingForecastGridDataURL:
            return "NOAA /points response was missing forecastGridData"
        case .missingGridIdentifiers:
            return "NOAA /points response was missing grid identifiers"
        }
    }
}

final class NOAAClient {
    private let session: URLSession
    private let userAgent: String
    private let acceptHeader = "application/geo+json"

    init(
        session: URLSession = .shared,
        userAgent: String = "WeatherRelay/1.0 (iPhone Block 1 NOAA debug client)"
    ) {
        self.session = session
        self.userAgent = userAgent
    }

    func fetchOnePointWeather(latitude: Double, longitude: Double) async throws -> NOAAOnePointWeatherDebugData {
        try await fetchAnchorWeather(
            latitude: latitude,
            longitude: longitude,
            fieldAnchorDate: Date(),
            logPrefix: "NOAAClient"
        )
    }

    func fetchThreeByThreeField(centerLatitude: Double, centerLongitude: Double) async -> ThreeByThreeWeatherFieldDebugData {
        let center = WeatherFieldCenter(latitude: centerLatitude, longitude: centerLongitude)
        let anchors = Block1FieldGeometry.makeAnchorCoordinates(center: center)
        let fieldAnchorDate = Date()

        print(
            """
            NOAAClient: starting 3x3 field fetch \
            centerLat=\(centerLatitude) \
            centerLon=\(centerLongitude) \
            fieldAnchorUnix=\(Int(fieldAnchorDate.timeIntervalSince1970)) \
            anchorSpacingMiles=\(Int(Block1FieldGeometry.anchorSpacingMiles)) \
            anchorSpacingMeters=\(Int(Block1FieldGeometry.anchorSpacingMeters))
            """
        )

        let anchorResults = await withTaskGroup(of: WeatherFieldAnchorResult.self) { group in
            for anchor in anchors {
                group.addTask { [self] in
                    let label = anchor.label
                    do {
                        print(
                            """
                            NOAAClient: anchor fetch start \
                            anchor=\(label) \
                            lat=\(anchor.latitude) \
                            lon=\(anchor.longitude)
                            """
                        )
                        let weatherData = try await fetchAnchorWeather(
                            latitude: anchor.latitude,
                            longitude: anchor.longitude,
                            fieldAnchorDate: fieldAnchorDate,
                            logPrefix: "NOAAClient[\(label)]"
                        )
                        return WeatherFieldAnchorResult(
                            anchor: anchor,
                            fetchedAt: weatherData.fetchedAt,
                            weatherData: weatherData,
                            errorMessage: nil
                        )
                    } catch {
                        print("NOAAClient: anchor fetch failed anchor=\(label) error=\(error.localizedDescription)")
                        return WeatherFieldAnchorResult(
                            anchor: anchor,
                            fetchedAt: nil,
                            weatherData: nil,
                            errorMessage: error.localizedDescription
                        )
                    }
                }
            }

            var results: [WeatherFieldAnchorResult] = []
            for await result in group {
                results.append(result)
            }

            return results.sorted {
                if $0.anchor.row == $1.anchor.row {
                    return $0.anchor.column < $1.anchor.column
                }

                return $0.anchor.row < $1.anchor.row
            }
        }

        print("NOAAClient: completed 3x3 field fetch anchors=\(anchorResults.count)")

        return ThreeByThreeWeatherFieldDebugData(
            center: center,
            geometrySpacingMeters: Block1FieldGeometry.anchorSpacingMeters,
            fieldAnchorDate: fieldAnchorDate,
            anchorResults: anchorResults
        )
    }

    private func fetchAnchorWeather(
        latitude: Double,
        longitude: Double,
        fieldAnchorDate: Date,
        logPrefix: String
    ) async throws -> NOAAOnePointWeatherDebugData {
        let pointsURL = try makePointsURL(latitude: latitude, longitude: longitude)
        print("\(logPrefix): fetching points url=\(pointsURL.absoluteString)")
        let pointsJSON = try await fetchJSONObject(from: pointsURL)
        let pointInfo = try parsePointInfo(from: pointsJSON, latitude: latitude, longitude: longitude)

        print(
            """
            \(logPrefix): resolved point \
            cwa=\(pointInfo.cwa) \
            gridId=\(pointInfo.gridId) \
            gridX=\(pointInfo.gridX) \
            gridY=\(pointInfo.gridY) \
            forecastGridDataURL=\(pointInfo.forecastGridDataURL.absoluteString)
            """
        )

        print("\(logPrefix): fetching forecastGridData url=\(pointInfo.forecastGridDataURL.absoluteString)")
        let gridJSON = try await fetchJSONObject(from: pointInfo.forecastGridDataURL)
        let forecastProperties = try parseForecastProperties(from: gridJSON)
        let fetchedAt = Date()

        let rawTemperature = Self.selectQuantitativeValue(fieldName: "temperature", properties: forecastProperties, now: fetchedAt)
        let rawWindSpeed = Self.selectQuantitativeValue(fieldName: "windSpeed", properties: forecastProperties, now: fetchedAt)
        let rawWindGust = Self.selectQuantitativeValue(fieldName: "windGust", properties: forecastProperties, now: fetchedAt)
        let rawProbabilityOfPrecipitation = Self.selectQuantitativeValue(fieldName: "probabilityOfPrecipitation", properties: forecastProperties, now: fetchedAt)
        let rawVisibility = Self.selectQuantitativeValue(fieldName: "visibility", properties: forecastProperties, now: fetchedAt)
        let rawWeather = Self.selectTextValue(fieldName: "weather", properties: forecastProperties, now: fetchedAt)
        let rawHazards = Self.selectTextValue(fieldName: "hazards", properties: forecastProperties, now: fetchedAt)

        let snapshot = OnePointWeatherSnapshot(
            temperatureC: Self.convertTemperatureToCelsius(rawTemperature),
            windSpeedKmh: Self.convertSpeedToKilometersPerHour(rawWindSpeed),
            windGustKmh: Self.convertSpeedToKilometersPerHour(rawWindGust),
            precipitationProbabilityPercent: rawProbabilityOfPrecipitation?.value,
            visibilityMeters: Self.convertLengthToMeters(rawVisibility),
            weatherSummary: rawWeather?.summary,
            hazardSummary: rawHazards?.summary
        )
        let threeSlotModel = Self.deriveThreeSlotModel(properties: forecastProperties, fieldAnchorDate: fieldAnchorDate)

        print(
            """
            \(logPrefix): normalized snapshot \
            temperatureC=\(snapshot.temperatureC.map(Self.formatDouble) ?? "nil") \
            windSpeedKmh=\(snapshot.windSpeedKmh.map(Self.formatDouble) ?? "nil") \
            windGustKmh=\(snapshot.windGustKmh.map(Self.formatDouble) ?? "nil") \
            precipitationProbabilityPercent=\(snapshot.precipitationProbabilityPercent.map(Self.formatDouble) ?? "nil") \
            visibilityMeters=\(snapshot.visibilityMeters.map(Self.formatDouble) ?? "nil") \
            weatherSummary=\(snapshot.weatherSummary ?? "nil") \
            hazardSummary=\(snapshot.hazardSummary ?? "nil")
            """
        )
        Self.logThreeSlotModel(threeSlotModel, logPrefix: logPrefix)

        return NOAAOnePointWeatherDebugData(
            pointInfo: pointInfo,
            fetchedAt: fetchedAt,
            rawTemperature: rawTemperature,
            rawWindSpeed: rawWindSpeed,
            rawWindGust: rawWindGust,
            rawProbabilityOfPrecipitation: rawProbabilityOfPrecipitation,
            rawVisibility: rawVisibility,
            rawWeather: rawWeather,
            rawHazards: rawHazards,
            snapshot: snapshot,
            threeSlotModel: threeSlotModel
        )
    }

    private func makePointsURL(latitude: Double, longitude: Double) throws -> URL {
        let latitudeString = String(format: "%.4f", latitude)
        let longitudeString = String(format: "%.4f", longitude)

        guard let url = URL(string: "https://api.weather.gov/points/\(latitudeString),\(longitudeString)") else {
            throw NOAAClientError.invalidResponse
        }

        return url
    }

    private func fetchJSONObject(from url: URL) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(acceptHeader, forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NOAAClientError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw NOAAClientError.httpStatus(httpResponse.statusCode)
        }

        guard let jsonObject = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NOAAClientError.invalidJSON
        }

        return jsonObject
    }

    private func parsePointInfo(
        from json: [String: Any],
        latitude: Double,
        longitude: Double
    ) throws -> NOAAResolvedPointInfo {
        guard let properties = json["properties"] as? [String: Any] else {
            throw NOAAClientError.missingPointsProperties
        }

        guard
            let forecastGridDataString = properties["forecastGridData"] as? String,
            let forecastGridDataURL = URL(string: forecastGridDataString)
        else {
            throw NOAAClientError.missingForecastGridDataURL
        }

        guard
            let gridId = properties["gridId"] as? String,
            let gridX = properties["gridX"] as? Int,
            let gridY = properties["gridY"] as? Int
        else {
            throw NOAAClientError.missingGridIdentifiers
        }

        let cwa = properties["cwa"] as? String ?? "-"

        return NOAAResolvedPointInfo(
            requestLatitude: latitude,
            requestLongitude: longitude,
            cwa: cwa,
            gridId: gridId,
            gridX: gridX,
            gridY: gridY,
            forecastGridDataURL: forecastGridDataURL
        )
    }

    private func parseForecastProperties(from json: [String: Any]) throws -> [String: Any] {
        guard let properties = json["properties"] as? [String: Any] else {
            throw NOAAClientError.missingPointsProperties
        }

        return properties
    }

    private static func selectQuantitativeValue(
        fieldName: String,
        properties: [String: Any],
        now: Date
    ) -> NOAASelectedQuantitativeValue? {
        guard
            let field = properties[fieldName] as? [String: Any],
            let values = field["values"] as? [[String: Any]]
        else {
            return nil
        }

        let unitCode = field["uom"] as? String
        guard let selected = selectBestSeriesEntry(values: values, now: now) else {
            return nil
        }

        return NOAASelectedQuantitativeValue(
            fieldName: fieldName,
            validTime: selected.validTime,
            unitCode: unitCode,
            value: Self.doubleValue(from: selected.value["value"])
        )
    }

    private static func parseQuantitativeSeries(
        fieldName: String,
        properties: [String: Any],
        normalizer: (NOAASelectedQuantitativeValue) -> Double?
    ) -> [NOAAQuantitativeSeriesValue] {
        guard
            let field = properties[fieldName] as? [String: Any],
            let values = field["values"] as? [[String: Any]]
        else {
            return []
        }

        let unitCode = field["uom"] as? String

        return values.compactMap { item in
            guard
                let validTime = item["validTime"] as? String,
                let dateRange = parseDateRange(from: validTime),
                let rawValue = doubleValue(from: item["value"])
            else {
                return nil
            }

            let selectedValue = NOAASelectedQuantitativeValue(
                fieldName: fieldName,
                validTime: validTime,
                unitCode: unitCode,
                value: rawValue
            )

            guard let normalizedValue = normalizer(selectedValue) else {
                return nil
            }

            return NOAAQuantitativeSeriesValue(
                fieldName: fieldName,
                validTime: validTime,
                unitCode: unitCode,
                startDate: dateRange.start,
                endDate: dateRange.end,
                normalizedValue: normalizedValue
            )
        }
    }

    private static func selectTextValue(
        fieldName: String,
        properties: [String: Any],
        now: Date
    ) -> NOAASelectedTextValue? {
        guard
            let field = properties[fieldName] as? [String: Any],
            let values = field["values"] as? [[String: Any]]
        else {
            return nil
        }

        guard let selected = selectBestSeriesEntry(values: values, now: now) else {
            return nil
        }

        let summary = summarizeTextValue(selected.value["value"])
        guard !summary.isEmpty else {
            return nil
        }

        return NOAASelectedTextValue(
            fieldName: fieldName,
            validTime: selected.validTime,
            summary: summary
        )
    }

    private static func selectBestSeriesEntry(values: [[String: Any]], now: Date) -> (validTime: String, startDate: Date?, value: [String: Any])? {
        let entries = values.compactMap { item -> (validTime: String, startDate: Date?, value: [String: Any])? in
            guard let validTime = item["validTime"] as? String else {
                return nil
            }

            return (validTime: validTime, startDate: startDate(from: validTime), value: item)
        }

        let datedEntries = entries.filter { $0.startDate != nil }
        let currentOrPast = datedEntries
            .filter { ($0.startDate ?? .distantPast) <= now }
            .sorted { ($0.startDate ?? .distantPast) > ($1.startDate ?? .distantPast) }

        if let entry = currentOrPast.first {
            return entry
        }

        let future = datedEntries
            .filter { ($0.startDate ?? .distantFuture) > now }
            .sorted { ($0.startDate ?? .distantFuture) < ($1.startDate ?? .distantFuture) }

        return future.first ?? entries.first
    }

    private static func startDate(from validTime: String) -> Date? {
        let startString = validTime.split(separator: "/", maxSplits: 1).first.map(String.init) ?? validTime
        return fractionalISO8601Formatter.date(from: startString) ?? plainISO8601Formatter.date(from: startString)
    }

    private static func parseDateRange(from validTime: String) -> (start: Date, end: Date)? {
        let parts = validTime.split(separator: "/", maxSplits: 1).map(String.init)
        guard let startString = parts.first, let startDate = startDate(from: startString) else {
            return nil
        }

        guard parts.count == 2 else {
            return (startDate, startDate.addingTimeInterval(3600))
        }

        guard let duration = iso8601Duration(parts[1]) else {
            return nil
        }

        return (startDate, startDate.addingTimeInterval(duration))
    }

    private static func iso8601Duration(_ string: String) -> TimeInterval? {
        guard string.hasPrefix("P") else {
            return nil
        }

        var totalSeconds: TimeInterval = 0
        var numberBuffer = ""
        var inTimeSection = false

        for character in string.dropFirst() {
            if character == "T" {
                inTimeSection = true
                continue
            }

            if character.isNumber || character == "." {
                numberBuffer.append(character)
                continue
            }

            guard let value = Double(numberBuffer) else {
                return nil
            }
            numberBuffer.removeAll()

            switch character {
            case "D":
                totalSeconds += value * 86_400
            case "H":
                totalSeconds += value * 3_600
            case "M":
                totalSeconds += value * (inTimeSection ? 60 : 2_592_000)
            case "S":
                totalSeconds += value
            default:
                return nil
            }
        }

        return totalSeconds > 0 ? totalSeconds : nil
    }

    private static func deriveThreeSlotModel(
        properties: [String: Any],
        fieldAnchorDate: Date
    ) -> OnePointThreeSlotWeatherModel {
        let slotDurationMinutes = 60

        let temperatureSeries = parseQuantitativeSeries(
            fieldName: "temperature",
            properties: properties,
            normalizer: convertTemperatureToCelsius
        )
        let windSpeedSeries = parseQuantitativeSeries(
            fieldName: "windSpeed",
            properties: properties,
            normalizer: convertSpeedToKilometersPerHour
        )
        let windGustSeries = parseQuantitativeSeries(
            fieldName: "windGust",
            properties: properties,
            normalizer: convertSpeedToKilometersPerHour
        )
        let precipitationSeries = parseQuantitativeSeries(
            fieldName: "probabilityOfPrecipitation",
            properties: properties,
            normalizer: { $0.value }
        )
        let visibilitySeries = parseQuantitativeSeries(
            fieldName: "visibility",
            properties: properties,
            normalizer: convertLengthToMeters
        )
        let weatherSeries = parseTextSeries(fieldName: "weather", properties: properties)
        let hazardSeries = parseTextSeries(fieldName: "hazards", properties: properties)

        let slotOffsets = [0, 60, 120]
        let slots = slotOffsets.map { offsetMinutes -> OnePointWeatherSlot in
            let slotStart = fieldAnchorDate.addingTimeInterval(TimeInterval(offsetMinutes * 60))
            let slotEnd = slotStart.addingTimeInterval(TimeInterval(slotDurationMinutes * 60))

            let temperature = deriveSlotValue(
                series: temperatureSeries,
                fieldName: "temperature",
                aggregation: .overlapWeightedAverage,
                slotStart: slotStart,
                slotEnd: slotEnd
            )
            let windSpeed = deriveSlotValue(
                series: windSpeedSeries,
                fieldName: "windSpeed",
                aggregation: .overlapWeightedAverage,
                slotStart: slotStart,
                slotEnd: slotEnd
            )
            let windGust = deriveSlotValue(
                series: windGustSeries,
                fieldName: "windGust",
                aggregation: .slotMaximum,
                slotStart: slotStart,
                slotEnd: slotEnd
            )
            let precipitation = deriveSlotValue(
                series: precipitationSeries,
                fieldName: "probabilityOfPrecipitation",
                aggregation: .slotMaximum,
                slotStart: slotStart,
                slotEnd: slotEnd
            )
            let visibility = deriveSlotValue(
                series: visibilitySeries,
                fieldName: "visibility",
                aggregation: .slotMinimum,
                slotStart: slotStart,
                slotEnd: slotEnd
            )
            let weather = deriveSlotText(
                series: weatherSeries,
                fieldName: "weather",
                slotStart: slotStart,
                slotEnd: slotEnd
            )
            let hazards = deriveSlotText(
                series: hazardSeries,
                fieldName: "hazards",
                slotStart: slotStart,
                slotEnd: slotEnd
            )

            return OnePointWeatherSlot(
                offsetMinutes: offsetMinutes,
                startDate: slotStart,
                endDate: slotEnd,
                temperatureC: temperature.value,
                windSpeedKmh: windSpeed.value,
                windGustKmh: windGust.value,
                precipitationProbabilityPercent: precipitation.value,
                visibilityMeters: visibility.value,
                weatherSummary: weather.summary,
                hazardSummary: hazards.summary,
                temperatureSelectionNote: temperature.note,
                windSpeedSelectionNote: windSpeed.note,
                windGustSelectionNote: windGust.note,
                precipitationSelectionNote: precipitation.note,
                visibilitySelectionNote: visibility.note,
                weatherSelectionNote: weather.note,
                hazardSelectionNote: hazards.note
            )
        }

        return OnePointThreeSlotWeatherModel(
            anchorDate: fieldAnchorDate,
            slotDurationMinutes: slotDurationMinutes,
            slots: slots
        )
    }

    private static func deriveSlotValue(
        series: [NOAAQuantitativeSeriesValue],
        fieldName: String,
        aggregation: SlotAggregation,
        slotStart: Date,
        slotEnd: Date
    ) -> (value: Double?, note: String) {
        let slotDuration = slotEnd.timeIntervalSince(slotStart)
        let overlappingSeries = series.compactMap { sample -> (sample: NOAAQuantitativeSeriesValue, overlap: TimeInterval)? in
            let overlapStart = max(sample.startDate, slotStart)
            let overlapEnd = min(sample.endDate, slotEnd)
            let overlap = overlapEnd.timeIntervalSince(overlapStart)
            guard overlap > 0 else {
                return nil
            }

            return (sample, overlap)
        }

        if !overlappingSeries.isEmpty {
            let derivedValue: Double
            let aggregationDescription: String
            switch aggregation {
            case .overlapWeightedAverage:
                derivedValue = overlappingSeries.reduce(0.0) { partial, item in
                    partial + item.sample.normalizedValue * (item.overlap / slotDuration)
                }
                aggregationDescription = "overlap-weighted average"
            case .slotMaximum:
                derivedValue = overlappingSeries.map(\.sample.normalizedValue).max() ?? 0
                aggregationDescription = "slot maximum"
            case .slotMinimum:
                derivedValue = overlappingSeries.map(\.sample.normalizedValue).min() ?? 0
                aggregationDescription = "slot minimum"
            }
            let sourceDescription = overlappingSeries.map {
                "\($0.sample.validTime) overlapMinutes=\(Int($0.overlap / 60)) value=\(formatDouble($0.sample.normalizedValue))"
            }.joined(separator: "; ")

            return (
                derivedValue,
                "\(aggregationDescription) from \(overlappingSeries.count) interval(s): \(sourceDescription)"
            )
        }

        let slotMidpoint = slotStart.addingTimeInterval(slotDuration / 2)
        let nearest = series.sorted {
            let leftDistance = distanceFromIntervalMidpoint($0, to: slotMidpoint)
            let rightDistance = distanceFromIntervalMidpoint($1, to: slotMidpoint)
            if leftDistance == rightDistance {
                return $0.startDate < $1.startDate
            }

            return leftDistance < rightDistance
        }.first

        if let nearest {
            return (
                nearest.normalizedValue,
                "fallback nearest interval for \(aggregation.description): \(nearest.validTime) value=\(formatDouble(nearest.normalizedValue))"
            )
        }

        return (nil, "no usable \(fieldName) values")
    }

    private static func parseTextSeries(
        fieldName: String,
        properties: [String: Any]
    ) -> [NOAATextSeriesValue] {
        guard
            let field = properties[fieldName] as? [String: Any],
            let values = field["values"] as? [[String: Any]]
        else {
            return []
        }

        return values.compactMap { item in
            guard
                let validTime = item["validTime"] as? String,
                let dateRange = parseDateRange(from: validTime)
            else {
                return nil
            }

            let summary = summarizeTextValue(item["value"])
            guard !summary.isEmpty else {
                return nil
            }

            return NOAATextSeriesValue(
                fieldName: fieldName,
                validTime: validTime,
                startDate: dateRange.start,
                endDate: dateRange.end,
                summary: summary
            )
        }
    }

    private static func deriveSlotText(
        series: [NOAATextSeriesValue],
        fieldName: String,
        slotStart: Date,
        slotEnd: Date
    ) -> (summary: String?, note: String) {
        let slotDuration = slotEnd.timeIntervalSince(slotStart)
        let overlappingSeries = series.compactMap { sample -> (sample: NOAATextSeriesValue, overlap: TimeInterval)? in
            let overlapStart = max(sample.startDate, slotStart)
            let overlapEnd = min(sample.endDate, slotEnd)
            let overlap = overlapEnd.timeIntervalSince(overlapStart)
            guard overlap > 0 else {
                return nil
            }

            return (sample, overlap)
        }

        if !overlappingSeries.isEmpty {
            let summaries = deduplicatedStrings(overlappingSeries.map(\.sample.summary))
            let summary = summaries.joined(separator: " | ")
            let sourceDescription = overlappingSeries.map {
                "\($0.sample.validTime) overlapMinutes=\(Int($0.overlap / 60)) summary=\($0.sample.summary)"
            }.joined(separator: "; ")

            return (
                summary,
                "overlap summary from \(overlappingSeries.count) interval(s): \(sourceDescription)"
            )
        }

        let slotMidpoint = slotStart.addingTimeInterval(slotDuration / 2)
        let nearest = series.sorted {
            let leftDistance = distanceFromTextIntervalMidpoint($0, to: slotMidpoint)
            let rightDistance = distanceFromTextIntervalMidpoint($1, to: slotMidpoint)
            if leftDistance == rightDistance {
                return $0.startDate < $1.startDate
            }

            return leftDistance < rightDistance
        }.first

        if let nearest {
            return (
                nearest.summary,
                "fallback nearest interval summary: \(nearest.validTime) summary=\(nearest.summary)"
            )
        }

        return (nil, "no usable \(fieldName) text values")
    }

    private static func distanceFromIntervalMidpoint(_ value: NOAAQuantitativeSeriesValue, to date: Date) -> TimeInterval {
        let midpoint = value.startDate.addingTimeInterval(value.endDate.timeIntervalSince(value.startDate) / 2)
        return abs(midpoint.timeIntervalSince(date))
    }

    private static func distanceFromTextIntervalMidpoint(_ value: NOAATextSeriesValue, to date: Date) -> TimeInterval {
        let midpoint = value.startDate.addingTimeInterval(value.endDate.timeIntervalSince(value.startDate) / 2)
        return abs(midpoint.timeIntervalSince(date))
    }

    private static func logThreeSlotModel(_ model: OnePointThreeSlotWeatherModel, logPrefix: String) {
        print(
            """
            \(logPrefix): derived three-slot model \
            anchorUnix=\(Int(model.anchorDate.timeIntervalSince1970)) \
            slotDurationMinutes=\(model.slotDurationMinutes)
            """
        )

        for slot in model.slots {
            print(
                """
                \(logPrefix): slot offsetMinutes=\(slot.offsetMinutes) \
                startUnix=\(Int(slot.startDate.timeIntervalSince1970)) \
                endUnix=\(Int(slot.endDate.timeIntervalSince1970)) \
                temperatureC=\(slot.temperatureC.map(formatDouble) ?? "nil") \
                windSpeedKmh=\(slot.windSpeedKmh.map(formatDouble) ?? "nil") \
                windGustKmh=\(slot.windGustKmh.map(formatDouble) ?? "nil") \
                precipitationProbabilityPercent=\(slot.precipitationProbabilityPercent.map(formatDouble) ?? "nil") \
                visibilityMeters=\(slot.visibilityMeters.map(formatDouble) ?? "nil")
                """
            )
            print("\(logPrefix): slot \(slot.offsetMinutes) temperature rule=\(slot.temperatureSelectionNote)")
            print("\(logPrefix): slot \(slot.offsetMinutes) windSpeed rule=\(slot.windSpeedSelectionNote)")
            print("\(logPrefix): slot \(slot.offsetMinutes) windGust rule=\(slot.windGustSelectionNote)")
            print("\(logPrefix): slot \(slot.offsetMinutes) precipitation rule=\(slot.precipitationSelectionNote)")
            print("\(logPrefix): slot \(slot.offsetMinutes) visibility rule=\(slot.visibilitySelectionNote)")
            print("\(logPrefix): slot \(slot.offsetMinutes) weather summary=\(slot.weatherSummary ?? "nil")")
            print("\(logPrefix): slot \(slot.offsetMinutes) weather rule=\(slot.weatherSelectionNote)")
            print("\(logPrefix): slot \(slot.offsetMinutes) hazard summary=\(slot.hazardSummary ?? "nil")")
            print("\(logPrefix): slot \(slot.offsetMinutes) hazard rule=\(slot.hazardSelectionNote)")
        }
    }

    private static func summarizeTextValue(_ rawValue: Any?) -> String {
        switch rawValue {
        case let value as String:
            return value
        case let value as NSNumber:
            return value.stringValue
        case let value as [String]:
            return value.joined(separator: ", ")
        case let value as [[String: Any]]:
            return value.map { summarizeWeatherCondition($0) }.filter { !$0.isEmpty }.joined(separator: " | ")
        case let value as [Any]:
            return value.map { summarizeTextValue($0) }.filter { !$0.isEmpty }.joined(separator: ", ")
        case let value as [String: Any]:
            let parts = value.keys.sorted().compactMap { key -> String? in
                let text = summarizeTextValue(value[key])
                return text.isEmpty ? nil : "\(key)=\(text)"
            }
            return parts.joined(separator: ", ")
        default:
            return ""
        }
    }

    private static func summarizeWeatherCondition(_ value: [String: Any]) -> String {
        var parts: [String] = []

        if let coverage = value["coverage"] as? String, !coverage.isEmpty {
            parts.append("coverage=\(coverage)")
        }

        if let weather = value["weather"] as? String, !weather.isEmpty {
            parts.append("weather=\(weather)")
        }

        if let intensity = value["intensity"] as? String, !intensity.isEmpty {
            parts.append("intensity=\(intensity)")
        }

        if let visibility = value["visibility"] as? [String: Any] {
            let visibilityText = summarizeTextValue(visibility)
            if !visibilityText.isEmpty {
                parts.append("visibility=\(visibilityText)")
            }
        }

        if let attributes = value["attributes"] as? [String], !attributes.isEmpty {
            parts.append("attributes=\(attributes.joined(separator: ","))")
        }

        return parts.joined(separator: ", ")
    }

    nonisolated private static func convertTemperatureToCelsius(_ value: NOAASelectedQuantitativeValue?) -> Double? {
        guard let value, let raw = value.value else {
            return nil
        }

        switch value.unitCode {
        case "wmoUnit:degC", nil:
            return raw
        case "wmoUnit:degF":
            return (raw - 32) * 5 / 9
        default:
            return raw
        }
    }

    nonisolated private static func convertSpeedToKilometersPerHour(_ value: NOAASelectedQuantitativeValue?) -> Double? {
        guard let value, let raw = value.value else {
            return nil
        }

        switch value.unitCode {
        case "wmoUnit:km_h-1", nil:
            return raw
        case "wmoUnit:m_s-1":
            return raw * 3.6
        case "wmoUnit:kn":
            return raw * 1.852
        default:
            return raw
        }
    }

    nonisolated private static func convertLengthToMeters(_ value: NOAASelectedQuantitativeValue?) -> Double? {
        guard let value, let raw = value.value else {
            return nil
        }

        switch value.unitCode {
        case "wmoUnit:m", nil:
            return raw
        case "wmoUnit:km":
            return raw * 1_000
        case "wmoUnit:mi_us":
            return raw * 1_609.344
        case "wmoUnit:ft":
            return raw * 0.3048
        default:
            return raw
        }
    }

    private static func doubleValue(from anyValue: Any?) -> Double? {
        if anyValue is NSNull {
            return nil
        }

        if let number = anyValue as? NSNumber {
            return number.doubleValue
        }

        if let string = anyValue as? String {
            return Double(string)
        }

        return nil
    }

    nonisolated private static func formatDouble(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    private static func deduplicatedStrings(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []

        for value in values where !seen.contains(value) {
            seen.insert(value)
            result.append(value)
        }

        return result
    }

    private static let fractionalISO8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plainISO8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }()
}

private extension NOAAClient {
    enum SlotAggregation {
        case overlapWeightedAverage
        case slotMaximum
        case slotMinimum

        var description: String {
            switch self {
            case .overlapWeightedAverage:
                return "overlap-weighted average"
            case .slotMaximum:
                return "slot maximum"
            case .slotMinimum:
                return "slot minimum"
            }
        }
    }
}
