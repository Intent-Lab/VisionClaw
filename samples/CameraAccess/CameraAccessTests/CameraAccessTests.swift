/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation
import MWDATCore
import SwiftUI
import XCTest

@testable import CameraAccess

#if canImport(MWDATMockDevice)
import MWDATMockDevice

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

final class BackendBootstrapDecodingTests: XCTestCase {
  func testBootstrapPayloadAcceptsCloudSQLNumericStringsAndNumericStepDurations() throws {
    let json = """
    {
      "worker": {
        "id": "11111111-1111-1111-1111-111111111111",
        "login_code": "EMBC-0001",
        "display_name": "Lucas Pereira",
        "role": "Kitchen Staff",
        "active": true
      },
      "device": {
        "id": "22222222-2222-4222-8222-222222222222",
        "worker_id": "11111111-1111-1111-1111-111111111111",
        "platform": "ios",
        "device_label": "iPhone"
      },
      "queue": [
        {
          "shift_assignment_id": "33333333-3333-4333-8333-333333333333",
          "worker_id": "11111111-1111-1111-1111-111111111111",
          "package_id": "44444444-4444-4444-8444-444444444444",
          "package_title": "Meal Prep",
          "package_version": "2",
          "package_run_id": "55555555-5555-4555-8555-555555555555",
          "sop_id": "66666666-6666-4666-8666-666666666666",
          "sop_title": "Burger Assembly",
          "sop_version": "1",
          "sort_order": "1",
          "required": "true",
          "active": true,
          "source_type": "package",
          "steps": [
            {
              "id": "step-1",
              "title": "Prepare the bun",
              "duration": 15,
              "validation": "visual",
              "allowManualComplete": false
            },
            {
              "index": 1,
              "title": "Record temperature log",
              "instruction": "Read the temperature logger display.",
              "requires_photo": false
            }
          ]
        }
      ],
      "assigned_packages": [],
      "worker_session_token": "worker-token",
      "worker_session_expires_at": "2026-05-31T14:43:20.929Z"
    }
    """

    let payload = try JSONDecoder().decode(BootstrapPayload.self, from: Data(json.utf8))

    XCTAssertEqual(payload.worker.loginCode, "EMBC-0001")
    XCTAssertEqual(payload.queue.first?.sortOrder, 1)
    XCTAssertEqual(payload.queue.first?.packageVersion, 2)
    XCTAssertEqual(payload.queue.first?.steps.first?.duration, "15")
    XCTAssertEqual(payload.queue.first?.steps.last?.description, "Read the temperature logger display.")
    XCTAssertEqual(payload.workerSessionToken, "worker-token")
  }

  func testExecutionEventDecodesCloudSQLUuidResponse() throws {
    let json = """
    {
      "id": "bb81da90-9e5e-491e-ba02-0c91730b35b9",
      "session_id": "0089c81d-e79f-407f-a235-a1b84a535c9c",
      "event_type": "step_complete",
      "payload": {
        "source": "vision",
        "checked": true,
        "step_index": 0
      },
      "created_at": "2026-05-31T02:57:53.933Z",
      "workspace_id": "00000000-0000-4000-8000-000000000001"
    }
    """

    let event = try JSONDecoder().decode(BackendExecutionEvent.self, from: Data(json.utf8))

    XCTAssertEqual(event.id, "bb81da90-9e5e-491e-ba02-0c91730b35b9")
    XCTAssertEqual(event.sessionID, "0089c81d-e79f-407f-a235-a1b84a535c9c")
    XCTAssertEqual(event.eventType, "step_complete")
  }
}

private final class RequestCaptureURLProtocol: URLProtocol {
  static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

  override class func canInit(with request: URLRequest) -> Bool {
    true
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    guard let handler = Self.handler else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }

    do {
      let (response, data) = try handler(request)
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }

  override func stopLoading() {}
}

private struct WorkerUploadTargetRequestCapture: Equatable {
  let sessionID: String
  let assetType: String
  let filename: String
  let contentType: String
  let byteSize: Int
  let source: String?
}

private struct WorkerAdminAPISnapshot {
  let heartbeats: [WorkerLiveHeartbeatRequest]
  let uploadTargetRequests: [WorkerUploadTargetRequestCapture]
  let uploadCalls: [(assetID: String, byteSize: Int, contentType: String)]
  let finalizeRequests: [WorkerMediaFinalizeRequest]
  let telemetryBatches: [WorkerTelemetryBatch]
  let liveTokenRequests: [(model: String?, sessionID: String?)]
  let spotterRequests: [GeminiSpotterRequest]
}

private func requestBodyData(from request: URLRequest) -> Data? {
  if let body = request.httpBody {
    return body
  }

  guard let stream = request.httpBodyStream else { return nil }
  stream.open()
  defer { stream.close() }

  let bufferSize = 1024
  let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
  defer { buffer.deallocate() }

  var data = Data()
  while stream.hasBytesAvailable {
    let bytesRead = stream.read(buffer, maxLength: bufferSize)
    if bytesRead < 0 {
      return nil
    }
    if bytesRead == 0 {
      break
    }
    data.append(buffer, count: bytesRead)
  }

  return data
}

private final class WorkerAdminAPIMock: WorkerAdminAPI, @unchecked Sendable {
  private let lock = NSLock()

  var heartbeatErrors: [Error] = []
  var uploadTargetErrors: [Error] = []
  var uploadErrors: [Error] = []
  var finalizeErrors: [Error] = []
  var telemetryErrors: [Error] = []
  var liveTokenErrors: [Error] = []
  var spotterErrors: [Error] = []
  var uploadTargetResponses: [WorkerMediaUploadTarget] = []
  var liveTokenResponses: [GeminiLiveTokenResponse] = []
  var spotterResponses: [GeminiSpotterResponse] = []
  var onFinalizeAttempt: ((WorkerMediaFinalizeRequest) -> Void)?

