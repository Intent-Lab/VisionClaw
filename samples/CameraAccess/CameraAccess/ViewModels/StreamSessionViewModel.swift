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
// DAT 0.9 model: a DeviceSession is created and started first, then a Camera is
// added to it and its Stream carries the video. The old single StreamSession
// object (0.4) is gone; this view model keeps the same public surface so the
// views and the LiveKit bridge are unchanged.
//

import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import MWDATCamera
import MWDATCore
import SwiftUI
import VideoToolbox

enum StreamingStatus: Equatable {
  case streaming
  case waiting
  case stopped
}

enum StreamingMode {
  case glasses
  case iPhone
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
  @Published var selectedResolution: StreamingResolution = .high

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

  // DAT 0.9 splits the old StreamSession into a DeviceSession (the connection to
  // the glasses) and a Camera whose `stream` carries the video. Both are nil when
  // the Wearables SDK is unavailable (simulator, or a build without glasses); the
  // iPhone camera path never touches them.
  private var deviceSession: DeviceSession?
  private var camera: Camera?
  // Set when the user asked to stream; the session state observer starts the
  // camera as soon as the session reaches `.started`, since a camera can only be
  // added to a started session.
  private var wantsStream: Bool = false
  // Listener tokens are used to manage DAT SDK event subscriptions
  private var sessionStateListenerToken: AnyListenerToken?
  private var stateListenerToken: AnyListenerToken?
  private var videoFrameListenerToken: AnyListenerToken?
  private var errorListenerToken: AnyListenerToken?
  private var photoDataListenerToken: AnyListenerToken?
  private let wearables: WearablesInterface?
  private let deviceSelector: AutoDeviceSelector?
  private var deviceMonitorTask: Task<Void, Never>?
  // CPU-based CIContext for rendering decoded pixel buffers in background
  private let cpuCIContext = CIContext(options: [.useSoftwareRenderer: true])
  // VideoDecoder for decompressing HEVC/H.264 frames in background
  private let videoDecoder = VideoDecoder()
  private var backgroundFrameCount = 0
  private var bgDiagLogged = false
  // Throttles the (redundant, expensive) UIImage preview so it can't saturate
  // the main thread; the LiveKit feed itself is never throttled.
  private var previewThrottle: Int = 0
  // Requested glasses frame rate. Low fps gives each frame more of the limited
  // Bluetooth-Classic bandwidth -> less per-frame compression -> sharper frames,
  // which is what the vision model needs (it samples stills, not motion). Meta's
  // auto-ladder floor is 15fps, so the glasses may clamp this up; the fps log
  // below reports the actual delivered rate.
  private let requestedFrameRate: UInt = 5
  private var fpsCount: Int = 0
  private var fpsWindowStart: Date = .now

  init(wearables: WearablesInterface?) {
    self.wearables = wearables

    if let wearables {
      // Let the SDK auto-select from available devices
      let selector = AutoDeviceSelector(wearables: wearables)
      self.deviceSelector = selector

      // Monitor device availability
      deviceMonitorTask = Task { @MainActor in
        for await device in selector.activeDeviceStream() {
          self.hasActiveDevice = device != nil
        }
      }
    } else {
      self.deviceSelector = nil
    }

    setupVideoDecoder()
  }

  /// Bridge to the LiveKit call: every decoded glasses frame is also handed
  /// here, so the room publishes exactly what the glasses see.
  var onDecodedFrame: ((CVPixelBuffer) -> Void)?

  private func setupVideoDecoder() {
    videoDecoder.setFrameCallback { [weak self] decodedFrame in
      Task { @MainActor [weak self] in
        guard let self else { return }
        let pixelBuffer = decodedFrame.pixelBuffer
        self.onDecodedFrame?(pixelBuffer)
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        if let cgImage = self.cpuCIContext.createCGImage(ciImage, from: rect) {
          let image = UIImage(cgImage: cgImage)
          if self.backgroundFrameCount <= 5 || self.backgroundFrameCount % 120 == 0 {
            NSLog("[Stream] Background frame #%d decoded and forwarded (%dx%d)",
                  self.backgroundFrameCount, width, height)
          }
        }
      }
    }
  }

  /// Store the resolution to use for the next stream. In 0.9 the config is applied
  /// when the camera is added, so this only takes effect when not streaming.
  func updateResolution(_ resolution: StreamingResolution) {
    guard !isStreaming else { return }
    selectedResolution = resolution
    NSLog("[Stream] Resolution changed to %@", resolutionLabel)
  }

