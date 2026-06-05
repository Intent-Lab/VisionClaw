import Foundation
import SwiftUI

@MainActor
class GeminiSessionViewModel: ObservableObject {
  @Published var isGeminiActive: Bool = false
  @Published var connectionState: GeminiConnectionState = .disconnected
  @Published var isModelSpeaking: Bool = false
  @Published var errorMessage: String?
  @Published var userTranscript: String = ""
  @Published var aiTranscript: String = ""
  @Published var messages: [ChatMessage] = ChatHistoryStore.load()
  @Published var toolCallStatus: ToolCallStatus = .idle
  @Published var openClawConnectionState: OpenClawConnectionState = .notConfigured
  private let geminiService = GeminiLiveService()
  private let openClawBridge = OpenClawBridge()
  private var toolCallRouter: ToolCallRouter?
  private let audioManager = AudioManager()
  private let eventClient = OpenClawEventClient()
  private var lastVideoFrameTime: Date = .distantPast
  private var latestVideoFrame: UIImage?
  private let photoCaptureStore = PhotoCaptureStore.shared
  @Published var lastCapturedPhoto: CapturedPhoto?
  private var stateObservation: Task<Void, Never>?

  // Chat message tracking
  private var activeUserBubbleId: String?
  private var activeAIBubbleId: String?
  private var lastUserText: String = ""
  private var lastAIText: String = ""

  var streamingMode: StreamingMode = .glasses

