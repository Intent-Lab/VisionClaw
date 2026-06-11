import Foundation
import QuartzCore
import SwiftUI
import WebRTC

final class WebRTCRealtimeVideoForwarder: @unchecked Sendable {
  private let queue = DispatchQueue(
    label: "visionclaw.webrtc.realtime-forwarder",
    qos: .userInteractive
  )
  private let stateLock = NSLock()
  private var imageHandler: ((UIImage) -> Void)?
  private var pixelBufferHandler: ((CVPixelBuffer, Int64) -> Void)?
  private var pendingPixelBuffer: CVPixelBuffer?
  private var pendingPixelBufferTimestampNs: Int64 = 0
  private var pendingPixelBufferQueuedAt = CACurrentMediaTime()
  private var isPixelBufferDrainScheduled = false
  private var pixelBufferForwardCount: Int64 = 0
  private var stalePixelBufferDropCount: Int64 = 0
  private var pixelBufferStatsWindowStart = CACurrentMediaTime()

  func updateHandlers(
    imageHandler: ((UIImage) -> Void)?,
    pixelBufferHandler: ((CVPixelBuffer, Int64) -> Void)?
  ) {
    clearPendingPixelBuffer()
    queue.async {
      self.imageHandler = imageHandler
      self.pixelBufferHandler = pixelBufferHandler
    }
  }

  func enqueueImage(_ image: UIImage) {
    queue.async {
      self.imageHandler?(image)
    }
  }

  func enqueuePixelBuffer(_ pixelBuffer: CVPixelBuffer, timeStampNs: Int64) {
    let queuedAt = CACurrentMediaTime()

    var shouldScheduleDrain = false
    stateLock.lock()
    if pendingPixelBuffer != nil {
      stalePixelBufferDropCount += 1
    }
    pendingPixelBuffer = pixelBuffer
    pendingPixelBufferTimestampNs = timeStampNs
    pendingPixelBufferQueuedAt = queuedAt
    if !isPixelBufferDrainScheduled {
      isPixelBufferDrainScheduled = true
      shouldScheduleDrain = true
    }
    stateLock.unlock()

    if shouldScheduleDrain {
      queue.async { [weak self] in
        self?.drainLatestPixelBuffer()
      }
    }
  }

  private func clearPendingPixelBuffer() {
    stateLock.lock()
    pendingPixelBuffer = nil
    isPixelBufferDrainScheduled = false
    stateLock.unlock()
  }

  private func drainLatestPixelBuffer() {
    while true {
      stateLock.lock()
      guard let pixelBuffer = pendingPixelBuffer else {
        isPixelBufferDrainScheduled = false
        stateLock.unlock()
        return
      }
      let timeStampNs = pendingPixelBufferTimestampNs
      let queuedAt = pendingPixelBufferQueuedAt
      pendingPixelBuffer = nil
      stateLock.unlock()

      pixelBufferHandler?(pixelBuffer, timeStampNs)
      pixelBufferForwardCount += 1
      logPixelBufferForwardStatsIfNeeded(waitDurationMs: (CACurrentMediaTime() - queuedAt) * 1000)
    }
  }

  private func logPixelBufferForwardStatsIfNeeded(waitDurationMs: Double) {
    guard pixelBufferForwardCount == 1 || pixelBufferForwardCount % 120 == 0 else { return }
    let now = CACurrentMediaTime()
    let elapsed = max(now - pixelBufferStatsWindowStart, 0.001)
    let fps = Double(pixelBufferForwardCount) / elapsed
    NSLog(
      "[WebRTC] Realtime forwarder rate=%.1ffps last-wait=%.2fms stale-dropped=%lld",
      fps,
      waitDurationMs,
      stalePixelBufferDropCount
    )
    Task {
      await WorkerTelemetry.shared.record(
        "webrtc_realtime_forwarder",
        source: "webrtc",
        stage: "forwarder",
        durationMs: waitDurationMs,
        metricValue: fps,
        metricUnit: "fps",
        payload: [
          "fps": fps,
          "wait_ms": waitDurationMs,
          "stale_dropped": stalePixelBufferDropCount
        ]
      )
    }
    pixelBufferStatsWindowStart = now
    pixelBufferForwardCount = 0
    stalePixelBufferDropCount = 0
  }
}

