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

    private let slotOffsets = [0, 60, 120]

    private var fieldData: ThreeByThreeWeatherFieldDebugData? {
        viewModel.latestFieldWeatherData
    }

    private var boundaryCoordinates: [CLLocationCoordinate2D] {
        guard let fieldData else {
            return []
        }

        let corners = Block1FieldGeometry.fieldBoundaryCoordinates(center: fieldData.center)
        guard let first = corners.first else {
            return []
        }

        return corners + [first]
    }

    private var annotations: [WeatherFieldMapAnnotation] {
        guard let fieldData else {
            return []
        }

        return fieldData.anchorResults.map { anchorResult in
            let slot = anchorResult.weatherData?.threeSlotModel.slots.first(where: { $0.offsetMinutes == selectedSlotOffsetMinutes })
            return WeatherFieldMapAnnotation(
                anchorResult: anchorResult,
                selectedSlot: slot
            )
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            if let fieldData {
                Text(
                    """
                    Center \(String(format: "%.5f", fieldData.center.latitude)), \
                    \(String(format: "%.5f", fieldData.center.longitude)) \
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

                    ForEach(annotations) { annotation in
                        Annotation(annotation.anchorLabel, coordinate: annotation.coordinate) {
                            WeatherFieldAnchorAnnotationView(annotation: annotation)
                        }
                    }
                }
                .mapStyle(.standard)
                .clipShape(RoundedRectangle(cornerRadius: 12))

                List {
                    Section("Anchor Summary") {
                        ForEach(annotations) { annotation in
                            Text(
                                """
                                \(annotation.anchorLabel) \
                                windMph=\(annotation.windDisplayText) \
                                visibility=\(annotation.visibilityDisplayText) \
                                missing=\(annotation.isMissing ? "yes" : "no")
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
            print("WeatherFieldMapView: appeared hasField=\(fieldData != nil) slotOffsetMin=\(selectedSlotOffsetMinutes)")
            updateCameraPosition()
        }
        .onChange(of: selectedSlotOffsetMinutes) { _, newOffset in
            print("WeatherFieldMapView: selected slot changed slotOffsetMin=\(newOffset)")
        }
        .onChange(of: viewModel.latestPacketRevision) { _, newRevision in
            print("WeatherFieldMapView: weather field changed packetRevision=\(newRevision) hasField=\(fieldData != nil)")
            updateCameraPosition()
        }
    }

    private func updateCameraPosition() {
        guard let fieldData else {
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
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: fieldData.center.latitude,
                longitude: fieldData.center.longitude
            ),
            span: MKCoordinateSpan(latitudeDelta: latitudeSpan, longitudeDelta: longitudeSpan)
        )

        cameraPosition = .region(region)
        print(
            """
            WeatherFieldMapView: camera updated \
            centerLat=\(fieldData.center.latitude) \
            centerLon=\(fieldData.center.longitude) \
            latDelta=\(latitudeSpan) \
            lonDelta=\(longitudeSpan)
            """
        )
    }
}

private struct WeatherFieldMapAnnotation: Identifiable {
    let anchorLabel: String
    let coordinate: CLLocationCoordinate2D
    let windDisplayText: String
    let visibilityDisplayText: String
    let isMissing: Bool

    var id: String { anchorLabel }

    init(anchorResult: WeatherFieldAnchorResult, selectedSlot: OnePointWeatherSlot?) {
        anchorLabel = anchorResult.anchor.label
        coordinate = CLLocationCoordinate2D(
            latitude: anchorResult.anchor.latitude,
            longitude: anchorResult.anchor.longitude
        )

        let isSlotMissing = selectedSlot == nil
        let isAnchorMissing = anchorResult.weatherData == nil
        isMissing = isAnchorMissing || isSlotMissing

        if let windKmh = selectedSlot?.windSpeedKmh {
            let windMph = windKmh * 0.621371
            windDisplayText = "W\(Int(windMph.rounded()))"
        } else {
            windDisplayText = "W--"
        }

        if let visibilityMeters = selectedSlot?.visibilityMeters {
            let visibilityMiles = visibilityMeters / 1_609.344
            if visibilityMiles >= 10 {
                visibilityDisplayText = "V\(Int(visibilityMiles.rounded()))"
            } else {
                visibilityDisplayText = String(format: "V%.1f", visibilityMiles)
            }
        } else {
            visibilityDisplayText = "V--"
        }
    }
}

private struct WeatherFieldAnchorAnnotationView: View {
    let annotation: WeatherFieldMapAnnotation

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(annotation.anchorLabel)
                .font(.caption2)
                .fontWeight(.bold)
            Text(annotation.windDisplayText)
                .font(.caption2)
            Text(annotation.visibilityDisplayText)
                .font(.caption2)
        }
        .foregroundStyle(annotation.isMissing ? Color.primary : Color.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(annotation.isMissing ? Color.gray.opacity(0.35) : Color.blue.opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(annotation.isMissing ? Color.gray : Color.blue, lineWidth: 1)
        )
    }
}
