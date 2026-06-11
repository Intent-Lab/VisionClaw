import Foundation
import QuartzCore
import UIKit

enum GeminiConnectionState: Equatable {
  case disconnected
  case connecting
  case settingUp
  case ready
  case error(String)
}

enum GeminiRecoverableDisconnectReason: Equatable {
  case socketClosed(String)
  case socketError(String)
  case receiveError(String)
  case sendError(String)
  case pingError(String)
  case goAway(seconds: Int)

  var message: String {
    switch self {
    case .socketClosed(let message):
      return message
    case .socketError(let message):
      return message
    case .receiveError(let message):
      return message
    case .sendError(let message):
      return message
    case .pingError(let message):
      return message
    case .goAway(let seconds):
      return "Server closing (time left: \(seconds)s)"
    }
  }
}

@MainActor
class GeminiLiveService: ObservableObject {
  @Published var connectionState: GeminiConnectionState = .disconnected
  @Published var isModelSpeaking: Bool = false

  var onAudioReceived: ((Data) -> Void)?
  var onTurnComplete: (() -> Void)?
  var onInterrupted: (() -> Void)?
  var onDisconnected: ((String?) -> Void)?
  var onInputTranscription: ((String) -> Void)?
  var onOutputTranscription: ((String) -> Void)?
  var onSocketOpened: (() -> Void)?
  var onSocketClosed: ((String?) -> Void)?
  var onRecoverableDisconnect: ((GeminiRecoverableDisconnectReason) -> Void)?

  // Latency tracking
  private var lastUserSpeechEnd: Date?
  private var responseLatencyLogged = false

  private var webSocketTask: URLSessionWebSocketTask?
  private var receiveTask: Task<Void, Never>?
  private var pingTask: Task<Void, Never>?
  private var connectContinuation: CheckedContinuation<Bool, Never>?
  private var closeWaitContinuation: CheckedContinuation<Void, Never>?
  private let delegate = WebSocketDelegate()
  private var urlSession: URLSession!
  private let sendQueue = DispatchQueue(label: "gemini.send", qos: .userInitiated)
  private var latestVideoFrameBase64: String?
  private var setupSystemInstruction: String = GeminiConfig.defaultSystemInstruction
  private var setupModel: String = GeminiConfig.model
  private var videoFrameSendCount: Int64 = 0
  private var videoFrameStatsWindowStart = CACurrentMediaTime()
  private var connectionGeneration = 0
  private var isClosingIntentionally = false
  private var didNotifyRecoverableDisconnect = false
  private let keepaliveIntervalNanoseconds: UInt64 = 15_000_000_000

  var lastVideoFrameBase64: String? { latestVideoFrameBase64 }

  init() {
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 30
    self.urlSession = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
  }