enum WebRTCConnectionState: Equatable {
  case disconnected
  case connecting
  case waitingForPeer
  case connected
  case backgrounded
  case error(String)
}

/// Orchestrates the WebRTC live streaming session: signaling, peer connection, and frame forwarding.
/// Follows the same @MainActor ObservableObject pattern as GeminiSessionViewModel.
@MainActor
class WebRTCSessionViewModel: ObservableObject {
  @Published var isActive: Bool = false
  @Published var connectionState: WebRTCConnectionState = .disconnected
  @Published var roomCode: String = ""
  @Published var isMuted: Bool = false
  @Published var errorMessage: String?
  @Published var remoteVideoTrack: RTCVideoTrack?
  @Published var remoteAudioTrack: RTCAudioTrack?
  @Published var hasRemoteVideo: Bool = false
  @Published var hasRemoteAudio: Bool = false
  @Published var incomingRemoteVideoEnabled: Bool = true
  @Published var isUnderLiveVideoPressure: Bool = false
  @Published private(set) var roomMode: WebRTCRoomMode = .observation

  nonisolated let realtimeVideoForwarder = WebRTCRealtimeVideoForwarder()

  private var webRTCClient: WebRTCClient?
  private var signalingClient: SignalingClient?
  private var delegateAdapter: WebRTCDelegateAdapter?
  private var currentCaptureMode: StreamingMode = .glasses
  private var wantsIncomingRemoteVideo = true
  private var isUsingPhoneFallbackProfile = false
  private var stablePhoneSenderWindows = 0

  /// Saved room code for reconnecting after app backgrounding.
  private var savedRoomCode: String?
  private var foregroundObserver: Any?

  var isSupportMode: Bool {
    roomMode == .support
  }

  func startSession(
    captureMode: StreamingMode = .glasses,
    roomMode: WebRTCRoomMode = .support
  ) async {
    guard !isActive else { return }
    guard WebRTCConfig.isConfigured else {
      errorMessage = "WebRTC signaling URL not configured."
      return
    }

    isActive = true
    connectionState = .connecting
    savedRoomCode = nil
    currentCaptureMode = captureMode
    self.roomMode = roomMode
    wantsIncomingRemoteVideo = roomMode == .support && captureMode != .iPhone
    incomingRemoteVideoEnabled = wantsIncomingRemoteVideo
    isUsingPhoneFallbackProfile = false
    stablePhoneSenderWindows = 0
    Task {
      await WorkerTelemetry.shared.record(
        "webrtc_session_start",
        source: "webrtc",
        stage: "connecting",
        payload: [
          "capture_mode": captureMode == .iPhone ? "iphone" : "glasses",
          "room_mode": roomMode.rawValue,
          "audio_enabled": roomMode.usesAudio
        ]
      )
    }

    // Fetch TURN credentials for NAT traversal across networks
    let iceServers = await WebRTCConfig.fetchIceServers()

    setupWebRTCClient(iceServers: iceServers, captureMode: captureMode)
    connectSignaling(rejoinCode: nil)
    observeForeground()
  }

  func stopSession() {
    removeForegroundObserver()
    realtimeVideoForwarder.updateHandlers(imageHandler: nil, pixelBufferHandler: nil)
    webRTCClient?.close()
    webRTCClient = nil
    delegateAdapter = nil
    signalingClient?.disconnect()
    signalingClient = nil
    isActive = false
    connectionState = .disconnected
    isUnderLiveVideoPressure = false
    roomCode = ""
    savedRoomCode = nil
    isMuted = false
    remoteVideoTrack = nil
    remoteAudioTrack = nil
    hasRemoteVideo = false
    hasRemoteAudio = false
    incomingRemoteVideoEnabled = true
    wantsIncomingRemoteVideo = true
    roomMode = .observation
    isUsingPhoneFallbackProfile = false
    stablePhoneSenderWindows = 0
    Task {
      await WorkerTelemetry.shared.record(
        "webrtc_session_stop",
        source: "webrtc",
        stage: "disconnected"
      )
    }
  }

