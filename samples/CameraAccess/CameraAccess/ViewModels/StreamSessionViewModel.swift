/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// StreamSessionViewModel.swift
//
// Core view model demonstrating video streaming from Meta wearable devices using the DAT SDK.
// This class showcases the key streaming patterns: device selection, session management,
// video frame handling, photo capture, and error handling.
//

import CoreImage
import CoreMedia
import CoreVideo
import MWDATCamera
import MWDATCore
import SwiftUI
import VideoToolbox

enum StreamingStatus {
  case streaming
  case waiting
  case stopped
}

enum StreamingMode {
  case glasses
  case iPhone
}

/// Capture settings tuned for a responsive preview. Meta's sample uses low/24;
/// larger raw frames need a lower source cadence to avoid saturating the phone.
struct StreamPerformanceProfile {
  let videoCodec: VideoCodec
  let frameRate: UInt

  static let aiResolution: StreamingResolution = .low

  static func forResolution(_ resolution: StreamingResolution) -> StreamPerformanceProfile {
    switch resolution {
    case .low:
      return StreamPerformanceProfile(videoCodec: .raw, frameRate: 24)
    case .medium, .high:
      return StreamPerformanceProfile(videoCodec: .raw, frameRate: 7)
    @unknown default:
      return StreamPerformanceProfile(videoCodec: .raw, frameRate: 7)
    }
  }
}

enum DeviceSessionStartFailureCategory: Equatable {
  case stoppedBeforeReady
  case timedOut
  case streamUnavailable
  case transientDeviceError
  case fatalDeviceError
  case cancelled
}

/// DeviceSession.stopped is terminal. A failed start may be retried only by
/// retiring that session and creating one fresh session while the same request
/// and active glasses are still current.
struct DeviceSessionStartRecoveryPolicy {
  static let maxAttempts = 2

  static func shouldRetry(
    attemptNumber: Int,
    hasActiveDevice: Bool,
    isOperationCurrent: Bool,
    failure: DeviceSessionStartFailureCategory
  ) -> Bool {
    guard attemptNumber < maxAttempts, hasActiveDevice, isOperationCurrent else {
      return false
    }

    switch failure {
    case .stoppedBeforeReady, .timedOut, .streamUnavailable, .transientDeviceError:
      return true
    case .fatalDeviceError, .cancelled:
      return false
    }
  }
}

enum DeviceSessionStartTimeoutDisposition: Equatable {
  case ready
  case rearmWhilePaused
  case beginStoppedErrorGrace
  case awaitStoppedErrorGrace
  case fail
}

/// A paused DeviceSession is still connected and owned by the app. Meta DAT can
/// pause it while another system experience temporarily owns the glasses, so a
/// startup deadline may be re-armed once instead of replacing the live session.
/// The overall budget keeps a permanently paused session from leaving the UI in
/// Connecting forever.
struct DeviceSessionStartWaitPolicy {
  static let timeoutInterval: Duration = .seconds(8)
  static let overallTimeout: Duration = .seconds(16)

  static func timeoutDisposition(
    for state: DeviceSessionState,
    isWaitingForLateError: Bool,
    hasRemainingOverallBudget: Bool
  ) -> DeviceSessionStartTimeoutDisposition {
    switch state {
    case .started:
      return .ready
    case .paused:
      return hasRemainingOverallBudget ? .rearmWhilePaused : .fail
    case .stopped:
      return isWaitingForLateError ? .awaitStoppedErrorGrace : .beginStoppedErrorGrace
    case .idle, .starting, .stopping:
      return .fail
    }
  }
}

enum DeviceSessionPublishedStateAction: Equatable {
  case none
  case showWaiting
  case retireSession
}

struct DeviceSessionPublishedStatePolicy {
  static func action(
    for state: DeviceSessionState,
    isStartingSession: Bool
  ) -> DeviceSessionPublishedStateAction {
    // The startup waiter owns terminal-state retry and late-error collection.
    guard !isStartingSession else { return .none }
    switch state {
    case .paused:
      return .showWaiting
    case .stopped:
      return .retireSession
    case .idle, .starting, .started, .stopping:
      return .none
    }
  }
}

private enum DeviceSessionStartWaitError: LocalizedError {
  case stoppedBeforeReady
  case timedOut
  case streamUnavailable

  var errorDescription: String? {
    switch self {
    case .stoppedBeforeReady:
      return "The glasses session stopped before it was ready."
    case .timedOut:
      return "The glasses took too long to finish connecting."
    case .streamUnavailable:
      return "The glasses connected, but the camera stream was unavailable."
    }
  }
}

private enum DeviceSessionStartEvent: @unchecked Sendable {
  case started
  case stopped
  case deviceError(DeviceSessionError)
  case timeout
  case stoppedErrorGraceExpired
  case observerEnded
  case cancelled
}

