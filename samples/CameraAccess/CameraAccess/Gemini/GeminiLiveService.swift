import Foundation
import UIKit

enum GeminiConnectionState: Equatable {
  case disconnected
  case connecting
  case settingUp
  case ready
  case error(String)
}

struct GeminiVideoFramePolicy {
  static func targetPixelSize(
    for sourceSize: CGSize,
    maxLongEdge: CGFloat = GeminiConfig.videoMaxLongEdge
  ) -> CGSize {
    guard sourceSize.width > 0, sourceSize.height > 0, maxLongEdge > 0 else {
      return .zero
    }

    let scale = min(1, maxLongEdge / max(sourceSize.width, sourceSize.height))
    return CGSize(
      width: max(1, (sourceSize.width * scale).rounded()),
      height: max(1, (sourceSize.height * scale).rounded())
    )
  }

  static func jpegData(for image: UIImage) -> Data? {
    let sourceSize: CGSize
    if let cgImage = image.cgImage {
      sourceSize = CGSize(width: cgImage.width, height: cgImage.height)
    } else {
      sourceSize = CGSize(
        width: image.size.width * image.scale,
        height: image.size.height * image.scale
      )
    }

    let targetSize = targetPixelSize(for: sourceSize)
    guard targetSize != .zero else { return nil }

    if targetSize == sourceSize {
      return image.jpegData(compressionQuality: GeminiConfig.videoJPEGQuality)
    }

    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
    let resized = renderer.image { _ in
      image.draw(in: CGRect(origin: .zero, size: targetSize))
    }
    return resized.jpegData(compressionQuality: GeminiConfig.videoJPEGQuality)
  }
}

private struct GeminiVideoEncodeRequest: @unchecked Sendable {
  let image: UIImage
  let socket: URLSessionWebSocketTask
}

private struct ParsedGeminiInboundMessage: @unchecked Sendable {
  let json: [String: Any]
  let audioChunks: [Data]
}

@MainActor
class GeminiLiveService: ObservableObject {
  nonisolated static let activityHandlingMode = "NO_INTERRUPTION"

  @Published var connectionState: GeminiConnectionState = .disconnected
  @Published var isModelSpeaking: Bool = false

  var onAudioReceived: ((Data) -> Void)?
  var onTurnComplete: (() -> Void)?
  var onInterrupted: (() -> Void)?
  var onDisconnected: ((String?) -> Void)?
  var onInputTranscription: ((String) -> Void)?
  var onOutputTranscription: ((String) -> Void)?
  var onToolCall: ((GeminiToolCall) -> Void)?
  var onToolCallCancellation: ((GeminiToolCallCancellation) -> Void)?

  // Latency tracking
  private var lastUserSpeechEnd: Date?
  private var responseLatencyLogged = false

  private var webSocketTask: URLSessionWebSocketTask?
  private var receiveTask: Task<Void, Never>?
  private var connectContinuation: CheckedContinuation<Bool, Never>?
  private let delegate = WebSocketDelegate()
  private var urlSession: URLSession!
  private let sendQueue = DispatchQueue(label: "gemini.send", qos: .userInitiated)
  private var isVideoStreamingPaused = false
  private lazy var videoFramePump = LatestValuePump<GeminiVideoEncodeRequest>(
    label: "gemini.video.latest-frame",
    qos: .utility
  ) { request in
    autoreleasepool {
      let encodeStart = CFAbsoluteTimeGetCurrent()
      guard let jpegData = GeminiVideoFramePolicy.jpegData(for: request.image) else { return }
      let base64 = jpegData.base64EncodedString()
      let json: [String: Any] = [
        "realtimeInput": [
          "video": [
            "mimeType": "image/jpeg",
            "data": base64
          ]
        ]
      ]
      guard let message = Self.serializedJSONString(json) else { return }

      // Video gets its own bounded lane. Waiting here never blocks audio or a
      // tool result, and the pump retains only one newer pending frame.
      let sendCompleted = DispatchSemaphore(value: 0)
      request.socket.send(.string(message)) { error in
        if let error {
          NSLog("[Gemini] Video frame send failed: %@", error.localizedDescription)
        }
        sendCompleted.signal()
      }
      if sendCompleted.wait(timeout: .now() + 10) == .timedOut {
        NSLog("[Gemini] Video frame send timed out and was dropped")
      }

      let elapsedMs = (CFAbsoluteTimeGetCurrent() - encodeStart) * 1_000
      if elapsedMs >= 100 {
        NSLog("[Latency] Gemini vision encode+send %.0fms (%d bytes)", elapsedMs, jpegData.count)
      }
    }
  }

