import Foundation

enum ConferenceSourceType: String, CaseIterable {
  case badge
  case card
  case booth
  case slide

  var displayName: String {
    rawValue.capitalized
  }
}

enum ConferenceExtractionDisposition: String, Equatable {
  case accepted
  case review

  var displayName: String {
    rawValue.capitalized
  }
}

struct ConferenceExtraction: Equatable {
  let name: String
  let company: String?
  let role: String?
  let sourceType: ConferenceSourceType
  let confidence: Double
  let observedText: String?
  let disposition: ConferenceExtractionDisposition
  let detectedAt: Date

  var confidenceText: String {
    "\(Int((confidence * 100).rounded()))%"
  }

  var summaryText: String {
    [company, role]
      .compactMap { value in
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
      }
      .joined(separator: " / ")
  }
}
