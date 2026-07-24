import Foundation
import XCTest

@testable import CameraAccess

@MainActor
final class GlassesSessionShortcutTests: XCTestCase {
  func testGlassesSessionDestinationIsTheDedicatedVisionClawDeepLink() {
    XCTAssertEqual(
      GlassesSessionShortcutDestination.url,
      URL(string: "visionclaw://glasses-session")
    )
    XCTAssertEqual(GlassesSessionShortcutDestination.url.scheme, "visionclaw")
    XCTAssertEqual(GlassesSessionShortcutDestination.url.host, "glasses-session")
  }

  func testOpenGlassesSessionIntentAlwaysHandsOffToForegroundApp() {
    XCTAssertTrue(OpenGlassesSessionIntent.openAppWhenRun)
  }

  func testShortcutRequestStoreIsSingleUse() throws {
    let suiteName = "GlassesSessionShortcutTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    XCTAssertFalse(GlassesSessionShortcutRequestStore.consume(from: defaults))
    GlassesSessionShortcutRequestStore.record(in: defaults)
    XCTAssertTrue(GlassesSessionShortcutRequestStore.consume(from: defaults))
    XCTAssertFalse(GlassesSessionShortcutRequestStore.consume(from: defaults))
  }

  func testGlassesSessionDeepLinkCreatesDedicatedSessionHandoff() async throws {
    let vault = GlassesBrokerCredentialVault(
      secureStore: ShortcutSecureStore(),
      namespace: "shortcut-tests"
    )
    let model = GlassesBrokerConnectionModel(credentialVault: vault)

    XCTAssertNil(model.glassesSessionLaunchRequestID)
    let didHandleDeepLink = await model.handleDeepLink(
      GlassesSessionShortcutDestination.url
    )
    XCTAssertTrue(didHandleDeepLink)
    let requestID = try XCTUnwrap(model.glassesSessionLaunchRequestID)
    XCTAssertTrue(model.consumeGlassesSessionLaunchRequest(requestID))
    XCTAssertNil(model.glassesSessionLaunchRequestID)
    XCTAssertFalse(model.consumeGlassesSessionLaunchRequest(requestID))
  }

  func testStaleConsumerCannotClearANewerGlassesSessionRequest() throws {
    let vault = GlassesBrokerCredentialVault(
      secureStore: ShortcutSecureStore(),
      namespace: "shortcut-tests"
    )
    let model = GlassesBrokerConnectionModel(credentialVault: vault)

    model.requestGlassesSession()
    let firstRequestID = try XCTUnwrap(
      model.glassesSessionLaunchRequestID
    )
    model.requestGlassesSession()
    let secondRequestID = try XCTUnwrap(
      model.glassesSessionLaunchRequestID
    )

    XCTAssertNotEqual(firstRequestID, secondRequestID)
    XCTAssertFalse(
      model.consumeGlassesSessionLaunchRequest(firstRequestID)
    )
    XCTAssertEqual(
      model.glassesSessionLaunchRequestID,
      secondRequestID
    )
    XCTAssertTrue(
      model.consumeGlassesSessionLaunchRequest(secondRequestID)
    )
  }

  func testOldDismissalCannotHideANewerHandoff() {
    let firstRequestID = UUID()
    let secondRequestID = UUID()
    var state = GlassesSessionHandoffPresentationState()

    state.present(requestID: firstRequestID)
    state.present(requestID: secondRequestID)

    XCTAssertFalse(state.dismiss(requestID: firstRequestID))
    XCTAssertTrue(state.isPresented)
    XCTAssertEqual(state.activeRequestID, secondRequestID)
    XCTAssertTrue(state.dismiss(requestID: secondRequestID))
    XCTAssertFalse(state.isPresented)
  }

  func testOnlyOneFocusedGlassesShortcutIsPublished() {
    XCTAssertEqual(VisionClawAppShortcuts.appShortcuts.count, 1)
  }

  func testVisionClawSchemeIsAddedWithoutRemovingDATCallbackScheme() throws {
    let urlTypes = try XCTUnwrap(
      Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes")
        as? [[String: Any]]
    )
    let schemes = urlTypes.flatMap {
      $0["CFBundleURLSchemes"] as? [String] ?? []
    }

    XCTAssertTrue(schemes.contains("visionclaw"))
    XCTAssertTrue(schemes.contains("cameraaccess"))
  }
}

private final class ShortcutSecureStore: GlassesBrokerSecureStoring {
  private var values: [String: Data] = [:]

  func data(for account: String) throws -> Data? {
    values[account]
  }

  func set(_ data: Data, for account: String) throws {
    values[account] = data
  }

  func remove(account: String) throws {
    values.removeValue(forKey: account)
  }
}