  private var recordedHeartbeats: [WorkerLiveHeartbeatRequest] = []
  private var recordedUploadTargetRequests: [WorkerUploadTargetRequestCapture] = []
  private var recordedUploadCalls: [(assetID: String, byteSize: Int, contentType: String)] = []
  private var recordedFinalizeRequests: [WorkerMediaFinalizeRequest] = []
  private var recordedTelemetryBatches: [WorkerTelemetryBatch] = []
  private var recordedLiveTokenRequests: [(model: String?, sessionID: String?)] = []
  private var recordedSpotterRequests: [GeminiSpotterRequest] = []

  func sendWorkerLiveHeartbeat(_ heartbeat: WorkerLiveHeartbeatRequest) async throws -> WorkerLiveHeartbeatResponse {
    let queuedError = lock.withLock { () -> Error? in
      recordedHeartbeats.append(heartbeat)
      return heartbeatErrors.isEmpty ? nil : heartbeatErrors.removeFirst()
    }

    if let queuedError {
      throw queuedError
    }

    return WorkerLiveHeartbeatResponse(
      sessionID: heartbeat.sessionID,
      updatedAt: "2026-05-30T18:31:00.000Z",
      isFreshLiveSession: true,
      webrtcRoomCode: heartbeat.webrtcRoomCode,
      supportMode: heartbeat.helpRequested ? "handoff_requested" : "ai",
      aiSessionStatus: heartbeat.helpRequested ? "paused" : "active",
      humanSupportStatus: heartbeat.helpRequested ? "ringing" : "none",
      shouldOpenLiveRoom: false
    )
  }

  func requestWorkerMediaUploadTarget(
    sessionID: String,
    assetType: String,
    filename: String,
    contentType: String,
    byteSize: Int,
    source: String?
  ) async throws -> WorkerMediaUploadTarget {
    let (queuedError, response) = lock.withLock { () -> (Error?, WorkerMediaUploadTarget) in
      recordedUploadTargetRequests.append(
        WorkerUploadTargetRequestCapture(
          sessionID: sessionID,
          assetType: assetType,
          filename: filename,
          contentType: contentType,
          byteSize: byteSize,
          source: source
        )
      )
      let queuedError = uploadTargetErrors.isEmpty ? nil : uploadTargetErrors.removeFirst()
      let response: WorkerMediaUploadTarget
      if uploadTargetResponses.isEmpty {
        let index = recordedUploadTargetRequests.count
        response = WorkerMediaUploadTarget(
          assetID: "\(assetType)-asset-\(index)",
          bucket: "\(assetType)-bucket",
          path: "sessions/\(sessionID)/\(filename)",
          uploadURL: "https://upload.example/\(assetType)-\(index)"
        )
      } else {
        response = uploadTargetResponses.removeFirst()
      }
      return (queuedError, response)
    }

    if let queuedError {
      throw queuedError
    }
    return response
  }

  func finalizeWorkerMediaUpload(_ finalize: WorkerMediaFinalizeRequest) async throws {
    let (queuedError, finalizeHandler) = lock.withLock { () -> (Error?, ((WorkerMediaFinalizeRequest) -> Void)?) in
      recordedFinalizeRequests.append(finalize)
      let queuedError = finalizeErrors.isEmpty ? nil : finalizeErrors.removeFirst()
      return (queuedError, onFinalizeAttempt)
    }

    finalizeHandler?(finalize)

    if let queuedError {
      throw queuedError
    }
  }

  func uploadBinary(
    to target: WorkerMediaUploadTarget,
    data: Data,
    contentType: String
  ) async throws {
    let queuedError = lock.withLock { () -> Error? in
      recordedUploadCalls.append((assetID: target.assetID, byteSize: data.count, contentType: contentType))
      return uploadErrors.isEmpty ? nil : uploadErrors.removeFirst()
    }

    if let queuedError {
      throw queuedError
    }
  }

  func sendWorkerTelemetryBatch(_ batch: WorkerTelemetryBatch) async throws {
    let queuedError = lock.withLock { () -> Error? in
      recordedTelemetryBatches.append(batch)
      return telemetryErrors.isEmpty ? nil : telemetryErrors.removeFirst()
    }

    if let queuedError {
      throw queuedError
    }
  }

  func requestGeminiLiveToken(
    model: String?,
    sessionID: String?
  ) async throws -> GeminiLiveTokenResponse {
    let (queuedError, response) = lock.withLock { () -> (Error?, GeminiLiveTokenResponse) in
      recordedLiveTokenRequests.append((model: model, sessionID: sessionID))
      let queuedError = liveTokenErrors.isEmpty ? nil : liveTokenErrors.removeFirst()
      let response = liveTokenResponses.isEmpty
        ? GeminiLiveTokenResponse(
            token: "ephemeral-token",
            expiresAt: "2026-05-30T19:00:00.000Z",
            newSessionExpiresAt: "2026-05-30T18:31:00.000Z",
            model: model ?? GeminiConfig.model,
            websocketBaseURL: GeminiConfig.ephemeralTokenWebsocketBaseURL,
            queryParameterName: "access_token",
            systemInstruction: "Server-built checklist instruction.",
            runtimeContext: nil,
            diagnosticsID: "test-diagnostics",
            provider: "gemini"
          )
        : liveTokenResponses.removeFirst()
      return (queuedError, response)
    }

    if let queuedError {
      throw queuedError
    }
    return response
  }