/// Runs at most one value while retaining only the newest pending value.
/// Slow consumers cannot build an ever-growing queue of stale camera frames.
final class LatestValuePump<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private let queue: DispatchQueue
  private let consume: (Value) -> Void
  private var pendingValue: Value?
  private var isRunning = false

  init(
    label: String,
    qos: DispatchQoS = .userInitiated,
    consume: @escaping (Value) -> Void
  ) {
    self.queue = DispatchQueue(label: label, qos: qos)
    self.consume = consume
  }

  /// Returns true when an older pending value was replaced.
  @discardableResult
  func submit(_ value: Value) -> Bool {
    var shouldStart = false
    lock.lock()
    let replacedPendingValue = pendingValue != nil
    pendingValue = value
    if !isRunning {
      isRunning = true
      shouldStart = true
    }
    lock.unlock()

    if shouldStart {
      queue.async { [weak self] in
        self?.drain()
      }
    }
    return replacedPendingValue
  }

  func reset() {
    lock.lock()
    pendingValue = nil
    lock.unlock()
  }

  private func drain() {
    while true {
      let value: Value?
      lock.lock()
      value = pendingValue
      pendingValue = nil
      if value == nil {
        isRunning = false
      }
      lock.unlock()

      guard let value else { return }
      consume(value)
    }
  }
}

private final class ApplicationBackgroundState: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false

  var isBackground: Bool {
    lock.lock()
    defer { lock.unlock() }
    return value
  }

  func set(_ newValue: Bool) {
    lock.lock()
    value = newValue
    lock.unlock()
  }
}

private struct QueuedVideoFrame: @unchecked Sendable {
  let frame: VideoFrame
  let generation: UInt64
}

@MainActor
class StreamSessionViewModel: ObservableObject {
  @Published var currentVideoFrame: UIImage?
  @Published var hasReceivedFirstFrame: Bool = false
  @Published var streamingStatus: StreamingStatus = .stopped
  @Published var showError: Bool = false
  @Published var errorMessage: String = ""
  @Published var hasActiveDevice: Bool = false
  @Published var streamingMode: StreamingMode = .glasses
  @Published var selectedResolution: StreamingResolution = .low
  @Published private(set) var isPreparingForAIMode: Bool = false
  @Published private(set) var isStartingSession: Bool = false

  var isStreaming: Bool {
    streamingStatus != .stopped
  }

  var resolutionLabel: String {
    switch selectedResolution {
    case .low: return "360x640"
    case .medium: return "504x896"
    case .high: return "720x1280"
    @unknown default: return "Unknown"
    }
  }

  // Photo capture properties
  @Published var capturedPhoto: UIImage?
  @Published var showPhotoPreview: Bool = false

  // Gemini Live integration
  var geminiSessionVM: GeminiSessionViewModel?

  // WebRTC Live streaming integration
  var webrtcSessionVM: WebRTCSessionViewModel?

  // DAT SDK 0.7.0 session-based model: a DeviceSession owns the device connection, and a
  // camera Stream (added to a started session) produces video frames + photos. Both are
  // created on demand in startSession() because addStream() requires a started DeviceSession.
  private var deviceSession: DeviceSession?
  private var stream: MWDATCamera.Stream?
  private var sessionStateListenerToken: AnyListenerToken?
  private var sessionErrorListenerToken: AnyListenerToken?
  // Listener tokens are used to manage DAT SDK event subscriptions
  private var stateListenerToken: AnyListenerToken?
  private var videoFrameListenerToken: AnyListenerToken?
  private var errorListenerToken: AnyListenerToken?
  private var photoDataListenerToken: AnyListenerToken?
  private let wearables: WearablesInterface
  private let deviceSelector: AutoDeviceSelector
  private var deviceMonitorTask: Task<Void, Never>?
  private var iPhoneCameraManager: IPhoneCameraManager?
  private var streamGeneration: UInt64 = 0
  private var sessionStartGeneration: UInt64 = 0
  private var aiPreparationGeneration: UInt64 = 0
  private let applicationBackgroundState = ApplicationBackgroundState()
  private var applicationStateObserverTokens: [NSObjectProtocol] = []

  private var foregroundFramePump: LatestValuePump<QueuedVideoFrame>?

  // CPU-based CIContext for rendering decoded pixel buffers in background
  private let cpuCIContext = CIContext(options: [.useSoftwareRenderer: true])
  // VideoDecoder for decompressing HEVC/H.264 frames in background
  private let videoDecoder = VideoDecoder()
  private var backgroundFrameCount = 0
  private var bgDiagLogged = false
  private static let lastSessionDiagnosticKey = "VisionClawLastDeviceSessionDiagnostic"

  init(wearables: WearablesInterface) {
    self.wearables = wearables
    // Let the SDK auto-select from available devices
    self.deviceSelector = AutoDeviceSelector(wearables: wearables)
    if let previousDiagnostic = UserDefaults.standard.string(
      forKey: Self.lastSessionDiagnosticKey)
    {
      NSLog("[DeviceSession] Previous diagnostic: %@", previousDiagnostic)
    }
    applicationBackgroundState.set(UIApplication.shared.applicationState == .background)
    applicationStateObserverTokens = [
      NotificationCenter.default.addObserver(
        forName: UIApplication.didEnterBackgroundNotification,
        object: nil,
        queue: .main
      ) { [weak applicationBackgroundState] _ in
        applicationBackgroundState?.set(true)
      },
      NotificationCenter.default.addObserver(
        forName: UIApplication.willEnterForegroundNotification,
        object: nil,
        queue: .main
      ) { [weak applicationBackgroundState] _ in
        applicationBackgroundState?.set(false)
      }
    ]

    // Monitor device availability
    deviceMonitorTask = Task { @MainActor in
      for await device in deviceSelector.activeDeviceStream() {
        NSLog("[Wearables] active device=%@", device.map { String(describing: $0) } ?? "<none>")
        self.hasActiveDevice = device != nil
      }
    }

    setupVideoDecoder()
    // Session + camera Stream (and their listeners) are created on start, not here —
    // addStream() requires a started DeviceSession in the 0.7.0 model.
  }