  func toggleMute() {
    isMuted.toggle()
    webRTCClient?.muteAudio(isMuted)
  }

  @discardableResult
  func refreshSupportAudioRoute(captureMode: StreamingMode) -> String? {
    guard roomMode.usesAudio else { return nil }
    currentCaptureMode = captureMode
    return webRTCClient?.configureSupportAudioRoute(captureMode: captureMode)
  }

  /// Called by StreamSessionViewModel on each video frame.
  func pushVideoFrame(_ image: UIImage) {
    guard isActive, connectionState == .connected else { return }
    webRTCClient?.pushVideoFrame(image)
  }

  func pushVideoPixelBuffer(_ pixelBuffer: CVPixelBuffer, timeStampNs: Int64) {
    guard isActive, connectionState == .connected else { return }
    webRTCClient?.pushPixelBuffer(pixelBuffer, timeStampNs: timeStampNs)
  }

  // MARK: - WebRTC + Signaling Setup

  private func setupWebRTCClient(
    iceServers: [RTCIceServer]?,
    captureMode: StreamingMode
  ) {
    let client = WebRTCClient()
    let adapter = WebRTCDelegateAdapter(viewModel: self)
    delegateAdapter = adapter
    client.delegate = adapter
    let profile: WebRTCStreamProfile
    switch captureMode {
    case .iPhone:
      profile = isUsingPhoneFallbackProfile
        ? WebRTCConfig.supportModePhoneFallbackProfile
        : WebRTCConfig.supportModePhoneProfile
    case .glasses:
      profile = isUsingPhoneFallbackProfile
        ? WebRTCConfig.supportModeGlassesFallbackProfile
        : WebRTCConfig.supportModeGlassesProfile
    }
    client.setup(
      iceServers: iceServers,
      profile: profile,
      receiveRemoteVideo: wantsIncomingRemoteVideo,
      captureMode: captureMode,
      roomMode: roomMode
    )
    webRTCClient = client
    realtimeVideoForwarder.updateHandlers(
      imageHandler: { [weak client] image in
        client?.pushVideoFrame(image)
      },
      pixelBufferHandler: { [weak client] pixelBuffer, timeStampNs in
        client?.pushPixelBuffer(pixelBuffer, timeStampNs: timeStampNs)
      }
    )
  }

  private func connectSignaling(rejoinCode: String?) {
    signalingClient?.disconnect()

    let signaling = SignalingClient()
    signalingClient = signaling

    signaling.onConnected = { [weak self] in
      Task { @MainActor in
        Task {
          await WorkerTelemetry.shared.record(
            "webrtc_signaling_connected",
            source: "webrtc",
            stage: "signaling"
          )
        }
        if let code = rejoinCode {
          NSLog("[WebRTC] Reconnected, rejoining room: %@", code)
          self?.signalingClient?.rejoinRoom(code: code)
        } else {
          self?.signalingClient?.createRoom()
        }
      }
    }

    signaling.onMessageReceived = { [weak self] message in
      Task { @MainActor in
        self?.handleSignalingMessage(message)
      }
    }

    signaling.onDisconnected = { [weak self] reason in
      Task { @MainActor in
        guard let self, self.isActive else { return }
        Task {
          await WorkerTelemetry.shared.record(
            "webrtc_signaling_disconnected",
            source: "webrtc",
            stage: self.savedRoomCode != nil ? "backgrounded" : "failed",
            payload: ["reason": reason ?? NSNull()]
          )
        }
        // Don't fully stop -- mark as backgrounded so we can reconnect
        if self.savedRoomCode != nil {
          self.connectionState = .backgrounded
          NSLog("[WebRTC] Signaling disconnected (backgrounded), will rejoin: %@", reason ?? "unknown")
        } else {
          self.stopSession()
          self.errorMessage = "Signaling disconnected: \(reason ?? "Unknown")"
        }
      }
    }

    guard let url = URL(string: WebRTCConfig.signalingServerURL) else {
      errorMessage = "Invalid signaling URL"
      isActive = false
      connectionState = .disconnected
      return
    }
    signaling.connect(url: url)
  }