  func connect(
    systemInstruction: String? = nil,
    credential: GeminiLiveCredential
  ) async -> Bool {
    guard let url = GeminiConfig.websocketURL(credential: credential) else {
      connectionState = .error("Gemini Live credential is invalid")
      return false
    }

    setupSystemInstruction = resolvedSystemInstruction(systemInstruction)
    setupModel = credential.model
    connectionState = .connecting
    connectionGeneration += 1
    let generation = connectionGeneration
    isClosingIntentionally = false
    didNotifyRecoverableDisconnect = false
    stopKeepalive()

    let result = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
      self.connectContinuation = continuation

      self.delegate.onOpen = { [weak self] protocol_ in
        guard let self else { return }
        Task { @MainActor in
          guard self.connectionGeneration == generation else { return }
          Task {
            await WorkerTelemetry.shared.record(
              "gemini_socket_open",
              source: "gemini_live",
              stage: "connected",
              payload: ["protocol": protocol_ ?? NSNull()]
            )
          }
          self.onSocketOpened?()
          self.connectionState = .settingUp
          self.startKeepalive(generation: generation)
          self.sendSetupMessage()
          self.startReceiving()
        }
      }

      self.delegate.onClose = { [weak self] code, reason in
        guard let self else { return }
        let reasonStr = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "no reason"
        Task { @MainActor in
          guard self.connectionGeneration == generation else { return }
          Task {
            await WorkerTelemetry.shared.record(
              "gemini_socket_closed",
              source: "gemini_live",
              stage: "closed",
              payload: [
                "code": code.rawValue,
                "reason": reasonStr
              ]
            )
          }
          let message = "Connection closed (code \(code.rawValue): \(reasonStr))"
          if self.isClosingIntentionally || code == .normalClosure {
            self.stopKeepalive()
            self.resolveConnect(success: false)
            self.connectionState = .disconnected
            self.isModelSpeaking = false
            self.resolveCloseWait()
            return
          }
          self.notifyRecoverableDisconnect(.socketClosed(message), state: .disconnected)
        }
      }

      self.delegate.onError = { [weak self] error in
        guard let self else { return }
        let msg = error?.localizedDescription ?? "Unknown error"
        Task { @MainActor in
          guard self.connectionGeneration == generation else { return }
          Task {
            await WorkerTelemetry.shared.record(
              "gemini_socket_error",
              source: "gemini_live",
              stage: "failed",
              payload: ["error": msg]
            )
          }
          guard !self.isClosingIntentionally else {
            self.stopKeepalive()
            self.resolveConnect(success: false)
            self.connectionState = .disconnected
            self.isModelSpeaking = false
            self.resolveCloseWait()
            return
          }
          self.notifyRecoverableDisconnect(.socketError(msg), state: .error(msg))
        }
      }

      self.webSocketTask = self.urlSession.webSocketTask(with: url)
      self.webSocketTask?.resume()

      // Timeout after 15 seconds
      Task {
        try? await Task.sleep(nanoseconds: 15_000_000_000)
        await MainActor.run {
          guard self.connectionGeneration == generation else { return }
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
    isClosingIntentionally = true
    connectionGeneration += 1
    stopKeepalive()
    receiveTask?.cancel()
    receiveTask = nil
    webSocketTask?.cancel(with: .normalClosure, reason: nil)
    webSocketTask = nil
    delegate.onOpen = nil
    delegate.onClose = nil
    delegate.onError = nil
    onSocketOpened = nil
    onSocketClosed = nil
    onRecoverableDisconnect = nil
    connectionState = .disconnected
    isModelSpeaking = false
    resolveConnect(success: false)
    resolveCloseWait()
  }

  func disconnectAndWaitForClose(timeout: TimeInterval = 1.0) async {
    isClosingIntentionally = true
    stopKeepalive()
    receiveTask?.cancel()
    receiveTask = nil

    guard let task = webSocketTask, connectionState != .disconnected else {
      disconnect()
      return
    }

    resolveCloseWait()
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      closeWaitContinuation = continuation
      let boundedTimeout = DispatchTimeInterval.milliseconds(Int(max(timeout, 0.05) * 1_000))
      DispatchQueue.main.asyncAfter(deadline: .now() + boundedTimeout) { [weak self] in
        Task { @MainActor in
          guard let self else { return }
          if self.closeWaitContinuation != nil {
            NSLog("[Gemini] WebSocket close wait timed out")
          }
          self.resolveCloseWait()
        }
      }
      task.cancel(with: .normalClosure, reason: nil)
    }

    webSocketTask = nil
    delegate.onOpen = nil
    delegate.onClose = nil
    delegate.onError = nil
    onSocketOpened = nil
    onSocketClosed = nil
    onRecoverableDisconnect = nil
    connectionState = .disconnected
    isModelSpeaking = false
    resolveConnect(success: false)
  }

  func sendAudio(data: Data) {
    guard connectionState == .ready else { return }
    sendQueue.async { [weak self] in
      let base64 = data.base64EncodedString()
      let json: [String: Any] = [
        "realtimeInput": [
          "audio": [
            "mimeType": "audio/pcm;rate=16000",
            "data": base64
          ]
        ]
      ]
      Task { @MainActor [weak self] in
        self?.sendJSON(json)
      }
    }
  }

  func sendVideoFrame(image: UIImage) {
    guard connectionState == .ready else { return }
    let frameStartedAt = CACurrentMediaTime()
    sendQueue.async { [weak self] in
      guard let self else { return }
      let encodeStartedAt = CACurrentMediaTime()
      guard let jpegData = image.jpegData(compressionQuality: GeminiConfig.videoJPEGQuality) else { return }
      let encodeDurationMs = (CACurrentMediaTime() - encodeStartedAt) * 1000
      let base64 = jpegData.base64EncodedString()
      let json: [String: Any] = [
        "realtimeInput": [
          "video": [
            "mimeType": "image/jpeg",
            "data": base64
          ]
        ]
      ]
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.videoFrameSendCount += 1
        self.logVideoSendStatsIfNeeded(
          payloadBytes: jpegData.count,
          encodeDurationMs: encodeDurationMs,
          totalDurationMs: (CACurrentMediaTime() - frameStartedAt) * 1000
        )
        self.latestVideoFrameBase64 = base64
        self.sendJSON(json)
      }
    }
  }