  func startSession() async {
    guard !isGeminiActive else { return }

    guard GeminiConfig.isConfigured else {
      errorMessage = "Gemini API key not configured. Open GeminiConfig.swift and replace YOUR_GEMINI_API_KEY with your key from https://aistudio.google.com/apikey"
      return
    }

    isGeminiActive = true
    RemoteLogger.shared.log("session:start")

    // Insert session divider if there are previous messages
    if !messages.isEmpty {
      messages.append(ChatMessage(role: .sessionDivider, text: ""))
    }

    // Wire audio callbacks
    audioManager.onAudioCaptured = { [weak self] data in
      guard let self else { return }
      Task { @MainActor in
        // Mute mic while model speaks when speaker is on the phone
        // (loudspeaker + co-located mic overwhelms iOS echo cancellation)
        let speakerOnPhone = self.streamingMode == .iPhone || SettingsManager.shared.speakerOutputEnabled
        if speakerOnPhone && self.geminiService.isModelSpeaking { return }
        self.geminiService.sendAudio(data: data)
      }
    }

    geminiService.onAudioReceived = { [weak self] data in
      self?.audioManager.playAudio(data: data)
    }

    geminiService.onInterrupted = { [weak self] in
      self?.audioManager.stopPlayback()
    }

    geminiService.onTurnComplete = { [weak self] in
      guard let self else { return }
      Task { @MainActor in
        // Log finalized transcripts before clearing
        if !self.lastUserText.isEmpty {
          RemoteLogger.shared.log("voice:user", data: ["text": self.lastUserText])
        }
        if !self.lastAIText.isEmpty {
          RemoteLogger.shared.log("voice:ai", data: ["text": self.lastAIText])
        }
        self.finalizeCurrentBubbles()
        self.userTranscript = ""
        ChatHistoryStore.save(self.messages)
      }
    }

    geminiService.onInputTranscription = { [weak self] text in
      guard let self else { return }
      Task { @MainActor in
        self.userTranscript += text
        self.aiTranscript = ""
        self.updateUserBubble(self.userTranscript)
      }
    }

    geminiService.onOutputTranscription = { [weak self] text in
      guard let self else { return }
      Task { @MainActor in
        self.aiTranscript += text
        self.updateAIBubble(self.aiTranscript)
      }
    }

    // Handle unexpected disconnection
    geminiService.onDisconnected = { [weak self] reason in
      guard let self else { return }
      Task { @MainActor in
        guard self.isGeminiActive else { return }
        self.stopSession()
        self.errorMessage = "Connection lost: \(reason ?? "Unknown error")"
      }
    }

    // Check OpenClaw connectivity and start fresh session
    await openClawBridge.checkConnection()
    openClawBridge.resetSession()
    openClawBridge.eventClient = eventClient

    // Wire tool call handling
    toolCallRouter = ToolCallRouter(bridge: openClawBridge)

    // Local capture_photo handler
    toolCallRouter?.onCapturePhoto = { [weak self] description, completion in
      guard let self else { completion(.failure("Session ended")); return }
      guard let frame = self.latestVideoFrame else {
        completion(.failure("No camera frame available to capture"))
        return
      }
      if let photo = self.photoCaptureStore.saveFrame(frame, description: description) {
        self.lastCapturedPhoto = photo
        // Also upload to Mac so agent can access the file
        if let jpegData = frame.jpegData(compressionQuality: 0.9) {
          let base64 = jpegData.base64EncodedString()
          if let macPath = self.openClawBridge.uploadImageFile(base64) {
            completion(.success("Photo captured and saved: \(photo.filename)\nAlso saved on Mac at: \(macPath)"))
          } else {
            completion(.success("Photo captured and saved: \(photo.filename)"))
          }
        } else {
          completion(.success("Photo captured and saved: \(photo.filename)"))
        }
      } else {
        completion(.failure("Failed to save photo"))
      }
    }

    // Auto-save to gallery when image is attached to execute call
    toolCallRouter?.onAutoSaveFrame = { [weak self] image, description in
      guard let self else { return }
      if let photo = self.photoCaptureStore.saveFrame(image, description: description) {
        self.lastCapturedPhoto = photo
      }
    }

    geminiService.onToolCall = { [weak self] toolCall in
      guard let self else { return }
      Task { @MainActor in
        for call in toolCall.functionCalls {
          self.finalizeCurrentBubbles()
          let msg = ChatMessage(role: .toolCall(call.name), text: "Executing...", status: .streaming)
          self.messages.append(msg)
          let toolMsgId = msg.id

          let taskDesc = (call.args["task"] as? String) ?? ""
          RemoteLogger.shared.log("voice:tool_call", data: ["tool": call.name, "task": taskDesc])

          self.toolCallRouter?.handleToolCall(call) { [weak self] response in
            guard let self else { return }
            if let idx = self.messages.firstIndex(where: { $0.id == toolMsgId }) {
              self.messages[idx].text = "Done"
              self.messages[idx].status = .complete
            }
            RemoteLogger.shared.log("voice:tool_result", data: ["tool": call.name, "result": String(response.prefix(500))])
            // Reset active bubbles so post-tool AI text goes into a new bubble
            self.finalizeCurrentBubbles()
            self.geminiService.sendToolResponse(response)
          }
        }
      }
    }

    geminiService.onToolCallCancellation = { [weak self] cancellation in
      guard let self else { return }
      Task { @MainActor in
        self.toolCallRouter?.cancelToolCalls(ids: cancellation.ids)
      }
    }

    // Observe service state
    stateObservation = Task { [weak self] in
      guard let self else { return }
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        guard !Task.isCancelled else { break }
        self.connectionState = self.geminiService.connectionState
        self.isModelSpeaking = self.geminiService.isModelSpeaking
        self.toolCallStatus = self.openClawBridge.lastToolCallStatus
        self.openClawConnectionState = self.openClawBridge.connectionState
      }
    }

    // Setup audio
    do {
      try audioManager.setupAudioSession(useIPhoneMode: streamingMode == .iPhone)
    } catch {
      errorMessage = "Audio setup failed: \(error.localizedDescription)"
      isGeminiActive = false
      return
    }

    // Connect to Gemini and wait for setupComplete
    let setupOk = await geminiService.connect()

