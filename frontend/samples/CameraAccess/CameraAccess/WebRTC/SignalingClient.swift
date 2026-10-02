import Foundation
import WebRTC

enum SignalingMessage {
  case roomCreated(String)
  case roomRejoined(String)
  case roomJoined
  case peerJoined
  case peerLeft
  case offer(RTCSessionDescription)
  case answer(RTCSessionDescription)
  case candidate(RTCIceCandidate)
  case error(String)
}

/// WebSocket client for WebRTC signaling. Exchanges SDP offers/answers and ICE candidates
/// via a relay server. Follows the same URLSessionWebSocketTask pattern as GeminiLiveService.
class SignalingClient {
  var onMessageReceived: ((SignalingMessage) -> Void)?
  var onConnected: (() -> Void)?
  var onDisconnected: ((String?) -> Void)?

  private var webSocketTask: URLSessionWebSocketTask?
  private var urlSession: URLSession!
  private let delegate = WebSocketDelegate()
  private let sendQueue = DispatchQueue(label: "signaling.send")
  private var receiveTask: Task<Void, Never>?

  init() {
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 30
    self.urlSession = URLSession(
      configuration: config, delegate: delegate, delegateQueue: nil)
  }

  func connect(url: URL) {
    disconnect()

    delegate.onOpen = { [weak self] in
      NSLog("[Signaling] Connected to %@", url.absoluteString)
      self?.onConnected?()
    }
    delegate.onClose = { [weak self] reason in
      NSLog("[Signaling] Disconnected: %@", reason ?? "unknown")
      self?.onDisconnected?(reason)
    }

    webSocketTask = urlSession.webSocketTask(with: url)
    webSocketTask?.resume()
    startReceiving()
  }

  func createRoom() {
    sendJSON(["type": "create"])
  }

  func joinRoom(code: String) {
    sendJSON(["type": "join", "room": code])
  }

  func rejoinRoom(code: String) {
    sendJSON(["type": "rejoin", "room": code])
  }

  func send(sdp: RTCSessionDescription) {
    let type = sdp.type == .offer ? "offer" : "answer"
    sendJSON(["type": type, "sdp": sdp.sdp])
  }

  func send(candidate: RTCIceCandidate) {
    sendJSON([
      "type": "candidate",
      "candidate": candidate.sdp,
      "sdpMid": candidate.sdpMid ?? "",
      "sdpMLineIndex": candidate.sdpMLineIndex,
    ] as [String: Any])
  }

  func disconnect() {
    receiveTask?.cancel()
    receiveTask = nil
    webSocketTask?.cancel(with: .goingAway, reason: nil)
    webSocketTask = nil
  }

  // MARK: - Private

  private func sendJSON(_ dict: [String: Any]) {
    sendQueue.async { [weak self] in
      guard let self, let task = self.webSocketTask else { return }
      guard let data = try? JSONSerialization.data(withJSONObject: dict),
        let text = String(data: data, encoding: .utf8)
      else { return }
      task.send(.string(text)) { error in
        if let error {
          NSLog("[Signaling] Send error: %@", error.localizedDescription)
        }
      }
    }
  }

  private func startReceiving() {
    receiveTask = Task { [weak self] in
      while !Task.isCancelled {
        guard let self, let task = self.webSocketTask else { break }
        do {
          let message = try await task.receive()
          switch message {
          case .string(let text):
            self.handleMessage(text)
          case .data(let data):
            if let text = String(data: data, encoding: .utf8) {
              self.handleMessage(text)
            }
          @unknown default:
            break
          }
        } catch {
          if !Task.isCancelled {
            NSLog("[Signaling] Receive error: %@", error.localizedDescription)
            self.onDisconnected?(error.localizedDescription)
          }
          break
        }
      }
    }
  }

  private func handleMessage(_ text: String) {
    guard let data = text.data(using: .utf8),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let type = json["type"] as? String
    else { return }

    switch type {
    case "room_created":
      if let room = json["room"] as? String {
        onMessageReceived?(.roomCreated(room))
      }

    case "room_joined":
      onMessageReceived?(.roomJoined)

    case "room_rejoined":
      if let room = json["room"] as? String {
        onMessageReceived?(.roomRejoined(room))
      }

    case "peer_joined":
      onMessageReceived?(.peerJoined)

    case "peer_left":
      onMessageReceived?(.peerLeft)

    case "offer":
      if let sdp = json["sdp"] as? String {
        let sessionDesc = RTCSessionDescription(type: .offer, sdp: sdp)
        onMessageReceived?(.offer(sessionDesc))
      }

    case "answer":
      if let sdp = json["sdp"] as? String {
        let sessionDesc = RTCSessionDescription(type: .answer, sdp: sdp)
        onMessageReceived?(.answer(sessionDesc))
      }

    case "candidate":
      if let candidate = json["candidate"] as? String,
        let sdpMid = json["sdpMid"] as? String,
        let sdpMLineIndex = json["sdpMLineIndex"] as? Int32
      {
        let iceCandidate = RTCIceCandidate(
          sdp: candidate, sdpMLineIndex: sdpMLineIndex, sdpMid: sdpMid)
        onMessageReceived?(.candidate(iceCandidate))
      }

    case "error":
      let msg = json["message"] as? String ?? "Unknown signaling error"
      onMessageReceived?(.error(msg))

    default:
      NSLog("[Signaling] Unknown message type: %@", type)
    }
  }
}

// MARK: - WebSocket Delegate

private class WebSocketDelegate: NSObject, URLSessionWebSocketDelegate {
  var onOpen: (() -> Void)?
  var onClose: ((String?) -> Void)?

  func urlSession(
    _ session: URLSession, webSocketTask: URLSessionWebSocketTask,
    didOpenWithProtocol protocol: String?
  ) {
    onOpen?()
  }

  func urlSession(
    _ session: URLSession, webSocketTask: URLSessionWebSocketTask,
    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?
  ) {
    let reasonStr = reason.flatMap { String(data: $0, encoding: .utf8) }
    onClose?(reasonStr)
  }
}
