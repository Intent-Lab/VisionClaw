import CoreLocation
import Foundation

class LocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
  @Published var currentCoordinate: CLLocationCoordinate2D?
  @Published var currentAddress: String?
  @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined

  private let manager = CLLocationManager()
  private let geocoder = CLGeocoder()

  override init() {
    super.init()
    manager.delegate = self
    manager.desiredAccuracy = kCLLocationAccuracyBest
    authorizationStatus = manager.authorizationStatus
  }

  func requestPermissionAndStart() {
    switch manager.authorizationStatus {
    case .notDetermined:
      manager.requestWhenInUseAuthorization()
    case .authorizedWhenInUse, .authorizedAlways:
      manager.requestLocation()
    default:
      NSLog("[Location] Authorization denied: %d", manager.authorizationStatus.rawValue)
    }
  }

  func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    guard let location = locations.last else { return }
    currentCoordinate = location.coordinate
    NSLog("[Location] Updated: %.5f, %.5f", location.coordinate.latitude, location.coordinate.longitude)
    geocoder.reverseGeocodeLocation(location) { [weak self] placemarks, error in
      guard let placemark = placemarks?.first else { return }
      let parts = [placemark.subThoroughfare, placemark.thoroughfare, placemark.locality, placemark.administrativeArea].compactMap { $0 }
      let address = parts.joined(separator: " ")
      DispatchQueue.main.async {
        self?.currentAddress = address
        NSLog("[Location] Address: %@", address)
      }
    }
  }

  func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    NSLog("[Location] Error: %@", error.localizedDescription)
  }

  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    authorizationStatus = manager.authorizationStatus
    if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways {
      manager.requestLocation()
    }
  }
}