    if !setupOk {
      let msg: String
      if case .error(let err) = geminiService.connectionState {
        msg = err
      } else {
        msg = "Failed to connect to Gemini"
      }
      errorMessage = msg
      geminiService.disconnect()
      stateObservation?.cancel()
      stateObservation = nil
      isGeminiActive = false
      connectionState = .disconnected
      return
    }

    // Start mic capture
    do {
      try audioManager.startCapture()
    } catch {
      errorMessage = "Mic capture failed: \(error.localizedDescription)"
      geminiService.disconnect()
      stateObservation?.cancel()
      stateObservation = nil
      isGeminiActive = false
      connectionState = .disconnected
      return
    }

    // Always connect event client — needed for image sending via chat.send
    if SettingsManager.shared.proactiveNotificationsEnabled {
      eventClient.onNotification = { [weak self] text in
        guard let self else { return }
        Task { @MainActor in
          guard self.isGeminiActive, self.connectionState == .ready else { return }
          self.geminiService.sendTextMessage(text)
        }
      }
    } else {
      eventClient.onNotification = nil
    }
    eventClient.connect()
  }

  func stopSession() {
    RemoteLogger.shared.log("session:end")
    eventClient.disconnect()
    toolCallRouter?.cancelAll()
    toolCallRouter = nil
    audioManager.stopCapture()
    geminiService.disconnect()
    stateObservation?.cancel()
    stateObservation = nil
    isGeminiActive = false
    connectionState = .disconnected
    isModelSpeaking = false
    userTranscript = ""
    aiTranscript = ""
    toolCallStatus = .idle
    ChatHistoryStore.save(messages)
  }

  func sendVideoFrameIfThrottled(image: UIImage) {
    // Always keep latest frame for capture_photo and include_image
    latestVideoFrame = image
    toolCallRouter?.latestFrame = image
    guard SettingsManager.shared.videoStreamingEnabled else { return }
    guard isGeminiActive, connectionState == .ready else { return }
    let now = Date()
    guard now.timeIntervalSince(lastVideoFrameTime) >= GeminiConfig.videoFrameInterval else { return }
    lastVideoFrameTime = now
    geminiService.sendVideoFrame(image: image)
  }

  // MARK: - Chat message helpers

  private func updateUserBubble(_ text: String) {
    guard !text.isEmpty else { return }
    if let id = activeUserBubbleId, let idx = messages.firstIndex(where: { $0.id == id }) {
      messages[idx].text = text
    } else {
      // Finalize previous AI bubble before starting new user turn
      if let aiId = activeAIBubbleId, let idx = messages.firstIndex(where: { $0.id == aiId }) {
        messages[idx].status = .complete
        activeAIBubbleId = nil
      }
      let msg = ChatMessage(role: .user, text: text, status: .streaming)
      messages.append(msg)
      activeUserBubbleId = msg.id
    }
    lastUserText = text
  }

  private func updateAIBubble(_ text: String) {
    guard !text.isEmpty else { return }
    // Finalize user bubble when AI starts responding
    if let userId = activeUserBubbleId, let idx = messages.firstIndex(where: { $0.id == userId }) {
      messages[idx].status = .complete
    }
    if let id = activeAIBubbleId, let idx = messages.firstIndex(where: { $0.id == id }) {
      messages[idx].text = text
    } else {
      let msg = ChatMessage(role: .assistant, text: text, status: .streaming)
      messages.append(msg)
      activeAIBubbleId = msg.id
    }
    lastAIText = text
  }

  private func finalizeCurrentBubbles() {
    if let id = activeUserBubbleId, let idx = messages.firstIndex(where: { $0.id == id }) {
      messages[idx].status = .complete
    }
    if let id = activeAIBubbleId, let idx = messages.firstIndex(where: { $0.id == id }) {
      messages[idx].status = .complete
    }
    activeUserBubbleId = nil
    activeAIBubbleId = nil
    lastUserText = ""
    lastAIText = ""
  }
}
