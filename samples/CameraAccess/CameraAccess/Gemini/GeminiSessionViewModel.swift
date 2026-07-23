import Foundation
import SwiftUI

struct ToolAudioGate {
  private var pendingCallIDs: Set<String> = []

  var hasPendingCalls: Bool {
    !pendingCallIDs.isEmpty
  }

  mutating func begin(callIDs: [String]) {
    pendingCallIDs.formUnion(callIDs)
  }

  mutating func finish(callID: String) {
    pendingCallIDs.remove(callID)
  }

  @discardableResult
  mutating func cancel(callIDs: [String]) -> Bool {
    pendingCallIDs.subtract(callIDs)
    return !hasPendingCalls
  }

  mutating func reset() {
    pendingCallIDs.removeAll()
  }
}

@MainActor
class GeminiSessionViewModel: ObservableObject {
  @Published var isGeminiActive: Bool = false
  @Published var connectionState: GeminiConnectionState = .disconnected
  @Published var isModelSpeaking: Bool = false
  @Published var errorMessage: String?
  @Published var userTranscript: String = ""
  @Published var aiTranscript: String = ""
  @Published var toolCallStatus: ToolCallStatus = .idle
  @Published var openClawConnectionState: OpenClawConnectionState = .notConfigured
  private let geminiService = GeminiLiveService()
  private let openClawBridge = OpenClawBridge()
  private var toolCallRouter: ToolCallRouter?
  private let audioManager = AudioManager()
  private let eventClient = OpenClawEventClient()
  private var toolAudioGate = ToolAudioGate()
  private var lastVideoFrameTime: Date = .distantPast
  private var stateObservation: Task<Void, Never>?
  private var isInputAudioPaused = false
  private var pendingProactiveNotifications: [String] = []
  private var isProactiveTurnInFlight = false
  private var awaitingPostToolTurn = false
  private var lastConversationActivity: Date = .distantPast

  var streamingMode: StreamingMode = .glasses

  func startSession() async {
    guard !isGeminiActive else { return }

    guard GeminiConfig.isConfigured else {
      errorMessage = "Gemini API key not configured. Open GeminiConfig.swift and replace YOUR_GEMINI_API_KEY with your key from https://aistudio.google.com/apikey"
      return
    }

    isGeminiActive = true

    // Wire audio callbacks
    audioManager.onAudioCaptured = { [weak self] data in
      guard let self else { return }
      Task { @MainActor in
        // Keep the session half-duplex until every locally queued PCM buffer has
        // played. This prevents the glasses from feeding Gemini's voice back into
        // its own sensitive VAD after server-side turnComplete arrives.
        if self.geminiService.isModelSpeaking
            || self.audioManager.isPlaybackActive
            || self.toolAudioGate.hasPendingCalls
            || self.awaitingPostToolTurn
            || self.isProactiveTurnInFlight {
          self.pauseInputAudioIfNeeded()
          return
        }
        self.isInputAudioPaused = false
        self.geminiService.sendAudio(data: data)
      }
    }

    geminiService.onAudioReceived = { [weak self] data in
      guard let self else { return }
      self.lastConversationActivity = Date()
      self.audioManager.playAudio(data: data)
    }

    geminiService.onInterrupted = { [weak self] in
      guard let self else { return }
      self.lastConversationActivity = Date()
      self.isProactiveTurnInFlight = false
      self.awaitingPostToolTurn = false
      self.audioManager.stopPlayback(reason: "Gemini interruption")
      self.isInputAudioPaused = false
    }

    geminiService.onTurnComplete = { [weak self] in
      guard let self else { return }
      self.lastConversationActivity = Date()
      self.isProactiveTurnInFlight = false
      self.awaitingPostToolTurn = false
      // Clear user transcript when AI finishes responding
      self.userTranscript = ""
    }

    geminiService.onInputTranscription = { [weak self] text in
      guard let self else { return }
      self.lastConversationActivity = Date()
      self.userTranscript += text
      self.aiTranscript = ""
    }

    geminiService.onOutputTranscription = { [weak self] text in
      guard let self else { return }
      self.lastConversationActivity = Date()
      self.aiTranscript += text
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

    // Wire tool call handling
    toolCallRouter = ToolCallRouter(bridge: openClawBridge)

    geminiService.onToolCall = { [weak self] toolCall in
      guard let self else { return }
      Task { @MainActor in
        self.lastConversationActivity = Date()
        let callIDs = toolCall.functionCalls.map(\.id)
        guard let toolCallRouter = self.toolCallRouter else {
          let canResumeStreaming = self.toolAudioGate.cancel(callIDs: callIDs)
          if canResumeStreaming {
            self.geminiService.setVideoStreamingPaused(false)
          }
          return
        }

        if !callIDs.isEmpty {
          self.toolAudioGate.begin(callIDs: callIDs)
          self.pauseInputAudioIfNeeded()
          self.geminiService.setVideoStreamingPaused(true)
          // Never stop or discard playback here. The acknowledgement is allowed
          // to drain completely while OpenClaw runs.
        }

        toolCallRouter.handleToolCalls(toolCall.functionCalls) { [weak self] response in
          guard let self else { return }
          self.awaitingPostToolTurn = true
          self.geminiService.sendToolResponse(response) { [weak self] sent in
            guard let self else { return }
            for callID in callIDs {
              self.toolAudioGate.finish(callID: callID)
            }
            if !self.toolAudioGate.hasPendingCalls {
              self.geminiService.setVideoStreamingPaused(false)
            }
            if !sent {
              self.awaitingPostToolTurn = false
              self.errorMessage = "The OpenClaw result could not be returned to Gemini."
            }
          }
        }
      }
    }

    geminiService.onToolCallCancellation = { [weak self] cancellation in
      guard let self else { return }
      Task { @MainActor in
        self.toolCallRouter?.cancelToolCalls(ids: cancellation.ids)
        let canResumeStreaming = self.toolAudioGate.cancel(callIDs: cancellation.ids)
        if canResumeStreaming {
          self.awaitingPostToolTurn = false
          self.geminiService.setVideoStreamingPaused(false)
        }
      }
    }

    // Observe service state
    stateObservation = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        guard !Task.isCancelled else { break }
        guard let self else { break }
        let nextConnectionState = self.geminiService.connectionState
        if self.connectionState != nextConnectionState {
          self.connectionState = nextConnectionState
        }

        let nextIsModelSpeaking = self.geminiService.isModelSpeaking
          || self.audioManager.isPlaybackActive
        if self.isModelSpeaking != nextIsModelSpeaking {
          self.isModelSpeaking = nextIsModelSpeaking
        }

        let nextToolCallStatus = self.openClawBridge.lastToolCallStatus
        if self.toolCallStatus != nextToolCallStatus {
          self.toolCallStatus = nextToolCallStatus
        }

        let nextOpenClawState = self.openClawBridge.connectionState
        if self.openClawConnectionState != nextOpenClawState {
          self.openClawConnectionState = nextOpenClawState
        }

        self.deliverPendingNotificationIfIdle()
      }
    }

