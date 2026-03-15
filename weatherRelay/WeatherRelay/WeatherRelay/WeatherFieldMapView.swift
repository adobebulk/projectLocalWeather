//
//  WeatherFieldMapView.swift
//  WeatherRelay
//
//  Created by Codex on 2026-03-14.
//

import CoreLocation
import MapKit
import SwiftUI

struct WeatherFieldMapView: View {
    @ObservedObject var viewModel: WeatherDebugViewModel

    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var selectedSlotOffsetMinutes = 0
    @State private var selectedAnchorNode: AnchorWeatherNode?
    @State private var mapSize: CGSize = .zero
    @State private var hasInitializedCamera = false
    @State private var lastCameraSignature: CameraSignature?
    @State private var renderedAnchorNodes: [AnchorWeatherNode] = []

    private let slotOffsets = [0, 60, 120]

    private var fieldData: ThreeByThreeWeatherFieldDebugData? {
        viewModel.latestFieldWeatherData
    }

    private var boundaryCoordinates: [CLLocationCoordinate2D] {
        guard let fieldData else {
            return []
        }

        let corners = Block1FieldGeometry.fieldBoundaryCoordinates(
            center: fieldData.center,
            fieldWidthMiles: fieldData.fieldWidthMiles,
            fieldHeightMiles: fieldData.fieldHeightMiles
        )
        guard let first = corners.first else {
            return []
        }

        return corners + [first]
    }

