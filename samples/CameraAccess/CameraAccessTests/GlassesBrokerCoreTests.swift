import CryptoKit
import Foundation
import XCTest

@testable import CameraAccess

final class GlassesBrokerPairingTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  func testStrictV1PairingLinkParsesCanonicalBrokerOffer() throws {
    let link = try makePairingLink()

    let offer = try GlassesBrokerPairingOffer.parse(link, now: now)

    XCTAssertEqual(offer.version, 1)
    XCTAssertEqual(
      offer.brokerID,
      "broker_abcdefghijklmnopqrstuvwxyz0123456789"
    )
    XCTAssertEqual(
      offer.endpoint,
      URL(string: "https://192.168.1.16:38443")!
    )
    XCTAssertEqual(offer.tlsPublicKeyPinSHA256, Data(repeating: 0xaa, count: 32))
    XCTAssertEqual(
      offer.pairingSecret,
      "pairing-secret-value-with-high-entropy-123456"
    )
  }

  func testPairingLinkRejectsUnknownFieldsDuplicatesPaddingAndExpiry() throws {
    let validJSON = try pairingJSON()
    let padded = validJSON.base64URLEncodedString() + "="
    let expiredJSON = try pairingJSON(expiresAt: 1_799_999_999_999)
    let unknownJSON = Data(
      """
      {"brokerID":"broker_abcdefghijklmnopqrstuvwxyz0123456789","endpoint":"https://192.168.1.16:38443","expiresAt":1800000120000,"pairingSecret":"pairing-secret-value-with-high-entropy-123456","routeTarget":"shell","tlsPinSHA256":"\(String(repeating: "a", count: 64))","version":1}
      """.utf8
    )

    let rejected = [
      URL(string: "https://pair?payload=\(validJSON.base64URLEncodedString())")!,
      URL(string: "visionclaw://other?payload=\(validJSON.base64URLEncodedString())")!,
      URL(string: "visionclaw://pair?payload=\(padded)")!,
      URL(
        string: "visionclaw://pair?payload=\(validJSON.base64URLEncodedString())&payload=\(validJSON.base64URLEncodedString())"
      )!,
      URL(string: "visionclaw://pair?payload=\(expiredJSON.base64URLEncodedString())")!,
      URL(string: "visionclaw://pair?payload=\(unknownJSON.base64URLEncodedString())")!,
    ]

    for link in rejected {
      XCTAssertThrowsError(try GlassesBrokerPairingOffer.parse(link, now: now))
    }
  }

  func testPairingLinkRejectsPublicAndHostnameEndpointsForLANOnlyPairing() throws {
    for endpoint in [
      "https://8.8.8.8:38443",
      "https://visionclaw.local:38443",
      "https://172.15.0.1:38443",
      "https://192.169.1.16:38443",
    ] {
      let payload = try pairingJSON(endpoint: endpoint)
      let link = try XCTUnwrap(
        URL(
          string:
            "visionclaw://pair?payload=\(payload.base64URLEncodedString())"
        )
      )
      XCTAssertThrowsError(
        try GlassesBrokerPairingOffer.parse(link, now: now),
        "Expected \(endpoint) to be rejected"
      )
    }
  }

  func testPhoneIdentityAndPairedRecordPersistWithoutPairingSecret() throws {
    let secureStore = TestBrokerSecureStore()
    let firstVault = GlassesBrokerCredentialVault(
      secureStore: secureStore,
      namespace: "tests"
    )
    let firstPublicKey = try firstVault.phonePublicKeyDER()
    let record = GlassesBrokerPairedRecord(
      brokerID: "broker_abcdefghijklmnopqrstuvwxyz0123456789",
      endpoint: URL(string: "https://192.168.1.16:38443")!,
      tlsPublicKeyPinSHA256: Data(repeating: 0xaa, count: 32),
      pairingID: "pairing-1",
      grantedScopes: ["harness:invoke", "harness:read"],
      pairedAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
    try firstVault.savePairedBroker(record)

    let secondVault = GlassesBrokerCredentialVault(
      secureStore: secureStore,
      namespace: "tests"
    )

    XCTAssertEqual(try secondVault.phonePublicKeyDER(), firstPublicKey)
    XCTAssertEqual(try secondVault.pairedBroker(), record)
    let persistedText = secureStore.values.values
      .compactMap { String(data: $0, encoding: .utf8) }
      .joined(separator: "\n")
    XCTAssertFalse(persistedText.contains("pairing-secret"))
  }

  func testCanonicalJSONMatchesBrokerSortedKeyContract() throws {
    let body = GlassesHarnessInvokeRequest(
      clientRequestID: "request-1",
      harnessID: "eva",
      instruction: "List agents"
    )

    XCTAssertEqual(
      String(
        data: try GlassesBrokerCanonicalJSON.encode(body),
        encoding: .utf8
      ),
      #"{"clientRequestID":"request-1","harnessID":"eva","instruction":"List agents"}"#
    )
  }

  private func makePairingLink() throws -> URL {
    let payload = try pairingJSON().base64URLEncodedString()
    return try XCTUnwrap(URL(string: "visionclaw://pair?payload=\(payload)"))
  }

  private func pairingJSON(
    expiresAt: Int64 = 1_800_000_120_000,
    endpoint: String = "https://192.168.1.16:38443"
  ) throws -> Data {
    Data(
      """
      {"brokerID":"broker_abcdefghijklmnopqrstuvwxyz0123456789","endpoint":"\(endpoint)","expiresAt":\(expiresAt),"pairingSecret":"pairing-secret-value-with-high-entropy-123456","tlsPinSHA256":"\(String(repeating: "a", count: 64))","version":1}
      """.utf8
    )
  }
}