    // Setup audio
    do {
      try audioManager.setupAudioSession(useIPhoneMode: streamingMode == .iPhone)
    } catch {
      let message = "Audio setup failed: \(error.localizedDescription)"
      stopSession()
      errorMessage = message
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
      stopSession()
      errorMessage = msg
      return
    }

    // Start mic capture
    do {
      try audioManager.startCapture()
    } catch {
      let message = "Mic capture failed: \(error.localizedDescription)"
      stopSession()
      errorMessage = message
      return
    }

    // Connect to OpenClaw event stream for proactive notifications
    if SettingsManager.shared.proactiveNotificationsEnabled {
      eventClient.onNotification = { [weak self] text in
        guard let self else { return }
        Task { @MainActor in
          guard self.isGeminiActive, self.connectionState == .ready else { return }
          self.enqueueProactiveNotification(text)
        }
      }
      eventClient.connect()
    }
  }

  func stopSession() {
    eventClient.disconnect()
    toolCallRouter?.cancelAll()
    toolCallRouter = nil
    toolAudioGate.reset()
    isInputAudioPaused = false
    pendingProactiveNotifications.removeAll()
    isProactiveTurnInFlight = false
    awaitingPostToolTurn = false
    audioManager.stopPlayback(reason: "AI session stopped")
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
  }

  func sendVideoFrameIfThrottled(image: UIImage) {
    guard SettingsManager.shared.videoStreamingEnabled else { return }
    guard isGeminiActive, connectionState == .ready else { return }
    let now = Date()
    guard now.timeIntervalSince(lastVideoFrameTime) >= GeminiConfig.videoFrameInterval else { return }
    lastVideoFrameTime = now
    geminiService.sendVideoFrame(image: image)
  }

  private func pauseInputAudioIfNeeded() {
    guard !isInputAudioPaused else { return }
    isInputAudioPaused = true
    geminiService.sendAudioStreamEnd()
  }

  private func enqueueProactiveNotification(_ text: String) {
    pendingProactiveNotifications.append(text)
    if pendingProactiveNotifications.count > 10 {
      pendingProactiveNotifications.removeFirst(pendingProactiveNotifications.count - 10)
    }
    deliverPendingNotificationIfIdle()
  }

  private func deliverPendingNotificationIfIdle() {
    guard isGeminiActive,
          connectionState == .ready,
          !isProactiveTurnInFlight,
          !pendingProactiveNotifications.isEmpty,
          !geminiService.isModelSpeaking,
          !audioManager.isPlaybackActive,
          !toolAudioGate.hasPendingCalls,
          !awaitingPostToolTurn,
          userTranscript.isEmpty,
          Date().timeIntervalSince(lastConversationActivity) >= 0.75 else { return }

    isProactiveTurnInFlight = true
    lastConversationActivity = Date()
    let text = pendingProactiveNotifications.removeFirst()
    pauseInputAudioIfNeeded()
    geminiService.sendTextMessage(text)
  }

}