    var body: some View {
        VStack(spacing: 12) {
            if let fieldData {
                Text(
                    """
                    Center \(String(format: "%.5f", fieldData.center.latitude)), \
                    \(String(format: "%.5f", fieldData.center.longitude)) \
                    | width \(Int(fieldData.fieldWidthMiles.rounded())) mi \
                    | slot +\(selectedSlotOffsetMinutes)m
                    """
                )
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)

                Picker("Slot", selection: $selectedSlotOffsetMinutes) {
                    ForEach(slotOffsets, id: \.self) { offset in
                        Text("\(offset) min").tag(offset)
                    }
                }
                .pickerStyle(.segmented)

                Map(position: $cameraPosition) {
                    if !boundaryCoordinates.isEmpty {
                        MapPolyline(coordinates: boundaryCoordinates)
                            .stroke(.teal.opacity(0.8), lineWidth: 2)
                    }

                    ForEach(renderedAnchorNodes) { node in
                        Annotation(node.anchorId, coordinate: node.coordinate) {
                            WeatherFieldAnchorAnnotationView(node: node)
                                .onTapGesture {
                                    selectedAnchorNode = node
                                    AppLogger.shared.log(
                                        category: "MAP",
                                        message: "anchor tapped id=\(node.anchorId) slot=\(node.slotOffsetMinutes) visibilitySource=\(node.visibilitySource ?? "none")"
                                    )
                                }
                        }
                    }
                }
                .mapStyle(.standard)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: MapSizePreferenceKey.self, value: proxy.size)
                    }
                )
                .onPreferenceChange(MapSizePreferenceKey.self) { newSize in
                    guard newSize.width > 0, newSize.height > 0 else {
                        return
                    }

                    if mapSize.width == 0 || mapSize.height == 0 {
                        AppLogger.shared.log(
                            category: "MAP",
                            message: "map size became non-zero width=\(Int(newSize.width.rounded())) height=\(Int(newSize.height.rounded()))"
                        )
                    }

                    mapSize = newSize
                    updateCameraPosition(reason: "map-size-change")
                }

                List {
                    Section("Anchor Summary") {
                        ForEach(renderedAnchorNodes) { node in
                            Text(
                                """
                                \(node.anchorId) \
                                wind=\(node.windDisplayText) \
                                visibility=\(node.visibilityDisplayText) \
                                missing=\(node.isMissing ? "yes" : "no")
                                """
                            )
                        }
                    }
                }
                .listStyle(.plain)
            } else {
                ContentUnavailableView(
                    "No Weather Field Yet",
                    systemImage: "map",
                    description: Text("Fetch NOAA 3x3 Field from Weather Debug first.")
                )
            }
        }
        .padding()
        .navigationTitle("Weather Field Map")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            let hasField = fieldData != nil
            AppLogger.shared.log(category: "MAP", message: "weather field map appeared hasField=\(hasField) slot=\(selectedSlotOffsetMinutes)")
            if let fieldData {
                AppLogger.shared.log(
                    category: "MAP",
                    message: "map boundary updated widthMi=\(Int(fieldData.fieldWidthMiles.rounded())) heightMi=\(Int(fieldData.fieldHeightMiles.rounded()))"
                )
            }
            rebuildAnchorNodes(reason: "appear")
            updateCameraPosition(reason: "appear")
        }
        .onChange(of: selectedSlotOffsetMinutes) { _, newOffset in
            AppLogger.shared.log(category: "MAP", message: "map slot changed slotOffset=\(newOffset)")
            rebuildAnchorNodes(reason: "slot-change")
        }
        .onChange(of: viewModel.latestPacketRevision) { _, newRevision in
            AppLogger.shared.log(category: "MAP", message: "map weather field changed packetRevision=\(newRevision) hasField=\(fieldData != nil)")
            if let fieldData {
                AppLogger.shared.log(
                    category: "MAP",
                    message: "map boundary updated widthMi=\(Int(fieldData.fieldWidthMiles.rounded())) heightMi=\(Int(fieldData.fieldHeightMiles.rounded()))"
                )
            }
            rebuildAnchorNodes(reason: "field-revision")
            updateCameraPosition(reason: "field-revision")
        }
        .sheet(item: $selectedAnchorNode) { node in
            AnchorDetailView(anchor: node)
        }
    }

    private func rebuildAnchorNodes(reason: String) {
        guard let fieldData else {
            renderedAnchorNodes = []
            AppLogger.shared.log(category: "MAP", message: "annotation model rebuilt reason=\(reason) count=0")
            return
        }

        renderedAnchorNodes = fieldData.anchorResults.map { anchorResult in
            let slot = anchorResult.weatherData?.threeSlotModel.slots.first(where: { $0.offsetMinutes == selectedSlotOffsetMinutes })
            let packetSlot = viewModel.latestRegionalSnapshotPacketDebug?
                .anchors
                .first(where: { $0.anchorLabel == anchorResult.anchor.label })?
                .slots
                .first(where: { $0.offsetMinutes == selectedSlotOffsetMinutes })
            return AnchorWeatherNode(
                anchorResult: anchorResult,
                selectedSlotOffsetMinutes: selectedSlotOffsetMinutes,
                slot: slot,
                packetSlot: packetSlot
            )
        }

        AppLogger.shared.log(category: "MAP", message: "annotation model rebuilt reason=\(reason) count=\(renderedAnchorNodes.count)")
    }

    private func updateCameraPosition(reason: String) {
        guard let fieldData else {
            AppLogger.shared.log(category: "MAP", message: "camera update skipped reason=\(reason) missing-field")
            return
        }

        guard mapSize.width > 0, mapSize.height > 0 else {
            AppLogger.shared.log(category: "MAP", message: "camera update skipped reason=\(reason) map-size-zero")
            return
        }

        let allCoordinates = boundaryCoordinates + fieldData.anchorResults.map {
            CLLocationCoordinate2D(latitude: $0.anchor.latitude, longitude: $0.anchor.longitude)
        }

        let latitudes = allCoordinates.map(\.latitude)
        let longitudes = allCoordinates.map(\.longitude)

        guard
            let minLatitude = latitudes.min(),
            let maxLatitude = latitudes.max(),
            let minLongitude = longitudes.min(),
            let maxLongitude = longitudes.max()
        else {
            return
        }

        let latitudeSpan = max((maxLatitude - minLatitude) * 1.25, 0.5)
        let longitudeSpan = max((maxLongitude - minLongitude) * 1.25, 0.5)
        let signature = CameraSignature(
            centerLatitudeE5: Int((fieldData.center.latitude * 100_000).rounded()),
            centerLongitudeE5: Int((fieldData.center.longitude * 100_000).rounded()),
            latitudeSpanE4: Int((latitudeSpan * 10_000).rounded()),
            longitudeSpanE4: Int((longitudeSpan * 10_000).rounded())
        )

        if let lastCameraSignature, lastCameraSignature == signature {
            AppLogger.shared.log(category: "MAP", message: "camera update skipped because unchanged reason=\(reason)")
            return
        }

        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: fieldData.center.latitude,
                longitude: fieldData.center.longitude
            ),
            span: MKCoordinateSpan(latitudeDelta: latitudeSpan, longitudeDelta: longitudeSpan)
        )

        cameraPosition = .region(region)
        lastCameraSignature = signature
        if !hasInitializedCamera {
            hasInitializedCamera = true
            AppLogger.shared.log(
                category: "MAP",
                message: "initial camera applied centerLat=\(fieldData.center.latitude) centerLon=\(fieldData.center.longitude)"
            )
        }
        AppLogger.shared.log(
            category: "MAP",
            message: "map camera updated reason=\(reason) centerLat=\(fieldData.center.latitude) centerLon=\(fieldData.center.longitude) latDelta=\(latitudeSpan) lonDelta=\(longitudeSpan)"
        )
    }
}