final class SecureBrokerTransportTests: XCTestCase {
  func testCertificateAndPublicKeyPinsFailClosedOnAnyMismatch() {
    let certificate = Data("leaf-certificate".utf8)
    let publicKey = Data("subject-public-key-info".utf8)
    let certificatePin = GlassesBrokerTLSPin.certificateSHA256(
      Data(SHA256.hash(data: certificate))
    )
    let publicKeyPin = GlassesBrokerTLSPin.publicKeySHA256(
      Data(SHA256.hash(data: publicKey))
    )

    XCTAssertTrue(
      GlassesBrokerPinValidator.matches(
        pin: certificatePin,
        leafCertificateDER: certificate,
        leafPublicKeyDER: Data("other-key".utf8)
      )
    )
    XCTAssertTrue(
      GlassesBrokerPinValidator.matches(
        pin: publicKeyPin,
        leafCertificateDER: Data("other-certificate".utf8),
        leafPublicKeyDER: publicKey
      )
    )
    XCTAssertFalse(
      GlassesBrokerPinValidator.matches(
        pin: publicKeyPin,
        leafCertificateDER: certificate,
        leafPublicKeyDER: Data("wrong-key".utf8)
      )
    )
  }

  func testDiscoveryPolicyCapsDeduplicatesAndKeepsTXTUntrusted() {
    let raw = (0..<40).map { index in
      BonjourBrokerRawCandidate(
        stableID: "service-\(index % 20)",
        serviceName: "VisionClaw \(index)",
        endpointDescription: "VisionClaw \(index)._visionclaw._tcp.local.",
        brokerIDHint: index == 3
          ? "broker_abcdefghijklmnopqrstuvwxyz0123456789"
          : nil,
        versionHint: "1",
        tlsHint: "1"
      )
    }

    let candidates = BonjourBrokerDiscoveryPolicy.boundedCandidates(
      from: raw,
      limit: 8
    )

    XCTAssertEqual(candidates.count, 8)
    XCTAssertEqual(Set(candidates.map(\.stableID)).count, 8)
    XCTAssertTrue(candidates.allSatisfy { !$0.isAuthenticated })
    XCTAssertTrue(candidates.allSatisfy { !$0.isTrusted })
  }
}

@MainActor
final class GlassesBrokerConnectionTests: XCTestCase {
  func testPairingUsesQRPinAndPersistsOnlySafeBrokerRecord() async throws {
    let store = TestBrokerSecureStore()
    let vault = GlassesBrokerCredentialVault(
      secureStore: store,
      namespace: "pairing-tests"
    )
    let transport = TestSecureBrokerTransport()
    let connection = GlassesBrokerConnection(
      credentialVault: vault,
      transport: transport,
      now: { Date(timeIntervalSince1970: 1_800_000_000) },
      nonce: { Data(repeating: 0x01, count: 18) }
    )
    let offer = try GlassesBrokerPairingOffer.parse(
      try pairingLink(),
      now: Date(timeIntervalSince1970: 1_800_000_000)
    )
    transport.responses = [
      .json(
        status: 201,
        """
        {"brokerID":"broker_abcdefghijklmnopqrstuvwxyz0123456789","grantedScopes":["harness:invoke","harness:read","harness:cancel"],"pairedAt":1800000000000,"pairingID":"pairing-1"}
        """
      ),
    ]

    let record = try await connection.completePairing(
      offer: offer,
      deviceName: "Jaack iPhone"
    )

    XCTAssertEqual(record, try vault.pairedBroker())
    let request = try XCTUnwrap(transport.requests.first)
    XCTAssertEqual(request.url?.path, "/v1/pairing/complete")
    XCTAssertEqual(
      transport.pins.first,
      .publicKeySHA256(Data(repeating: 0xaa, count: 32))
    )
    let body = try XCTUnwrap(request.httpBody)
    let json = try XCTUnwrap(
      JSONSerialization.jsonObject(with: body) as? [String: Any]
    )
    XCTAssertEqual(
      Set(json.keys),
      Set(["deviceName", "pairingSecret", "phonePublicKeyDER"])
    )
    XCTAssertNil(json["routeTarget"])
  }

