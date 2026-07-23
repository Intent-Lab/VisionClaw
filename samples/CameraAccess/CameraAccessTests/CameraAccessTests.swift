/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation
import MWDATCamera
import MWDATCore
import MWDATMockDevice
import SwiftUI
import XCTest

@testable import CameraAccess

final class MetaWearablesConfigurationTests: XCTestCase {
  func testDefaultBuildUsesMetaDeveloperModeApplicationID() {
    let config = Bundle.main.object(forInfoDictionaryKey: "MWDAT") as? [String: Any]

    XCTAssertEqual(config?["MetaAppID"] as? String, "0")
    XCTAssertNotNil(config?["ClientToken"])
  }

  func testMetaAIAppSchemeCanBeDiscoveredForPermissionFlow() {
    let schemes = Bundle.main.object(
      forInfoDictionaryKey: "LSApplicationQueriesSchemes"
    ) as? [String]

    XCTAssertTrue(schemes?.contains("fb-viewapp") == true)
  }

  func testSDKSupportsCurrentMetaGlassesFamily() {
    XCTAssertTrue(DeviceType.allCases.contains(.metaGlasses))
  }
}

@MainActor
final class WearablesLinkStateTests: XCTestCase {
  func testCameraPermissionRetryOnlyOccursAfterDeviceConnects() {
    XCTAssertFalse(WearablesViewModel.shouldRetryCameraPermission(for: .disconnected))
    XCTAssertFalse(WearablesViewModel.shouldRetryCameraPermission(for: .connecting))
    XCTAssertTrue(WearablesViewModel.shouldRetryCameraPermission(for: .connected))
  }

  func testConnectionStatusExplainsTheActualMetaLinkState() {
    XCTAssertEqual(
      WearablesViewModel.connectionStatus(for: .connecting, deviceName: "Test Glasses"),
      "Test Glasses found — completing Meta connection")
    XCTAssertEqual(
      WearablesViewModel.connectionStatus(for: .disconnected, deviceName: "Test Glasses"),
      "Test Glasses found, but disconnected in Meta AI")
    XCTAssertEqual(
      WearablesViewModel.connectionStatus(for: .connected, deviceName: "Test Glasses"),
      "Test Glasses connected")
  }
}

final class SettingsManagerTests: XCTestCase {
  func testEmptySystemPromptFallsBackToOpenClawRoutingPrompt() {
    let settings = SettingsManager.shared
    let previous = settings.geminiSystemPrompt
    defer { settings.geminiSystemPrompt = previous }

    settings.geminiSystemPrompt = "   \n"

    XCTAssertEqual(settings.geminiSystemPrompt, GeminiConfig.defaultSystemInstruction)
  }

  func testEmptyOpenClawAgentTargetFallsBackToDefaultGatewayAgent() {
    let settings = SettingsManager.shared
    let previous = settings.openClawAgentTarget
    defer { settings.openClawAgentTarget = previous }

    settings.openClawAgentTarget = "   "

    XCTAssertEqual(settings.openClawAgentTarget, "openclaw")
  }

  func testDefaultPromptRoutesOpenClawEnvironmentQuestionsToExecute() {
    let prompt = GeminiConfig.defaultSystemInstruction

    XCTAssertTrue(prompt.contains("OpenClaw is your external system"))
    XCTAssertTrue(prompt.contains("which agents are active"))
    XCTAssertFalse(prompt.contains("NO ability to take actions"))
  }

  func testMandatoryOpenClawHandoffRulesSurviveCustomPrompt() {
    let settings = SettingsManager.shared
    let previous = settings.geminiSystemPrompt
    defer { settings.geminiSystemPrompt = previous }

    settings.geminiSystemPrompt = "Use my custom voice and vocabulary."

    let prompt = GeminiConfig.systemInstruction
    XCTAssertTrue(prompt.contains("exactly one short pending acknowledgement"))
    XCTAssertTrue(prompt.contains("After calling execute, stop speaking"))
    XCTAssertTrue(prompt.contains("Never report success or a result until execute returns"))
  }
}