  func requestGeminiSpotter(_ request: GeminiSpotterRequest) async throws -> GeminiSpotterResponse {
    let (queuedError, response) = lock.withLock { () -> (Error?, GeminiSpotterResponse) in
      recordedSpotterRequests.append(request)
      let queuedError = spotterErrors.isEmpty ? nil : spotterErrors.removeFirst()
      let response = spotterResponses.isEmpty
        ? GeminiSpotterResponse(
            matched: true,
            confidence: 0.93,
            reason: "Clear visual evidence.",
	            evidenceTimestamp: request.capturedAt,
	            threshold: 0.88,
	            model: "gemini-3.5-flash",
	            autoComplete: true,
	            modelAutoComplete: nil,
	            evidenceWindowSatisfied: nil,
	            activeDurationSatisfied: nil,
	            elapsedActiveMs: nil,
	            minActiveSeconds: nil,
	            stableObservations: nil,
	            stableObservationsRequired: nil,
	            advancedToStepIndex: nil,
	            completedSop: nil,
	            packageProgressWarning: nil
	          )
	        : spotterResponses.removeFirst()
      return (queuedError, response)
    }

    if let queuedError {
      throw queuedError
    }
    return response
  }

  func snapshot() -> WorkerAdminAPISnapshot {
    lock.lock()
    defer { lock.unlock() }
    return WorkerAdminAPISnapshot(
      heartbeats: recordedHeartbeats,
      uploadTargetRequests: recordedUploadTargetRequests,
      uploadCalls: recordedUploadCalls,
      finalizeRequests: recordedFinalizeRequests,
      telemetryBatches: recordedTelemetryBatches,
      liveTokenRequests: recordedLiveTokenRequests,
      spotterRequests: recordedSpotterRequests
    )
  }
}

private actor SleepRecorder {
  private(set) var values: [UInt64] = []

  func record(_ value: UInt64) {
    values.append(value)
  }

  func snapshot() -> [UInt64] {
    values
  }
}

private final class CallOrderRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storedValues: [String] = []

  func append(_ value: String) {
    lock.lock()
    storedValues.append(value)
    lock.unlock()
  }

  var values: [String] {
    lock.lock()
    defer { lock.unlock() }
    return storedValues
  }
}