  init() {
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 30
    self.urlSession = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
  }

  func connect() async -> Bool {
    guard let url = GeminiConfig.websocketURL() else {
      connectionState = .error("No API key configured")
      return false
    }

    connectionState = .connecting

    let result = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
      self.connectContinuation = continuation

      self.delegate.onOpen = { [weak self] protocol_ in
        guard let self else { return }
        Task { @MainActor in
          self.connectionState = .settingUp
          self.sendSetupMessage()
          self.startReceiving()
        }
      }

      self.delegate.onClose = { [weak self] code, reason in
        guard let self else { return }
        let reasonStr = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "no reason"
        Task { @MainActor in
          self.resolveConnect(success: false)
          self.connectionState = .disconnected
          self.isModelSpeaking = false
          self.onDisconnected?("Connection closed (code \(code.rawValue): \(reasonStr))")
        }
      }

      self.delegate.onError = { [weak self] error in
        guard let self else { return }
        let msg = error?.localizedDescription ?? "Unknown error"
        Task { @MainActor in
          self.resolveConnect(success: false)
          self.connectionState = .error(msg)
          self.isModelSpeaking = false
          self.onDisconnected?(msg)
        }
      }

      self.webSocketTask = self.urlSession.webSocketTask(with: url)
      self.webSocketTask?.resume()

      // Timeout after 15 seconds
      Task {
        try? await Task.sleep(nanoseconds: 15_000_000_000)
        await MainActor.run {
          self.resolveConnect(success: false)
          if self.connectionState == .connecting || self.connectionState == .settingUp {
            self.connectionState = .error("Connection timed out")
          }
        }
      }
    }

