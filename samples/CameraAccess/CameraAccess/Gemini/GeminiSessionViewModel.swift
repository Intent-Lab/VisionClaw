import Foundation
import SwiftUI
import UIKit

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
  @Published var isAudioSuspendedByDeviceSession: Bool = false
  @Published var activeAudioRoute: String = "unknown"
  private let geminiService = GeminiLiveService()
  private let openClawBridge = OpenClawBridge()
  private var toolCallRouter: ToolCallRouter?
  private let audioManager = AudioManager()
  private let eventClient = OpenClawEventClient()
  private var lastVideoFrameTime: Date = .distantPast
  private var stateObservation: Task<Void, Never>?
  private var deviceSessionResumeTask: Task<Void, Never>?
  private var pendingForegroundResume = false
  private var didBecomeActiveObserver: NSObjectProtocol?

  var streamingMode: StreamingMode = .glasses

  init() {
    didBecomeActiveObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.didBecomeActiveNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      guard let self else { return }
      guard self.pendingForegroundResume else { return }
      guard self.isGeminiActive else {
        self.pendingForegroundResume = false
        return
      }

      self.pendingForegroundResume = false
      self.resumeAfterDeviceSessionPauseIfNeeded()
    }
  }

  deinit {
    if let didBecomeActiveObserver {
      NotificationCenter.default.removeObserver(didBecomeActiveObserver)
    }
  }

  func startSession() async {
    guard !isGeminiActive else { return }
    isAudioSuspendedByDeviceSession = false

    guard GeminiConfig.isConfigured else {
      errorMessage = "Gemini API key not configured. Open GeminiConfig.swift and replace YOUR_GEMINI_API_KEY with your key from https://aistudio.google.com/apikey"
      return
    }

    isGeminiActive = true

    // Wire audio callbacks
    audioManager.onAudioCaptured = { [weak self] data in
      guard let self else { return }
      Task { @MainActor in
        guard !self.isAudioSuspendedByDeviceSession else { return }
        // Mute mic while model speaks when speaker is on the phone
        // (loudspeaker + co-located mic overwhelms iOS echo cancellation)
        let speakerOnPhone = self.streamingMode == .iPhone || SettingsManager.shared.speakerOutputEnabled
        if speakerOnPhone && self.geminiService.isModelSpeaking { return }
        self.geminiService.sendAudio(data: data)
      }
    }

    geminiService.onAudioReceived = { [weak self] data in
      guard let self else { return }
      guard !self.isAudioSuspendedByDeviceSession else { return }
      self.audioManager.playAudio(data: data)
    }

    geminiService.onInterrupted = { [weak self] in
      self?.audioManager.stopPlayback()
    }

    geminiService.onTurnComplete = { [weak self] in
      guard let self else { return }
      Task { @MainActor in
        // Clear user transcript when AI finishes responding
        self.userTranscript = ""
      }
    }

    geminiService.onInputTranscription = { [weak self] text in
      guard let self else { return }
      Task { @MainActor in
        self.userTranscript += text
        self.aiTranscript = ""
      }
    }

    geminiService.onOutputTranscription = { [weak self] text in
      guard let self else { return }
      Task { @MainActor in
        self.aiTranscript += text
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

    // Wire tool call handling
    toolCallRouter = ToolCallRouter(bridge: openClawBridge)

    geminiService.onToolCall = { [weak self] toolCall in
      guard let self else { return }
      Task { @MainActor in
        for call in toolCall.functionCalls {
          self.toolCallRouter?.handleToolCall(call) { [weak self] response in
            self?.geminiService.sendToolResponse(response)
          } sendFollowUp: { [weak self] text in
            self?.geminiService.sendTextMessage(text)
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
      activeAudioRoute = audioManager.activeInputRouteDescription
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
      activeAudioRoute = audioManager.activeInputRouteDescription
    } catch {
      errorMessage = "Mic capture failed: \(error.localizedDescription)"
      geminiService.disconnect()
      stateObservation?.cancel()
      stateObservation = nil
      isGeminiActive = false
      connectionState = .disconnected
      return
    }

    // Connect to OpenClaw event stream for proactive notifications
    if SettingsManager.shared.proactiveNotificationsEnabled {
      eventClient.onNotification = { [weak self] text in
        guard let self else { return }
        Task { @MainActor in
          guard self.isGeminiActive, self.connectionState == .ready else { return }
          self.geminiService.sendTextMessage(text)
        }
      }
      eventClient.connect()
    }
  }

  func stopSession() {
    eventClient.disconnect()
    toolCallRouter?.cancelAll()
    toolCallRouter = nil
    audioManager.stopCapture()
    geminiService.disconnect()
    stateObservation?.cancel()
    stateObservation = nil
    deviceSessionResumeTask?.cancel()
    deviceSessionResumeTask = nil
    pendingForegroundResume = false
    isGeminiActive = false
    connectionState = .disconnected
    isModelSpeaking = false
    isAudioSuspendedByDeviceSession = false
    activeAudioRoute = "inactive"
    userTranscript = ""
    aiTranscript = ""
    toolCallStatus = .idle
  }

  func sendVideoFrameIfThrottled(image: UIImage) {
    guard SettingsManager.shared.videoStreamingEnabled else { return }
    guard isGeminiActive, connectionState == .ready else { return }
    guard !isAudioSuspendedByDeviceSession else { return }
    let now = Date()
    guard now.timeIntervalSince(lastVideoFrameTime) >= GeminiConfig.videoFrameInterval else { return }
    lastVideoFrameTime = now
    geminiService.sendVideoFrame(image: image)
  }

  func suspendForDeviceSessionPause() {
    guard isGeminiActive else { return }
    guard streamingMode == .glasses else { return }
    guard !isAudioSuspendedByDeviceSession else { return }

    deviceSessionResumeTask?.cancel()
    deviceSessionResumeTask = nil
    pendingForegroundResume = false
    isAudioSuspendedByDeviceSession = true
    audioManager.stopPlayback()

    if UIApplication.shared.applicationState == .active {
      audioManager.suspendCapture()
      activeAudioRoute = "suspended: \(audioManager.activeInputRouteDescription)"
    } else {
      activeAudioRoute = "background-suspended: \(audioManager.activeInputRouteDescription)"
    }
  }

  func resumeAfterDeviceSessionPauseIfNeeded() {
    guard isGeminiActive else { return }
    guard streamingMode == .glasses else { return }
    guard isAudioSuspendedByDeviceSession else { return }

    if audioManager.isCaptureRunning {
      pendingForegroundResume = false
      activeAudioRoute = audioManager.activeInputRouteDescription
      isAudioSuspendedByDeviceSession = false
      return
    }

    if UIApplication.shared.applicationState != .active {
      pendingForegroundResume = true
      activeAudioRoute = "resume pending until foreground"
      return
    }

    pendingForegroundResume = false
    deviceSessionResumeTask?.cancel()
    deviceSessionResumeTask = Task { @MainActor [weak self] in
      guard let self else { return }

      for attempt in 1...4 {
        guard !Task.isCancelled else { return }

        do {
          try self.audioManager.resumeCapture()
          self.activeAudioRoute = self.audioManager.activeInputRouteDescription
          self.isAudioSuspendedByDeviceSession = false
          self.deviceSessionResumeTask = nil
          return
        } catch {
          self.audioManager.stopCapture()

          if attempt < 4 {
            let delayNs = UInt64(attempt) * 300_000_000
            try? await Task.sleep(nanoseconds: delayNs)
          }
        }
      }

      self.pendingForegroundResume = true
      self.activeAudioRoute = "resume pending until foreground"
      self.errorMessage = "Audio resume deferred until the app is active again"
      self.deviceSessionResumeTask = nil
    }
  }

}
