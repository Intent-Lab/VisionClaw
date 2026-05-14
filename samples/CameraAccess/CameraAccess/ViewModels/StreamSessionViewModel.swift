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

import Combine
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

@MainActor
final class DeviceSessionManager: ObservableObject {
  @Published private(set) var isReady: Bool = false
  @Published private(set) var hasActiveDevice: Bool = false
  @Published private(set) var currentState: DeviceSessionState = .stopped

  private let wearables: WearablesInterface
  private let deviceSelector: AutoDeviceSelector
  private var deviceSession: DeviceSession?
  private var deviceMonitorTask: Task<Void, Never>?
  private var stateObserverTask: Task<Void, Never>?

  init(wearables: WearablesInterface) {
    self.wearables = wearables
    self.deviceSelector = AutoDeviceSelector(wearables: wearables)
    startDeviceMonitoring()
  }

  deinit {
    deviceMonitorTask?.cancel()
    stateObserverTask?.cancel()
  }

  func getSession() async -> DeviceSession? {
    if let session = deviceSession, session.state == .started {
      isReady = true
      currentState = session.state
      return session
    }

    if let session = deviceSession {
      currentState = session.state
      switch session.state {
      case .stopped:
        deviceSession = nil
      case .paused, .stopping:
        isReady = false
        return nil
      case .idle, .starting:
        return await waitForReadySession(session)
      case .started:
        isReady = true
        return session
      @unknown default:
        return nil
      }
    }

    guard deviceSession == nil else { return nil }

    do {
      let session = try wearables.createSession(deviceSelector: deviceSelector)
      deviceSession = session
      currentState = session.state
      try session.start()
      return await waitForReadySession(session)
    } catch {
      isReady = false
      currentState = .stopped
      deviceSession = nil
    }

    return nil
  }

  func stopSession() {
    stateObserverTask?.cancel()
    stateObserverTask = nil
    deviceSession?.stop()
    deviceSession = nil
    isReady = false
    currentState = .stopped
  }

  private func startDeviceMonitoring() {
    deviceMonitorTask = Task { [weak self] in
      guard let self else { return }
      for await device in deviceSelector.activeDeviceStream() {
        hasActiveDevice = device != nil
        if device != nil {
          _ = await getSession()
        } else {
          handleDeviceLost()
        }
      }
    }
  }

  private func startStateObserver(for session: DeviceSession) {
    stateObserverTask?.cancel()
    stateObserverTask = Task { [weak self] in
      guard let self else { return }
      for await state in session.stateStream() {
        currentState = state
        isReady = state == .started
        if state == .stopped {
          deviceSession = nil
          return
        }
      }
    }
  }

  private func waitForReadySession(_ session: DeviceSession) async -> DeviceSession? {
    currentState = session.state

    if session.state == .started {
      isReady = true
      startStateObserver(for: session)
      return session
    }

    for await state in session.stateStream() {
      currentState = state
      switch state {
      case .started:
        isReady = true
        startStateObserver(for: session)
        return session
      case .paused, .stopped:
        isReady = false
        if state == .stopped {
          deviceSession = nil
        }
        return nil
      case .idle, .starting, .stopping:
        continue
      @unknown default:
        continue
      }
    }

    return nil
  }

  private func handleDeviceLost() {
    stateObserverTask?.cancel()
    stateObserverTask = nil
    deviceSession?.stop()
    deviceSession = nil
    isReady = false
    currentState = .stopped
  }
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
  @Published var deviceSessionStateDescription: String = "stopped"
  @Published var isDeviceSessionReady: Bool = false

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

  // The core DAT SDK StreamSession - attached to a DeviceSession when video mode is active
  private var streamSession: StreamSession?
  // Listener tokens are used to manage DAT SDK event subscriptions
  private var stateListenerToken: AnyListenerToken?
  private var videoFrameListenerToken: AnyListenerToken?
  private var errorListenerToken: AnyListenerToken?
  private var photoDataListenerToken: AnyListenerToken?
  private let wearables: WearablesInterface
  private let sessionManager: DeviceSessionManager
  private var cancellables = Set<AnyCancellable>()
  private var iPhoneCameraManager: IPhoneCameraManager?

  // CPU-based CIContext for rendering decoded pixel buffers in background
  private let cpuCIContext = CIContext(options: [.useSoftwareRenderer: true])
  // VideoDecoder for decompressing HEVC/H.264 frames in background
  private let videoDecoder = VideoDecoder()
  private var backgroundFrameCount = 0
  private var bgDiagLogged = false