  func sendTextMessage(_ text: String) {
    guard connectionState == .ready else { return }
    sendQueue.async { [weak self] in
      let msg: [String: Any] = [
        "clientContent": [
          "turns": [
            ["role": "user", "parts": [["text": text]]]
          ]
        ]
      ]
      Task { @MainActor [weak self] in
        self?.sendJSON(msg)
      }
    }
  }

  private func logVideoSendStatsIfNeeded(
    payloadBytes: Int,
    encodeDurationMs: Double,
    totalDurationMs: Double
  ) {
    guard videoFrameSendCount == 1 || videoFrameSendCount % 10 == 0 else { return }
    let now = CACurrentMediaTime()
    let elapsed = max(now - videoFrameStatsWindowStart, 0.001)
    let fps = Double(videoFrameSendCount) / elapsed
    NSLog(
      "[Gemini] Vision lane frames=%lld rate=%.2ffps encode=%.1fms total=%.1fms payload=%dB",
      videoFrameSendCount,
      fps,
      encodeDurationMs,
      totalDurationMs,
      payloadBytes
    )
    Task {
      await WorkerTelemetry.shared.record(
        "gemini_video_frame_sent",
        source: "gemini_live",
        stage: "video",
        durationMs: totalDurationMs,
        metricValue: Double(payloadBytes),
        metricUnit: "bytes",
        payload: [
          "frames": Int(videoFrameSendCount),
          "fps": fps,
          "encode_ms": encodeDurationMs,
          "payload_bytes": payloadBytes
        ]
      )
    }
    videoFrameStatsWindowStart = now
    videoFrameSendCount = 0
  }

  // MARK: - Private

  private func resolveConnect(success: Bool) {
    if let cont = connectContinuation {
      connectContinuation = nil
      cont.resume(returning: success)
    }
  }

  private func resolveCloseWait() {
    guard let cont = closeWaitContinuation else { return }
    closeWaitContinuation = nil
    cont.resume()
  }