  // MARK: - Foreground Reconnect

  private func observeForeground() {
    removeForegroundObserver()
    foregroundObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.willEnterForegroundNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        self?.handleReturnToForeground()
      }
    }
  }

  private func removeForegroundObserver() {
    if let observer = foregroundObserver {
      NotificationCenter.default.removeObserver(observer)
      foregroundObserver = nil
    }
  }

  private func handleReturnToForeground() {
    guard isActive, let code = savedRoomCode else { return }
    NSLog("[WebRTC] App returned to foreground, reconnecting to room: %@", code)
    reconnectCurrentRoom(reason: "app_foreground", roomCode: code)
  }

  func setIncomingRemoteVideoEnabled(_ enabled: Bool) {
    guard currentCaptureMode == .iPhone else {
      incomingRemoteVideoEnabled = true
      return
    }
    guard enabled != wantsIncomingRemoteVideo else { return }
    wantsIncomingRemoteVideo = enabled
    incomingRemoteVideoEnabled = enabled
    remoteVideoTrack = nil
    hasRemoteVideo = false
    guard let code = savedRoomCode, isActive else { return }
    NSLog(
      "[WebRTC] Reconfiguring incoming supervisor video: %@",
      enabled ? "enabled" : "disabled"
    )
    reconnectCurrentRoom(reason: enabled ? "enable_remote_video" : "disable_remote_video", roomCode: code)
  }

  private func reconnectCurrentRoom(reason: String, roomCode code: String) {
    connectionState = .connecting

    // Tear down old peer connection, set up fresh one
    webRTCClient?.close()
    remoteVideoTrack = nil
    hasRemoteVideo = false

    Task {
      let iceServers = await WebRTCConfig.fetchIceServers()
      setupWebRTCClient(iceServers: iceServers, captureMode: currentCaptureMode)
      connectSignaling(rejoinCode: code)
    }
    NSLog("[WebRTC] Reconnecting room %@ (%@)", code, reason)
  }

  // MARK: - Signaling Message Handling

  private func handleSignalingMessage(_ message: SignalingMessage) {
    switch message {
    case .roomCreated(let code):
      roomCode = code
      savedRoomCode = code
      connectionState = .waitingForPeer
      NSLog("[WebRTC] Room created: %@", code)
      Task {
        await WorkerTelemetry.shared.record(
          "webrtc_room_created",
          source: "webrtc",
          stage: "room",
          payload: ["room_code_present": true]
        )
      }

    case .roomRejoined(let code):
      roomCode = code
      savedRoomCode = code
      connectionState = .waitingForPeer
      NSLog("[WebRTC] Room rejoined: %@", code)
      Task {
        await WorkerTelemetry.shared.record(
          "webrtc_room_rejoined",
          source: "webrtc",
          stage: "room",
          payload: ["room_code_present": true]
        )
      }

    case .peerJoined:
      NSLog("[WebRTC] Peer joined, creating offer")
      Task {
        await WorkerTelemetry.shared.record(
          "webrtc_peer_joined",
          source: "webrtc",
          stage: "peer"
        )
      }
      webRTCClient?.createOffer { [weak self] sdp in
        self?.signalingClient?.send(sdp: sdp)
      }

    case .answer(let sdp):
      webRTCClient?.set(remoteSdp: sdp) { error in
        if let error {
          NSLog("[WebRTC] Error setting remote SDP: %@", error.localizedDescription)
        }
      }

    case .candidate(let candidate):
      webRTCClient?.set(remoteCandidate: candidate) { error in
        if let error {
          NSLog("[WebRTC] Error adding ICE candidate: %@", error.localizedDescription)
        }
      }

    case .peerLeft:
      NSLog("[WebRTC] Peer left")
      connectionState = .waitingForPeer
      Task {
        await WorkerTelemetry.shared.record(
          "webrtc_peer_left",
          source: "webrtc",
          stage: "peer"
        )
      }

    case .error(let msg):
      Task {
        await WorkerTelemetry.shared.record(
          "webrtc_signaling_error",
          source: "webrtc",
          stage: "failed",
          payload: ["error": msg]
        )
      }
      // If rejoin fails (room expired), fall back to creating a new room
      if savedRoomCode != nil && msg == "Room not found" {
        NSLog("[WebRTC] Rejoin failed (room expired), creating new room")
        savedRoomCode = nil
        signalingClient?.createRoom()
      } else {
        errorMessage = msg
      }

    case .roomJoined, .offer:
      break
    }
  }

  // MARK: - Connection State Updates (from WebRTCClient delegate)

  fileprivate func handleConnectionStateChange(_ state: RTCIceConnectionState) {
    switch state {
    case .connected, .completed:
      connectionState = .connected
      NSLog("[WebRTC] Peer connected")
      Task {
        await WorkerTelemetry.shared.record(
          "webrtc_ice_connected",
          source: "webrtc",
          stage: "connected"
        )
      }
    case .disconnected:
      connectionState = .waitingForPeer
      Task {
        await WorkerTelemetry.shared.record(
          "webrtc_ice_disconnected",
          source: "webrtc",
          stage: "disconnected"
        )
      }
    case .failed:
      connectionState = .error("Connection failed")
      Task {
        await WorkerTelemetry.shared.record(
          "webrtc_ice_failed",
          source: "webrtc",
          stage: "failed"
        )
      }
    case .closed:
      connectionState = .disconnected
    default:
      break
    }
  }

  fileprivate func handleGeneratedCandidate(_ candidate: RTCIceCandidate) {
    signalingClient?.send(candidate: candidate)
  }

  fileprivate func handleRemoteVideoTrackReceived(_ track: RTCVideoTrack) {
    remoteVideoTrack = track
    hasRemoteVideo = true
    NSLog("[WebRTC] Remote video track received")
  }

  fileprivate func handleRemoteVideoTrackRemoved(_ track: RTCVideoTrack) {
    remoteVideoTrack = nil
    hasRemoteVideo = false
    NSLog("[WebRTC] Remote video track removed")
  }

  fileprivate func handleRemoteAudioTrackReceived(_ track: RTCAudioTrack) {
    guard roomMode.usesAudio else {
      track.isEnabled = false
      remoteAudioTrack = nil
      hasRemoteAudio = false
      NSLog("[WebRTC] Ignoring remote audio track in observation mode")
      return
    }
    track.isEnabled = true
    remoteAudioTrack = track
    hasRemoteAudio = true
    NSLog("[WebRTC] Remote audio track received")
    Task {
      await WorkerTelemetry.shared.record(
        "webrtc_remote_audio_track",
        source: "webrtc",
        stage: "receiver",
        payload: [
          "enabled": track.isEnabled,
          "track_id": track.trackId
        ]
      )
    }
  }

  fileprivate func handleSenderStats(_ stats: WebRTCSenderStats) {
    let enqueueMs = stats.lastEnqueueDurationMs ?? 0
    let captureModeLabel = currentCaptureMode == .iPhone ? "iphone" : "glasses"
    Task {
      await WorkerTelemetry.shared.record(
        "webrtc_sender_stats",
        source: "webrtc",
        stage: isUsingPhoneFallbackProfile ? "fallback" : "sender",
        metricValue: stats.windowFramesPerSecond,
        metricUnit: "fps",
        payload: [
          "sender_fps": stats.windowFramesPerSecond,
          "dropped_frames": stats.windowDroppedFrames,
          "enqueue_ms": enqueueMs,
          "fallback_profile": isUsingPhoneFallbackProfile,
          "capture_mode": captureModeLabel
        ]
      )
    }
    let minimumHealthyFps = currentCaptureMode == .glasses ? 9.0 : 14.0
    let maxHealthyEnqueueMs = currentCaptureMode == .glasses ? 28.0 : 20.0
    let isUnderPressure = enqueueMs > maxHealthyEnqueueMs
      || stats.windowDroppedFrames >= 3
      || stats.windowFramesPerSecond < minimumHealthyFps

    if isUnderPressure {
      isUnderLiveVideoPressure = true
      stablePhoneSenderWindows = 0
      guard !isUsingPhoneFallbackProfile else { return }
      isUsingPhoneFallbackProfile = true
      webRTCClient?.updateStreamProfile(fallbackProfile(for: currentCaptureMode))
      Task {
        await WorkerTelemetry.shared.record(
          "webrtc_profile_downgrade",
          source: "webrtc",
          stage: "fallback",
          payload: [
            "sender_fps": stats.windowFramesPerSecond,
            "dropped_frames": stats.windowDroppedFrames,
            "enqueue_ms": enqueueMs,
            "capture_mode": captureModeLabel
          ]
        )
      }
      NSLog(
        "[WebRTC] %@ sender downgraded to fallback profile (fps=%.1f dropped=%lld enqueue=%@ms)",
        captureModeLabel,
        stats.windowFramesPerSecond,
        stats.windowDroppedFrames,
        stats.lastEnqueueDurationMs.map { String(format: "%.1f", $0) } ?? "direct"
      )
      return
    }

    isUnderLiveVideoPressure = false
    guard isUsingPhoneFallbackProfile else { return }
    stablePhoneSenderWindows += 1

    if stablePhoneSenderWindows >= 6 {
      stablePhoneSenderWindows = 0
      isUsingPhoneFallbackProfile = false
      webRTCClient?.updateStreamProfile(defaultProfile(for: currentCaptureMode))
      Task {
        await WorkerTelemetry.shared.record(
          "webrtc_profile_restore",
          source: "webrtc",
          stage: "sender",
          payload: [
            "stable_windows": stablePhoneSenderWindows,
            "capture_mode": captureModeLabel
          ]
        )
      }
      NSLog("[WebRTC] %@ sender restored to default support profile", captureModeLabel)
    }
  }

  private func defaultProfile(for mode: StreamingMode) -> WebRTCStreamProfile {
    switch mode {
    case .iPhone:
      return WebRTCConfig.supportModePhoneProfile
    case .glasses:
      return WebRTCConfig.supportModeGlassesProfile
    }
  }

  private func fallbackProfile(for mode: StreamingMode) -> WebRTCStreamProfile {
    switch mode {
    case .iPhone:
      return WebRTCConfig.supportModePhoneFallbackProfile
    case .glasses:
      return WebRTCConfig.supportModeGlassesFallbackProfile
    }
  }
}

