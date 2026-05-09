import CoreLocation
import Foundation
import Combine

// Attempt to import the Multiset SDK. Drop MultiSetSDK.xcframework into the
// Xcode project (Embed & Sign) and this branch will activate automatically.
#if canImport(MultiSetSDK)
import MultiSetSDK
#endif

/// Orchestrates multiple spatial localization providers (Multiset VPS → GPS → …).
/// Publishes the best-available pose and provides it for attachment to notes,
/// photos, and generated reports.
@MainActor
final class SpatialLocalizationService: NSObject, ObservableObject {
  @Published var currentPose: SpatialPose?
  @Published var activeSource: SpatialSource = .unknown
  @Published var statusMessage: String = "Idle"

  private let locationService: LocationService

  #if canImport(MultiSetSDK)
  private var multisetInitialized = false
  private var multisetAvailable: Bool { multisetInitialized }
  #else
  private var multisetAvailable: Bool { false }
  #endif

  init(locationService: LocationService) {
    self.locationService = locationService
    super.init()
  }

  /// Start localization. Called at session start.
  func start() {
    // Always start GPS as the baseline
    locationService.requestPermissionAndStart()
    bootstrapInitialPose(source: .gps)

    // Try Multiset if credentials + map code are all configured
    if SettingsManager.shared.isMultisetConfigured {
      startMultiset()
    } else {
      statusMessage = "GPS only (Multiset not configured)"
      activeSource = .gps
    }
  }

  /// Stop all providers. Called at session stop.
  func stop() {
    #if canImport(MultiSetSDK)
    if multisetInitialized {
      // Real SDK call once xcframework is linked:
      // MultiSet.shared.stopLocalization()
      multisetInitialized = false
    }
    #endif
    statusMessage = "Stopped"
    activeSource = .unknown
  }

  // MARK: - GPS Provider

  private func bootstrapInitialPose(source: SpatialSource) {
    guard let coord = locationService.currentCoordinate else { return }
    self.currentPose = SpatialPose(
      source: source,
      confidence: 0.5,
      timestamp: Date(),
      latitude: coord.latitude,
      longitude: coord.longitude,
      altitude: nil,
      heading: nil,
      localX: nil,
      localY: nil,
      localZ: nil,
      mapCode: nil
    )
    self.activeSource = source
  }

  /// Update GPS pose from the LocationService. Called whenever GPS fixes arrive.
  func updateFromGPS() {
    guard activeSource != .multiset else { return }   // Don't downgrade precision
    guard let coord = locationService.currentCoordinate else { return }
    currentPose = SpatialPose(
      source: .gps,
      confidence: 0.5,
      timestamp: Date(),
      latitude: coord.latitude,
      longitude: coord.longitude,
      altitude: nil,
      heading: nil,
      localX: nil,
      localY: nil,
      localZ: nil,
      mapCode: nil
    )
    if activeSource != .gps { activeSource = .gps }
  }

  // MARK: - Multiset VPS Provider

  private func startMultiset() {
    #if canImport(MultiSetSDK)
    statusMessage = "Starting Multiset VPS…"
    NSLog("[Spatial] Initializing Multiset VPS (map: %@)", SettingsManager.shared.multisetMapCode)

    // Real SDK calls (activate once xcframework is linked):
    // let config = MultiSetConfig.default(
    //   clientId: SettingsManager.shared.multisetClientId,
    //   clientSecret: SettingsManager.shared.multisetClientSecret,
    //   mapCode: SettingsManager.shared.multisetMapCode
    // )
    // MultiSet.shared.initialize(config: config, callback: self)
    // MultiSet.shared.localize()

    multisetInitialized = true
    activeSource = .multiset
    statusMessage = "Multiset VPS active"
    #else
    statusMessage = "Multiset SDK not linked — add MultiSetSDK.xcframework"
    activeSource = .gps
    NSLog("[Spatial] Multiset xcframework not found; falling back to GPS")
    #endif
  }

  /// Handle a Multiset localization result. Wired via delegate when SDK is linked.
  fileprivate func handleMultisetSuccess(
    localX: Double, localY: Double, localZ: Double,
    lat: Double?, lon: Double?, heading: Double?,
    confidence: Double
  ) {
    let pose = SpatialPose(
      source: .multiset,
      confidence: confidence,
      timestamp: Date(),
      latitude: lat,
      longitude: lon,
      altitude: nil,
      heading: heading,
      localX: localX,
      localY: localY,
      localZ: localZ,
      mapCode: SettingsManager.shared.multisetMapCode
    )
    Task { @MainActor in
      self.currentPose = pose
      self.activeSource = .multiset
      self.statusMessage = String(format: "Multiset locked (%.0f%%)", confidence * 100)
      NSLog("[Spatial] Multiset pose: %@", pose.summary)
    }
  }

  fileprivate func handleMultisetFailure(_ error: String) {
    Task { @MainActor in
      self.statusMessage = "Multiset lost — using GPS"
      self.activeSource = .gps
      NSLog("[Spatial] Multiset error: %@", error)
    }
  }
}

// MARK: - MultiSet SDK Delegate (only compiled when xcframework is linked)

#if canImport(MultiSetSDK)
// Uncomment and wire once you've verified the Multiset SDK's actual delegate
// protocol names. The method signatures below match their documented patterns.
//
// extension SpatialLocalizationService: MultiSetLocalizationCallback {
//   func onLocalizationSuccess(result: LocalizationResult) {
//     handleMultisetSuccess(
//       localX: Double(result.position.x),
//       localY: Double(result.position.y),
//       localZ: Double(result.position.z),
//       lat: result.latitude,
//       lon: result.longitude,
//       heading: result.heading,
//       confidence: Double(result.confidence ?? 0)
//     )
//   }
//
//   func onLocalizationFailure(error: Error) {
//     handleMultisetFailure(error.localizedDescription)
//   }
// }
#endif
