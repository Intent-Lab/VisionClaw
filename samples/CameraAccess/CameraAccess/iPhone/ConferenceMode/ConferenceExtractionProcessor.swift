import Foundation

enum ConferenceExtractionHandlingResult: Equatable {
  case accepted(ConferenceExtraction)
  case review(ConferenceExtraction)
  case ignoredLowConfidence(Double)
  case ignoredDuplicate
  case invalid(String)
}

struct ConferenceExtractionProcessor {
  private(set) var recentDetections: [String: Date] = [:]
  let config: ConferenceModeConfig

  init(config: ConferenceModeConfig = .current) {
    self.config = config
  }

  mutating func handle(args: [String: Any], now: Date = Date()) -> ConferenceExtractionHandlingResult {
    guard let name = Self.cleanedString(args["name"]), !name.isEmpty else {
      return .invalid("Missing required field: name")
    }

    guard let sourceRaw = Self.cleanedString(args["source_type"]),
          let sourceType = ConferenceSourceType(rawValue: sourceRaw.lowercased()) else {
      return .invalid("Invalid required field: source_type")
    }

    guard let confidence = Self.parseConfidence(args["confidence"]) else {
      return .invalid("Invalid required field: confidence")
    }

    if confidence < config.reviewConfidenceMin {
      return .ignoredLowConfidence(confidence)
    }

    let company = Self.cleanedString(args["company"])
    let role = Self.cleanedString(args["role"])
    let observedText = Self.cleanedString(args["observed_text"])

    pruneDetections(olderThan: now.addingTimeInterval(-config.duplicateCooldown))
    let detectionKey = Self.normalizedKey(name: name, company: company, sourceType: sourceType)
    if let lastSeen = recentDetections[detectionKey],
       now.timeIntervalSince(lastSeen) < config.duplicateCooldown {
      return .ignoredDuplicate
    }

    recentDetections[detectionKey] = now

    let extraction = ConferenceExtraction(
      name: name,
      company: company,
      role: role,
      sourceType: sourceType,
      confidence: confidence,
      observedText: observedText,
      disposition: confidence >= config.acceptedConfidenceMin ? .accepted : .review,
      detectedAt: now
    )

    switch extraction.disposition {
    case .accepted:
      return .accepted(extraction)
    case .review:
      return .review(extraction)
    }
  }

  static func normalizedKey(
    name: String,
    company: String?,
    sourceType: ConferenceSourceType
  ) -> String {
    "\(name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())|\((company ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased())|\(sourceType.rawValue)"
  }

  private mutating func pruneDetections(olderThan cutoff: Date) {
    recentDetections = recentDetections.filter { _, timestamp in
      timestamp >= cutoff
    }
  }

  private static func cleanedString(_ value: Any?) -> String? {
    guard let string = value as? String else { return nil }
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func parseConfidence(_ value: Any?) -> Double? {
    switch value {
    case let number as NSNumber:
      return number.doubleValue
    case let string as String:
      return Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
    default:
      return nil
    }
  }
}