  private func startKeepalive(generation: Int) {
    stopKeepalive()
    let interval = keepaliveIntervalNanoseconds
    pingTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: interval)
        guard !Task.isCancelled else { break }
        await MainActor.run {
          self?.sendKeepalivePingIfCurrent(generation: generation)
        }
      }
    }
  }

  private func stopKeepalive() {
    pingTask?.cancel()
    pingTask = nil
  }

  private func sendKeepalivePingIfCurrent(generation: Int) {
    guard connectionGeneration == generation,
          !isClosingIntentionally,
          let task = webSocketTask else {
      return
    }

    task.sendPing { [weak self] error in
      guard let error else { return }
      Task { @MainActor in
        guard let self, self.connectionGeneration == generation else { return }
        self.notifyRecoverableDisconnect(
          .pingError(error.localizedDescription),
          state: .disconnected
        )
      }
    }
  }

  private func notifyRecoverableDisconnect(
    _ reason: GeminiRecoverableDisconnectReason,
    state: GeminiConnectionState
  ) {
    guard !isClosingIntentionally, !didNotifyRecoverableDisconnect else { return }
    didNotifyRecoverableDisconnect = true
    stopKeepalive()
    resolveConnect(success: false)
    connectionState = state
    isModelSpeaking = false
    resolveCloseWait()
    onRecoverableDisconnect?(reason)
  }

  private func resolvedSystemInstruction(_ override: String?) -> String {
    let candidate = override?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !candidate.isEmpty {
      return candidate
    }

    return GeminiConfig.defaultSystemInstruction
  }

  private func sendSetupMessage() {
    let setup: [String: Any] = [
      "setup": [
        "model": setupModel,
        "generationConfig": [
          "responseModalities": ["AUDIO"],
          "thinkingConfig": [
            "thinkingBudget": 0
          ]
        ],
        "systemInstruction": [
          "parts": [
            ["text": setupSystemInstruction]
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
          "activityHandling": "START_OF_ACTIVITY_INTERRUPTS",
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
    sendJSON(setup)
  }

  private func sendJSON(_ json: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: json),
          let string = String(data: data, encoding: .utf8) else {
      return
    }
    webSocketTask?.send(.string(string)) { [weak self] error in
      guard let self, let error else { return }
      Task { @MainActor in
        NSLog("[Gemini] WebSocket send failed: %@", error.localizedDescription)
        self.notifyRecoverableDisconnect(
          .sendError(error.localizedDescription),
          state: .error("WebSocket send failed: \(error.localizedDescription)")
        )
      }
    }
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
            await self.handleMessage(text)
          case .data(let data):
            if let text = String(data: data, encoding: .utf8) {
              await self.handleMessage(text)
            }
          @unknown default:
            break
          }
        } catch {
          if !Task.isCancelled {
            let reason = error.localizedDescription
            await MainActor.run {
              self.notifyRecoverableDisconnect(
                .receiveError(reason),
                state: .disconnected
              )
            }
          }
          break
        }
      }
    }
  }

  private func handleMessage(_ text: String) async {
    guard let data = text.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return
    }

    // Server-provided error payload
    if let errorObj = json["error"] as? [String: Any] {
      let status = errorObj["status"] as? String ?? "UNKNOWN"
      let message = errorObj["message"] as? String ?? "Unknown Gemini server error"
      let full = "Gemini setup error [\(status)]: \(message)"
      NSLog("[Gemini] %@", full)
      connectionState = .error(full)
      isModelSpeaking = false
      resolveConnect(success: false)
      resolveCloseWait()
      onSocketClosed?(full)
      onDisconnected?(full)
      return
    }

    // Setup complete
    if json["setupComplete"] != nil {
      connectionState = .ready
      Task {
        await WorkerTelemetry.shared.record(
          "gemini_setup_complete",
          source: "gemini_live",
          stage: "ready",
          payload: ["model": setupModel]
        )
      }
      resolveConnect(success: true)
      return
    }

    // GoAway - server will close soon
    if let goAway = json["goAway"] as? [String: Any] {
      let timeLeft = goAway["timeLeft"] as? [String: Any]
      let seconds = timeLeft?["seconds"] as? Int ?? 0
      notifyRecoverableDisconnect(.goAway(seconds: seconds), state: .disconnected)
      return
    }

    // Server content
    if let serverContent = json["serverContent"] as? [String: Any] {
      if let interrupted = serverContent["interrupted"] as? Bool, interrupted {
        isModelSpeaking = false
        onInterrupted?()
        return
      }

      if let modelTurn = serverContent["modelTurn"] as? [String: Any],
         let parts = modelTurn["parts"] as? [[String: Any]] {
        for part in parts {
          if let inlineData = part["inlineData"] as? [String: Any],
             let mimeType = inlineData["mimeType"] as? String,
             mimeType.hasPrefix("audio/pcm"),
             let base64Data = inlineData["data"] as? String,
             let audioData = Data(base64Encoded: base64Data) {
            if !isModelSpeaking {
              isModelSpeaking = true
              // Log latency: time from end of user speech to first audio response
              if let speechEnd = lastUserSpeechEnd, !responseLatencyLogged {
                let latency = Date().timeIntervalSince(speechEnd)
                NSLog("[Latency] %.0fms (user speech end -> first audio)", latency * 1000)
                Task {
                  await WorkerTelemetry.shared.record(
                    "gemini_first_audio_latency",
                    source: "gemini_live",
                    stage: "first_audio",
                    durationMs: latency * 1000,
                    metricValue: latency * 1000,
                    metricUnit: "ms"
                  )
                }
                responseLatencyLogged = true
              }
            }
            onAudioReceived?(audioData)
          } else if let text = part["text"] as? String {
            NSLog("[Gemini] %@", text)
          }
        }
      }

      if let turnComplete = serverContent["turnComplete"] as? Bool, turnComplete {
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