final class OpenClawEndpointTests: XCTestCase {
  func testLocalNetworkingDoesNotEnableArbitraryLoads() {
    let transportSecurity = Bundle.main.object(
      forInfoDictionaryKey: "NSAppTransportSecurity"
    ) as? [String: Any]

    XCTAssertEqual(transportSecurity?["NSAllowsLocalNetworking"] as? Bool, true)
    XCTAssertNotEqual(transportSecurity?["NSAllowsArbitraryLoads"] as? Bool, true)
  }

  func testHTTPProxyBuildsHTTPAndWebSocketURLs() {
    let endpoint = OpenClawEndpoint(host: "http://visionclaw-gateway.local", port: 8080)

    XCTAssertEqual(endpoint.chatCompletionsURL?.absoluteString,
                   "http://visionclaw-gateway.local:8080/v1/chat/completions")
    XCTAssertEqual(endpoint.webSocketURL?.absoluteString,
                   "ws://visionclaw-gateway.local:8080/")
  }

  func testHTTPSProxyUsesSecureWebSocket() {
    let endpoint = OpenClawEndpoint(host: "https://visionclaw.example", port: 443)

    XCTAssertEqual(endpoint.chatCompletionsURL?.absoluteString,
                   "https://visionclaw.example:443/v1/chat/completions")
    XCTAssertEqual(endpoint.webSocketURL?.absoluteString,
                   "wss://visionclaw.example:443/")
  }

  func testLANEndpointRemainsSupported() {
    let endpoint = OpenClawEndpoint(host: "192.168.1.2", port: 16743)

    XCTAssertEqual(endpoint.chatCompletionsURL?.absoluteString,
                   "http://192.168.1.2:16743/v1/chat/completions")
  }
}

final class OpenClawToolProtocolTests: XCTestCase {
  @MainActor
  func testGlassesSessionsUseFreshOpenClawConversationIDs() {
    let first = OpenClawBridge.makeConversationID()
    let second = OpenClawBridge.makeConversationID()

    XCTAssertTrue(first.hasPrefix("visionclaw-glass-"))
    XCTAssertNotEqual(first, second)
  }

  @MainActor
  func testRequestsUseBackwardCompatibleDefaultAgentWithoutDuplicateHistory() {
    let body = OpenClawBridge.makeRequestBody(
      task: "Count configured agents",
      agentTarget: "openclaw",
      conversationID: "glass-conversation")
    let messages = body["messages"] as? [[String: String]]

    XCTAssertEqual(body["model"] as? String, "openclaw")
    XCTAssertEqual(body["user"] as? String, "glass-conversation")
    XCTAssertEqual(messages, [["role": "user", "content": "Count configured agents"]])
    XCTAssertEqual(body["stream"] as? Bool, false)
  }

  @MainActor
  func testAgentAliasesPassThroughWithoutInventingSessionNamespaces() {
    let aliases = ["openclaw", "openclaw/default", "openclaw/glasses",
                   "openclaw:glasses", "agent:glasses"]

    for alias in aliases {
      let body = OpenClawBridge.makeRequestBody(
        task: "Inspect the environment",
        agentTarget: alias,
        conversationID: "shared-glass-thread")
      XCTAssertEqual(body["model"] as? String, alias)
      XCTAssertEqual(body["user"] as? String, "shared-glass-thread")
    }
  }

  func testExecuteToolWaitsForOpenClawBeforeFinalSpeech() {
    XCTAssertNil(ToolDeclarations.execute["behavior"])
  }

  func testToolAudioGateTracksEveryToolCallWithoutAnAudioDeadline() {
    var gate = ToolAudioGate()

    gate.begin(callIDs: ["first", "second"])
    XCTAssertTrue(gate.hasPendingCalls)

    gate.finish(callID: "first")
    XCTAssertTrue(gate.hasPendingCalls)

    gate.finish(callID: "second")
    XCTAssertFalse(gate.hasPendingCalls)
  }

