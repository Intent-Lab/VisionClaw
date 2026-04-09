import Foundation
import XCTest

@testable import CameraAccess

final class ConferenceModeTests: XCTestCase {

  override func tearDown() {
    SettingsManager.shared.resetAll()
    super.tearDown()
  }

  func testConferencePromptUsesFallbackWhenDisabled() {
    let fallback = "custom prompt"

    XCTAssertEqual(
      ConferencePrompts.activeSystemInstruction(conferenceModeEnabled: false, fallbackPrompt: fallback),
      fallback
    )
  }

  func testConferencePromptUsesRelationshipOpsWhenEnabled() {
    XCTAssertEqual(
      ConferencePrompts.activeSystemInstruction(conferenceModeEnabled: true, fallbackPrompt: "custom"),
      ConferencePrompts.relationshipOps
    )
  }

  func testToolDeclarationsExcludeExtractEntityWhenConferenceModeDisabled() {
    let names = ToolDeclarations.allDeclarations(conferenceModeEnabled: false).compactMap {
      $0["name"] as? String
    }

    XCTAssertEqual(names, [ToolDeclarations.executeName])
  }

  func testToolDeclarationsIncludeExtractEntityWhenConferenceModeEnabled() {
    let names = ToolDeclarations.allDeclarations(conferenceModeEnabled: true).compactMap {
      $0["name"] as? String
    }

    XCTAssertEqual(names, [ToolDeclarations.executeName, ToolDeclarations.extractEntityName])
  }

  func testProcessorAcceptsHighConfidenceExtraction() {
    var processor = makeProcessor()

    let result = processor.handle(
      args: [
        "name": "Sarah Chen",
        "company": "Acme AI",
        "role": "VP Engineering",
        "source_type": "badge",
        "confidence": 0.92
      ],
      now: Date(timeIntervalSince1970: 0)
    )

    guard case .accepted(let extraction) = result else {
      return XCTFail("Expected accepted extraction, got \(result)")
    }

    XCTAssertEqual(extraction.name, "Sarah Chen")
    XCTAssertEqual(extraction.company, "Acme AI")
    XCTAssertEqual(extraction.sourceType, .badge)
    XCTAssertEqual(extraction.disposition, .accepted)
  }

  func testProcessorReturnsReviewForMidConfidenceExtraction() {
    var processor = makeProcessor()

    let result = processor.handle(
      args: [
        "name": "Taylor Reed",
        "source_type": "card",
        "confidence": 0.61
      ],
      now: Date(timeIntervalSince1970: 0)
    )

    guard case .review(let extraction) = result else {
      return XCTFail("Expected review extraction, got \(result)")
    }

    XCTAssertEqual(extraction.disposition, .review)
    XCTAssertEqual(extraction.sourceType, .card)
  }

  func testProcessorIgnoresLowConfidenceExtraction() {
    var processor = makeProcessor()

    let result = processor.handle(
      args: [
        "name": "Jamie Park",
        "source_type": "booth",
        "confidence": 0.32
      ],
      now: Date(timeIntervalSince1970: 0)
    )

    guard case .ignoredLowConfidence(let confidence) = result else {
      return XCTFail("Expected low-confidence ignore, got \(result)")
    }

    XCTAssertEqual(confidence, 0.32, accuracy: 0.0001)
  }

  func testProcessorSuppressesDuplicatesWithinCooldown() {
    var processor = makeProcessor()

    let firstResult = processor.handle(
      args: [
        "name": "Morgan Lee",
        "company": "OpenClaw",
        "source_type": "badge",
        "confidence": 0.88
      ],
      now: Date(timeIntervalSince1970: 0)
    )

    guard case .accepted = firstResult else {
      return XCTFail("Expected first extraction to be accepted, got \(firstResult)")
    }

    let secondResult = processor.handle(
      args: [
        "name": "Morgan Lee",
        "company": "OpenClaw",
        "source_type": "badge",
        "confidence": 0.91
      ],
      now: Date(timeIntervalSince1970: 5)
    )

    XCTAssertEqual(secondResult, .ignoredDuplicate)
  }

  private func makeProcessor() -> ConferenceExtractionProcessor {
    ConferenceExtractionProcessor(
      config: ConferenceModeConfig(
        enabled: true,
        acceptedConfidenceMin: 0.70,
        reviewConfidenceMin: 0.50,
        duplicateCooldown: 10
      )
    )
  }
}