private struct CameraSignature: Equatable {
    let centerLatitudeE5: Int
    let centerLongitudeE5: Int
    let latitudeSpanE4: Int
    let longitudeSpanE4: Int
}

private struct MapSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

private struct AnchorWeatherNode: Identifiable {
    let anchorId: String
    let latitude: Double
    let longitude: Double
    let slotOffsetMinutes: Int
    let slotStartDate: Date?
    let slotEndDate: Date?
    let temperatureC: Double?
    let windSpeedKmh: Double?
    let windGustKmh: Double?
    let precipitationProbabilityPercent: Double?
    let precipitationKind: String?
    let precipitationIntensity: String?
    let visibilityMeters: Double?
    let hazardText: String?
    let visibilitySource: String?
    let forecastGridVisibilityMeters: Double?
    let observationVisibilityMeters: Double?
    let observationAgeMinutes: Int?
    let finalPacketVisibilityMeters: UInt16?
    let isMissing: Bool

    var id: String { "\(anchorId)-\(slotOffsetMinutes)" }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var windDisplayText: String {
        guard let windSpeedKmh else {
            return "W--"
        }

        let mph = windSpeedKmh * 0.621371
        return "W\(Int(mph.rounded()))"
    }

    var visibilityDisplayText: String {
        if let finalPacketVisibilityMeters, finalPacketVisibilityMeters > 0 {
            let miles = Double(finalPacketVisibilityMeters) / 1_609.344
            if miles >= 10 {
                return "V\(Int(miles.rounded()))"
            }

            return String(format: "V%.1f", miles)
        }

        return "V--"
    }

    init(
        anchorResult: WeatherFieldAnchorResult,
        selectedSlotOffsetMinutes: Int,
        slot: OnePointWeatherSlot?,
        packetSlot: RegionalSnapshotSlotPacketDebug?
    ) {
        anchorId = anchorResult.anchor.label
        latitude = anchorResult.anchor.latitude
        longitude = anchorResult.anchor.longitude
        slotOffsetMinutes = selectedSlotOffsetMinutes
        slotStartDate = slot?.startDate
        slotEndDate = slot?.endDate
        temperatureC = slot?.temperatureC
        windSpeedKmh = slot?.windSpeedKmh
        windGustKmh = slot?.windGustKmh
        precipitationProbabilityPercent = slot?.precipitationProbabilityPercent
        precipitationKind = packetSlot?.precipitationKind.description
        precipitationIntensity = packetSlot?.precipitationIntensity.description
        visibilityMeters = slot?.visibilityMeters
        hazardText = packetSlot?.hazardFlags.description
        visibilitySource = packetSlot?.visibilitySource
        forecastGridVisibilityMeters = slot?.visibilityMeters
        observationVisibilityMeters = anchorResult.weatherData?.observationVisibility?.normalizedVisibilityMeters
        observationAgeMinutes = anchorResult.weatherData?.observationVisibility?.observationAgeMinutes
        finalPacketVisibilityMeters = packetSlot?.visibilityM
        isMissing = anchorResult.weatherData == nil || slot == nil
    }
}

