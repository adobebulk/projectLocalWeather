//
//  LocationManager.swift
//  WeatherRelay
//
//  Created by Codex on 2026-03-13.
//

import Combine
import CoreLocation
import Foundation

final class LocationManager: NSObject, ObservableObject {
    struct LocationFix {
        let latitude: Double
        let longitude: Double
        let horizontalAccuracy: Double
        let timestamp: Date
    }

    @Published var authorizationStatus: CLAuthorizationStatus
    @Published var currentFix: LocationFix?

    var latestLatitude: Double? { currentFix?.latitude }
    var latestLongitude: Double? { currentFix?.longitude }
    var latestHorizontalAccuracy: Double? { currentFix?.horizontalAccuracy }
    var latestTimestamp: Date? { currentFix?.timestamp }

    var statusText: String {
        switch authorizationStatus {
        case .notDetermined:
            return "Requesting permission"
        case .restricted:
            return "Location restricted"
        case .denied:
            return "Location denied"
        case .authorizedAlways, .authorizedWhenInUse:
            return currentFix == nil ? "Waiting for fix" : "Location ready"
        @unknown default:
            return "Location unknown"
        }
    }

    var hasValidLocation: Bool {
        guard let currentFix else {
            return false
        }

        return currentFix.horizontalAccuracy >= 0
    }

    var canRequestAlwaysAuthorization: Bool {
        authorizationStatus == .authorizedWhenInUse
    }

    private let locationManager = CLLocationManager()

    override init() {
        authorizationStatus = locationManager.authorizationStatus
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.requestWhenInUseAuthorization()
        print("LocationManager: initialized")
    }

    func requestAlwaysAuthorizationIfPossible() {
        guard canRequestAlwaysAuthorization else {
            print("LocationManager: Always authorization request skipped status=\(authorizationStatus.description)")
            return
        }

        print("LocationManager: requesting Always authorization")
        locationManager.requestAlwaysAuthorization()
    }

    private func startUpdatesIfAuthorized() {
        switch authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            locationManager.allowsBackgroundLocationUpdates = authorizationStatus == .authorizedAlways
            print("LocationManager: starting location updates")
            locationManager.startUpdatingLocation()
        case .notDetermined:
            print("LocationManager: waiting for authorization")
        case .restricted, .denied:
            print("LocationManager: location access unavailable")
        @unknown default:
            print("LocationManager: unknown authorization state")
        }
    }
}

extension LocationManager: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        print("LocationManager: authorization changed to \(authorizationStatus.description)")
        startUpdatesIfAuthorized()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else {
            return
        }

        currentFix = LocationFix(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            horizontalAccuracy: location.horizontalAccuracy,
            timestamp: location.timestamp
        )

        print(
            """
            LocationManager: updated location \
            lat=\(location.coordinate.latitude) \
            lon=\(location.coordinate.longitude) \
            accuracy=\(location.horizontalAccuracy) \
            timestamp=\(location.timestamp.timeIntervalSince1970)
            """
        )
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("LocationManager: location update failed error=\(error.localizedDescription)")
    }
}

private extension CLAuthorizationStatus {
    var description: String {
        switch self {
        case .notDetermined:
            return "notDetermined"
        case .restricted:
            return "restricted"
        case .denied:
            return "denied"
        case .authorizedAlways:
            return "authorizedAlways"
        case .authorizedWhenInUse:
            return "authorizedWhenInUse"
        @unknown default:
            return "unknownDefault"
        }
    }
}
