import CoreLocation
import Foundation

/// Source of a spatial pose fix. Ranked from most precise to least.
enum SpatialSource: String, Codable {
  case multiset      // Sub-5cm VPS via pre-scanned facility map
  case googleGeo     // ARCore Geospatial API (future — outdoor mapped areas)
  case gps           // Phone GPS (fallback, ~5-10m accuracy)
  case unknown

  var displayName: String {
    switch self {
    case .multiset: return "Multiset VPS"
    case .googleGeo: return "Google Geospatial"
    case .gps: return "GPS"
    case .unknown: return "Unknown"
    }
  }

  /// Approximate accuracy in meters. Used for report defensibility labels.
  var accuracyLabel: String {
    switch self {
    case .multiset: return "±5 cm"
    case .googleGeo: return "±1 m"
    case .gps: return "±5-10 m"
    case .unknown: return "unknown"
    }
  }
}

/// A unified pose combining global (WGS-84) and map-local (6-DoF) coordinates.
/// When Multiset is active we populate everything; GPS-only populates lat/lon.
struct SpatialPose: Codable {
  let source: SpatialSource
  let confidence: Double   // 0.0 - 1.0
  let timestamp: Date

  // Global coordinates (WGS-84)
  let latitude: Double?
  let longitude: Double?
  let altitude: Double?
  let heading: Double?

  // Map-local coordinates (only populated for Multiset)
  let localX: Double?
  let localY: Double?
  let localZ: Double?
  let mapCode: String?

  /// Short human-readable summary used in notes and reports.
  var summary: String {
    var parts: [String] = [source.displayName, source.accuracyLabel]
    if let lat = latitude, let lon = longitude {
      parts.append(String(format: "%.5f, %.5f", lat, lon))
    }
    if let x = localX, let y = localY, let z = localZ, let map = mapCode {
      parts.append(String(format: "map:%@ (%.2f, %.2f, %.2f)", map, x, y, z))
    }
    return parts.joined(separator: " | ")
  }
}