  private func streamConfig() -> StreamConfiguration {
    // 720x1280 (.high) for the most detail the glasses will stream. A low frame
    // rate trades motion smoothness for sharper frames on the Bluetooth-limited
    // link, which suits a vision model that reads stills.
    StreamConfiguration(
      videoCodec: VideoCodec.raw,
      resolution: selectedResolution,
      frameRate: requestedFrameRate)
  }

  private func observeSession(_ session: DeviceSession) {
    sessionStateListenerToken = session.statePublisher.listen { [weak self] state in
      Task { @MainActor [weak self] in
        self?.handleSessionState(state)
      }
    }
  }

  private func handleSessionState(_ state: DeviceSessionState) {
    switch state {
    case .started:
      // A camera can only be added to a started session; start it now if the user
      // asked to stream and one isn't already attached.
      if wantsStream, camera == nil {
        beginStream()
      }
    case .idle, .stopped:
      camera = nil
      deviceSession = nil
      wantsStream = false
      currentVideoFrame = nil
      streamingStatus = .stopped
    case .starting, .stopping:
      streamingStatus = .waiting
    case .paused:
      streamingStatus = .waiting
    }
  }

  /// Adds a camera to the started session and wires its stream's listeners, then
  /// starts it. The video frames flow through `camera.stream.videoFramePublisher`.
  private func beginStream() {
    guard let session = deviceSession, session.state == .started else { return }
    do {
      guard let newCamera = try session.addCamera(config: streamConfig()) else {
        glassesIssue = .reconnecting
        return
      }
      camera = newCamera
      attachStreamListeners(to: newCamera.stream)
      // Subscribe before start() so no initial state transitions are missed.
      newCamera.stream.start()
    } catch {
      camera = nil
      // Sleeping or out-of-range glasses are a wait, not a hard error.
      glassesIssue = mapDeviceSessionError(error)
    }
  }

  private func attachStreamListeners(to stream: MWDATCamera.Stream) {
    // Subscribe to stream state changes using the DAT SDK listener pattern
    stateListenerToken = stream.statePublisher.listen { [weak self] state in
      Task { @MainActor [weak self] in
        self?.updateStatusFromState(state)
      }
    }

    // Subscribe to video frames from the device camera
    // This callback fires whether the app is in the foreground or background,
    // enabling continuous streaming even when the screen is locked.
    videoFrameListenerToken = stream.videoFramePublisher.listen { [weak self] videoFrame in
      Task { @MainActor [weak self] in
        guard let self else { return }

        // Feed LiveKit every frame -- this is the call's actual video and must
        // run at full frame rate. Raw frames (VideoCodec.raw) carry the pixel
        // buffer directly; hand it straight to the room in both foreground and
        // background so the agent keeps seeing the glasses with the screen off.
        if let pixelBuffer = CMSampleBufferGetImageBuffer(videoFrame.sampleBuffer) {
          self.onDecodedFrame?(pixelBuffer)
        }
        if !self.hasReceivedFirstFrame {
          self.hasReceivedFirstFrame = true
          self.fpsWindowStart = .now
          if let pb = CMSampleBufferGetImageBuffer(videoFrame.sampleBuffer) {
            NSLog("[Stream] first glasses frame %dx%d (config %@)",
                  CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb), self.resolutionLabel)
          }
        }
        // Report the actual delivered frame rate so we can see whether the
        // glasses honor the requested fps or clamp it to their floor.
        self.fpsCount += 1
        let fpsElapsed = Date.now.timeIntervalSince(self.fpsWindowStart)
        if fpsElapsed >= 3 {
          NSLog("[Stream] delivered %.1f fps (requested %u)",
                Double(self.fpsCount) / fpsElapsed, self.requestedFrameRate)
          self.fpsCount = 0
          self.fpsWindowStart = .now
        }
        // The UIImage preview is only for the legacy StreamView; LiveKit renders
        // the track itself during a call, so makeUIImage (a GPU->CPU render) is
        // redundant here. Throttle it to a few fps and skip it while backgrounded
        // so 24fps of it can't saturate the main thread and trip the watchdog
        // (the freeze then SIGKILL).
        self.previewThrottle &+= 1
        if self.previewThrottle % 6 == 0,
           UIApplication.shared.applicationState != .background,
           let image = videoFrame.makeUIImage() {
          self.currentVideoFrame = image
        }
      }
    }