final class WorkerAdminLiveSessionCoordinatorTests: XCTestCase {
  private func makeTempFile(data: Data, suffix: String = UUID().uuidString) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("worker-admin-\(suffix)")
      .appendingPathExtension("mp4")
    try? FileManager.default.removeItem(at: url)
    try data.write(to: url)
    return url
  }

  func testHeartbeatKeepsStickyRoomCodeAndLastFrameLocation() async throws {
    let api = WorkerAdminAPIMock()
    api.uploadTargetResponses = [
      WorkerMediaUploadTarget(
        assetID: "frame-asset-1",
        bucket: "live-frames",
        path: "sessions/session-1/last-frame.jpg",
        uploadURL: "https://upload.example/frame-1"
      )
    ]

    let frameFinalized = expectation(description: "frame finalized")
    api.onFinalizeAttempt = { finalize in
      if finalize.assetID == "frame-asset-1", finalize.status == "uploaded" {
        frameFinalized.fulfill()
      }
    }

    let coordinator = WorkerAdminLiveSessionCoordinator(
      api: api,
      heartbeatIntervalNanoseconds: 0,
      sleeper: { _ in }
    )

    await coordinator.start(sessionID: "session-1", currentStepIndex: 0, helpRequested: false)
    await coordinator.updateRoomCode("ROOM42")
    await coordinator.enqueueFrameUpload(data: Data([0x01, 0x02, 0x03]))

    await fulfillment(of: [frameFinalized], timeout: 1.0)

    await coordinator.updateRoomCode("")
    await coordinator.updateHelpRequested(true)

    let snapshot = api.snapshot()
    XCTAssertEqual(snapshot.heartbeats.first?.webrtcRoomCode, nil)
    XCTAssertEqual(snapshot.heartbeats.last?.webrtcRoomCode, "ROOM42")
    XCTAssertEqual(snapshot.heartbeats.last?.lastFrameBucket, "live-frames")
    XCTAssertEqual(snapshot.heartbeats.last?.lastFramePath, "sessions/session-1/last-frame.jpg")
    XCTAssertEqual(snapshot.finalizeRequests.last?.status, "uploaded")
  }

  func testFrameUploadFinalizesFailedWhenUploadFailsAfterRetries() async throws {
    let api = WorkerAdminAPIMock()
    api.uploadTargetResponses = [
      WorkerMediaUploadTarget(
        assetID: "frame-asset-2",
        bucket: "live-frames",
        path: "sessions/session-2/last-frame.jpg",
        uploadURL: "https://upload.example/frame-2"
      )
    ]
    api.uploadErrors = [
      URLError(.networkConnectionLost),
      URLError(.networkConnectionLost),
      URLError(.networkConnectionLost),
      URLError(.networkConnectionLost),
    ]

    let sleepRecorder = SleepRecorder()
    let frameFailed = expectation(description: "frame failed finalize")
    api.onFinalizeAttempt = { finalize in
      if finalize.assetID == "frame-asset-2", finalize.status == "failed" {
        frameFailed.fulfill()
      }
    }

    let coordinator = WorkerAdminLiveSessionCoordinator(
      api: api,
      heartbeatIntervalNanoseconds: 0,
      sleeper: { value in
        await sleepRecorder.record(value)
      }
    )

    await coordinator.start(sessionID: "session-2", currentStepIndex: 0, helpRequested: false)
    await coordinator.enqueueFrameUpload(data: Data([0x0A, 0x0B]))

    await fulfillment(of: [frameFailed], timeout: 1.0)

    let snapshot = api.snapshot()
    let recordedSleeps = await sleepRecorder.snapshot()
    XCTAssertEqual(snapshot.uploadCalls.count, 4)
    XCTAssertEqual(snapshot.finalizeRequests.last?.status, "failed")
    XCTAssertEqual(recordedSleeps, [750_000_000, 1_500_000_000, 3_000_000_000])
  }

  func testVideoUploadFinalizesFailedWhenRecordingIsMissing() async throws {
    let api = WorkerAdminAPIMock()
    api.uploadTargetResponses = [
      WorkerMediaUploadTarget(
        assetID: "video-asset-1",
        bucket: "execution-videos",
        path: "sessions/session-3/recording.mp4",
        uploadURL: "https://upload.example/video-1"
      )
    ]

    let coordinator = WorkerAdminLiveSessionCoordinator(
      api: api,
      sessionID: "session-3",
      heartbeatIntervalNanoseconds: 0,
      sleeper: { _ in }
    )

    let result = await coordinator.uploadVideoRecording(from: nil)
    let snapshot = api.snapshot()

    XCTAssertEqual(result.uploadState, "failed")
    XCTAssertEqual(snapshot.uploadTargetRequests.last?.byteSize, 0)
    XCTAssertEqual(snapshot.uploadTargetRequests.last?.source, "session-recording")
    XCTAssertEqual(snapshot.finalizeRequests.last?.status, "failed")
    XCTAssertTrue(snapshot.uploadCalls.isEmpty)
  }

  func testPrepareVideoRecordingUploadReturnsPendingWithoutUploading() async throws {
    let api = WorkerAdminAPIMock()
    api.uploadTargetResponses = [
      WorkerMediaUploadTarget(
        assetID: "video-asset-2",
        bucket: "execution-videos",
        path: "sessions/session-4/recording.mp4",
        uploadURL: "https://upload.example/video-2"
      )
    ]

    let coordinator = WorkerAdminLiveSessionCoordinator(
      api: api,
      sessionID: "session-4",
      heartbeatIntervalNanoseconds: 0,
      sleeper: { _ in }
    )

    let preparedResult = await coordinator.prepareVideoRecordingUpload(source: "stream-capture")
    let prepared = try XCTUnwrap(preparedResult)
    let snapshot = api.snapshot()

    XCTAssertEqual(prepared.result.uploadState, "pending")
    XCTAssertEqual(prepared.result.assetID, "video-asset-2")
    XCTAssertEqual(prepared.result.byteSize, 0)
    XCTAssertEqual(snapshot.uploadTargetRequests.last?.byteSize, 0)
    XCTAssertEqual(snapshot.uploadTargetRequests.last?.source, "stream-capture")
    XCTAssertTrue(snapshot.uploadCalls.isEmpty)
    XCTAssertTrue(snapshot.finalizeRequests.isEmpty)
  }

  func testCompleteSessionEndsBeforePreparedVideoUpload() async throws {
    let api = WorkerAdminAPIMock()
    api.uploadTargetResponses = [
      WorkerMediaUploadTarget(
        assetID: "video-asset-2",
        bucket: "execution-videos",
        path: "sessions/session-4/recording.mp4",
        uploadURL: "https://upload.example/video-2"
      )
    ]

    let callOrder = CallOrderRecorder()
    api.onFinalizeAttempt = { finalize in
      if finalize.assetID == "video-asset-2", finalize.status == "uploaded" {
        callOrder.append("finalize")
      }
    }

    let coordinator = WorkerAdminLiveSessionCoordinator(
      api: api,
      heartbeatIntervalNanoseconds: 0,
      sleeper: { _ in }
    )

    await coordinator.start(sessionID: "session-4", currentStepIndex: 0, helpRequested: false)
    let preparedResult = await coordinator.prepareVideoRecordingUpload(source: "stream-capture")
    let prepared = try XCTUnwrap(preparedResult)
    let result = await coordinator.completeSession(pendingVideoUpload: prepared) {
      callOrder.append("end")
    }
    let completionSnapshot = api.snapshot()

    XCTAssertEqual(result.uploadState, "pending")
    XCTAssertEqual(callOrder.values, ["end"])
    XCTAssertTrue(completionSnapshot.uploadCalls.isEmpty)
    XCTAssertTrue(completionSnapshot.finalizeRequests.isEmpty)
  }

  func testPreparedVideoUploadReusesReservedAssetID() async throws {
    let api = WorkerAdminAPIMock()
    api.uploadTargetResponses = [
      WorkerMediaUploadTarget(
        assetID: "video-asset-2",
        bucket: "execution-videos",
        path: "sessions/session-4/recording.mp4",
        uploadURL: "https://upload.example/video-2"
      )
    ]

    let fileURL = try makeTempFile(data: Data([0x01, 0x02, 0x03]), suffix: "prepared-reuse")
    defer { try? FileManager.default.removeItem(at: fileURL) }

    let coordinator = WorkerAdminLiveSessionCoordinator(
      api: api,
      sessionID: "session-4",
      heartbeatIntervalNanoseconds: 0,
      sleeper: { _ in }
    )

    let preparedResult = await coordinator.prepareVideoRecordingUpload(source: "stream-capture")
    let prepared = try XCTUnwrap(preparedResult)
    let result = await coordinator.uploadPreparedVideoRecording(
      from: fileURL,
      preparedUpload: prepared
    )
    let snapshot = api.snapshot()

    XCTAssertTrue(result.succeeded)
    XCTAssertEqual(snapshot.uploadCalls.last?.assetID, "video-asset-2")
    XCTAssertEqual(snapshot.finalizeRequests.last?.assetID, "video-asset-2")
    XCTAssertEqual(snapshot.finalizeRequests.last?.status, "uploaded")
  }

  func testPreparedVideoUploadFinalizesFailedWhenRecordingIsMissing() async throws {
    let api = WorkerAdminAPIMock()
    api.uploadTargetResponses = [
      WorkerMediaUploadTarget(
        assetID: "video-asset-missing",
        bucket: "execution-videos",
        path: "sessions/session-missing/recording.mp4",
        uploadURL: "https://upload.example/video-missing"
      )
    ]

    let coordinator = WorkerAdminLiveSessionCoordinator(
      api: api,
      sessionID: "session-missing",
      heartbeatIntervalNanoseconds: 0,
      sleeper: { _ in }
    )

    let preparedResult = await coordinator.prepareVideoRecordingUpload(source: "phone-recording")
    let prepared = try XCTUnwrap(preparedResult)
    let result = await coordinator.uploadPreparedVideoRecording(
      from: nil,
      preparedUpload: prepared
    )
    let snapshot = api.snapshot()

    XCTAssertEqual(result.uploadState, "failed")
    XCTAssertEqual(result.assetID, "video-asset-missing")
    XCTAssertTrue(snapshot.uploadCalls.isEmpty)
    XCTAssertEqual(snapshot.finalizeRequests.last?.assetID, "video-asset-missing")
    XCTAssertEqual(snapshot.finalizeRequests.last?.status, "failed")
  }

  func testVideoFinalizeRetriesTransientErrorsThenSucceeds() async throws {
    let api = WorkerAdminAPIMock()
    api.uploadTargetResponses = [
      WorkerMediaUploadTarget(
        assetID: "video-asset-3",
        bucket: "execution-videos",
        path: "sessions/session-5/recording.mp4",
        uploadURL: "https://upload.example/video-3"
      )
    ]
    api.finalizeErrors = [
      URLError(.timedOut),
      URLError(.networkConnectionLost),
    ]

    let sleepRecorder = SleepRecorder()
    let fileURL = try makeTempFile(data: Data([0xAB, 0xCD, 0xEF]), suffix: "retry")
    defer { try? FileManager.default.removeItem(at: fileURL) }

    let coordinator = WorkerAdminLiveSessionCoordinator(
      api: api,
      sessionID: "session-5",
      heartbeatIntervalNanoseconds: 0,
      sleeper: { value in
        await sleepRecorder.record(value)
      }
    )

    let result = await coordinator.uploadVideoRecording(from: fileURL)
    let snapshot = api.snapshot()
    let recordedSleeps = await sleepRecorder.snapshot()

    XCTAssertTrue(result.succeeded)
    XCTAssertEqual(snapshot.uploadTargetRequests.last?.source, "session-recording")
    XCTAssertEqual(
      snapshot.finalizeRequests.filter { $0.assetID == "video-asset-3" && $0.status == "uploaded" }.count,
      3
    )
    XCTAssertEqual(recordedSleeps, [750_000_000, 1_500_000_000])
  }

  func testVideoUploadIncludesExplicitRecordingSource() async throws {
    let api = WorkerAdminAPIMock()
    api.uploadTargetResponses = [
      WorkerMediaUploadTarget(
        assetID: "video-asset-4",
        bucket: "execution-videos",
        path: "sessions/session-6/recording.mp4",
        uploadURL: "https://upload.example/video-4"
      )
    ]

    let fileURL = try makeTempFile(data: Data([0x11, 0x22, 0x33]), suffix: "phone-source")
    defer { try? FileManager.default.removeItem(at: fileURL) }

    let coordinator = WorkerAdminLiveSessionCoordinator(
      api: api,
      sessionID: "session-6",
      heartbeatIntervalNanoseconds: 0,
      sleeper: { _ in }
    )

    let result = await coordinator.uploadVideoRecording(from: fileURL, source: "phone-recording")
    let snapshot = api.snapshot()

    XCTAssertTrue(result.succeeded)
    XCTAssertEqual(snapshot.uploadTargetRequests.last?.source, "phone-recording")
  }

  func testTelemetryBatchFlushesSanitizedPayload() async throws {
    let api = WorkerAdminAPIMock()
    let telemetry = WorkerTelemetry(
      api: api,
      sessionID: "11111111-1111-1111-1111-111111111111",
      deviceID: "iphone-test",
      appBuild: "test-build",
      flushIntervalNanoseconds: 0,
      maxBatchSize: 20
    )

    await telemetry.record(
      "video_upload_success",
      source: "media_upload",
      stage: "uploaded",
      durationMs: 42,
      metricValue: 1024,
      metricUnit: "bytes",
      payload: [
        "token": "secret-token",
        "uploadUrl": "https://signed.example/upload?token=secret",
        "image_data": "data:image/jpeg;base64,abcd",
        "asset_type": "video"
      ]
    )
    await telemetry.flush()

    let snapshot = api.snapshot()
    let batch = try XCTUnwrap(snapshot.telemetryBatches.first)
    XCTAssertEqual(batch.sessionID, "11111111-1111-1111-1111-111111111111")
    XCTAssertEqual(batch.deviceID, "iphone-test")
    XCTAssertEqual(batch.appBuild, "test-build")
    XCTAssertEqual(batch.events.first?.name, "video_upload_success")
    XCTAssertEqual(batch.events.first?.payload["token"] as? String, "[redacted]")
    XCTAssertEqual(batch.events.first?.payload["uploadUrl"] as? String, "[redacted-url]")
    XCTAssertEqual(batch.events.first?.payload["image_data"] as? String, "[redacted-raw-payload]")
    XCTAssertEqual(batch.events.first?.payload["asset_type"] as? String, "video")
  }

  func testTelemetryFailureDoesNotBlockCoordinatorUpload() async throws {
    let api = WorkerAdminAPIMock()
    api.telemetryErrors = [URLError(.timedOut)]
    api.uploadTargetResponses = [
      WorkerMediaUploadTarget(
        assetID: "video-asset-telemetry",
        bucket: "execution-videos",
        path: "sessions/session-telemetry/recording.mp4",
        uploadURL: "https://upload.example/video-telemetry"
      )
    ]
    let telemetry = WorkerTelemetry(
      api: api,
      sessionID: "22222222-2222-2222-2222-222222222222",
      flushIntervalNanoseconds: 0,
      maxBatchSize: 100
    )
    let fileURL = try makeTempFile(data: Data([0x41, 0x42, 0x43]), suffix: "telemetry")
    defer { try? FileManager.default.removeItem(at: fileURL) }
    let coordinator = WorkerAdminLiveSessionCoordinator(
      api: api,
      sessionID: "22222222-2222-2222-2222-222222222222",
      heartbeatIntervalNanoseconds: 0,
      telemetry: telemetry,
      sleeper: { _ in }
    )

    let result = await coordinator.uploadVideoRecording(from: fileURL)
    await telemetry.flush()

    let snapshot = api.snapshot()
    XCTAssertTrue(result.succeeded)
    XCTAssertEqual(snapshot.finalizeRequests.last?.status, "uploaded")
    XCTAssertEqual(snapshot.telemetryBatches.count, 1)
  }
}