private struct WeatherFieldAnchorAnnotationView: View {
    let node: AnchorWeatherNode

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(node.anchorId)
                .font(.caption2)
                .fontWeight(.bold)
            Text(node.windDisplayText)
                .font(.caption2)
            Text(node.visibilityDisplayText)
                .font(.caption2)
        }
        .foregroundStyle(node.isMissing ? Color.primary : Color.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(node.isMissing ? Color.gray.opacity(0.35) : Color.blue.opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(node.isMissing ? Color.gray : Color.blue, lineWidth: 1)
        )
    }
}

private struct AnchorDetailView: View {
    let anchor: AnchorWeatherNode

    var body: some View {
        NavigationStack {
            List {
                Section("Anchor") {
                    Text("Anchor ID: \(anchor.anchorId)")
                    Text("Latitude: \(formatCoordinate(anchor.latitude))")
                    Text("Longitude: \(formatCoordinate(anchor.longitude))")
                }

                Section("Slot") {
                    Text("Slot offset: \(anchor.slotOffsetMinutes) min")
                    Text("validTime: \(formatValidTime(start: anchor.slotStartDate, end: anchor.slotEndDate))")
                }

                Section("Weather") {
                    Text("Temperature: \(formatDouble(anchor.temperatureC, suffix: " C"))")
                    Text("Wind speed: \(formatDouble(anchor.windSpeedKmh, suffix: " km/h"))")
                    Text("Wind gust: \(formatDouble(anchor.windGustKmh, suffix: " km/h"))")
                    Text("Precip probability: \(formatDouble(anchor.precipitationProbabilityPercent, suffix: " %"))")
                    Text("Precip type: \(formatText(anchor.precipitationKind))")
                    Text("Visibility: \(formatDouble(anchor.visibilityMeters, suffix: " m"))")
                    Text("Hazards: \(formatText(anchor.hazardText))")
                }

                Section("Visibility Diagnostics") {
                    Text("visibility source: \(formatText(anchor.visibilitySource))")
                    Text("forecast-grid visibility meters: \(formatDouble(anchor.forecastGridVisibilityMeters, suffix: " m"))")
                    Text("observation visibility meters: \(formatDouble(anchor.observationVisibilityMeters, suffix: " m"))")
                    Text("observation age: \(anchor.observationAgeMinutes.map { "\($0) min" } ?? "—")")
                    Text("final packet visibility field: \(anchor.finalPacketVisibilityMeters.map(String.init) ?? "—")")
                }
            }
            .navigationTitle(anchor.anchorId)
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func formatCoordinate(_ value: Double) -> String {
        String(format: "%.5f", value)
    }

    private func formatDouble(_ value: Double?, suffix: String) -> String {
        guard let value else {
            return "—"
        }

        return String(format: "%.2f%@", value, suffix)
    }

    private func formatText(_ value: String?) -> String {
        guard let value, !value.isEmpty else {
            return "—"
        }

        return value
    }

    private func formatValidTime(start: Date?, end: Date?) -> String {
        guard let start, let end else {
            return "—"
        }

        return "\(Self.timeFormatter.string(from: start)) to \(Self.timeFormatter.string(from: end))"
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
}