  func testToolAudioGateReleasesCancelledCallsAndResetsOnSessionStop() {
    var gate = ToolAudioGate()

    gate.begin(callIDs: ["first", "second"])
    XCTAssertFalse(gate.cancel(callIDs: ["first"]))
    XCTAssertTrue(gate.hasPendingCalls)

    XCTAssertTrue(gate.cancel(callIDs: ["second"]))
    XCTAssertFalse(gate.hasPendingCalls)

    gate.begin(callIDs: ["third"])
    gate.reset()
    XCTAssertFalse(gate.hasPendingCalls)
  }

  func testCompletedToolResultDoesNotInterruptSpokenAudio() {
    let response = ToolResult.success("finished").responseValue

    XCTAssertEqual(response["result"] as? String, "finished")
    XCTAssertNil(response["scheduling"])
  }

  @MainActor
  func testMultipleToolResultsShareOneOrderedResponseEnvelope() {
    let first = ToolCallRouter.buildFunctionResponse(
      callId: "first",
      name: "execute",
      result: .success("one"))
    let second = ToolCallRouter.buildFunctionResponse(
      callId: "second",
      name: "execute",
      result: .success("two"))
    let message = ToolCallRouter.buildToolResponse(functionResponses: [first, second])
    let toolResponse = message["toolResponse"] as? [String: Any]
    let responses = toolResponse?["functionResponses"] as? [[String: Any]]

    XCTAssertEqual(responses?.count, 2)
    XCTAssertEqual(responses?.map { $0["id"] as? String }, ["first", "second"])
  }

  @MainActor
  func testCancellingOneToolCallKeepsItsSiblingRunning() async {
    let firstCallStarted = expectation(description: "first call started")
    let responseSent = expectation(description: "remaining response sent")
    var sentResponse: [String: Any]?
    let router = ToolCallRouter(bridge: OpenClawBridge()) { task, _ in
      if task == "first" {
        firstCallStarted.fulfill()
        try? await Task.sleep(nanoseconds: 5_000_000_000)
      }
      return .success("\(task)-result")
    }

    router.handleToolCalls([
      GeminiFunctionCall(id: "first-id", name: "execute", args: ["task": "first"]),
      GeminiFunctionCall(id: "second-id", name: "execute", args: ["task": "second"])
    ]) { response in
      sentResponse = response
      responseSent.fulfill()
    }

    await fulfillment(of: [firstCallStarted], timeout: 1)
    router.cancelToolCalls(ids: ["first-id"])
    await fulfillment(of: [responseSent], timeout: 1)

    let toolResponse = sentResponse?["toolResponse"] as? [String: Any]
    let responses = toolResponse?["functionResponses"] as? [[String: Any]]
    XCTAssertEqual(responses?.map { $0["id"] as? String }, ["second-id"])
    XCTAssertEqual(
      responses?.first?["response"] as? [String: String],
      ["result": "second-result"])
  }

  func testToolResultsAreCappedForGeminiLive() {
    let oversized = String(repeating: "x", count: ToolResult.maxResponseCharacters + 500)
    let response = ToolResult.success(oversized).responseValue
    let result = response["result"] as? String

    XCTAssertNotNil(result)
    XCTAssertLessThanOrEqual(result?.count ?? Int.max, ToolResult.maxResponseCharacters)
    XCTAssertTrue(result?.hasSuffix("[response truncated]") == true)
  }

  @MainActor
  func testOpenClawRequestGateSerializesRequests() async {
    let gate = OpenClawRequestGate()
    var events: [String] = []

    let first = Task { @MainActor in
      await gate.acquire()
      events.append("first-start")
      try? await Task.sleep(nanoseconds: 50_000_000)
      events.append("first-end")
      gate.release()
    }
    try? await Task.sleep(nanoseconds: 5_000_000)
    let second = Task { @MainActor in
      await gate.acquire()
      events.append("second-start")
      gate.release()
    }

    _ = await (first.result, second.result)
    XCTAssertEqual(events, ["first-start", "first-end", "second-start"])
  }
}