@MainActor
final class GeminiInstructionSyncTests: XCTestCase {
  override func setUp() async throws {
    try await super.setUp()
    try? Wearables.configure()
  }

  func testGeminiInstructionPreviewIncludesActiveStepContext() async throws {
    let viewModel = StreamSessionViewModel(wearables: Wearables.shared)
    let sop = SOPTemplate(
      name: "Cold Chain Verification SOP",
      steps: [
        SOPStepTemplate(
          id: "inspect_packaging_seal",
          order: 1,
          title: "Inspect packaging seal",
          description: "Check the package seal before accepting the delivery.",
          aiPrompt: "Confirm the seal is intact before intake.",
          expectedObjects: ["seal", "package"]
        ),
        SOPStepTemplate(
          id: "record_temperature_log",
          order: 2,
          title: "Record temperature log",
          description: "Read the thermometer and capture the result in the log.",
          aiPrompt: "Verify that the worker recorded the temperature reading.",
          expectedObjects: ["thermometer", "clipboard"]
        ),
      ]
    )

    viewModel.checklistItems = [
      ChecklistItemState(
        itemID: "inspect_packaging_seal",
        name: "Inspect packaging seal",
        description: "Check the package seal before accepting the delivery.",
        aiPrompt: "Confirm the seal is intact before intake.",
        expectedObjects: ["seal", "package"],
        isChecked: true,
        completionSource: .manual
      ),
      ChecklistItemState(
        itemID: "record_temperature_log",
        name: "Record temperature log",
        description: "Read the thermometer and capture the result in the log.",
        aiPrompt: "Verify that the worker recorded the temperature reading.",
        expectedObjects: ["thermometer", "clipboard"]
      ),
    ]

    let instruction = try XCTUnwrap(viewModel.debugGeminiInstructionPreview(for: sop))

    XCTAssertTrue(instruction.contains("SOP title: Cold Chain Verification SOP"))
    XCTAssertTrue(instruction.contains("Step title: Record temperature log"))
    XCTAssertTrue(instruction.contains("Step description: Read the thermometer and capture the result in the log."))
    XCTAssertTrue(instruction.contains("Vision completion prompt: Verify that the worker recorded the temperature reading."))
    XCTAssertTrue(instruction.contains("Expected objects to look for: thermometer, clipboard"))
    XCTAssertTrue(instruction.contains("Direct next action: Guide the worker through this step now: Record temperature log."))
    XCTAssertTrue(viewModel.geminiInstructionSyncStatus.contains("Record temperature log"))
  }

