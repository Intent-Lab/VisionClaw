import Foundation
import UIKit

final class GeminiLiveSpotter {
  private weak var api: WorkerAdminAPI?

  struct SpotterRequestItem: Hashable {
    let id: String
    let name: String
    let aiPrompt: String
    let expectedObjects: [String]
    let preconditions: [String]
    let postconditions: [String]
    let skipRisk: String
    let evidenceRequired: Bool
    let validation: String
    let critical: Bool
  }

  struct SpotterMatch: Equatable {
    let id: String
    let matched: Bool
    let confidence: Double
    let reason: String
    let evidenceTimestamp: String
    let threshold: Double
    let autoComplete: Bool
    let advancedToStepIndex: Int?
    let completedSop: Bool
    let evidenceWindowSatisfied: Bool?
    let activeDurationSatisfied: Bool?
    let stableObservations: Int?
    let stableObservationsRequired: Int?
  }

  func configure(api: WorkerAdminAPI?) {
    self.api = api
  }

  func detectVisibleItemMatches(
    image: UIImage,
    items: [SpotterRequestItem],
    sessionID: String?,
    elapsedActiveMs: Int? = nil
  ) async throws -> [SpotterMatch] {
    guard !items.isEmpty else { return [] }
    guard let api, let sessionID, !sessionID.isEmpty else { return [] }
    guard let imagePayload = Self.encodedSpotterImage(image) else { return [] }

    let capturedAt = ISO8601DateFormatter().string(from: Date())

    var matches: [SpotterMatch] = []
    for item in items {
      let response = try await api.requestGeminiSpotter(
        GeminiSpotterRequest(
          sessionID: sessionID,
          stepID: item.id,
          stepTitle: item.name,
          aiPrompt: item.aiPrompt,
          expectedObjects: item.expectedObjects,
          preconditions: item.preconditions,
          postconditions: item.postconditions,
          skipRisk: item.skipRisk,
          evidenceRequired: item.evidenceRequired,
          imageBase64: imagePayload.base64,
          imageMimeType: imagePayload.mimeType,
          capturedAt: capturedAt,
          critical: item.critical,
          allowAIComplete: item.validation.lowercased() == "visual",
          elapsedActiveMs: elapsedActiveMs
        )
      )

      matches.append(
        SpotterMatch(
          id: item.id,
          matched: response.matched,
          confidence: response.confidence,
          reason: response.reason,
          evidenceTimestamp: response.evidenceTimestamp,
          threshold: response.threshold ?? (item.critical ? 0.94 : ((item.evidenceRequired || item.skipRisk == "high") ? 0.9 : 0.88)),
          autoComplete: response.autoComplete,
          advancedToStepIndex: response.advancedToStepIndex,
          completedSop: response.completedSop ?? false,
          evidenceWindowSatisfied: response.evidenceWindowSatisfied,
          activeDurationSatisfied: response.activeDurationSatisfied,
          stableObservations: response.stableObservations,
          stableObservationsRequired: response.stableObservationsRequired
        )
      )
    }
    return matches
  }

  private static func encodedSpotterImage(_ image: UIImage) -> (base64: String, mimeType: String)? {
    let resized = image.resizedForSpotter(maxDimension: 768)
    guard let jpegData = resized.jpegData(compressionQuality: 0.45) else { return nil }
    return (jpegData.base64EncodedString(), "image/jpeg")
  }
}

private extension UIImage {
  func resizedForSpotter(maxDimension: CGFloat) -> UIImage {
    let width = size.width
    let height = size.height
    guard width > 0, height > 0 else { return self }

    let longest = max(width, height)
    guard longest > maxDimension else { return self }

    let scale = maxDimension / longest
    let targetSize = CGSize(width: width * scale, height: height * scale)
    let renderer = UIGraphicsImageRenderer(size: targetSize)
    return renderer.image { _ in
      self.draw(in: CGRect(origin: .zero, size: targetSize))
    }
  }
}