final class PlaybackDrainTrackerTests: XCTestCase {
  func testPlaybackRemainsActiveUntilEveryBufferWasPlayed() {
    let tracker = PlaybackDrainTracker()
    let first = tracker.enqueue()
    let second = tracker.enqueue()

    XCTAssertTrue(first.becameActive)
    XCTAssertFalse(second.becameActive)
    XCTAssertTrue(tracker.isActive)
    XCTAssertEqual(tracker.pendingBufferCount, 2)

    XCTAssertFalse(tracker.complete(first.ticket))
    XCTAssertTrue(tracker.isActive)
    XCTAssertEqual(tracker.pendingBufferCount, 1)

    XCTAssertTrue(tracker.complete(second.ticket))
    XCTAssertFalse(tracker.isActive)
    XCTAssertEqual(tracker.pendingBufferCount, 0)
  }

  func testStaleCompletionCannotDrainANewPlaybackGeneration() {
    let tracker = PlaybackDrainTracker()
    let stale = tracker.enqueue()
    tracker.invalidate()
    let current = tracker.enqueue()

    XCTAssertFalse(tracker.complete(stale.ticket))
    XCTAssertTrue(tracker.isActive)
    XCTAssertEqual(tracker.pendingBufferCount, 1)

    XCTAssertTrue(tracker.complete(current.ticket))
    XCTAssertFalse(tracker.isActive)
  }
}

final class GeminiSpeechReliabilityTests: XCTestCase {
  func testRealtimeVoiceActivityCannotInterruptAResponse() {
    XCTAssertEqual(GeminiLiveService.activityHandlingMode, "NO_INTERRUPTION")
  }

  func testProactiveNotificationIsACompleteTextTurn() {
    let message = GeminiLiveService.textTurnMessage("scheduled update")
    let clientContent = message["clientContent"] as? [String: Any]
    let turns = clientContent?["turns"] as? [[String: Any]]
    let parts = turns?.first?["parts"] as? [[String: String]]

    XCTAssertEqual(clientContent?["turnComplete"] as? Bool, true)
    XCTAssertEqual(turns?.first?["role"] as? String, "user")
    XCTAssertEqual(parts?.first?["text"], "scheduled update")
  }
}

final class StreamingPerformanceTests: XCTestCase {
  func testMediumAndHighUseSupportedLowLatencyCaptureCadence() {
    let low = StreamPerformanceProfile.forResolution(.low)
    let medium = StreamPerformanceProfile.forResolution(.medium)
    let high = StreamPerformanceProfile.forResolution(.high)

    XCTAssertEqual(low.videoCodec, .raw)
    XCTAssertEqual(low.frameRate, 24)
    XCTAssertEqual(medium.videoCodec, .raw)
    XCTAssertEqual(medium.frameRate, 7)
    XCTAssertEqual(high.videoCodec, .raw)
    XCTAssertEqual(high.frameRate, 7)
    XCTAssertEqual(StreamPerformanceProfile.aiResolution, .low)
  }

  func testLatestValuePumpKeepsOnlyNewestPendingValue() {
    let firstStarted = expectation(description: "first value started")
    let valuesFinished = expectation(description: "two values finished")
    valuesFinished.expectedFulfillmentCount = 2
    let releaseFirst = DispatchSemaphore(value: 0)
    let valuesLock = NSLock()
    var values: [Int] = []

    let pump = LatestValuePump<Int>(label: "test.latest-value-pump") { value in
      valuesLock.lock()
      values.append(value)
      valuesLock.unlock()

      if value == 1 {
        firstStarted.fulfill()
        releaseFirst.wait()
      }
      valuesFinished.fulfill()
    }

    XCTAssertFalse(pump.submit(1))
    wait(for: [firstStarted], timeout: 1)
    XCTAssertFalse(pump.submit(2))
    XCTAssertTrue(pump.submit(3))
    releaseFirst.signal()
    wait(for: [valuesFinished], timeout: 1)

    valuesLock.lock()
    let capturedValues = values
    valuesLock.unlock()
    XCTAssertEqual(capturedValues, [1, 3])
  }