  func testSpotterTargetsOnlyCurrentIncompleteStep() async throws {
    let viewModel = StreamSessionViewModel(wearables: Wearables.shared)

    viewModel.checklistItems = [
      ChecklistItemState(
        itemID: "inspect_packaging_seal",
        name: "Inspect packaging seal",
        aiPrompt: "Confirm the seal is intact before intake.",
        expectedObjects: ["seal", "package"],
        isChecked: true,
        completionSource: .manual
      ),
      ChecklistItemState(
        itemID: "record_temperature_log",
        name: "Record temperature log",
        critical: true,
        aiPrompt: "Verify that the worker recorded the temperature reading.",
        expectedObjects: ["thermometer", "clipboard"]
      ),
      ChecklistItemState(
        itemID: "stage_delivery",
        name: "Stage delivery",
        aiPrompt: "Confirm the package is staged for pickup.",
        expectedObjects: ["package", "pickup shelf"]
      ),
    ]

    XCTAssertEqual(viewModel.debugSpotterTargetIDs(), ["record_temperature_log"])
  }
}

@MainActor
final class AssignmentDrivenFlowTests: XCTestCase {
  override func setUp() async throws {
    try await super.setUp()
    try? Wearables.configure()
  }

  func testExplicitHomeSelectionStartsFirstPendingSOP() async throws {
    let viewModel = StreamSessionViewModel(wearables: Wearables.shared)
    let secondAssignment = SOPTemplate(
      name: "Second assigned SOP",
      items: ["Inspect secondary station"],
      packageTitle: "Line A",
      sortOrder: 2
    )
    let firstAssignment = SOPTemplate(
      name: "First assigned SOP",
      items: ["Inspect primary station"],
      packageTitle: "Line A",
      sortOrder: 1
    )

    viewModel.availableSOPs = [secondAssignment, firstAssignment]
    viewModel.startCurrentAssignmentFromHome()

    XCTAssertEqual(viewModel.currentAssignedSOP?.name, "First assigned SOP")
    XCTAssertEqual(viewModel.selectedSOP?.name, "First assigned SOP")
    XCTAssertEqual(viewModel.activeCaptureSOP?.name, "First assigned SOP")
    XCTAssertEqual(viewModel.preferredCaptureMode, .iPhone)
  }

  func testExplicitHomeSelectionPrefersGlassesWhenAvailable() async throws {
    let viewModel = StreamSessionViewModel(wearables: Wearables.shared)
    viewModel.hasActiveDevice = true
    viewModel.availableSOPs = [
      SOPTemplate(
        name: "Assigned SOP",
        items: ["Inspect station"],
        packageTitle: "Line A",
        sortOrder: 1
      )
    ]

    viewModel.startCurrentAssignmentFromHome()

    XCTAssertEqual(viewModel.activeCaptureSOP?.name, "Assigned SOP")
    XCTAssertEqual(viewModel.preferredCaptureMode, .glasses)
  }
}