  init(wearables: WearablesInterface) {
    self.wearables = wearables
    self.sessionManager = DeviceSessionManager(wearables: wearables)

    sessionManager.$hasActiveDevice
      .receive(on: DispatchQueue.main)
      .assign(to: &$hasActiveDevice)

    sessionManager.$isReady
      .receive(on: DispatchQueue.main)
      .assign(to: &$isDeviceSessionReady)

    sessionManager.$currentState
      .receive(on: DispatchQueue.main)
      .sink { [weak self] state in
        self?.handleDeviceSessionStateChange(state)
      }
      .store(in: &cancellables)

    setupVideoDecoder()
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

  /// Recreate the StreamSession with the current selectedResolution.
  /// Only call when not actively streaming.
  func updateResolution(_ resolution: StreamingResolution) {
    guard !isStreaming else { return }
    selectedResolution = resolution
    NSLog("[Stream] Resolution changed to %@", resolutionLabel)
  }

  private func attachListeners(to streamSession: StreamSession) {
    clearListeners()

    // Subscribe to session state changes using the DAT SDK listener pattern
    stateListenerToken = streamSession.statePublisher.listen { [weak self] state in
      Task { @MainActor [weak self] in
        self?.updateStatusFromState(state)
      }
    }

    // Subscribe to video frames from the device camera
    // This callback fires whether the app is in the foreground or background,
    // enabling continuous streaming even when the screen is locked.
    videoFrameListenerToken = streamSession.videoFramePublisher.listen { [weak self] videoFrame in
      Task { @MainActor [weak self] in
        guard let self else { return }

        let isInBackground = UIApplication.shared.applicationState == .background

        if !isInBackground {
          self.backgroundFrameCount = 0
          self.bgDiagLogged = false
          if let image = videoFrame.makeUIImage() {
            self.currentVideoFrame = image
            if !self.hasReceivedFirstFrame {
              self.hasReceivedFirstFrame = true
            }
            self.geminiSessionVM?.sendVideoFrameIfThrottled(image: image)
            self.webrtcSessionVM?.pushVideoFrame(image)
          }
        } else {
          // In background: makeUIImage() uses VideoToolbox GPU rendering which iOS suspends.
          // Instead, use our VideoDecoder (VTDecompressionSession) to decode compressed
          // frames into pixel buffers, then convert via CPU CIContext.
          self.backgroundFrameCount += 1

          let sampleBuffer = videoFrame.sampleBuffer
          let hasCompressedData = CMSampleBufferGetDataBuffer(sampleBuffer) != nil

          if hasCompressedData {
            // Compressed frame (HEVC/H.264) - decode via VTDecompressionSession
            do {
              try self.videoDecoder.decode(sampleBuffer)
            } catch {
              if self.backgroundFrameCount <= 5 || self.backgroundFrameCount % 120 == 0 {
                NSLog("[Stream] Background frame #%d decode error: %@",
                      self.backgroundFrameCount, String(describing: error))
              }
            }
          } else if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            // Raw pixel buffer - convert directly via CPU CIContext
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            let rect = CGRect(x: 0, y: 0, width: width, height: height)
            if let cgImage = self.cpuCIContext.createCGImage(ciImage, from: rect) {
              let image = UIImage(cgImage: cgImage)
              self.geminiSessionVM?.sendVideoFrameIfThrottled(image: image)
              self.webrtcSessionVM?.pushVideoFrame(image)
            }
            self.videoDecoder.invalidateSession()
          }
        }
      }
    }

    // Subscribe to streaming errors
    errorListenerToken = streamSession.errorPublisher.listen { [weak self] error in
      Task { @MainActor [weak self] in
        guard let self else { return }
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

    updateStatusFromState(streamSession.state)

    // Subscribe to photo capture events
    photoDataListenerToken = streamSession.photoDataPublisher.listen { [weak self] photoData in
      Task { @MainActor [weak self] in
        guard let self else { return }
        if let uiImage = UIImage(data: photoData.data) {
          self.capturedPhoto = uiImage
          self.showPhotoPreview = true
        }
      }
    }
  }

  private func clearListeners() {
    stateListenerToken = nil
    videoFrameListenerToken = nil
    errorListenerToken = nil
    photoDataListenerToken = nil
  }

  func handleStartStreaming() async {
    if !SettingsManager.shared.videoStreamingEnabled {
      await startAudioOnlyGlassesSession()
      return
    }

    let permission = Permission.camera
    do {
      let status = try await wearables.checkPermissionStatus(permission)
      if status == .granted {
        await startSession()
        return
      }
      let requestStatus = try await wearables.requestPermission(permission)
      if requestStatus == .granted {
        await startSession()
        return
      }
      showError("Camera permission denied")
    } catch {
      showError("Permission error: \(error.description)")
    }
  }

  func startSession() async {
    streamingMode = .glasses
    streamingStatus = .waiting

    guard let deviceSession = await sessionManager.getSession() else {
      showError("Could not start a device session with the glasses.")
      return
    }

    guard deviceSession.state == .started else {
      showError("Device session is not ready yet.")
      return
    }

    let config = StreamSessionConfig(
      videoCodec: VideoCodec.raw,
      resolution: selectedResolution,
      frameRate: 24)

    guard let stream = try? deviceSession.addStream(config: config) else {
      showError("Failed to attach camera streaming to the device session.")
      return
    }

    streamSession = stream
    attachListeners(to: stream)
    await stream.start()
  }

  private func showError(_ message: String) {
    errorMessage = message
    showError = true
  }

  func stopSession() async {
    if streamingMode == .iPhone {
      stopIPhoneSession()
      return
    }
    if !SettingsManager.shared.videoStreamingEnabled {
      stopAudioOnlyGlassesSession()
      return
    }
    guard let streamSession else {
      clearActiveGlassesStreamingState()
      sessionManager.stopSession()
      return
    }
    clearActiveGlassesStreamingState()
    await streamSession.stop()
    sessionManager.stopSession()
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
    streamSession?.capturePhoto(format: .jpeg)
  }

  func dismissPhotoPreview() {
    showPhotoPreview = false
    capturedPhoto = nil
  }

  private func updateStatusFromState(_ state: StreamSessionState) {
    guard SettingsManager.shared.videoStreamingEnabled else { return }

    switch state {
    case .stopped:
      currentVideoFrame = nil
      streamingStatus = .stopped
    case .waitingForDevice, .starting, .stopping, .paused:
      streamingStatus = .waiting
    case .streaming:
      streamingStatus = .streaming
    }
  }

  private func handleDeviceSessionStateChange(_ state: DeviceSessionState) {
    deviceSessionStateDescription = describeDeviceSessionState(state)

    guard streamingMode == .glasses else { return }

    switch state {
    case .started:
      if !SettingsManager.shared.videoStreamingEnabled {
        streamingStatus = .streaming
      } else if streamSession == nil {
        streamingStatus = .stopped
      } else if streamingStatus == .stopped {
        streamingStatus = .waiting
      }
    case .idle, .starting, .paused, .stopping:
      if streamSession != nil || streamingStatus != .stopped {
        streamingStatus = .waiting
      }
    case .stopped:
      clearActiveGlassesStreamingState()
    @unknown default:
      if streamSession != nil || streamingStatus != .stopped {
        streamingStatus = .waiting
      }
    }
  }

  private func clearActiveGlassesStreamingState() {
    clearListeners()
    streamSession = nil
    currentVideoFrame = nil
    hasReceivedFirstFrame = false
    streamingStatus = .stopped
  }

  private func describeDeviceSessionState(_ state: DeviceSessionState) -> String {
    switch state {
    case .idle: return "idle"
    case .starting: return "starting"
    case .started: return "started"
    case .paused: return "paused"
    case .stopping: return "stopping"
    case .stopped: return "stopped"
    @unknown default: return "unknown"
    }
  }

  private func startAudioOnlyGlassesSession() async {
    guard hasActiveDevice else {
      showError("No active glasses found. Connect the glasses first.")
      return
    }

    guard await sessionManager.getSession() != nil else {
      showError("Could not start an audio-only device session.")
      return
    }

    streamingMode = .glasses
    currentVideoFrame = nil
    hasReceivedFirstFrame = false
    streamingStatus = isDeviceSessionReady ? .streaming : .waiting
    NSLog("[Stream] Audio-only glasses mode started")
  }

  private func stopAudioOnlyGlassesSession() {
    clearActiveGlassesStreamingState()
    sessionManager.stopSession()
    NSLog("[Stream] Audio-only glasses mode stopped")
  }

  private func formatStreamingError(_ error: StreamSessionError) -> String {
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
    @unknown default:
      return "An unknown streaming error occurred."
    }
  }
}