// MARK: - Delegate Adapter (bridges nonisolated delegate to @MainActor ViewModel)

private class WebRTCDelegateAdapter: WebRTCClientDelegate {
  private weak var viewModel: WebRTCSessionViewModel?

  init(viewModel: WebRTCSessionViewModel) {
    self.viewModel = viewModel
  }

  func webRTCClient(_ client: WebRTCClient, didChangeConnectionState state: RTCIceConnectionState) {
    Task { @MainActor [weak self] in
      self?.viewModel?.handleConnectionStateChange(state)
    }
  }

  func webRTCClient(_ client: WebRTCClient, didGenerateCandidate candidate: RTCIceCandidate) {
    Task { @MainActor [weak self] in
      self?.viewModel?.handleGeneratedCandidate(candidate)
    }
  }

  func webRTCClient(_ client: WebRTCClient, didReceiveRemoteVideoTrack track: RTCVideoTrack) {
    Task { @MainActor [weak self] in
      self?.viewModel?.handleRemoteVideoTrackReceived(track)
    }
  }

  func webRTCClient(_ client: WebRTCClient, didRemoveRemoteVideoTrack track: RTCVideoTrack) {
    Task { @MainActor [weak self] in
      self?.viewModel?.handleRemoteVideoTrackRemoved(track)
    }
  }

  func webRTCClient(_ client: WebRTCClient, didReceiveRemoteAudioTrack track: RTCAudioTrack) {
    Task { @MainActor [weak self] in
      self?.viewModel?.handleRemoteAudioTrackReceived(track)
    }
  }

  func webRTCClient(_ client: WebRTCClient, didUpdateSenderStats stats: WebRTCSenderStats) {
    Task { @MainActor [weak self] in
      self?.viewModel?.handleSenderStats(stats)
    }
  }
}