final class SpotterEvidenceWindowTests: XCTestCase {
  func testRequiresMultiplePositiveSamplesBeforeAutoComplete() {
    var window = SpotterEvidenceWindow()

    let first = window.record(
      stepID: "seal-check",
      matched: true,
      autoComplete: true,
      confidence: 0.92,
      threshold: 0.88
    )
    let second = window.record(
      stepID: "seal-check",
      matched: true,
      autoComplete: true,
      confidence: 0.91,
      threshold: 0.88
    )
    let third = window.record(
      stepID: "seal-check",
      matched: true,
      autoComplete: true,
      confidence: 0.9,
      threshold: 0.88
    )

    XCTAssertFalse(first.shouldAutoComplete)
    XCTAssertFalse(second.shouldAutoComplete)
    XCTAssertTrue(third.shouldAutoComplete)
    XCTAssertEqual(third.positiveCount, 3)
  }

  func testNegativeSamplesPreventStableAutoComplete() {
    var window = SpotterEvidenceWindow()

    _ = window.record(stepID: "seal-check", matched: true, autoComplete: true, confidence: 0.92, threshold: 0.88)
    _ = window.record(stepID: "seal-check", matched: false, autoComplete: false, confidence: 0.2, threshold: 0.88)
    let decision = window.record(
      stepID: "seal-check",
      matched: true,
      autoComplete: true,
      confidence: 0.91,
      threshold: 0.88
    )

    XCTAssertFalse(decision.shouldAutoComplete)
    XCTAssertEqual(decision.sampleCount, 3)
    XCTAssertEqual(decision.positiveCount, 2)
  }
}

final class OpsAPIClientRoutingTests: XCTestCase {
  override func tearDown() {
    RequestCaptureURLProtocol.handler = nil
    super.tearDown()
  }

  func testWorkerRoutesUseAdminBaseURL() async throws {
    let settings = SettingsManager.shared
    let originalOpsBaseURL = settings.opsBaseURL
    let originalAdminBaseURL = settings.adminBaseURL
    let originalBearerToken = settings.workerAPIBearerToken

    settings.opsBaseURL = "https://ops.example.test"
    settings.adminBaseURL = "http://admin.example.test:3001"
    settings.workerAPIBearerToken = "worker-bearer-token"
    defer {
      settings.opsBaseURL = originalOpsBaseURL
      settings.adminBaseURL = originalAdminBaseURL
      settings.workerAPIBearerToken = originalBearerToken
    }

    let lock = NSLock()
    var capturedRequests: [URLRequest] = []
    RequestCaptureURLProtocol.handler = { request in
      lock.withLock {
        capturedRequests.append(request)
      }

      let body: Data
      switch request.url?.path {
      case "/health":
        body = Data(#"{"status":"ok","service":"ops"}"#.utf8)
      case "/api/worker/live/heartbeat":
        body = Data(
          #"{"sessionId":"11111111-1111-1111-1111-111111111111","updatedAt":"2026-05-30T18:31:00.000Z","isFreshLiveSession":true,"webrtcRoomCode":"ROOM42","supportMode":"handoff_requested","aiSessionStatus":"paused","humanSupportStatus":"ringing","supportUpdatedAt":"2026-05-30T18:31:00.000Z","shouldOpenLiveRoom":false}"#
            .utf8
        )
      case "/api/worker/media/upload-target":
        body = Data(
          #"{"assetId":"video-asset-1","bucket":"execution-videos","path":"sessions/session-1/recording.mp4","uploadUrl":"https://upload.example/video-1"}"#
            .utf8
        )
      case "/api/worker/gemini/live-token":
        body = Data(
          #"{"token":"ephemeral-token","expiresAt":"2026-05-30T19:00:00.000Z","newSessionExpiresAt":"2026-05-30T18:31:00.000Z","model":"gemini-live-2.5-flash-native-audio","websocketBaseURL":"wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1alpha.GenerativeService.BidiGenerateContentConstrained","queryParameterName":"access_token"}"#
            .utf8
        )
      case "/api/worker/gemini/spotter":
        body = Data(
          #"{"matched":true,"confidence":0.93,"reason":"Clear visual evidence.","evidenceTimestamp":"2026-05-30T18:31:00.000Z","threshold":0.88,"model":"gemini-3.5-flash","autoComplete":true}"#
            .utf8
        )
      default:
        body = Data("{}".utf8)
      }

      let response = HTTPURLResponse(
        url: try XCTUnwrap(request.url),
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )
      return (try XCTUnwrap(response), body)
    }

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [RequestCaptureURLProtocol.self]
    let client = OpsAPIClient(session: URLSession(configuration: configuration))

    let health = try await client.health()
    XCTAssertEqual(health, "ok:ops")

    try await client.sendWorkerLiveHeartbeat(
      WorkerLiveHeartbeatRequest(
        sessionID: "11111111-1111-1111-1111-111111111111",
        webrtcRoomCode: "ROOM42",
        currentStepIndex: 2,
        helpRequested: true,
        status: "active",
        lastFrameBucket: "live-frames",
        lastFramePath: "sessions/session-1/last-frame.jpg"
      )
    )

    _ = try await client.requestWorkerMediaUploadTarget(
      sessionID: "11111111-1111-1111-1111-111111111111",
      assetType: "video",
      filename: "recording.mp4",
      contentType: "video/mp4",
      byteSize: 256,
      source: "phone-recording"
    )

    _ = try await client.requestGeminiLiveToken(
      model: "models/gemini-live-2.5-flash-native-audio",
      sessionID: "11111111-1111-1111-1111-111111111111"
    )

    _ = try await client.requestGeminiSpotter(
      GeminiSpotterRequest(
        sessionID: "11111111-1111-1111-1111-111111111111",
        stepID: "step-1",
        stepTitle: "Check seal",
        aiPrompt: "Confirm the seal is visible.",
        expectedObjects: ["seal"],
        preconditions: ["Package is in view"],
        postconditions: ["Seal is visible"],
        skipRisk: "medium",
        evidenceRequired: true,
        imageBase64: "ZmFrZQ==",
        imageMimeType: "image/jpeg",
        capturedAt: "2026-05-30T18:31:00.000Z",
        critical: false,
        allowAIComplete: true,
        elapsedActiveMs: nil
      )
    )

    let requests = lock.withLock { capturedRequests }
    XCTAssertEqual(requests.map { $0.url?.host }, ["ops.example.test", "admin.example.test", "admin.example.test", "admin.example.test", "admin.example.test"])
    XCTAssertEqual(requests.map { $0.url?.path }, ["/health", "/api/worker/live/heartbeat", "/api/worker/media/upload-target", "/api/worker/gemini/live-token", "/api/worker/gemini/spotter"])
    XCTAssertNil(requests.first?.value(forHTTPHeaderField: "Authorization"))
    XCTAssertEqual(requests.dropFirst().first?.value(forHTTPHeaderField: "Authorization"), "Bearer worker-bearer-token")
    let uploadPayload = try XCTUnwrap(
      JSONSerialization.jsonObject(with: try XCTUnwrap(requestBodyData(from: requests[2]))) as? [String: Any]
    )
    XCTAssertEqual(uploadPayload["source"] as? String, "phone-recording")
    let tokenPayload = try XCTUnwrap(
      JSONSerialization.jsonObject(with: try XCTUnwrap(requestBodyData(from: requests[3]))) as? [String: Any]
    )
    XCTAssertEqual(tokenPayload["model"] as? String, "models/gemini-live-2.5-flash-native-audio")
    XCTAssertEqual(tokenPayload["sessionId"] as? String, "11111111-1111-1111-1111-111111111111")
    let spotterPayload = try XCTUnwrap(
      JSONSerialization.jsonObject(with: try XCTUnwrap(requests.last.flatMap(requestBodyData(from:)))) as? [String: Any]
    )
    XCTAssertEqual(spotterPayload["stepId"] as? String, "step-1")
    XCTAssertEqual(spotterPayload["allowAIComplete"] as? Bool, true)
    XCTAssertEqual(spotterPayload["imageBase64"] as? String, "ZmFrZQ==")
  }

  func testWorkerRouteErrorsMentionAdminIngest() async throws {
    let settings = SettingsManager.shared
    let originalAdminBaseURL = settings.adminBaseURL
    let originalBearerToken = settings.workerAPIBearerToken

    settings.adminBaseURL = "http://admin.example.test:3001"
    settings.workerAPIBearerToken = "worker-bearer-token"
    defer {
      settings.adminBaseURL = originalAdminBaseURL
      settings.workerAPIBearerToken = originalBearerToken
    }

    RequestCaptureURLProtocol.handler = { request in
      let response = HTTPURLResponse(
        url: try XCTUnwrap(request.url),
        statusCode: 404,
        httpVersion: nil,
        headerFields: ["Content-Type": "text/html"]
      )
      let body = Data("<pre>Cannot POST /api/worker/media/upload-target</pre>".utf8)
      return (try XCTUnwrap(response), body)
    }

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [RequestCaptureURLProtocol.self]
    let client = OpsAPIClient(session: URLSession(configuration: configuration))

    do {
      _ = try await client.requestWorkerMediaUploadTarget(
        sessionID: "11111111-1111-1111-1111-111111111111",
        assetType: "video",
        filename: "recording.mp4",
        contentType: "video/mp4",
        byteSize: 256,
        source: "stream-capture"
      )
      XCTFail("Expected admin ingest request to fail")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("Admin ingest returned HTTP 404"))
      XCTAssertFalse(error.localizedDescription.localizedCaseInsensitiveContains("ops-api"))
      XCTAssertTrue(error.localizedDescription.contains("/api/worker/media/upload-target"))
    }
  }