  func testGeminiVisionSizeIsIndependentOfPreviewResolution() {
    let low = GeminiVideoFramePolicy.targetPixelSize(for: CGSize(width: 360, height: 640))
    let medium = GeminiVideoFramePolicy.targetPixelSize(for: CGSize(width: 504, height: 896))
    let high = GeminiVideoFramePolicy.targetPixelSize(for: CGSize(width: 720, height: 1280))

    XCTAssertEqual(low.width, 360)
    XCTAssertEqual(low.height, 640)
    XCTAssertEqual(medium.width, 360)
    XCTAssertEqual(medium.height, 640)
    XCTAssertEqual(high.width, 360)
    XCTAssertEqual(high.height, 640)
  }
}

final class DeviceSessionStartRecoveryPolicyTests: XCTestCase {
  func testFirstTransientFailureRetriesOnlyWhileGlassesAndOperationRemainCurrent() {
    XCTAssertTrue(DeviceSessionStartRecoveryPolicy.shouldRetry(
      attemptNumber: 1,
      hasActiveDevice: true,
      isOperationCurrent: true,
      failure: .stoppedBeforeReady))
    XCTAssertTrue(DeviceSessionStartRecoveryPolicy.shouldRetry(
      attemptNumber: 1,
      hasActiveDevice: true,
      isOperationCurrent: true,
      failure: .transientDeviceError))
  }

  func testSecondFailureNeverCreatesAThirdSession() {
    XCTAssertFalse(DeviceSessionStartRecoveryPolicy.shouldRetry(
      attemptNumber: 2,
      hasActiveDevice: true,
      isOperationCurrent: true,
      failure: .timedOut))
  }

  func testInactiveGlassesOrSupersededOperationNeverRetries() {
    XCTAssertFalse(DeviceSessionStartRecoveryPolicy.shouldRetry(
      attemptNumber: 1,
      hasActiveDevice: false,
      isOperationCurrent: true,
      failure: .streamUnavailable))
    XCTAssertFalse(DeviceSessionStartRecoveryPolicy.shouldRetry(
      attemptNumber: 1,
      hasActiveDevice: true,
      isOperationCurrent: false,
      failure: .stoppedBeforeReady))
  }

  func testFatalAndCancelledFailuresNeverRetry() {
    XCTAssertFalse(DeviceSessionStartRecoveryPolicy.shouldRetry(
      attemptNumber: 1,
      hasActiveDevice: true,
      isOperationCurrent: true,
      failure: .fatalDeviceError))
    XCTAssertFalse(DeviceSessionStartRecoveryPolicy.shouldRetry(
      attemptNumber: 1,
      hasActiveDevice: true,
      isOperationCurrent: true,
      failure: .cancelled))
  }

  func testPausedStartupRearmsOnlyWhileOverallBudgetRemains() {
    XCTAssertEqual(
      DeviceSessionStartWaitPolicy.timeoutDisposition(
        for: .paused,
        isWaitingForLateError: false,
        hasRemainingOverallBudget: true),
      .rearmWhilePaused)
    XCTAssertEqual(
      DeviceSessionStartWaitPolicy.timeoutDisposition(
        for: .paused,
        isWaitingForLateError: false,
        hasRemainingOverallBudget: false),
      .fail)
  }

  func testStartupOverallBudgetAllowsExactlyOnePauseRearmInterval() {
    XCTAssertEqual(
      DeviceSessionStartWaitPolicy.overallTimeout,
      DeviceSessionStartWaitPolicy.timeoutInterval
        + DeviceSessionStartWaitPolicy.timeoutInterval)
  }

  func testStartedSessionWinsEvenAtOverallDeadline() {
    XCTAssertEqual(
      DeviceSessionStartWaitPolicy.timeoutDisposition(
        for: .started,
        isWaitingForLateError: false,
        hasRemainingOverallBudget: false),
      .ready)
  }

