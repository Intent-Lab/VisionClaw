/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation
import MWDATCore
#if canImport(MWDATMockDevice)
import MWDATMockDevice
#endif
import SwiftUI
import XCTest

@testable import CameraAccess

#if canImport(MWDATMockDevice)
@MainActor
class ViewModelIntegrationTests: XCTestCase {

  private var mockDevice: MockRaybanMeta?
  private var cameraKit: MockCameraKit?

  override func setUp() async throws {
    try await super.setUp()
    try? Wearables.configure()

    // Pair mock device and set up camera kit
    let pairedMockDevice = MockDeviceKit.shared.pairRaybanMeta()
    mockDevice = pairedMockDevice
    cameraKit = pairedMockDevice.getCameraKit()

    // Power on and unfold the device to make it available
    pairedMockDevice.powerOn()
    pairedMockDevice.unfold()

    // Wait for device to be available in Wearables
    try await Task.sleep(nanoseconds: 1_000_000_000)
  }

  override func tearDown() async throws {
    MockDeviceKit.shared.pairedDevices.forEach { mockDevice in
      MockDeviceKit.shared.unpairDevice(mockDevice)
    }
    mockDevice = nil
    cameraKit = nil
    try await super.tearDown()
  }

  // MARK: - Video Streaming Flow Tests

  func testVideoStreamingFlow() async throws {
    guard let camera = cameraKit else {
      XCTFail("Mock device and camera should be available")
      return
    }

    guard let videoURL = Bundle(for: type(of: self)).url(forResource: "plant", withExtension: "mp4") else {
      XCTFail("Could not find resource in test bundle")
      return
    }

    // Setup camera feed
    await camera.setCameraFeed(fileURL: videoURL)

    let viewModel = StreamSessionViewModel(wearables: Wearables.shared)

    // Initially not streaming
    XCTAssertEqual(viewModel.streamingStatus, .stopped)
    XCTAssertFalse(viewModel.isStreaming)
    XCTAssertFalse(viewModel.hasReceivedFirstFrame)
    XCTAssertNil(viewModel.currentVideoFrame)

    // Start streaming session
    await viewModel.handleStartStreaming()

    // Wait for streaming to establish
    try await Task.sleep(nanoseconds: 10_000_000_000)

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
    await camera.setCameraFeed(fileURL: videoURL)
    await camera.setCapturedImage(fileURL: imageURL)

    let viewModel = StreamSessionViewModel(wearables: Wearables.shared)

    // Initially not streaming
    XCTAssertEqual(viewModel.streamingStatus, .stopped)
    XCTAssertFalse(viewModel.isStreaming)
    XCTAssertFalse(viewModel.hasReceivedFirstFrame)
    XCTAssertNil(viewModel.currentVideoFrame)

    // Start streaming session
    await viewModel.handleStartStreaming()

    // Wait for streaming to establish
    try await Task.sleep(nanoseconds: 10_000_000_000)

    // Verify streaming is active and receiving frames
    XCTAssertTrue(viewModel.isStreaming)
    XCTAssertTrue(viewModel.hasReceivedFirstFrame)
    XCTAssertNotNil(viewModel.currentVideoFrame)
    XCTAssertTrue([.streaming, .waiting].contains(viewModel.streamingStatus))

    // Capture photo while streaming
    viewModel.capturePhoto()
    try await Task.sleep(nanoseconds: 10_000_000_000)

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
}
#endif

private final class MutableOpenClawBridgeConfig: OpenClawBridgeConfig {
  var host: String
  var port: Int
  var gatewayToken: String
  var modelOverride: String
  var thinkingOverride: String

  init(
    host: String = "http://unit-test.local",
    port: Int = 443,
    gatewayToken: String = "unit-test-token",
    modelOverride: String = "",
    thinkingOverride: String = ""
  ) {
    self.host = host
    self.port = port
    self.gatewayToken = gatewayToken
    self.modelOverride = modelOverride
    self.thinkingOverride = thinkingOverride
  }
}

private final class MockOpenClawURLProtocol: URLProtocol {
  struct Stub {
    let statusCode: Int
    let body: Data
  }