  func testTelemetryRouteUsesAdminBaseURL() async throws {
    let settings = SettingsManager.shared
    let originalAdminBaseURL = settings.adminBaseURL
    let originalBearerToken = settings.workerAPIBearerToken

    settings.adminBaseURL = "http://admin.example.test:3001"
    settings.workerAPIBearerToken = "worker-bearer-token"
    defer {
      settings.adminBaseURL = originalAdminBaseURL
      settings.workerAPIBearerToken = originalBearerToken
    }

    let lock = NSLock()
    var capturedRequests: [URLRequest] = []
    RequestCaptureURLProtocol.handler = { request in
      lock.withLock {
        capturedRequests.append(request)
      }

      let response = HTTPURLResponse(
        url: try XCTUnwrap(request.url),
        statusCode: 202,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )
      return (try XCTUnwrap(response), Data(#"{"accepted":1,"inserted":1}"#.utf8))
    }

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [RequestCaptureURLProtocol.self]
    let client = OpsAPIClient(session: URLSession(configuration: configuration))

    try await client.sendWorkerTelemetryBatch(
      WorkerTelemetryBatch(
        sessionID: "11111111-1111-1111-1111-111111111111",
        deviceID: "iphone-test",
        workerID: nil,
        platform: "ios",
        appBuild: "test-build",
        events: [
          WorkerTelemetryEvent(
            name: "heartbeat_result",
            source: "ios_app",
            stage: "heartbeat",
            payload: ["status": "active"]
          )
        ]
      )
    )

    let request = try XCTUnwrap(lock.withLock { capturedRequests.first })
    XCTAssertEqual(request.url?.host, "admin.example.test")
    XCTAssertEqual(request.url?.path, "/api/worker/telemetry")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer worker-bearer-token")
    let payload = try XCTUnwrap(
      JSONSerialization.jsonObject(with: try XCTUnwrap(requestBodyData(from: request))) as? [String: Any]
    )
    XCTAssertEqual(payload["sessionId"] as? String, "11111111-1111-1111-1111-111111111111")
    XCTAssertEqual(payload["deviceId"] as? String, "iphone-test")
    XCTAssertEqual(payload["platform"] as? String, "ios")
    XCTAssertEqual((payload["events"] as? [[String: Any]])?.first?["name"] as? String, "heartbeat_result")
  }
}
