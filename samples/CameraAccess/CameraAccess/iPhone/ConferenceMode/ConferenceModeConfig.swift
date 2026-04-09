import Foundation

struct ConferenceModeConfig: Equatable {
  let enabled: Bool
  let acceptedConfidenceMin: Double
  let reviewConfidenceMin: Double
  let duplicateCooldown: TimeInterval

  static let acceptedConfidenceThreshold = 0.70
  static let reviewConfidenceThreshold = 0.50
  static let duplicateCooldownInterval: TimeInterval = 10

  static var current: ConferenceModeConfig {
    ConferenceModeConfig(
      enabled: SettingsManager.shared.conferenceModeEnabled,
      acceptedConfidenceMin: acceptedConfidenceThreshold,
      reviewConfidenceMin: reviewConfidenceThreshold,
      duplicateCooldown: duplicateCooldownInterval
    )
  }
}