  private static var stubs: [Stub] = []
  private static var requests: [URLRequest] = []
  private static let lock = NSLock()

  static func reset() {
    lock.lock()
    defer { lock.unlock() }
    stubs.removeAll()
    requests.removeAll()
  }

  static func enqueueJSON(statusCode: Int = 200, assistantContent: String) {
    let bodyObject: [String: Any] = [
      "id": "chatcmpl_test",
      "object": "chat.completion",
      "choices": [
        [
          "message": [
            "role": "assistant",
            "content": assistantContent,
          ],
        ],
      ],
    ]
    let body = try! JSONSerialization.data(withJSONObject: bodyObject)  // swiftlint:disable:this force_try
    lock.lock()
    stubs.append(Stub(statusCode: statusCode, body: body))
    lock.unlock()
  }

  static func recordedMessageContents() -> [String] {
    lock.lock()
    let captured = requests
    lock.unlock()
    return captured.compactMap { request in
      guard let body = requestBody(for: request),
            let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let messages = json["messages"] as? [[String: Any]],
            let last = messages.last,
            let content = last["content"] as? String else {
        return nil
      }
      return content
    }
  }

  private static func requestBody(for request: URLRequest) -> Data? {
    if let body = request.httpBody {
      return body
    }

    guard let stream = request.httpBodyStream else {
      return nil
    }

    stream.open()
    defer { stream.close() }

    var data = Data()
    let bufferSize = 4096
    var buffer = [UInt8](repeating: 0, count: bufferSize)

    while stream.hasBytesAvailable {
      let readCount = stream.read(&buffer, maxLength: bufferSize)
      if readCount < 0 {
        return nil
      }
      if readCount == 0 {
        break
      }
      data.append(buffer, count: readCount)
    }

    return data.isEmpty ? nil : data
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    Self.lock.lock()
    Self.requests.append(request)
    let stub = Self.stubs.isEmpty ? nil : Self.stubs.removeFirst()
    Self.lock.unlock()

    guard let stub else {
      client?.urlProtocol(self, didFailWithError: NSError(
        domain: "MockOpenClawURLProtocol",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "No stub available"]))
      return
    }

    let response = HTTPURLResponse(
      url: request.url ?? URL(string: "http://unit-test.local")!,  // swiftlint:disable:this force_unwrapping
      statusCode: stub.statusCode,
      httpVersion: nil,
      headerFields: ["Content-Type": "application/json"]
    )!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: stub.body)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

@MainActor
final class OpenClawBridgeOverrideTests: XCTestCase {

  override func setUp() {
    super.setUp()
    MockOpenClawURLProtocol.reset()
  }

  override func tearDown() {
    MockOpenClawURLProtocol.reset()
    super.tearDown()
  }

  private func makeBridge(config: MutableOpenClawBridgeConfig) -> OpenClawBridge {
    let sessionConfig = URLSessionConfiguration.ephemeral
    sessionConfig.protocolClasses = [MockOpenClawURLProtocol.self]
    let session = URLSession(configuration: sessionConfig)
    return OpenClawBridge(
      session: session,
      pingSession: session,
      config: config,
      sessionKeyFactory: { "agent:main:test:session" }
    )
  }

  private func unwrapSuccess(_ result: ToolResult, file: StaticString = #filePath, line: UInt = #line) -> String {
    switch result {
    case .success(let value):
      return value
    case .failure(let error):
      XCTFail("Expected success, got failure: \(error)", file: file, line: line)
      return ""
    }
  }

  private func unwrapFailure(_ result: ToolResult, file: StaticString = #filePath, line: UInt = #line) -> String {
    switch result {
    case .success(let value):
      XCTFail("Expected failure, got success: \(value)", file: file, line: line)
      return ""
    case .failure(let error):
      return error
    }
  }