    // Subscribe to streaming errors
    errorListenerToken = stream.errorPublisher.listen { [weak self] error in
      Task { @MainActor [weak self] in
        guard let self else { return }
        // One voice: glasses-state conditions render as placeholder text on
        // the call screen, never as alert dialogs. Sleeping/absent glasses are
        // a plain wait; everything else maps to a typed issue.
        switch error {
        case .deviceNotConnected, .deviceNotFound:
          self.glassesIssue = nil
        case .hingesClosed:
          self.glassesIssue = .hingesClosed
        case .permissionDenied:
          self.glassesIssue = .permissionNeeded
        default:
          self.glassesIssue = .reconnecting
        }
      }
    }

    // Do not seed from stream.state here: a freshly created camera's stream is
    // .stopped until start(), and seeding that would flip streamingStatus to
    // .stopped mid-startup. The statePublisher above delivers the real
    // transitions (.starting -> .streaming) right after start().

    // Subscribe to photo capture events
    photoDataListenerToken = stream.photoDataPublisher.listen { [weak self] photoData in
      Task { @MainActor [weak self] in
        guard let self else { return }
        guard let uiImage = UIImage(data: photoData.data) else { return }
        self.capturedPhoto = uiImage
        self.showPhotoPreview = true
      }
    }
  }

  /// Glasses-state conditions the call screen's placeholder can name --
  /// the app's own voice, replacing the sample's alert dialogs.
  enum GlassesIssue: Equatable {
    case sdkUnavailable
    case permissionNeeded
    case hingesClosed
    case reconnecting
  }

  @Published var glassesIssue: GlassesIssue?

  func handleStartStreaming() async {
    glassesIssue = nil
    guard let wearables else {
      glassesIssue = .sdkUnavailable
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
      glassesIssue = .permissionNeeded
    } catch {
      // Sleeping or out-of-range glasses are a wait state, not an error.
      let text = String(describing: error).lowercased()
      if text.contains("powered off") || text.contains("disconnected") || text.contains("no device") {
        NSLog("[Stream] glasses unavailable, waiting: %@", String(describing: error))
        glassesIssue = nil
      } else {
        glassesIssue = .reconnecting
      }
    }
  }

  /// Creates and starts the DeviceSession, then streams once it reaches `.started`.
  func startSession() async {
    guard let wearables, let deviceSelector else {
      glassesIssue = .sdkUnavailable
      return
    }
    guard deviceSession == nil else {
      // Session already up; just (re)start the camera if needed.
      wantsStream = true
      if deviceSession?.state == .started, camera == nil {
        beginStream()
      }
      return
    }
    wantsStream = true
    do {
      let session = try wearables.createSession(deviceSelector: deviceSelector)
      deviceSession = session
      // Subscribe before start() so no initial state transitions are missed.
      observeSession(session)
      streamingStatus = .waiting
      try session.start()
    } catch {
      glassesIssue = mapDeviceSessionError(error)
      wantsStream = false
      deviceSession = nil
      streamingStatus = .stopped
    }
  }

  private func mapDeviceSessionError(_ error: DeviceSessionError) -> GlassesIssue? {
    switch error {
    case .noEligibleDevice:
      // No glasses in range/awake: a plain wait, not a hard error.
      return nil
    default:
      return .reconnecting
    }
  }

  private func showError(_ message: String) {
    errorMessage = message
    showError = true
  }

  /// Stops the camera stream and ends the device session. `stop()` is terminal
  /// and cascades to the stream; the state observers clear our references.
  func stopSession() async {
    wantsStream = false
    if let camera {
      camera.stop()
    }
    deviceSession?.stop()
  }

  func dismissError() {
    showError = false
    errorMessage = ""
  }

  func capturePhoto() {
    _ = camera?.stream.capturePhoto(format: .jpeg)
  }

  func dismissPhotoPreview() {
    showPhotoPreview = false
    capturedPhoto = nil
  }

  private func updateStatusFromState(_ state: StreamState) {
    switch state {
    case .stopped:
      currentVideoFrame = nil
      streamingStatus = .stopped
    case .waitingForDevice, .starting, .stopping, .paused:
      streamingStatus = .waiting
    case .streaming:
      streamingStatus = .streaming
      glassesIssue = nil
    }
  }
}