    return result
  }

  func disconnect() {
    receiveTask?.cancel()
    receiveTask = nil
    webSocketTask?.cancel(with: .normalClosure, reason: nil)
    webSocketTask = nil
    delegate.onOpen = nil
    delegate.onClose = nil
    delegate.onError = nil
    onToolCall = nil
    onToolCallCancellation = nil
    connectionState = .disconnected
    isModelSpeaking = false
    isVideoStreamingPaused = false
    videoFramePump.reset()
    resolveConnect(success: false)
  }

  func sendAudio(data: Data) {
    guard connectionState == .ready else { return }
    let socket = webSocketTask
    sendQueue.async {
      let base64 = data.base64EncodedString()
      let json: [String: Any] = [
        "realtimeInput": [
          "audio": [
            "mimeType": "audio/pcm;rate=16000",
            "data": base64
          ]
        ]
      ]
      Self.sendJSON(json, over: socket)
    }
  }

  func sendAudioStreamEnd() {
    guard connectionState == .ready else { return }
    let socket = webSocketTask
    sendQueue.async {
      let json: [String: Any] = [
        "realtimeInput": [
          "audioStreamEnd": true
        ]
      ]
      Self.sendJSON(json, over: socket)
    }
  }

  func sendVideoFrame(image: UIImage) {
    guard connectionState == .ready,
          !isVideoStreamingPaused,
          let socket = webSocketTask else { return }
    videoFramePump.submit(GeminiVideoEncodeRequest(image: image, socket: socket))
  }

  func setVideoStreamingPaused(_ paused: Bool) {
    isVideoStreamingPaused = paused
    if paused {
      videoFramePump.reset()
    }
  }

  func sendToolResponse(
    _ response: [String: Any],
    completion: @escaping @MainActor (Bool) -> Void
  ) {
    if let data = try? JSONSerialization.data(withJSONObject: response) {
      NSLog("[Gemini] Sending tool response: %d bytes", data.count)
    }
    guard let socket = webSocketTask,
          let message = Self.serializedJSONString(response) else {
      completion(false)
      return
    }
    sendQueue.async {
      socket.send(.string(message)) { error in
        if let error {
          NSLog("[Gemini] Tool response send failed: %@", error.localizedDescription)
        }
        Task { @MainActor in
          completion(error == nil)
        }
      }
    }
  }

  func sendTextMessage(_ text: String) {
    guard connectionState == .ready else { return }
    let socket = webSocketTask
    sendQueue.async {
      let msg = Self.textTurnMessage(text)
      Self.sendJSON(msg, over: socket)
    }
  }

  nonisolated static func textTurnMessage(_ text: String) -> [String: Any] {
    [
      "clientContent": [
        "turns": [
          ["role": "user", "parts": [["text": text]]]
        ],
        "turnComplete": true
      ]
    ]
  }

  // MARK: - Private

  private func resolveConnect(success: Bool) {
    if let cont = connectContinuation {
      connectContinuation = nil
      cont.resume(returning: success)
    }
  }

  private func sendSetupMessage() {
    let systemInstruction = GeminiConfig.systemInstruction
    NSLog(
      "[Gemini] Setup: system instruction %d chars, OpenClaw routing=%@, tools=%d",
      systemInstruction.count,
      systemInstruction.contains("OpenClaw is your external system") ? "yes" : "no",
      ToolDeclarations.allDeclarations().count
    )
    let setup: [String: Any] = [
      "setup": [
        "model": GeminiConfig.model,
        "generationConfig": [
          "responseModalities": ["AUDIO"],
          "mediaResolution": "MEDIA_RESOLUTION_LOW",
          "thinkingConfig": [
            "thinkingBudget": 0
          ]
        ],
        "systemInstruction": [
          "parts": [
            ["text": systemInstruction]
          ]
        ],
        "tools": [
          [
            "functionDeclarations": ToolDeclarations.allDeclarations()
          ]
        ],
        "realtimeInputConfig": [
          "automaticActivityDetection": [
            "disabled": false,
            "startOfSpeechSensitivity": "START_SENSITIVITY_HIGH",
            "endOfSpeechSensitivity": "END_SENSITIVITY_LOW",
            "silenceDurationMs": 500,
            "prefixPaddingMs": 40
          ],
          // Reliability-first half duplex: a detected echo/noise event cannot
          // cut a spoken response mid-sentence. The client also pauses mic PCM
          // until local AVAudioPlayerNode playback has fully drained.
          "activityHandling": Self.activityHandlingMode,
          "turnCoverage": "TURN_INCLUDES_ALL_INPUT"
        ],
        "contextWindowCompression": [
          "slidingWindow": [
            "targetTokens": 80000
          ]
        ],
        "inputAudioTranscription": [:] as [String: Any],
        "outputAudioTranscription": [:] as [String: Any]
      ]
    ]
    Self.sendJSON(setup, over: webSocketTask)
  }

  private nonisolated static func sendJSON(
    _ json: [String: Any],
    over socket: URLSessionWebSocketTask?
  ) {
    guard let string = serializedJSONString(json) else { return }
    socket?.send(.string(string)) { error in
      if let error {
        NSLog("[Gemini] WebSocket send failed: %@", error.localizedDescription)
      }
    }
  }

  private nonisolated static func serializedJSONString(_ json: [String: Any]) -> String? {
    guard let data = try? JSONSerialization.data(withJSONObject: json) else { return nil }
    return String(data: data, encoding: .utf8)
  }

  private func startReceiving() {
    receiveTask = Task { [weak self] in
      guard let self else { return }
      while !Task.isCancelled {
        guard let task = self.webSocketTask else { break }
        do {
          let message = try await task.receive()
          switch message {
          case .string(let text):
            if let parsed = await Task.detached(priority: .userInitiated, operation: {
              Self.parseInboundMessage(text)
            }).value {
              await self.handleMessage(parsed)
            }
          case .data(let data):
            if let text = String(data: data, encoding: .utf8) {
              if let parsed = await Task.detached(priority: .userInitiated, operation: {
                Self.parseInboundMessage(text)
              }).value {
                await self.handleMessage(parsed)
              }
            }
          @unknown default:
            break
          }
        } catch {
          if !Task.isCancelled {
            let reason = error.localizedDescription
            await MainActor.run {
              self.resolveConnect(success: false)
              self.connectionState = .disconnected
              self.isModelSpeaking = false
              self.onDisconnected?(reason)
            }
          }
          break
        }
      }
    }
  }

  private nonisolated static func parseInboundMessage(
    _ text: String
  ) -> ParsedGeminiInboundMessage? {
    guard let data = text.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return nil
    }

    var audioChunks: [Data] = []
    if let serverContent = json["serverContent"] as? [String: Any],
       let modelTurn = serverContent["modelTurn"] as? [String: Any],
       let parts = modelTurn["parts"] as? [[String: Any]] {
      for part in parts {
        guard let inlineData = part["inlineData"] as? [String: Any],
              let mimeType = inlineData["mimeType"] as? String,
              mimeType.hasPrefix("audio/pcm"),
              let base64Data = inlineData["data"] as? String,
              let audioData = Data(base64Encoded: base64Data) else { continue }
        audioChunks.append(audioData)
      }
    }

    return ParsedGeminiInboundMessage(json: json, audioChunks: audioChunks)
  }

  private func handleMessage(_ parsed: ParsedGeminiInboundMessage) async {
    let json = parsed.json

    // Setup complete
    if json["setupComplete"] != nil {
      connectionState = .ready
      resolveConnect(success: true)
      return
    }

    // GoAway - server will close soon
    if let goAway = json["goAway"] as? [String: Any] {
      let timeLeft = goAway["timeLeft"] as? [String: Any]
      let seconds = timeLeft?["seconds"] as? Int ?? 0
      connectionState = .disconnected
      isModelSpeaking = false
      onDisconnected?("Server closing (time left: \(seconds)s)")
      return
    }

    // Tool call from model (top-level message, not inside serverContent)
    if let toolCall = GeminiToolCall(json: json) {
      NSLog("[Gemini] Tool call received: %d function(s)", toolCall.functionCalls.count)
      onToolCall?(toolCall)
      return
    }

    // Tool call cancellation (user interrupted during tool execution)
    if let cancellation = GeminiToolCallCancellation(json: json) {
      NSLog("[Gemini] Tool call cancellation: %@", cancellation.ids.joined(separator: ", "))
      onToolCallCancellation?(cancellation)
      return
    }

    // Server content
    if let serverContent = json["serverContent"] as? [String: Any] {
      if let interrupted = serverContent["interrupted"] as? Bool, interrupted {
        NSLog("[Gemini] Server interrupted current response")
        isModelSpeaking = false
        onInterrupted?()
        return
      }

      if let modelTurn = serverContent["modelTurn"] as? [String: Any],
         let parts = modelTurn["parts"] as? [[String: Any]] {
        for audioData in parsed.audioChunks {
          if !isModelSpeaking {
            isModelSpeaking = true
            // Log latency: time from end of user speech to first audio response
            if let speechEnd = lastUserSpeechEnd, !responseLatencyLogged {
              let latency = Date().timeIntervalSince(speechEnd)
              NSLog("[Latency] %.0fms (user speech end -> first audio)", latency * 1000)
              responseLatencyLogged = true
            }
          }
          onAudioReceived?(audioData)
        }

        for part in parts {
          if let text = part["text"] as? String {
            NSLog("[Gemini] %@", text)
          }
        }
      }

      if let turnComplete = serverContent["turnComplete"] as? Bool, turnComplete {
        NSLog("[Gemini] Server turn complete")
        isModelSpeaking = false
        responseLatencyLogged = false
        onTurnComplete?()
      }

      if let inputTranscription = serverContent["inputTranscription"] as? [String: Any],
         let text = inputTranscription["text"] as? String, !text.isEmpty {
        NSLog("[Gemini] You: %@", text)
        lastUserSpeechEnd = Date()
        responseLatencyLogged = false
        onInputTranscription?(text)
      }
      if let outputTranscription = serverContent["outputTranscription"] as? [String: Any],
         let text = outputTranscription["text"] as? String, !text.isEmpty {
        NSLog("[Gemini] AI: %@", text)
        onOutputTranscription?(text)
      }
    }
  }
}

// MARK: - WebSocket Delegate

private class WebSocketDelegate: NSObject, URLSessionWebSocketDelegate {
  var onOpen: ((String?) -> Void)?
  var onClose: ((URLSessionWebSocketTask.CloseCode, Data?) -> Void)?
  var onError: ((Error?) -> Void)?

  func urlSession(
    _ session: URLSession,
    webSocketTask: URLSessionWebSocketTask,
    didOpenWithProtocol protocol: String?
  ) {
    onOpen?(`protocol`)
  }

  func urlSession(
    _ session: URLSession,
    webSocketTask: URLSessionWebSocketTask,
    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
    reason: Data?
  ) {
    onClose?(closeCode, reason)
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didCompleteWithError error: Error?
  ) {
    if let error {
      onError?(error)
    }
  }
}