  func testDelegateTaskAppliesInitialModelAndThinkingOverrides() async {
    let config = MutableOpenClawBridgeConfig(
      modelOverride: "openai-codex/gpt-5.3-codex",
      thinkingOverride: "high"
    )
    let bridge = makeBridge(config: config)

    MockOpenClawURLProtocol.enqueueJSON(assistantContent: "model override ok")
    MockOpenClawURLProtocol.enqueueJSON(assistantContent: "thinking override ok")
    MockOpenClawURLProtocol.enqueueJSON(assistantContent: "TASK_OK")

    let result = await bridge.delegateTask(task: "create test note")
    XCTAssertEqual(unwrapSuccess(result), "TASK_OK")
    XCTAssertEqual(
      MockOpenClawURLProtocol.recordedMessageContents(),
      ["/model openai-codex/gpt-5.3-codex", "/think high", "create test note"]
    )
  }

  func testDelegateTaskReappliesChangedOverridesOnLaterTurn() async {
    let config = MutableOpenClawBridgeConfig(
      modelOverride: "openai/gpt-4.1",
      thinkingOverride: "low"
    )
    let bridge = makeBridge(config: config)

    MockOpenClawURLProtocol.enqueueJSON(assistantContent: "model1")
    MockOpenClawURLProtocol.enqueueJSON(assistantContent: "think1")
    MockOpenClawURLProtocol.enqueueJSON(assistantContent: "FIRST_OK")

    let first = await bridge.delegateTask(task: "first task")
    XCTAssertEqual(unwrapSuccess(first), "FIRST_OK")

    config.modelOverride = "anthropic/claude-sonnet-4-5"
    config.thinkingOverride = "medium"

    MockOpenClawURLProtocol.enqueueJSON(assistantContent: "model2")
    MockOpenClawURLProtocol.enqueueJSON(assistantContent: "think2")
    MockOpenClawURLProtocol.enqueueJSON(assistantContent: "SECOND_OK")

    let second = await bridge.delegateTask(task: "second task")
    XCTAssertEqual(unwrapSuccess(second), "SECOND_OK")
    XCTAssertEqual(
      MockOpenClawURLProtocol.recordedMessageContents(),
      [
        "/model openai/gpt-4.1",
        "/think low",
        "first task",
        "/model anthropic/claude-sonnet-4-5",
        "/think medium",
        "second task",
      ]
    )
  }

  func testDelegateTaskClearsRemoteOverridesWhenSettingsBecomeEmpty() async {
    let config = MutableOpenClawBridgeConfig(
      modelOverride: "openai/gpt-4.1",
      thinkingOverride: "high"
    )
    let bridge = makeBridge(config: config)

    MockOpenClawURLProtocol.enqueueJSON(assistantContent: "model set")
    MockOpenClawURLProtocol.enqueueJSON(assistantContent: "think set")
    MockOpenClawURLProtocol.enqueueJSON(assistantContent: "FIRST_OK")

    let first = await bridge.delegateTask(task: "first task")
    XCTAssertEqual(unwrapSuccess(first), "FIRST_OK")

    config.modelOverride = ""
    config.thinkingOverride = ""

    MockOpenClawURLProtocol.enqueueJSON(assistantContent: "model cleared")
    MockOpenClawURLProtocol.enqueueJSON(assistantContent: "thinking cleared")
    MockOpenClawURLProtocol.enqueueJSON(assistantContent: "SECOND_OK")

    let second = await bridge.delegateTask(task: "second task")
    XCTAssertEqual(unwrapSuccess(second), "SECOND_OK")
    XCTAssertEqual(
      MockOpenClawURLProtocol.recordedMessageContents(),
      [
        "/model openai/gpt-4.1",
        "/think high",
        "first task",
        "/model default",
        "/think default",
        "second task",
      ]
    )
  }

  func testDelegateTaskFailsWhenOverrideCommandFails() async {
    let config = MutableOpenClawBridgeConfig(
      modelOverride: "bad/model",
      thinkingOverride: ""
    )
    let bridge = makeBridge(config: config)

    MockOpenClawURLProtocol.enqueueJSON(statusCode: 500, assistantContent: "server error")

    let result = await bridge.delegateTask(task: "should not run")
    let error = unwrapFailure(result)
    XCTAssertTrue(error.contains("HTTP 500"), "Expected HTTP 500 error, got: \(error)")
    XCTAssertEqual(MockOpenClawURLProtocol.recordedMessageContents(), ["/model bad/model"])
  }
}