  func testStoppedStartupKeepsLateErrorGraceWithoutDuplicatingIt() {
    XCTAssertEqual(
      DeviceSessionStartWaitPolicy.timeoutDisposition(
        for: .stopped,
        isWaitingForLateError: false,
        hasRemainingOverallBudget: false),
      .beginStoppedErrorGrace)
    XCTAssertEqual(
      DeviceSessionStartWaitPolicy.timeoutDisposition(
        for: .stopped,
        isWaitingForLateError: true,
        hasRemainingOverallBudget: false),
      .awaitStoppedErrorGrace)
  }

  func testPublishedStoppedStateIsRetiredOnlyAfterStartupReleasesOwnership() {
    XCTAssertEqual(
      DeviceSessionPublishedStatePolicy.action(
        for: .stopped,
        isStartingSession: true),
      .none)
    XCTAssertEqual(
      DeviceSessionPublishedStatePolicy.action(
        for: .stopped,
        isStartingSession: false),
      .retireSession)
    XCTAssertEqual(
      DeviceSessionPublishedStatePolicy.action(
        for: .paused,
        isStartingSession: false),
      .showWaiting)
  }
}

@MainActor
class ViewModelIntegrationTests: XCTestCase {

  private var mockDevice: (any MockGlasses)?
  private var cameraKit: MockCameraKit?

  override func setUp() async throws {
    try await super.setUp()
    try? Wearables.configure()
    MockDeviceKit.shared.enable(config: MockDeviceKitConfig())

    // Pair mock device and set up camera kit
    let pairedMockDevice = try MockDeviceKit.shared.pairGlasses(model: .rayBanMeta)
    mockDevice = pairedMockDevice
    cameraKit = pairedMockDevice.services.camera

    // Power on and unfold the device to make it available
    pairedMockDevice.powerOn()
    pairedMockDevice.unfold()

    // Wait for device to be available in Wearables
    try await Task.sleep(nanoseconds: 1_000_000_000)
  }

  override func tearDown() async throws {
    MockDeviceKit.shared.disable()
    mockDevice = nil
    cameraKit = nil
    try await super.tearDown()
  }

  // MARK: - Video Streaming Flow Tests

  func testVideoStreamingFlow() async throws {
    try skipBrokenMetaMockStreamOnIOS265Simulator()

    guard let camera = cameraKit else {
      XCTFail("Mock device and camera should be available")
      return
    }

    guard let videoURL = Bundle(for: type(of: self)).url(forResource: "plant", withExtension: "mp4") else {
      XCTFail("Could not find resource in test bundle")
      return
    }

    // Setup camera feed
    camera.setCameraFeed(fileURL: videoURL)

    let viewModel = StreamSessionViewModel(wearables: Wearables.shared)
    await waitUntil(timeout: 5) { viewModel.hasActiveDevice }
    XCTAssertTrue(viewModel.hasActiveDevice, "Mock glasses did not become active")
    guard viewModel.hasActiveDevice else { return }

    // Initially not streaming
    XCTAssertEqual(viewModel.streamingStatus, .stopped)
    XCTAssertFalse(viewModel.isStreaming)
    XCTAssertFalse(viewModel.hasReceivedFirstFrame)
    XCTAssertNil(viewModel.currentVideoFrame)

    // Start streaming session
    let started = await viewModel.handleStartStreaming()
    XCTAssertTrue(started)

    // Wait for streaming to establish
    await waitUntil(timeout: 10) {
      viewModel.isStreaming && viewModel.hasReceivedFirstFrame && viewModel.currentVideoFrame != nil
    }

    // Verify streaming is active and receiving frames
    XCTAssertTrue(viewModel.isStreaming)
    XCTAssertTrue(viewModel.hasReceivedFirstFrame)
    XCTAssertNotNil(viewModel.currentVideoFrame)
    XCTAssertTrue([.streaming, .waiting].contains(viewModel.streamingStatus))

    // Stop streaming
    await viewModel.stopSession()

    // Wait for session to stop
    try await Task.sleep(nanoseconds: 1_000_000_000)

    // Verify streaming stopped (allow for final states to be stopped or waiting)
    XCTAssertFalse(viewModel.isStreaming)
    XCTAssertTrue([.stopped, .waiting].contains(viewModel.streamingStatus))
  }