  deinit {
    for token in applicationStateObserverTokens {
      NotificationCenter.default.removeObserver(token)
    }
  }

  private func setupVideoDecoder() {
    videoDecoder.setFrameCallback { [weak self] decodedFrame in
      Task { @MainActor [weak self] in
        guard let self else { return }
        let pixelBuffer = decodedFrame.pixelBuffer
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        if let cgImage = self.cpuCIContext.createCGImage(ciImage, from: rect) {
          let image = UIImage(cgImage: cgImage)
          self.geminiSessionVM?.sendVideoFrameIfThrottled(image: image)
          self.webrtcSessionVM?.pushVideoFrame(image)
          if self.backgroundFrameCount <= 5 || self.backgroundFrameCount % 120 == 0 {
            NSLog("[Stream] Background frame #%d decoded and forwarded (%dx%d)",
                  self.backgroundFrameCount, width, height)
          }
        }
      }
    }
  }

  private func makeForegroundFramePump(generation: UInt64) -> LatestValuePump<QueuedVideoFrame> {
    LatestValuePump<QueuedVideoFrame>(
      label: "visionclaw.camera.latest-frame.\(generation)",
      qos: .userInitiated
    ) { [weak self] queuedFrame in
      autoreleasepool {
        guard let image = queuedFrame.frame.makeUIImage() else { return }

        // Keep this generation bounded all the way through MainActor publication.
        // A stalled high-resolution conversion cannot block a replacement low stream,
        // because every stream owns a separate pump.
        let published = DispatchSemaphore(value: 0)
        Task { @MainActor [weak self] in
          defer { published.signal() }
          self?.publishForegroundFrame(image, generation: queuedFrame.generation)
        }
        published.wait()
      }
    }
  }

  /// Recreate the StreamSession with the current selectedResolution.
  /// Only call when not actively streaming.
  func updateResolution(_ resolution: StreamingResolution) {
    guard !isStreaming else { return }
    selectedResolution = resolution
    // The StreamConfiguration is applied when the camera Stream is created on the next start.
    NSLog("[Stream] Resolution changed to %@", resolutionLabel)
  }

  private func attachStreamListeners(to stream: MWDATCamera.Stream, generation: UInt64) {
    // Subscribe to session state changes using the DAT SDK listener pattern
    stateListenerToken = stream.statePublisher.listen { [weak self] state in
      Task { @MainActor [weak self] in
        guard let self, generation == self.streamGeneration else { return }
        self.updateStatusFromState(state, generation: generation)
      }
    }

    // Subscribe to video frames from the device camera
    // This callback fires whether the app is in the foreground or background,
    // enabling continuous streaming even when the screen is locked.
    let framePump = makeForegroundFramePump(generation: generation)
    foregroundFramePump = framePump
    let backgroundState = applicationBackgroundState
    videoFrameListenerToken = stream.videoFramePublisher.listen { [weak self] videoFrame in
      if !backgroundState.isBackground {
        framePump.submit(QueuedVideoFrame(frame: videoFrame, generation: generation))
        return
      }

      Task { @MainActor [weak self] in
        guard let self, generation == self.streamGeneration else { return }
        self.handleBackgroundFrame(videoFrame)
      }
    }

    // Subscribe to streaming errors
    errorListenerToken = stream.errorPublisher.listen { [weak self] error in
      Task { @MainActor [weak self] in
        guard let self else { return }
        guard generation == self.streamGeneration else { return }
        // Suppress device-not-found errors when user hasn't started streaming yet
        if self.streamingStatus == .stopped {
          if case .deviceNotConnected = error { return }
          if case .deviceNotFound = error { return }
        }
        let newErrorMessage = formatStreamingError(error)
        if newErrorMessage != self.errorMessage {
          showError(newErrorMessage)
        }
      }
    }

    // Subscribe to photo capture events
    photoDataListenerToken = stream.photoDataPublisher.listen { [weak self] photoData in
      Task { @MainActor [weak self] in
        guard let self else { return }
        guard generation == self.streamGeneration else { return }
        if let uiImage = UIImage(data: photoData.data) {
          self.capturedPhoto = uiImage
          self.showPhotoPreview = true
        }
      }
    }
  }

  private func publishForegroundFrame(_ image: UIImage, generation: UInt64) {
    guard generation == streamGeneration, stream != nil else { return }
    backgroundFrameCount = 0
    bgDiagLogged = false
    currentVideoFrame = image
    if !hasReceivedFirstFrame {
      hasReceivedFirstFrame = true
    }
    geminiSessionVM?.sendVideoFrameIfThrottled(image: image)
    webrtcSessionVM?.pushVideoFrame(image)
  }

