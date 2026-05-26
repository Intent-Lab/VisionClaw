import Foundation

class OpenClawEventClient {
  var onNotification: ((String) -> Void)?

  private var webSocketTask: URLSessionWebSocketTask?
  private var session: URLSession?
  private var isConnected = false
  private var shouldReconnect = false
  private var reconnectDelay: TimeInterval = 2
  private let maxReconnectDelay: TimeInterval = 30

  // Pending RPC responses and chat results
  private var pendingResponses: [String: ([String: Any]) -> Void] = [:]
  private var pendingChatResults: [String: (String?) -> Void] = [:]

  func connect() {
    guard GeminiConfig.isOpenClawConfigured else {
      NSLog("[OpenClawWS] Not configured, skipping")
      return
    }

    shouldReconnect = true
    reconnectDelay = 2
    establishConnection()
  }

  func disconnect() {
    shouldReconnect = false
    isConnected = false
    // Cancel all pending callbacks so they don't fire after session stops
    pendingResponses.removeAll()
    pendingChatResults.removeAll()
    webSocketTask?.cancel(with: .normalClosure, reason: nil)
    webSocketTask = nil
    session?.invalidateAndCancel()
    session = nil
    NSLog("[OpenClawWS] Disconnected")
  }

  // MARK: - Private

  private func establishConnection() {
    let host = GeminiConfig.openClawHost
      .replacingOccurrences(of: "http://", with: "")
      .replacingOccurrences(of: "https://", with: "")
    let port = GeminiConfig.openClawPort
    guard let url = URL(string: "ws://\(host):\(port)") else {
      NSLog("[OpenClawWS] Invalid URL")
      return
    }

    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 30
    session = URLSession(configuration: config)
    var request = URLRequest(url: url)
    request.setValue("localhost:\(port)", forHTTPHeaderField: "Host")
    webSocketTask = session?.webSocketTask(with: request)
    webSocketTask?.resume()

    NSLog("[OpenClawWS] Connecting to %@", url.absoluteString)
    startReceiving()
  }

  private func startReceiving() {
    webSocketTask?.receive { [weak self] result in
      guard let self else { return }
      switch result {
      case .success(let message):
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
        self.startReceiving()
      case .failure(let error):
        NSLog("[OpenClawWS] Receive error: %@", error.localizedDescription)
        self.isConnected = false
        self.scheduleReconnect()
      }
    }
  }

  private func handleMessage(_ text: String) {
    guard let data = text.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let type = json["type"] as? String else { return }

    if type == "event" {
      handleEvent(json)
    } else if type == "res" {
      let id = json["id"] as? String ?? ""
      if let callback = pendingResponses.removeValue(forKey: id) {
        callback(json)
      } else {
        let ok = json["ok"] as? Bool ?? false
        if ok {
          NSLog("[OpenClawWS] Connected and authenticated")
          isConnected = true
          reconnectDelay = 2
        } else {
          let error = json["error"] as? [String: Any]
          let msg = error?["message"] as? String ?? "unknown"
          NSLog("[OpenClawWS] Connect failed: %@", msg)
        }
      }
    }
  }

  private func handleEvent(_ json: [String: Any]) {
    guard let event = json["event"] as? String else { return }
    let payload = json["payload"] as? [String: Any] ?? [:]

    switch event {
    case "connect.challenge":
      sendConnectHandshake()

    case "heartbeat":
      handleHeartbeatEvent(payload)

    case "cron":
      handleCronEvent(payload)

    case "chat":
      handleChatEvent(payload)

    default:
      break
    }
  }

  private func sendConnectHandshake() {
    let connectMsg: [String: Any] = [
      "type": "req",
      "id": UUID().uuidString,
      "method": "connect",
      "params": [
        "minProtocol": 3,
        "maxProtocol": 4,
        "client": [
          "id": "ios-node",
          "displayName": "VisionClaw Glass",
          "version": "1.0",
          "platform": "ios",
          "mode": "node"
        ],
        "role": "node",
        "caps": ["camera", "voice"],
        "commands": [] as [String],
        "permissions": [:] as [String: Any],
        "auth": [
          "token": GeminiConfig.openClawGatewayToken
        ],
        "scopes": ["operator.admin"]
      ] as [String: Any]
    ]

    guard let data = try? JSONSerialization.data(withJSONObject: connectMsg),
          let string = String(data: data, encoding: .utf8) else { return }
    webSocketTask?.send(.string(string)) { error in
      if let error {
        NSLog("[OpenClawWS] Handshake send error: %@", error.localizedDescription)
      }
    }
  }

