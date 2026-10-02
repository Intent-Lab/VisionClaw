import Foundation
import SwiftUI
import WebRTC

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
  @Published var hasRemoteVideo: Bool = false

  private var webRTCClient: WebRTCClient?
  private var signalingClient: SignalingClient?
  private var delegateAdapter: WebRTCDelegateAdapter?

  /// Saved room code for reconnecting after app backgrounding.
  private var savedRoomCode: String?
  private var foregroundObserver: Any?

  func startSession() async {
    guard !isActive else { return }
    guard WebRTCConfig.isConfigured else {
      errorMessage = "WebRTC signaling URL not configured."
      return
    }

    isActive = true
    connectionState = .connecting
    savedRoomCode = nil

    // Fetch TURN credentials for NAT traversal across networks
    let iceServers = await WebRTCConfig.fetchIceServers()

    setupWebRTCClient(iceServers: iceServers)
    connectSignaling(rejoinCode: nil)
    observeForeground()
  }

  func stopSession() {
    removeForegroundObserver()
    webRTCClient?.close()
    webRTCClient = nil
    delegateAdapter = nil
    signalingClient?.disconnect()
    signalingClient = nil
    isActive = false
    connectionState = .disconnected
    roomCode = ""
    savedRoomCode = nil
    isMuted = false
    remoteVideoTrack = nil
    hasRemoteVideo = false
  }

  func toggleMute() {
    isMuted.toggle()
    webRTCClient?.muteAudio(isMuted)
  }

  /// Called by StreamSessionViewModel on each video frame.
  func pushVideoFrame(_ image: UIImage) {
    guard isActive, connectionState == .connected else { return }
    webRTCClient?.pushVideoFrame(image)
  }

  // MARK: - WebRTC + Signaling Setup

  private func setupWebRTCClient(iceServers: [RTCIceServer]?) {
    let client = WebRTCClient()
    let adapter = WebRTCDelegateAdapter(viewModel: self)
    delegateAdapter = adapter
    client.delegate = adapter
    client.setup(iceServers: iceServers)
    webRTCClient = client
  }

  private func connectSignaling(rejoinCode: String?) {
    signalingClient?.disconnect()

    let signaling = SignalingClient()
    signalingClient = signaling

    signaling.onConnected = { [weak self] in
      Task { @MainActor in
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
    connectionState = .connecting

    // Tear down old peer connection, set up fresh one
    webRTCClient?.close()
    remoteVideoTrack = nil
    hasRemoteVideo = false

    Task {
      let iceServers = await WebRTCConfig.fetchIceServers()
      setupWebRTCClient(iceServers: iceServers)
      connectSignaling(rejoinCode: code)
    }
  }

  // MARK: - Signaling Message Handling

  private func handleSignalingMessage(_ message: SignalingMessage) {
    switch message {
    case .roomCreated(let code):
      roomCode = code
      savedRoomCode = code
      connectionState = .waitingForPeer
      NSLog("[WebRTC] Room created: %@", code)

    case .roomRejoined(let code):
      roomCode = code
      savedRoomCode = code
      connectionState = .waitingForPeer
      NSLog("[WebRTC] Room rejoined: %@", code)

    case .peerJoined:
      NSLog("[WebRTC] Peer joined, creating offer")
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

    case .error(let msg):
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
    case .disconnected:
      connectionState = .waitingForPeer
    case .failed:
      connectionState = .error("Connection failed")
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
}