  private func handleBackgroundFrame(_ videoFrame: VideoFrame) {
    // In background: makeUIImage() uses VideoToolbox GPU rendering which iOS suspends.
    // Instead, use our VideoDecoder for compressed frames and CPU rendering for raw ones.
    backgroundFrameCount += 1

    let sampleBuffer = videoFrame.sampleBuffer
    let hasCompressedData = CMSampleBufferGetDataBuffer(sampleBuffer) != nil

    if hasCompressedData {
      do {
        try videoDecoder.decode(sampleBuffer)
      } catch {
        if backgroundFrameCount <= 5 || backgroundFrameCount % 120 == 0 {
          NSLog("[Stream] Background frame #%d decode error: %@",
                backgroundFrameCount, String(describing: error))
        }
      }
    } else if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
      let width = CVPixelBufferGetWidth(pixelBuffer)
      let height = CVPixelBufferGetHeight(pixelBuffer)
      let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
      let rect = CGRect(x: 0, y: 0, width: width, height: height)
      if let cgImage = cpuCIContext.createCGImage(ciImage, from: rect) {
        let image = UIImage(cgImage: cgImage)
        geminiSessionVM?.sendVideoFrameIfThrottled(image: image)
        webrtcSessionVM?.pushVideoFrame(image)
      }
      videoDecoder.invalidateSession()
    }
  }

  @discardableResult
  func handleStartStreaming() async -> Bool {
    guard let operationGeneration = beginSessionStartOperation() else {
      recordSessionDiagnostic("Ignored duplicate Start streaming request")
      return false
    }
    defer { finishSessionStartOperation(operationGeneration) }

    let permission = Permission.camera
    do {
      try Task.checkCancellation()
      let status = try await wearables.checkPermissionStatus(permission)
      try Task.checkCancellation()
      if status == .granted {
        return await startSession(operationGeneration: operationGeneration)
      }
      let requestStatus = try await wearables.requestPermission(permission)
      try Task.checkCancellation()
      if requestStatus == .granted {
        return await startSession(operationGeneration: operationGeneration)
      }
      guard operationGeneration == sessionStartGeneration else { return false }
      showError("Permission denied")
      streamingStatus = .stopped
      return false
    } catch {
      guard operationGeneration == sessionStartGeneration else { return false }
      if error is CancellationError || Task.isCancelled {
        streamingStatus = .stopped
        return false
      }
      showError("Permission error: \(error.localizedDescription)")
      streamingStatus = .stopped
      return false
    }
  }

  @discardableResult
  func startSession() async -> Bool {
    guard let operationGeneration = beginSessionStartOperation() else {
      recordSessionDiagnostic("Ignored overlapping device-session start")
      return false
    }
    defer { finishSessionStartOperation(operationGeneration) }
    return await startSession(operationGeneration: operationGeneration)
  }

  private func startSession(operationGeneration: UInt64) async -> Bool {
    guard operationGeneration == sessionStartGeneration else { return false }

    // A stopped camera Stream must not leave its parent DeviceSession/capability behind.
    // Retire any stale ownership before creating the next 1:1 session.
    if stream != nil || deviceSession != nil {
      let retired = await retireCurrentGlassesSession(
        operationGeneration: operationGeneration,
        keepWaiting: true)
      guard retired, operationGeneration == sessionStartGeneration else { return false }
    }

    streamingStatus = .waiting

    for attemptNumber in 1...DeviceSessionStartRecoveryPolicy.maxAttempts {
      guard operationGeneration == sessionStartGeneration else { return false }
      guard !Task.isCancelled else {
        streamingStatus = .stopped
        return false
      }

      streamGeneration &+= 1
      let generation = streamGeneration
      var attemptSession: DeviceSession?
      var attemptStream: MWDATCamera.Stream?
      recordSessionDiagnostic(
        "Starting attempt \(attemptNumber)/\(DeviceSessionStartRecoveryPolicy.maxAttempts) generation=\(generation)")

      do {
        // Capture both async channels before start(). Meta DAT can report the terminal
        // state before its descriptive DeviceSessionError, so neither channel is optional.
        let session = try wearables.createSession(deviceSelector: deviceSelector)
        attemptSession = session
        guard operationGeneration == sessionStartGeneration,
              generation == streamGeneration
        else {
          session.stop()
          return false
        }

        deviceSession = session
        attachSessionListeners(to: session, generation: generation)
        let stateStream = session.stateStream()
        let errorStream = session.errorStream()
        try session.start()

        if session.state != .started {
          try await waitForDeviceSessionStart(
            session,
            stateStream: stateStream,
            errorStream: errorStream)
        }

        guard operationGeneration == sessionStartGeneration,
              generation == streamGeneration,
              deviceSession === session
        else {
          session.stop()
          return false
        }
        try Task.checkCancellation()

        // A system-owned experience can pause the session between the first started
        // notification and capability creation. Wait for resume; never restart a paused session.
        if session.state != .started {
          try await waitForDeviceSessionStart(
            session,
            stateStream: session.stateStream(),
            errorStream: session.errorStream())
        }
        guard session.state == .started else {
          throw DeviceSessionStartWaitError.stoppedBeforeReady
        }

        let performanceProfile = StreamPerformanceProfile.forResolution(selectedResolution)
        let config = StreamConfiguration(
          videoCodec: performanceProfile.videoCodec,
          resolution: selectedResolution,
          frameRate: performanceProfile.frameRate)
        guard let newStream = try session.addStream(config: config) else {
          throw DeviceSessionStartWaitError.streamUnavailable
        }
        attemptStream = newStream

        guard operationGeneration == sessionStartGeneration,
              generation == streamGeneration,
              deviceSession === session
        else {
          newStream.stop()
          session.stop()
          return false
        }
        try Task.checkCancellation()

        stream = newStream
        NSLog("[Stream] Starting %@ at %lu fps", resolutionLabel, performanceProfile.frameRate)
        attachStreamListeners(to: newStream, generation: generation)
        newStream.start()
        recordSessionDiagnostic("Attempt \(attemptNumber) reached DeviceSession.started")
        // Release startup ownership before a queued terminal state can be handled.
        // The public caller's defer remains as a harmless idempotent safeguard.
        finishSessionStartOperation(operationGeneration)
        return true
      } catch {
        let ownsAttempt = operationGeneration == sessionStartGeneration
          && generation == streamGeneration
          && (attemptSession == nil || deviceSession === attemptSession)
        let isOperationCurrent = ownsAttempt && !Task.isCancelled
        let failure = sessionStartFailureCategory(for: error)
        recordSessionDiagnostic(
          "Attempt \(attemptNumber) failed category=\(failure) error=\(String(describing: error))")

        guard isOperationCurrent else {
          attemptStream?.stop()
          if ownsAttempt {
            _ = await retireOwnedSessionAttempt(
              attemptSession,
              generation: generation,
              operationGeneration: operationGeneration,
              keepWaiting: false)
          } else {
            attemptSession?.stop()
          }
          return false
        }

        attemptStream?.stop()
        let shouldRetry = DeviceSessionStartRecoveryPolicy.shouldRetry(
          attemptNumber: attemptNumber,
          hasActiveDevice: hasActiveDevice,
          isOperationCurrent: isOperationCurrent,
          failure: failure)
        let retired = await retireOwnedSessionAttempt(
          attemptSession,
          generation: generation,
          operationGeneration: operationGeneration,
          keepWaiting: shouldRetry)

        guard operationGeneration == sessionStartGeneration else { return false }
        guard !Task.isCancelled else {
          streamingStatus = .stopped
          return false
        }

        if shouldRetry, retired {
          do {
            try await Task.sleep(nanoseconds: 300_000_000)
          } catch {
            if operationGeneration == sessionStartGeneration {
              streamingStatus = .stopped
            }
            return false
          }
          guard operationGeneration == sessionStartGeneration else { return false }
          guard hasActiveDevice else {
            streamingStatus = .stopped
            return false
          }
          streamingStatus = .waiting
          continue
        }

        streamingStatus = .stopped
        if retired {
          showError(formatSessionStartFailure(error, attempts: attemptNumber))
        } else {
          showError("The previous glasses session is still closing. Wait a moment, then try again.")
        }
        return false
      }
    }

    streamingStatus = .stopped
    return false
  }

  /// Subscribe to device-session-level state + error (connection lifecycle), separate from the
  /// camera Stream's own state/frames.
  private func attachSessionListeners(to session: DeviceSession, generation: UInt64) {
    sessionStateListenerToken = session.statePublisher.listen { [weak self] state in
      Task { @MainActor [weak self] in
        guard let self,
              generation == self.streamGeneration,
              self.deviceSession === session
        else { return }
        self.recordSessionDiagnostic("generation=\(generation) state=\(String(describing: state))")
        switch DeviceSessionPublishedStatePolicy.action(
          for: state,
          isStartingSession: self.isStartingSession)
        {
        case .none:
          break
        case .showWaiting:
          self.streamingStatus = .waiting
        case .retireSession:
          self.recordSessionDiagnostic(
            "DeviceSession stopped generation=\(generation); retiring owned camera session")
          await self.tearDownCurrentGlassesSession()
        }
      }
    }

    sessionErrorListenerToken = session.errorPublisher.listen { [weak self] error in
      Task { @MainActor [weak self] in
        guard let self else { return }
        guard generation == self.streamGeneration else { return }
        self.recordSessionDiagnostic(
          "generation=\(generation) error=\(String(describing: error))")
        // Startup owns error presentation while it decides whether a single safe retry is valid.
        if !self.isStartingSession && self.streamingStatus != .stopped {
          self.showError(self.formatDeviceSessionError(error))
        }
      }
    }
  }

  /// Meta DAT may deliver DeviceSession.stopped before its descriptive error. Keep the
  /// error stream alive briefly after that terminal state, while still bounding the total wait.
  private func waitForDeviceSessionStart(
    _ session: DeviceSession,
    stateStream: AsyncStream<DeviceSessionState>,
    errorStream: AsyncStream<DeviceSessionError>
  ) async throws {
    if session.state == .started { return }

    let clock = ContinuousClock()
    let overallDeadline = clock.now.advanced(by: DeviceSessionStartWaitPolicy.overallTimeout)
    let firstTimeoutDeadline = min(
      clock.now.advanced(by: DeviceSessionStartWaitPolicy.timeoutInterval),
      overallDeadline)

    try await withThrowingTaskGroup(of: DeviceSessionStartEvent.self) { group in
      group.addTask {
        for await state in stateStream {
          NSLog("[DeviceSession] startup state=%@", String(describing: state))
          if state == .started { return .started }
          if state == .stopped { return .stopped }
        }
        return .observerEnded
      }

      group.addTask {
        for await error in errorStream {
          return .deviceError(error)
        }
        return .observerEnded
      }

      group.addTask {
        do {
          try await clock.sleep(until: firstTimeoutDeadline)
          return .timeout
        } catch {
          return .cancelled
        }
      }

      var isWaitingForLateError = session.state == .stopped
      if isWaitingForLateError {
        group.addTask {
          do {
            try await Task.sleep(nanoseconds: 750_000_000)
            return .stoppedErrorGraceExpired
          } catch {
            return .cancelled
          }
        }
      }

      while let event = try await group.next() {
        guard !Task.isCancelled else {
          group.cancelAll()
          throw CancellationError()
        }

        switch event {
        case .started:
          group.cancelAll()
          return

        case .deviceError(let error):
          group.cancelAll()
          throw error

        case .stopped:
          if session.state == .started {
            group.cancelAll()
            return
          }
          if !isWaitingForLateError {
            isWaitingForLateError = true
            group.addTask {
              do {
                try await Task.sleep(nanoseconds: 750_000_000)
                return .stoppedErrorGraceExpired
              } catch {
                return .cancelled
              }
            }
          }

        case .timeout:
          let hasRemainingOverallBudget = clock.now < overallDeadline
          switch DeviceSessionStartWaitPolicy.timeoutDisposition(
            for: session.state,
            isWaitingForLateError: isWaitingForLateError,
            hasRemainingOverallBudget: hasRemainingOverallBudget)
          {
          case .ready:
            group.cancelAll()
            return
          case .rearmWhilePaused:
            let candidateDeadline = clock.now.advanced(
              by: DeviceSessionStartWaitPolicy.timeoutInterval)
            let nextDeadline = min(candidateDeadline, overallDeadline)
            NSLog("[DeviceSession] startup remains paused; re-arming within overall deadline")
            group.addTask {
              do {
                try await clock.sleep(until: nextDeadline)
                return .timeout
              } catch {
                return .cancelled
              }
            }
            continue
          case .beginStoppedErrorGrace:
            isWaitingForLateError = true
            group.addTask {
              do {
                try await Task.sleep(nanoseconds: 750_000_000)
                return .stoppedErrorGraceExpired
              } catch {
                return .cancelled
              }
            }
            continue
          case .awaitStoppedErrorGrace:
            continue
          case .fail:
            group.cancelAll()
            throw DeviceSessionStartWaitError.timedOut
          }

        case .stoppedErrorGraceExpired:
          group.cancelAll()
          throw DeviceSessionStartWaitError.stoppedBeforeReady

        case .observerEnded:
          if session.state == .started {
            group.cancelAll()
            return
          }
          if session.state == .stopped, !isWaitingForLateError {
            isWaitingForLateError = true
            group.addTask {
              do {
                try await Task.sleep(nanoseconds: 750_000_000)
                return .stoppedErrorGraceExpired
              } catch {
                return .cancelled
              }
            }
          }

        case .cancelled:
          if Task.isCancelled {
            group.cancelAll()
            throw CancellationError()
          }
        }
      }

      throw DeviceSessionStartWaitError.stoppedBeforeReady
    }
  }

  private func beginSessionStartOperation() -> UInt64? {
    guard !isStartingSession else { return nil }
    sessionStartGeneration &+= 1
    isStartingSession = true
    return sessionStartGeneration
  }

  private func finishSessionStartOperation(_ operationGeneration: UInt64) {
    guard operationGeneration == sessionStartGeneration else { return }
    isStartingSession = false
  }

  private func sessionStartFailureCategory(for error: Error) -> DeviceSessionStartFailureCategory {
    if error is CancellationError {
      return .cancelled
    }

    if let waitError = error as? DeviceSessionStartWaitError {
      switch waitError {
      case .stoppedBeforeReady: return .stoppedBeforeReady
      case .timedOut: return .timedOut
      case .streamUnavailable: return .streamUnavailable
      }
    }

    guard let deviceError = error as? DeviceSessionError else {
      return .fatalDeviceError
    }

    switch deviceError {
    case .datAppOnTheGlassesUpdateRequired,
         .thermalCritical,
         .thermalEmergency,
         .peakPowerShutdown,
         .batteryCritical:
      return .fatalDeviceError
    case .noEligibleDevice,
         .sessionAlreadyExists,
         .capabilityAlreadyActive,
         .sessionAlreadyStopped,
         .sessionIdle,
         .capabilityNotFound,
         .dwaUnavailable,
         .unexpectedError:
      return .transientDeviceError
    @unknown default:
      return .fatalDeviceError
    }
  }

  private func retireOwnedSessionAttempt(
    _ session: DeviceSession?,
    generation: UInt64,
    operationGeneration: UInt64,
    keepWaiting: Bool
  ) async -> Bool {
    guard operationGeneration == sessionStartGeneration,
          generation == streamGeneration
    else {
      session?.stop()
      return false
    }
    if let session, let currentSession = deviceSession, currentSession !== session {
      session.stop()
      return false
    }
    return await retireCurrentGlassesSession(
      operationGeneration: operationGeneration,
      keepWaiting: keepWaiting)
  }

  private func retireCurrentGlassesSession(
    operationGeneration: UInt64,
    keepWaiting: Bool
  ) async -> Bool {
    guard operationGeneration == sessionStartGeneration else { return false }

    let oldStream = stream
    let oldSession = deviceSession
    await cleanupSession()
    oldStream?.stop()
    oldSession?.stop()

    let reachedStopped: Bool
    if let oldSession {
      reachedStopped = await waitForSessionToStop(oldSession) {
        operationGeneration == self.sessionStartGeneration
      }
    } else {
      reachedStopped = true
    }

    guard operationGeneration == sessionStartGeneration else { return false }
    currentVideoFrame = nil
    hasReceivedFirstFrame = false
    streamingStatus = keepWaiting && reachedStopped ? .waiting : .stopped
    recordSessionDiagnostic(
      "Retired session terminal=\(reachedStopped) keepWaiting=\(keepWaiting)")
    return reachedStopped
  }

  private func formatSessionStartFailure(_ error: Error, attempts: Int) -> String {
    if let deviceError = error as? DeviceSessionError {
      return formatDeviceSessionError(deviceError)
    }
    if let waitError = error as? DeviceSessionStartWaitError {
      switch waitError {
      case .stoppedBeforeReady:
        if attempts > 1 {
          return "The glasses session stopped twice before it was ready. Make sure no other app is using the glasses, then try again."
        }
        return waitError.localizedDescription
      case .timedOut:
        return "The glasses took too long to connect. Keep them unfolded and close to your iPhone, then try again."
      case .streamUnavailable:
        return "The glasses connected, but the camera stream was unavailable. Please try again."
      }
    }
    return "Failed to start the glasses session: \(error.localizedDescription)"
  }

  private func recordSessionDiagnostic(_ message: String) {
    let timestamp = String(format: "%.3f", Date().timeIntervalSince1970)
    let diagnostic = "\(timestamp) \(message)"
    UserDefaults.standard.set(diagnostic, forKey: Self.lastSessionDiagnosticKey)
    NSLog("[DeviceSession] %@", diagnostic)
  }

  private func cleanupSession() async {
    streamGeneration &+= 1
    foregroundFramePump?.reset()
    foregroundFramePump = nil
    videoDecoder.invalidateSession()
    stream = nil
    deviceSession = nil

    let oldSessionStateToken = sessionStateListenerToken
    let oldSessionErrorToken = sessionErrorListenerToken
    let oldStateToken = stateListenerToken
    let oldFrameToken = videoFrameListenerToken
    let oldErrorToken = errorListenerToken
    let oldPhotoToken = photoDataListenerToken
    sessionStateListenerToken = nil
    sessionErrorListenerToken = nil
    stateListenerToken = nil
    videoFrameListenerToken = nil
    errorListenerToken = nil
    photoDataListenerToken = nil

    if let oldSessionStateToken { await oldSessionStateToken.cancel() }
    if let oldSessionErrorToken { await oldSessionErrorToken.cancel() }
    if let oldStateToken { await oldStateToken.cancel() }
    if let oldFrameToken { await oldFrameToken.cancel() }
    if let oldErrorToken { await oldErrorToken.cancel() }
    if let oldPhotoToken { await oldPhotoToken.cancel() }
  }

  private func tearDownCurrentGlassesSession() async {
    let teardownStartGeneration = sessionStartGeneration
    let oldStream = stream
    let oldSession = deviceSession
    if oldStream != nil || oldSession != nil {
      streamingStatus = .waiting
    }
    await cleanupSession()
    oldStream?.stop()
    oldSession?.stop()
    if let oldSession {
      let stopped = await waitForSessionToStop(oldSession) { !Task.isCancelled }
      recordSessionDiagnostic("Teardown reached terminal stopped=\(stopped)")
    }
    // A newer start may have begun while token cancellation / terminal stop was awaited.
    // Never let an old teardown clear the replacement session's UI.
    guard teardownStartGeneration == sessionStartGeneration,
          stream == nil,
          deviceSession == nil
    else { return }
    currentVideoFrame = nil
    hasReceivedFirstFrame = false
    streamingStatus = .stopped
  }

  /// AI uses the stable low-bandwidth camera profile. If the user is viewing a
  /// larger raw stream, replace it only after DAT confirms the old session stopped.
  @discardableResult
  func prepareForAIMode() async -> Bool {
    guard streamingMode == .glasses else { return true }
    guard selectedResolution != StreamPerformanceProfile.aiResolution else {
      return stream != nil && deviceSession != nil
    }
    guard !isPreparingForAIMode else { return false }

    aiPreparationGeneration &+= 1
    let preparationGeneration = aiPreparationGeneration
    isPreparingForAIMode = true
    defer {
      if preparationGeneration == aiPreparationGeneration {
        isPreparingForAIMode = false
      }
    }

    let previousStream = stream
    let previousSession = deviceSession
    streamingStatus = .waiting
    await cleanupSession()
    previousStream?.stop()
    previousSession?.stop()

    if let previousSession {
      let stopped = await waitForSessionToStop(previousSession) {
        preparationGeneration == self.aiPreparationGeneration
      }
      guard stopped else {
        if preparationGeneration == aiPreparationGeneration {
          showError("The glasses did not finish switching to AI mode. Please stop streaming and try again.")
          streamingStatus = .stopped
        }
        return false
      }
    }

    guard preparationGeneration == aiPreparationGeneration else { return false }
    selectedResolution = StreamPerformanceProfile.aiResolution
    let started = await startSession()
    guard preparationGeneration == aiPreparationGeneration else { return false }
    return started
  }

  private func waitForSessionToStop(
    _ session: DeviceSession,
    while isCurrent: () -> Bool
  ) async -> Bool {
    for _ in 0..<40 {
      if session.state == .stopped { return true }
      if !isCurrent() || Task.isCancelled { return false }
      do {
        try await Task.sleep(nanoseconds: 50_000_000)
      } catch {
        return false
      }
    }
    return session.state == .stopped
  }

  private func showError(_ message: String) {
    errorMessage = message
    showError = true
  }

  func stopSession() async {
    sessionStartGeneration &+= 1
    isStartingSession = false
    aiPreparationGeneration &+= 1
    isPreparingForAIMode = false
    if streamingMode == .iPhone {
      stopIPhoneSession()
      return
    }
    await tearDownCurrentGlassesSession()
  }

  // MARK: - iPhone Camera Mode

  func handleStartIPhone() async {
    let granted = await IPhoneCameraManager.requestPermission()
    if granted {
      startIPhoneSession()
    } else {
      showError("Camera permission denied. Please grant access in Settings.")
    }
  }

  private func startIPhoneSession() {
    streamingMode = .iPhone
    let camera = IPhoneCameraManager()
    camera.onFrameCaptured = { [weak self] image in
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.currentVideoFrame = image
        if !self.hasReceivedFirstFrame {
          self.hasReceivedFirstFrame = true
        }
        self.geminiSessionVM?.sendVideoFrameIfThrottled(image: image)
        self.webrtcSessionVM?.pushVideoFrame(image)
      }
    }
    camera.start()
    iPhoneCameraManager = camera
    streamingStatus = .streaming
    NSLog("[Stream] iPhone camera mode started")
  }

  private func stopIPhoneSession() {
    iPhoneCameraManager?.stop()
    iPhoneCameraManager = nil
    currentVideoFrame = nil
    hasReceivedFirstFrame = false
    streamingStatus = .stopped
    streamingMode = .glasses
    NSLog("[Stream] iPhone camera mode stopped")
  }

  func dismissError() {
    showError = false
    errorMessage = ""
  }

  func capturePhoto() {
    _ = stream?.capturePhoto(format: .jpeg)
  }

  func dismissPhotoPreview() {
    showPhotoPreview = false
    capturedPhoto = nil
  }

  private func updateStatusFromState(_ state: StreamState, generation: UInt64) {
    switch state {
    case .stopped:
      currentVideoFrame = nil
      hasReceivedFirstFrame = false
      streamingStatus = .waiting
      recordSessionDiagnostic("Camera stream stopped generation=\(generation); retiring parent session")
      Task { @MainActor [weak self] in
        guard let self, generation == self.streamGeneration else { return }
        await self.tearDownCurrentGlassesSession()
      }
    case .waitingForDevice, .starting, .stopping, .paused:
      streamingStatus = .waiting
    case .streaming:
      streamingStatus = .streaming
    }
  }

  private func formatStreamingError(_ error: StreamError) -> String {
    switch error {
    case .internalError:
      return "An internal error occurred. Please try again."
    case .deviceNotFound:
      return "Device not found. Please ensure your device is connected."
    case .deviceNotConnected:
      return "Device not connected. Please check your connection and try again."
    case .timeout:
      return "The operation timed out. Please try again."
    case .videoStreamingError:
      return "Video streaming failed. Please try again."
    case .permissionDenied:
      return "Camera permission denied. Please grant permission in Settings."
    case .hingesClosed:
      return "The hinges on the glasses were closed. Please open the hinges and try again."
    case .thermalCritical, .thermalEmergency:
      return "The glasses are too warm to stream right now. Let them cool down and try again."
    case .peakPowerShutdown:
      return "The glasses stopped streaming to protect the hardware. Let them cool down, then try again."
    case .batteryCritical:
      return "The glasses' battery is too low to stream. Charge them and try again."
    @unknown default:
      return "An unknown streaming error occurred."
    }
  }

  /// Map 0.7.0 device-session errors to a user-facing message. noEligibleDevice /
  /// datAppOnTheGlassesUpdateRequired are the common "glasses won't attach" cases.
  private func formatDeviceSessionError(_ error: DeviceSessionError) -> String {
    switch error {
    case .noEligibleDevice:
      return "No compatible glasses were found. Make sure your glasses are connected in the Meta AI app and camera access is granted."
    case .datAppOnTheGlassesUpdateRequired:
      return "Your glasses need a software update. Open the Meta AI app and update your glasses, then try again."
    case .sessionAlreadyExists, .capabilityAlreadyActive:
      return "A session is already active. Stop streaming and try again."
    case .sessionAlreadyStopped, .sessionIdle, .capabilityNotFound:
      return "The glasses session is not ready. Stop streaming and try again."
    case .thermalCritical, .thermalEmergency:
      return "The glasses are too warm to stream right now. Let them cool down and try again."
    case .peakPowerShutdown:
      return "The glasses stopped the session to protect the hardware. Let them cool down, then try again."
    case .batteryCritical:
      return "The glasses' battery is too low to stream. Charge them and try again."
    case .dwaUnavailable:
      return "The glasses connection service is unavailable. Restart the glasses and the Meta AI app, then try again."
    case .unexpectedError(let description):
      return "Failed to start session: \(description)"
    @unknown default:
      return "Failed to start the glasses session. Please try again."
    }
  }
}