  private func handleHeartbeatEvent(_ payload: [String: Any]) {
    let status = payload["status"] as? String ?? ""
    // Only notify if there's actual content (not empty/silent heartbeats)
    guard status == "sent", let preview = payload["preview"] as? String, !preview.isEmpty else {
      return
    }

    let silent = payload["silent"] as? Bool ?? false
    guard !silent else { return }

    NSLog("[OpenClawWS] Heartbeat notification: %@", String(preview.prefix(100)))
    onNotification?("[Notification from your assistant] \(preview)")
  }

  private func handleCronEvent(_ payload: [String: Any]) {
    let action = payload["action"] as? String ?? ""
    guard action == "finished" else { return }

    let summary = payload["summary"] as? String
      ?? payload["result"] as? String
      ?? ""
    guard !summary.isEmpty else { return }

    NSLog("[OpenClawWS] Cron notification: %@", String(summary.prefix(100)))
    onNotification?("[Scheduled update] \(summary)")
  }

  private func handleChatEvent(_ payload: [String: Any]) {
    let state = payload["state"] as? String ?? ""
    let runId = payload["runId"] as? String ?? ""
    guard !runId.isEmpty else { return }

    if state == "final" {
      if let callback = pendingChatResults.removeValue(forKey: runId) {
        let message = payload["message"] as? [String: Any]
        let content = message?["content"]
        let replyText: String?
        if let text = content as? String {
          replyText = text
        } else if let parts = content as? [[String: Any]] {
          replyText = parts.compactMap { ($0["type"] as? String == "text") ? $0["text"] as? String : nil }.joined(separator: "\n")
        } else {
          replyText = nil
        }
        NSLog("[OpenClawWS] chat final for %@: %@", runId, String((replyText ?? "nil").prefix(200)))
        callback(replyText ?? "Agent completed but returned no text.")
      }
    } else if state == "error" {
      if let callback = pendingChatResults.removeValue(forKey: runId) {
        let errorMsg = payload["errorMessage"] as? String ?? "Agent error"
        NSLog("[OpenClawWS] chat error for %@: %@", runId, errorMsg)
        callback(nil)
      }
    }
  }

  /// Send a chat message with optional image attachment via WebSocket chat.send RPC.
  /// This is the only way to reliably pass images to the OpenClaw agent.
  func sendChatMessage(
    sessionKey: String,
    message: String,
    imageBase64: String? = nil,
    completion: @escaping (String?) -> Void
  ) {
    guard isConnected, webSocketTask != nil else {
      NSLog("[OpenClawWS] Cannot send chat.send: not connected")
      completion(nil)
      return
    }

    let reqId = UUID().uuidString
    var params: [String: Any] = [
      "sessionKey": sessionKey,
      "message": message,
      "idempotencyKey": reqId
    ]

    if let imageBase64 {
      params["attachments"] = [[
        "mimeType": "image/jpeg",
        "fileName": "camera_frame.jpg",
        "content": imageBase64
      ]]
    }

    let request: [String: Any] = [
      "type": "req",
      "id": reqId,
      "method": "chat.send",
      "params": params
    ]

    // Register RPC ack callback — then wait for chat event
    pendingResponses[reqId] = { [weak self] response in
      let ok = response["ok"] as? Bool ?? false
      if ok {
        NSLog("[OpenClawWS] chat.send accepted, waiting for agent reply (runId=%@)", reqId)
        self?.pendingChatResults[reqId] = completion
      } else {
        let error = response["error"] as? [String: Any]
        let msg = error?["message"] as? String ?? "unknown"
        NSLog("[OpenClawWS] chat.send rejected: %@", msg)
        completion(nil)
      }
    }

    guard let data = try? JSONSerialization.data(withJSONObject: request),
          let string = String(data: data, encoding: .utf8) else {
      pendingResponses.removeValue(forKey: reqId)
      completion(nil)
      return
    }

    webSocketTask?.send(.string(string)) { [weak self] error in
      if let error {
        NSLog("[OpenClawWS] chat.send send error: %@", error.localizedDescription)
        self?.pendingResponses.removeValue(forKey: reqId)
        completion(nil)
      } else {
        NSLog("[OpenClawWS] chat.send sent (id=%@, hasImage=%@)", reqId, imageBase64 != nil ? "true" : "false")
      }
    }
  }

  private func scheduleReconnect() {
    guard shouldReconnect else { return }
    NSLog("[OpenClawWS] Reconnecting in %.0fs", reconnectDelay)
    DispatchQueue.main.asyncAfter(deadline: .now() + reconnectDelay) { [weak self] in
      guard let self, self.shouldReconnect else { return }
      self.reconnectDelay = min(self.reconnectDelay * 2, self.maxReconnectDelay)
      self.establishConnection()
    }
  }
}