  func testHarnessInvocationMintsRouteBoundCapabilityThenReturnsImmediately() async throws {
    let fixture = try pairedFixture()
    fixture.transport.responses = [
      .json(status: 201, #"{"capability":"header.payload.signature"}"#),
      .json(
        status: 200,
        #"{"clientRequestID":"request-1","message":"Eva is working on it.","operationID":"operation-1","status":"started"}"#
      ),
    ]

    let started = try await fixture.connection.invokeHarness(
      harnessID: "eva",
      instruction: "List agents",
      clientRequestID: "request-1"
    )

    XCTAssertEqual(started.operationID, "operation-1")
    XCTAssertEqual(started.status, .started)
    XCTAssertEqual(fixture.transport.requests.count, 2)
    XCTAssertEqual(
      fixture.transport.requests[0].url?.path,
      "/v1/capabilities"
    )
    XCTAssertEqual(
      fixture.transport.requests[1].url?.path,
      "/v1/harness/invoke"
    )
    XCTAssertEqual(
      fixture.transport.requests[1].value(
        forHTTPHeaderField: "Authorization"
      ),
      "Bearer header.payload.signature"
    )
    XCTAssertNotEqual(
      fixture.transport.requests[0].value(
        forHTTPHeaderField: "X-VisionClaw-Proof-Nonce"
      ),
      fixture.transport.requests[1].value(
        forHTTPHeaderField: "X-VisionClaw-Proof-Nonce"
      )
    )
    try verifyDeviceProof(
      request: fixture.transport.requests[1],
      publicKeyDER: fixture.publicKeyDER
    )
  }

  func testHarnessPollAndCancelUseOnlyTypedOperationFields() async throws {
    let fixture = try pairedFixture()
    fixture.transport.responses = [
      .json(status: 201, #"{"capability":"capability-for-poll"}"#),
      .json(
        status: 200,
        #"{"error":null,"operationID":"operation-1","response":"Done","sequence":2,"status":"completed"}"#
      ),
      .json(status: 201, #"{"capability":"capability-for-cancel"}"#),
      .json(
        status: 200,
        #"{"operationID":"operation-1","status":"aborted"}"#
      ),
    ]

    let polled = try await fixture.connection.pollHarness(
      operationID: "operation-1",
      afterSequence: 1
    )
    let cancelled = try await fixture.connection.cancelHarness(
      operationID: "operation-1",
      clientRequestID: "cancel-1"
    )

    XCTAssertEqual(polled.response, "Done")
    XCTAssertEqual(cancelled.status, .aborted)
    let pollBody = try XCTUnwrap(fixture.transport.requests[1].httpBody)
    let cancelBody = try XCTUnwrap(fixture.transport.requests[3].httpBody)
    XCTAssertEqual(
      String(data: pollBody, encoding: .utf8),
      #"{"afterSequence":1,"operationID":"operation-1"}"#
    )
    XCTAssertEqual(
      String(data: cancelBody, encoding: .utf8),
      #"{"clientRequestID":"cancel-1","operationID":"operation-1"}"#
    )
    XCTAssertFalse(
      String(data: pollBody + cancelBody, encoding: .utf8)?
        .contains("routeTarget") == true
    )
  }

  func testProtectedRequestFailsBeforeNetworkWhenScopeWasNotGranted() async throws {
    let fixture = try pairedFixture(grantedScopes: ["tasks:list"])

    await XCTAssertThrowsErrorAsync {
      _ = try await fixture.connection.invokeHarness(
        harnessID: "eva",
        instruction: "List agents",
        clientRequestID: "request-1"
      )
    }
    XCTAssertTrue(fixture.transport.requests.isEmpty)
  }

  func testCodexOperationStatusUsesTypedPostAckRouteAndScope() async throws {
    let fixture = try pairedFixture(
      grantedScopes: ["tasks:operation:status"]
    )
    fixture.transport.responses = [
      .json(status: 201, #"{"capability":"capability-for-status"}"#),
      .json(
        status: 200,
        #"{"receipt":{"acceptedAt":1800000000000,"forkedTaskReference":"task-fork","status":"started","turnReference":"turn-1"},"state":"completed"}"#
      ),
    ]

    let status = try await fixture.connection.codexOperationStatus(
      actionID: "action-1",
      clientRequestID: "request-1"
    )

    XCTAssertEqual(status.state, .completed)
    XCTAssertEqual(status.receipt?.turnReference, "turn-1")
    XCTAssertEqual(
      fixture.transport.requests[1].url?.path,
      "/v1/codex/operation-status"
    )
    XCTAssertEqual(
      String(
        data: try XCTUnwrap(fixture.transport.requests[1].httpBody),
        encoding: .utf8
      ),
      #"{"actionID":"action-1","clientRequestID":"request-1"}"#
    )
    let capabilityBody = try XCTUnwrap(
      fixture.transport.requests[0].httpBody
    )
    XCTAssertTrue(
      String(data: capabilityBody, encoding: .utf8)?
        .contains(#""scope":"tasks:operation:status""#) == true
    )
  }

  func testTrustedIPhoneApprovalCommitsExactPrivatePreparedActionOnce() async throws {
    let fixture = try pairedFixture(
      grantedScopes: [
        "tasks:continue",
        "tasks:continue:commit",
        "tasks:operation:status",
      ]
    )
    let bridge = GlassesBrokerCodexBridge(connection: fixture.connection)
    var presentedConfirmation: CodexContinuationConfirmation?
    bridge.confirmationHandler = {
      presentedConfirmation = $0
    }
    fixture.transport.responses = [
      .json(status: 201, #"{"capability":"capability-for-prepare"}"#),
      .json(
        status: 200,
        #"{"actionID":"action-1","clientRequestID":"request-1","confirmationNonce":"private-nonce-1","expiresAt":1800000060000,"taskReference":"task-input-1","taskTitle":"Build the broker","workspace":"VisionClaw"}"#
      ),
      .json(status: 201, #"{"capability":"capability-for-commit"}"#),
      .json(
        status: 200,
        #"{"acceptedAt":1800000000000,"forkedTaskReference":"task-fork-1","status":"started","turnReference":"turn-1"}"#
      ),
      .json(status: 201, #"{"capability":"capability-for-status"}"#),
      .json(
        status: 200,
        #"{"receipt":{"acceptedAt":1800000000000,"forkedTaskReference":"task-fork-1","status":"completed","turnReference":"turn-1"},"state":"completed"}"#
      ),
    ]
    let request = try XCTUnwrap(
      CodexTaskControlRequest(
        operation: .prepareContinue,
        taskReference: "task-input-1",
        instruction: "Implement exactly this full instruction.",
        clientRequestID: "request-1"
      )
    )

    let preparedResult = await bridge.perform(request)

    guard case .success(let modelMessage) = preparedResult else {
      return XCTFail("Prepare should succeed")
    }
    XCTAssertFalse(modelMessage.contains("action-1"))
    XCTAssertFalse(modelMessage.contains("request-1"))
    XCTAssertFalse(modelMessage.contains("private-nonce-1"))
    XCTAssertFalse(modelMessage.contains("commit_continue"))
    let confirmation = try XCTUnwrap(presentedConfirmation)
    XCTAssertEqual(confirmation.taskTitle, "Build the broker")
    XCTAssertEqual(confirmation.workspace, "VisionClaw")
    XCTAssertEqual(confirmation.taskReference, "task-input-1")
    XCTAssertEqual(
      confirmation.instruction,
      "Implement exactly this full instruction."
    )

    guard case .success = await bridge.confirmPendingContinuation(
      confirmationID: confirmation.id,
      nowMilliseconds: 1_800_000_000_000
    ) else {
      return XCTFail("Trusted physical approval should commit")
    }
    guard case .failure = await bridge.confirmPendingContinuation(
      confirmationID: confirmation.id,
      nowMilliseconds: 1_800_000_000_000
    ) else {
      return XCTFail("A consumed physical approval must be one-shot")
    }

    let commits = fixture.transport.requests.filter {
      $0.url?.path == "/v1/codex/commit"
    }
    XCTAssertEqual(commits.count, 1)
    XCTAssertEqual(
      String(
        data: try XCTUnwrap(commits.first?.httpBody),
        encoding: .utf8
      ),
      #"{"actionID":"action-1","clientRequestID":"request-1","confirmationNonce":"private-nonce-1"}"#
    )
    bridge.stopMonitoring()
  }

  func testTrustedCancelClearsPrivateNonceAndCancelsPreparedAction() async throws {
    let fixture = try pairedFixture(
      grantedScopes: [
        "tasks:continue",
        "tasks:cancel",
      ]
    )
    let bridge = GlassesBrokerCodexBridge(connection: fixture.connection)
    var presentedConfirmation: CodexContinuationConfirmation?
    bridge.confirmationHandler = {
      presentedConfirmation = $0
    }
    fixture.transport.responses = [
      .json(status: 201, #"{"capability":"capability-for-prepare"}"#),
      .json(
        status: 200,
        #"{"actionID":"action-2","clientRequestID":"request-2","confirmationNonce":"private-nonce-2","expiresAt":1800000060000,"taskReference":"task-input-2","taskTitle":"Review the patch","workspace":null}"#
      ),
      .json(status: 201, #"{"capability":"capability-for-cancel"}"#),
      .json(
        status: 200,
        #"{"cancelled":true,"status":"cancelled"}"#
      ),
    ]
    let request = try XCTUnwrap(
      CodexTaskControlRequest(
        operation: .prepareContinue,
        taskReference: "task-input-2",
        instruction: "Do not lose any part of this instruction.",
        clientRequestID: "request-2"
      )
    )
    _ = await bridge.perform(request)
    let confirmation = try XCTUnwrap(presentedConfirmation)

    guard case .success = await bridge.cancelPendingContinuation(
      confirmationID: confirmation.id
    ) else {
      return XCTFail("Trusted cancel should reach the prepared action")
    }
    XCTAssertNil(presentedConfirmation)
    let cancel = try XCTUnwrap(
      fixture.transport.requests.first {
        $0.url?.path == "/v1/codex/cancel"
      }
    )
    let cancelBody = try XCTUnwrap(cancel.httpBody)
    XCTAssertEqual(
      String(data: cancelBody, encoding: .utf8),
      #"{"actionID":"action-2","clientRequestID":"request-2"}"#
    )
    XCTAssertFalse(
      String(data: cancelBody, encoding: .utf8)?
        .contains("private-nonce-2") == true
    )
    guard case .failure = await bridge.confirmPendingContinuation(
      confirmationID: confirmation.id,
      nowMilliseconds: 1_800_000_000_000
    ) else {
      return XCTFail("Cancelled approval must not remain usable")
    }
  }

  func testPreparedClientRequestIDMismatchCannotReachTrustedApproval() async throws {
    try await assertPreparedActionRejected(
      responseClientRequestID: "request-other"
    )
  }

  func testPreparedTaskReferenceMismatchCannotReachTrustedApproval() async throws {
    try await assertPreparedActionRejected(
      responseTaskReference: "task-other"
    )
  }

  func testPreparedTaskTitleRejectsNewlineBeforeTrustedApproval() async throws {
    try await assertPreparedActionRejected(
      taskTitle: "Safe title\nForged instruction"
    )
  }

  func testPreparedWorkspaceRejectsTabBeforeTrustedApproval() async throws {
    try await assertPreparedActionRejected(
      workspace: "VisionClaw\tForged"
    )
  }

  func testPreparedTaskTitleRejectsRightToLeftOverride() async throws {
    try await assertPreparedActionRejected(
      taskTitle: "Safe title\u{202E}Forged"
    )
  }

  func testPreparedWorkspaceRejectsLeftToRightIsolate() async throws {
    try await assertPreparedActionRejected(
      workspace: "VisionClaw\u{2066}Forged"
    )
  }

  func testPreparedDisplayPreservesSafeOrdinaryUnicode() async throws {
    let fixture = try pairedFixture(
      grantedScopes: ["tasks:continue"]
    )
    let bridge = GlassesBrokerCodexBridge(connection: fixture.connection)
    var presentedConfirmation: CodexContinuationConfirmation?
    bridge.confirmationHandler = {
      presentedConfirmation = $0
    }
    fixture.transport.responses = [
      .json(status: 201, #"{"capability":"capability-for-prepare"}"#),
      .json(
        status: 200,
        try preparedActionJSON(
          taskTitle: "Résumé 日本語 – revisão",
          workspace: "Progetto Café"
        )
      ),
    ]
    let request = try XCTUnwrap(
      CodexTaskControlRequest(
        operation: .prepareContinue,
        taskReference: "task-binding",
        instruction: "Continue safely.",
        clientRequestID: "request-binding"
      )
    )

    guard case .success = await bridge.perform(request) else {
      return XCTFail("Safe ordinary Unicode should reach trusted approval")
    }
    let confirmation = try XCTUnwrap(presentedConfirmation)
    XCTAssertEqual(confirmation.taskTitle, "Résumé 日本語 – revisão")
    XCTAssertEqual(confirmation.workspace, "Progetto Café")
    bridge.stopMonitoring()
  }

  func testAuthenticatedStatusUsesPinnedProofOnlyAndTwoSecondDeadline() async throws {
    let fixture = try pairedFixture()
    fixture.transport.responses = [
      .json(
        status: 200,
        #"{"brokerID":"broker_abcdefghijklmnopqrstuvwxyz0123456789","ready":true,"version":"0.1.0"}"#
      ),
    ]

    let status = try await fixture.connection.checkPairedStatus()

    XCTAssertTrue(status.ready)
    XCTAssertEqual(fixture.transport.requests.count, 1)
    let request = try XCTUnwrap(fixture.transport.requests.first)
    XCTAssertEqual(request.url?.path, "/v1/session/status")
    XCTAssertEqual(request.timeoutInterval, 2)
    XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    XCTAssertEqual(String(data: request.httpBody ?? Data(), encoding: .utf8), "{}")
    try verifyDeviceProof(
      request: request,
      publicKeyDER: fixture.publicKeyDER
    )
  }

  func testConnectionModelDistinguishesReachableOfflineAndUnderScopedPairing() async throws {
    let reachableFixture = try pairedFixture()
    let reachableModel = GlassesBrokerConnectionModel(
      credentialVault: reachableFixture.vault,
      connection: reachableFixture.connection
    )
    reachableFixture.transport.responses = [
      .json(
        status: 200,
        #"{"brokerID":"broker_abcdefghijklmnopqrstuvwxyz0123456789","ready":true,"version":"0.1.0"}"#
      ),
    ]
    await reachableModel.refreshReachability()
    guard case .reachable = reachableModel.state else {
      return XCTFail("Expected authenticated reachable state")
    }
    XCTAssertNotNil(reachableModel.routingSnapshot().harnessBridge)

    let offlineFixture = try pairedFixture()
    let offlineModel = GlassesBrokerConnectionModel(
      credentialVault: offlineFixture.vault,
      connection: offlineFixture.connection
    )
    offlineFixture.transport.error = URLError(.timedOut)
    await offlineModel.refreshReachability()
    guard case .pairedOffline = offlineModel.state else {
      return XCTFail("Expected explicit paired-offline state")
    }
    let offlineSnapshot = offlineModel.routingSnapshot()
    XCTAssertTrue(offlineSnapshot.namedRoutingEnabled)
    XCTAssertNil(offlineSnapshot.harnessBridge)
    XCTAssertTrue(
      offlineSnapshot.harnessUnavailableReason?.contains("offline") == true
    )

    let underScopedFixture = try pairedFixture(
      grantedScopes: ["tasks:list"]
    )
    let underScopedModel = GlassesBrokerConnectionModel(
      credentialVault: underScopedFixture.vault,
      connection: underScopedFixture.connection
    )
    await underScopedModel.refreshReachability()
    guard case .unauthorized = underScopedModel.state else {
      return XCTFail("Expected explicit unauthorized state")
    }
    XCTAssertTrue(underScopedFixture.transport.requests.isEmpty)
    XCTAssertTrue(underScopedModel.routingSnapshot().namedRoutingEnabled)
    XCTAssertNil(underScopedModel.routingSnapshot().harnessBridge)
  }

  func testPairingDeepLinkOnlyStagesTrustedDetailsUntilPairButton() async throws {
    let store = TestBrokerSecureStore()
    let vault = GlassesBrokerCredentialVault(
      secureStore: store,
      namespace: "staged-pairing-tests"
    )
    let transport = TestSecureBrokerTransport()
    let connection = GlassesBrokerConnection(
      credentialVault: vault,
      transport: transport
    )
    let model = GlassesBrokerConnectionModel(
      credentialVault: vault,
      connection: connection
    )
    transport.responses = [
      .json(
        status: 201,
        #"{"brokerID":"broker_abcdefghijklmnopqrstuvwxyz0123456789","grantedScopes":["harness:invoke","harness:read"],"pairedAt":1800000000000,"pairingID":"pairing-1"}"#
      ),
    ]

    await model.handlePairingLink(
      try pairingLink(
        expiresAt: Int64(
          Date().addingTimeInterval(60).timeIntervalSince1970 * 1_000
        )
      )
    )

    XCTAssertTrue(transport.requests.isEmpty)
    XCTAssertNil(try vault.pairedBroker())
    let confirmation = try XCTUnwrap(model.pendingPairingConfirmation)
    XCTAssertEqual(confirmation.privateMacAddress, "192.168.1.16:38443")
    XCTAssertEqual(confirmation.brokerSuffix, "456789")
    XCTAssertEqual(
      confirmation.tlsFingerprintSHA256,
      Array(repeating: "AA", count: 32).joined(separator: ":")
    )

    await model.confirmPendingPairing(confirmationID: confirmation.id)

    XCTAssertEqual(transport.requests.count, 1)
    XCTAssertNotNil(try vault.pairedBroker())
    XCTAssertNil(model.pendingPairingConfirmation)
  }

  func testCorruptProtectedPairingBlocksLegacyUntilExplicitForget() throws {
    let store = TestBrokerSecureStore()
    let namespace = "corrupt-pairing-tests"
    store.values["\(namespace).paired-broker"] = Data("not-json".utf8)
    let vault = GlassesBrokerCredentialVault(
      secureStore: store,
      namespace: namespace
    )
    let model = GlassesBrokerConnectionModel(credentialVault: vault)

    guard case .blockedPairing = model.state else {
      return XCTFail("Unreadable secure state must be visibly blocked")
    }
    XCTAssertTrue(model.hasStoredPairing)
    let blockedSnapshot = model.routingSnapshot()
    XCTAssertTrue(blockedSnapshot.namedRoutingEnabled)
    XCTAssertNil(blockedSnapshot.harnessBridge)
    XCTAssertTrue(
      blockedSnapshot.harnessUnavailableReason?
        .contains("cannot be used") == true
    )

    model.forgetPairing()

    XCTAssertEqual(model.state, .unpaired)
    XCTAssertFalse(model.hasStoredPairing)
    XCTAssertFalse(model.routingSnapshot().namedRoutingEnabled)
  }

  func testOverlappingReachabilityIgnoresLateFailureFromOlderAttempt() async throws {
    let fixture = try pairedFixture()
    let model = GlassesBrokerConnectionModel(
      credentialVault: fixture.vault,
      connection: fixture.connection
    )
    fixture.transport.responses = [
      .json(status: 403, #"{"error":"pairing revoked"}"#),
      .json(
        status: 200,
        #"{"brokerID":"broker_abcdefghijklmnopqrstuvwxyz0123456789","ready":true,"version":"0.1.0"}"#
      ),
    ]
    fixture.transport.responseDelaysNanoseconds = [
      200_000_000,
      0,
    ]

    let firstRefresh = Task { @MainActor in
      await model.refreshReachability()
    }
    await waitForRequestCount(1, transport: fixture.transport)
    let secondRefresh = Task { @MainActor in
      await model.refreshReachability()
    }

    await secondRefresh.value
    guard case .reachable(let brokerID) = model.state else {
      firstRefresh.cancel()
      return XCTFail("Expected the newest reachability result to win")
    }
    XCTAssertEqual(
      brokerID,
      "broker_abcdefghijklmnopqrstuvwxyz0123456789"
    )
    await firstRefresh.value
    guard case .reachable = model.state else {
      return XCTFail("A stale failure replaced the newer reachable state")
    }
    XCTAssertNotNil(model.routingSnapshot().harnessBridge)
  }

  func testReachabilityResponseAfterForgetCannotRestoreRouting() async throws {
    let fixture = try pairedFixture()
    let model = GlassesBrokerConnectionModel(
      credentialVault: fixture.vault,
      connection: fixture.connection
    )
    fixture.transport.responses = [
      .json(
        status: 200,
        #"{"brokerID":"broker_abcdefghijklmnopqrstuvwxyz0123456789","ready":true,"version":"0.1.0"}"#
      ),
    ]
    fixture.transport.responseDelaysNanoseconds = [200_000_000]

    let refresh = Task { @MainActor in
      await model.refreshReachability()
    }
    await waitForRequestCount(1, transport: fixture.transport)
    model.forgetPairing()
    await refresh.value

    XCTAssertEqual(model.state, .unpaired)
    XCTAssertNil(model.pairedBroker)
    XCTAssertFalse(model.routingSnapshot().namedRoutingEnabled)
    XCTAssertNil(model.routingSnapshot().harnessBridge)
  }

  func testPairingLinkCannotReplaceExistingBrokerWithoutExplicitForget() async throws {
    let store = TestBrokerSecureStore()
    let vault = GlassesBrokerCredentialVault(
      secureStore: store,
      namespace: UUID().uuidString
    )
    let oldRecord = GlassesBrokerPairedRecord(
      brokerID: "broker_abcdefghijklmnopqrstuvwxyz0123456789",
      endpoint: URL(string: "https://192.168.1.16:38443")!,
      tlsPublicKeyPinSHA256: Data(repeating: 0xaa, count: 32),
      pairingID: "pairing-old",
      grantedScopes: ["harness:invoke", "harness:read"],
      pairedAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
    try vault.savePairedBroker(oldRecord)
    let transport = TestSecureBrokerTransport()
    let connection = GlassesBrokerConnection(
      credentialVault: vault,
      transport: transport
    )
    let model = GlassesBrokerConnectionModel(
      credentialVault: vault,
      connection: connection
    )
    let newBrokerID = "broker_9876543210zyxwvutsrqponmlkjihgfedcba"
    await model.handlePairingLink(
      try pairingLink(
        brokerID: newBrokerID,
        expiresAt: Int64(Date().addingTimeInterval(60).timeIntervalSince1970 * 1_000)
      )
    )

    XCTAssertTrue(transport.requests.isEmpty)
    XCTAssertNil(model.pendingPairingConfirmation)
    XCTAssertEqual(model.pairedBroker, oldRecord)
    XCTAssertEqual(try vault.pairedBroker(), oldRecord)
    XCTAssertTrue(model.pairingResultMessage.contains("Forget"))
  }

  private func pairedFixture(
    grantedScopes: Set<String> = [
      "harness:invoke",
      "harness:read",
      "harness:cancel",
    ]
  ) throws -> (
    connection: GlassesBrokerConnection,
    transport: TestSecureBrokerTransport,
    publicKeyDER: Data,
    vault: GlassesBrokerCredentialVault
  ) {
    let store = TestBrokerSecureStore()
    let vault = GlassesBrokerCredentialVault(
      secureStore: store,
      namespace: UUID().uuidString
    )
    let record = GlassesBrokerPairedRecord(
      brokerID: "broker_abcdefghijklmnopqrstuvwxyz0123456789",
      endpoint: URL(string: "https://192.168.1.16:38443")!,
      tlsPublicKeyPinSHA256: Data(repeating: 0xaa, count: 32),
      pairingID: "pairing-1",
      grantedScopes: grantedScopes,
      pairedAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
    try vault.savePairedBroker(record)
    let transport = TestSecureBrokerTransport()
    let nonceSource = TestBrokerNonceSource()
    let connection = GlassesBrokerConnection(
      credentialVault: vault,
      transport: transport,
      now: { Date(timeIntervalSince1970: 1_800_000_000) },
      nonce: { nonceSource.next() }
    )
    return (
      connection,
      transport,
      try vault.phonePublicKeyDER(),
      vault
    )
  }

  private func assertPreparedActionRejected(
    responseClientRequestID: String = "request-binding",
    responseTaskReference: String = "task-binding",
    taskTitle: String = "Build the broker",
    workspace: String? = "VisionClaw",
    file: StaticString = #filePath,
    line: UInt = #line
  ) async throws {
    let fixture = try pairedFixture(
      grantedScopes: ["tasks:continue"]
    )
    let bridge = GlassesBrokerCodexBridge(connection: fixture.connection)
    var presentedConfirmation: CodexContinuationConfirmation?
    bridge.confirmationHandler = {
      presentedConfirmation = $0
    }
    fixture.transport.responses = [
      .json(status: 201, #"{"capability":"capability-for-prepare"}"#),
      .json(
        status: 200,
        try preparedActionJSON(
          clientRequestID: responseClientRequestID,
          taskReference: responseTaskReference,
          taskTitle: taskTitle,
          workspace: workspace
        )
      ),
    ]
    let request = try XCTUnwrap(
      CodexTaskControlRequest(
        operation: .prepareContinue,
        taskReference: "task-binding",
        instruction: "Continue safely.",
        clientRequestID: "request-binding"
      )
    )

    guard case .failure(let message) = await bridge.perform(request) else {
      return XCTFail(
        "Unbound or unsafe prepared data must fail closed",
        file: file,
        line: line
      )
    }
    XCTAssertEqual(
      message,
      GlassesBrokerConnectionError.invalidResponse.localizedDescription,
      file: file,
      line: line
    )
    XCTAssertNil(presentedConfirmation, file: file, line: line)
    XCTAssertFalse(
      fixture.transport.requests.contains {
        $0.url?.path == "/v1/codex/commit"
      },
      file: file,
      line: line
    )
    bridge.stopMonitoring()
  }

  private func preparedActionJSON(
    clientRequestID: String = "request-binding",
    taskReference: String = "task-binding",
    taskTitle: String,
    workspace: String?
  ) throws -> String {
    let workspaceValue: Any
    if let workspace {
      workspaceValue = workspace
    } else {
      workspaceValue = NSNull()
    }
    let data = try JSONSerialization.data(
      withJSONObject: [
        "actionID": "action-binding",
        "clientRequestID": clientRequestID,
        "confirmationNonce": "private-nonce-binding",
        "expiresAt": 1_800_000_060_000,
        "taskReference": taskReference,
        "taskTitle": taskTitle,
        "workspace": workspaceValue,
      ],
      options: [.sortedKeys, .withoutEscapingSlashes]
    )
    return try XCTUnwrap(String(data: data, encoding: .utf8))
  }

  private func pairingLink(
    brokerID: String =
      "broker_abcdefghijklmnopqrstuvwxyz0123456789",
    expiresAt: Int64 = 1_800_000_120_000
  ) throws -> URL {
    let json = Data(
      """
      {"brokerID":"\(brokerID)","endpoint":"https://192.168.1.16:38443","expiresAt":\(expiresAt),"pairingSecret":"pairing-secret-value-with-high-entropy-123456","tlsPinSHA256":"\(String(repeating: "a", count: 64))","version":1}
      """.utf8
    )
    return try XCTUnwrap(
      URL(
        string: "visionclaw://pair?payload=\(json.base64URLEncodedString())"
      )
    )
  }

  private func waitForRequestCount(
    _ expectedCount: Int,
    transport: TestSecureBrokerTransport,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async {
    for _ in 0..<100 {
      if transport.requests.count >= expectedCount {
        return
      }
      await Task.yield()
    }
    XCTFail(
      "Timed out waiting for \(expectedCount) broker request(s)",
      file: file,
      line: line
    )
  }

  private func verifyDeviceProof(
    request: URLRequest,
    publicKeyDER: Data
  ) throws {
    let body = try XCTUnwrap(request.httpBody)
    let pairingID = try XCTUnwrap(
      request.value(forHTTPHeaderField: "X-VisionClaw-Pairing-ID")
    )
    let nonce = try XCTUnwrap(
      request.value(forHTTPHeaderField: "X-VisionClaw-Proof-Nonce")
    )
    let timestamp = try XCTUnwrap(
      Int64(
        try XCTUnwrap(
          request.value(forHTTPHeaderField: "X-VisionClaw-Proof-Timestamp")
        )
      )
    )
    let proof = try XCTUnwrap(
      Data(
        strictBase64URL: try XCTUnwrap(
          request.value(forHTTPHeaderField: "X-VisionClaw-Device-Proof")
        )
      )
    )
    let proofBody = GlassesBrokerDeviceProofRequest(
      bodyHash: Data(SHA256.hash(data: body)).base64URLEncodedString(),
      method: "POST",
      nonce: nonce,
      pairingID: pairingID,
      path: try XCTUnwrap(request.url?.path),
      timestamp: timestamp
    )
    let publicKey = try P256.Signing.PublicKey(derRepresentation: publicKeyDER)
    let signature = try P256.Signing.ECDSASignature(
      derRepresentation: proof
    )

    XCTAssertTrue(
      publicKey.isValidSignature(
        signature,
        for: try GlassesBrokerCanonicalJSON.encode(proofBody)
      )
    )
  }
}

@MainActor
final class EvaSpokenAuthorityTests: XCTestCase {
  func testEvaUsesRecognizedSpeechAndAppOwnedRequestIDInsteadOfModelFields() async {
    let bridge = RecordingScopedHarnessBridge()
    let appRequestID = "vcg_\(String(repeating: "a", count: 32))"
    let router = NamedHarnessRouter(
      registry: .standard(),
      harnessBridge: bridge,
      invocationRequestID: { appRequestID }
    )
    router.recognize(
      transcript: "Eva list the OpenClaw agents in this environment"
    )

    let result = await router.route(
      NamedHarnessRouteRequest(
        targetName: "Eva",
        operation: .execute,
        task: "Model-authored destructive instruction",
        taskReference: nil,
        clientRequestID: "model-authored-request-id"
      )
    )

    guard case .success = result else {
      return XCTFail("A non-empty recognized Eva request should route")
    }
    XCTAssertEqual(bridge.requests.count, 1)
    XCTAssertEqual(
      bridge.requests[0].instruction,
      "list the openclaw agents in this environment"
    )
    XCTAssertEqual(bridge.requests[0].clientRequestID, appRequestID)
    XCTAssertNotEqual(
      bridge.requests[0].instruction,
      "Model-authored destructive instruction"
    )
    XCTAssertNotEqual(
      bridge.requests[0].clientRequestID,
      "model-authored-request-id"
    )
  }

  func testEvaFailsClosedWhenInvocationHasNoSpokenRequest() async {
    let bridge = RecordingScopedHarnessBridge()
    let router = NamedHarnessRouter(
      registry: .standard(),
      harnessBridge: bridge,
      invocationRequestID: {
        "vcg_\(String(repeating: "b", count: 32))"
      }
    )
    router.recognize(transcript: "Eva")

    let result = await router.route(
      NamedHarnessRouteRequest(
        targetName: "Eva",
        operation: .execute,
        task: "Model supplied this task after empty speech",
        taskReference: nil,
        clientRequestID: "model-request"
      )
    )

    guard case .failure(let message) = result else {
      return XCTFail("An empty spoken request must fail closed")
    }
    XCTAssertTrue(message.contains("followed by the request"))
    XCTAssertTrue(message.contains("No action was taken"))
    XCTAssertTrue(bridge.requests.isEmpty)
  }
}

@MainActor
private final class RecordingScopedHarnessBridge:
  ScopedHarnessBridgeTransport
{
  private(set) var requests: [ScopedHarnessInvocationRequest] = []

  func perform(_ request: ScopedHarnessInvocationRequest) async -> ToolResult {
    requests.append(request)
    return .success("accepted")
  }
}

private final class TestBrokerNonceSource {
  private var byte: UInt8 = 0x02

  func next() -> Data {
    defer { byte &+= 1 }
    return Data(repeating: byte, count: 18)
  }
}

private final class TestBrokerSecureStore: GlassesBrokerSecureStoring {
  var values: [String: Data] = [:]

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

private final class TestSecureBrokerTransport: SecureBrokerTransporting {
  struct Response {
    let data: Data
    let status: Int

    static func json(status: Int, _ body: String) -> Response {
      Response(data: Data(body.utf8), status: status)
    }
  }

  var requests: [URLRequest] = []
  var pins: [GlassesBrokerTLSPin] = []
  var responses: [Response] = []
  var responseDelaysNanoseconds: [UInt64] = []
  var error: Error?

  func data(
    for request: URLRequest,
    expectedHost: String,
    pin: GlassesBrokerTLSPin
  ) async throws -> (Data, HTTPURLResponse) {
    requests.append(request)
    pins.append(pin)
    if let error {
      throw error
    }
    let response = responses.removeFirst()
    let delay = responseDelaysNanoseconds.isEmpty
      ? 0
      : responseDelaysNanoseconds.removeFirst()
    if delay > 0 {
      try await Task.sleep(nanoseconds: delay)
    }
    let http = try XCTUnwrap(
      HTTPURLResponse(
        url: try XCTUnwrap(request.url),
        statusCode: response.status,
        httpVersion: "HTTP/1.1",
        headerFields: ["content-type": "application/json"]
      )
    )
    return (response.data, http)
  }
}

private extension Data {
  func base64URLEncodedString() -> String {
    base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  init?(strictBase64URL value: String) {
    guard !value.isEmpty,
          value.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression)
            != nil else {
      return nil
    }
    var encoded = value
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
    guard let decoded = Data(base64Encoded: encoded),
          decoded.base64URLEncodedString() == value else {
      return nil
    }
    self = decoded
  }
}

private func XCTAssertThrowsErrorAsync<T>(
  _ expression: () async throws -> T,
  file: StaticString = #filePath,
  line: UInt = #line
) async {
  do {
    _ = try await expression()
    XCTFail("Expected expression to throw", file: file, line: line)
  } catch {
    // Expected.
  }
}