  // MARK: - Photo Capture Flow Tests

  func testStreamingAndPhotoCaptureFlow() async throws {
    try skipBrokenMetaMockStreamOnIOS265Simulator()

    guard let camera = cameraKit else {
      XCTFail("Mock device and camera should be available")
      return
    }

    guard let videoURL = Bundle(for: type(of: self)).url(forResource: "plant", withExtension: "mp4") else {
      XCTFail("Could not find resource in test bundle")
      return
    }

    guard let imageURL = Bundle(for: type(of: self)).url(forResource: "plant", withExtension: "png") else {
      XCTFail("Could not find resource in test bundle")
      return
    }

    // Setup camera feed
    camera.setCameraFeed(fileURL: videoURL)
    camera.setCapturedImage(fileURL: imageURL)

    let viewModel = StreamSessionViewModel(wearables: Wearables.shared)
    await waitUntil(timeout: 5) { viewModel.hasActiveDevice }
    XCTAssertTrue(viewModel.hasActiveDevice, "Mock glasses did not become active")
    guard viewModel.hasActiveDevice else { return }

    // Initially not streaming
    XCTAssertEqual(viewModel.streamingStatus, .stopped)
    XCTAssertFalse(viewModel.isStreaming)
    XCTAssertFalse(viewModel.hasReceivedFirstFrame)
    XCTAssertNil(viewModel.currentVideoFrame)

    // Start streaming session
    let started = await viewModel.handleStartStreaming()
    XCTAssertTrue(started)

    // Wait for streaming to establish
    await waitUntil(timeout: 10) {
      viewModel.isStreaming && viewModel.hasReceivedFirstFrame && viewModel.currentVideoFrame != nil
    }

    // Verify streaming is active and receiving frames
    XCTAssertTrue(viewModel.isStreaming)
    XCTAssertTrue(viewModel.hasReceivedFirstFrame)
    XCTAssertNotNil(viewModel.currentVideoFrame)
    XCTAssertTrue([.streaming, .waiting].contains(viewModel.streamingStatus))

    // Capture photo while streaming
    viewModel.capturePhoto()
    await waitUntil(timeout: 10) { viewModel.capturedPhoto != nil }

    // Verify photo captured while maintaining stream (allow for some timing flexibility)
    XCTAssertTrue(viewModel.capturedPhoto != nil)
    XCTAssertTrue(viewModel.showPhotoPreview)
    XCTAssertTrue(viewModel.isStreaming)

    // Dismiss photo and stop streaming
    viewModel.dismissPhotoPreview()
    XCTAssertFalse(viewModel.showPhotoPreview)
    XCTAssertNil(viewModel.capturedPhoto)

    await viewModel.stopSession()
    try await Task.sleep(nanoseconds: 1_000_000_000)

    XCTAssertFalse(viewModel.isStreaming)
    XCTAssertTrue([.stopped, .waiting].contains(viewModel.streamingStatus))
  }

  private func waitUntil(
    timeout: TimeInterval,
    condition: @escaping @MainActor () -> Bool
  ) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
      try? await Task.sleep(nanoseconds: 100_000_000)
    }
  }

  private func skipBrokenMetaMockStreamOnIOS265Simulator() throws {
    #if targetEnvironment(simulator)
    let version = ProcessInfo.processInfo.operatingSystemVersion
    if version.majorVersion == 26, version.minorVersion == 5 {
      throw XCTSkip(
        "Meta DAT 0.7 and 0.8 MockDeviceKit reject stream startup with "
          + "ProtoSerializerError on the iOS 26.5 simulator; verify this flow on glasses."
      )
    }
    #endif
  }
}
