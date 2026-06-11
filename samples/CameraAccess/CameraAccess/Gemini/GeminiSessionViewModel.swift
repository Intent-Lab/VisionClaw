import Foundation
import SwiftUI
import UIKit

@MainActor
class GeminiSessionViewModel: ObservableObject {
  @Published var isGeminiActive: Bool = false
  @Published var isAudioReady: Bool = false
  @Published var connectionState: GeminiConnectionState = .disconnected
  @Published var isModelSpeaking: Bool = false
  @Published var errorMessage: String?
  @Published var userTranscript: String = ""
  @Published var aiTranscript: String = ""

  private struct LiveSessionConfig {
    let credential: GeminiLiveCredential
    let systemInstruction: String
    let diagnosticsID: String?
    let provider: String?
  }

  private enum GeminiSessionIntent {
    case idle
    case active
    case humanSupport
  }

  private let geminiService = GeminiLiveService()
  private let audioManager = AudioManager()
  private var lastVideoFrameTime: Date = .distantPast
  private var stateObservation: Task<Void, Never>?
  private weak var workerAdminAPI: WorkerAdminAPI?
  private var adminExecutionSessionID: String?
  private var currentLiveCredential: GeminiLiveCredential?
  private var currentSessionInstruction: String?
  private var lastDiagnosticsID: String?
  private var isStoppingSession = false
  private var sessionIntent: GeminiSessionIntent = .idle
  private var sessionGeneration = 0
  private var reconnectTask: Task<Void, Never>?
  private var autoReconnectAttempts = 0
  private let maxAutoReconnectAttempts = 3

  var streamingMode: StreamingMode = .glasses
  var onInputCommand: ((String) -> Void)?
  var onInputAudioChunk: ((Data) -> Void)?
  var onOutputAudioChunk: ((Data) -> Void)?

  func configureWorkerAdminAPI(_ api: WorkerAdminAPI?, sessionID: String? = nil) {
    workerAdminAPI = api
    adminExecutionSessionID = sessionID
  }

  func startSession(systemInstruction: String? = nil) async {
    guard !isGeminiActive else {
      await refreshSessionInstruction(systemInstruction)
      return
    }

    sessionGeneration += 1
    sessionIntent = .active
    autoReconnectAttempts = 0
    reconnectTask?.cancel()
    reconnectTask = nil
    errorMessage = nil
    userTranscript = ""
    aiTranscript = ""
    isStoppingSession = false

    guard let liveConfig = await resolveLiveSessionConfig(fallbackInstruction: systemInstruction) else {
      sessionIntent = .idle
      errorMessage = "Gemini Live token unavailable. Check Admin AI Settings and the worker backend connection."
      return
    }
    currentLiveCredential = liveConfig.credential
    currentSessionInstruction = liveConfig.systemInstruction
    lastDiagnosticsID = liveConfig.diagnosticsID

    isAudioReady = false
    configureRealtimeCallbacks()
    startStateObservation()

    do {
      try audioManager.setupAudioSession(useIPhoneMode: streamingMode == .iPhone)
    } catch {
      sessionIntent = .idle
      await resetToIdle(message: "Audio setup failed: \(error.localizedDescription)")
      return
    }

    let setupOk = await geminiService.connect(
      systemInstruction: liveConfig.systemInstruction,
      credential: liveConfig.credential
    )

    if !setupOk {
      let message = liveConnectionError(
        fallback: "Failed to connect to Gemini",
        diagnosticsID: liveConfig.diagnosticsID
      )
      sessionIntent = .idle
      await resetToIdle(message: message)
      await recordTelemetry(
        "gemini_live_connect_failed",
        stage: "failed",
        payload: [
          "diagnostics_id": liveConfig.diagnosticsID ?? NSNull(),
          "error": message
        ]
      )
      return
    }

    do {
      try audioManager.startCapture()
    } catch {
      sessionIntent = .idle
      await resetToIdle(message: "Mic capture failed: \(error.localizedDescription)")
      return
    }

    isGeminiActive = true
    isAudioReady = true
    await recordTelemetry(
      "gemini_live_session_started",
      stage: "ready",
      payload: [
        "model": liveConfig.credential.model,
        "provider": liveConfig.provider ?? "gemini",
        "diagnostics_id": liveConfig.diagnosticsID ?? NSNull()
      ]
    )
  }

  func stopSession() async {
    sessionIntent = .idle
    sessionGeneration += 1
    reconnectTask?.cancel()
    reconnectTask = nil
    await resetToIdle(message: nil)
  }

  func stopSessionForHumanSupportHandoff() async {
    sessionIntent = .humanSupport
    sessionGeneration += 1
    reconnectTask?.cancel()
    reconnectTask = nil
    await resetToIdle(message: nil)
  }

  func refreshSessionInstruction(_ systemInstruction: String?) async {
    guard isGeminiActive else { return }
    guard let liveConfig = await resolveLiveSessionConfig(fallbackInstruction: systemInstruction) else {
      sessionIntent = .idle
      sessionGeneration += 1
      reconnectTask?.cancel()
      reconnectTask = nil
      await resetToIdle(message: "Gemini Live token refresh failed. Check Admin AI Settings and try again.")
      return
    }

    guard liveConfig.systemInstruction != currentSessionInstruction ||
      liveConfig.credential.model != currentLiveCredential?.model else {
      return
    }

    await reconnectTransport(with: liveConfig)
  }

  func sendVideoFrameIfThrottled(image: UIImage) {
    guard SettingsManager.shared.videoStreamingEnabled else { return }
    guard isGeminiActive, connectionState == .ready else { return }
    let now = Date()
    guard now.timeIntervalSince(lastVideoFrameTime) >= GeminiConfig.videoFrameInterval else { return }
    lastVideoFrameTime = now
    geminiService.sendVideoFrame(image: image)
  }

  private func configureRealtimeCallbacks() {
    audioManager.onAudioCaptured = { [weak self] data in
      guard let self else { return }
      Task { @MainActor in
        guard self.isGeminiActive, !self.isStoppingSession else { return }
        let speakerOnPhone = self.streamingMode == .iPhone || SettingsManager.shared.speakerOutputEnabled
        if speakerOnPhone && self.geminiService.isModelSpeaking { return }
        self.onInputAudioChunk?(data)
        self.geminiService.sendAudio(data: data)
      }
    }

    geminiService.onAudioReceived = { [weak self] data in
      guard let self else { return }
      Task { @MainActor in
        guard self.isGeminiActive, !self.isStoppingSession else { return }
        self.onOutputAudioChunk?(data)
        self.audioManager.playAudio(data: data)
      }
    }

    geminiService.onInterrupted = { [weak self] in
      guard let self else { return }
      Task { @MainActor in
        guard self.isGeminiActive, !self.isStoppingSession else { return }
        self.audioManager.stopPlayback()
      }
    }

    geminiService.onTurnComplete = { [weak self] in
      guard let self else { return }
      Task { @MainActor in
        self.userTranscript = ""
      }
    }

    geminiService.onInputTranscription = { [weak self] text in
      guard let self else { return }
      Task { @MainActor in
        self.userTranscript += text
        self.aiTranscript = ""
        self.onInputCommand?(self.userTranscript)
      }
    }

    geminiService.onOutputTranscription = { [weak self] text in
      guard let self else { return }
      Task { @MainActor in
        self.aiTranscript += text
      }
    }

    geminiService.onRecoverableDisconnect = { [weak self] reason in
      guard let self else { return }
      Task { @MainActor in
        await self.handleRecoverableDisconnect(reason)
      }
    }

    geminiService.onDisconnected = { [weak self] reason in
      guard let self else { return }
      Task { @MainActor in
        await self.handleFatalDisconnect("Gemini connection lost: \(reason ?? "Unknown error")")
      }
    }

    geminiService.onSocketClosed = { [weak self] reason in
      guard let self else { return }
      Task { @MainActor in
        await self.handleFatalDisconnect("Gemini socket closed: \(reason ?? "Unknown error")")
      }
    }
  }

  private func startStateObservation() {
    stateObservation?.cancel()
    stateObservation = Task { [weak self] in
      guard let self else { return }
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 100_000_000)
        guard !Task.isCancelled else { break }
        self.connectionState = self.geminiService.connectionState
        self.isModelSpeaking = self.geminiService.isModelSpeaking
      }
    }
  }

  private func handleFatalDisconnect(_ message: String) async {
    guard isGeminiActive, !isStoppingSession else { return }
    sessionIntent = .idle
    sessionGeneration += 1
    reconnectTask?.cancel()
    reconnectTask = nil
    await resetToIdle(message: message)
  }

  private func handleRecoverableDisconnect(_ reason: GeminiRecoverableDisconnectReason) async {
    guard isGeminiActive, !isStoppingSession, sessionIntent == .active else { return }
    isAudioReady = false
    isModelSpeaking = false

    let generation = sessionGeneration
    guard reconnectTask == nil else { return }
    reconnectTask = Task { @MainActor [weak self] in
      await self?.runAutoReconnect(reason: reason, generation: generation)
    }
  }

  private func shouldContinueAutoReconnect(generation: Int) -> Bool {
    sessionIntent == .active && sessionGeneration == generation
  }

  private func shouldUseReconnectGeneration(_ generation: Int?) -> Bool {
    guard let generation else { return true }
    return shouldContinueAutoReconnect(generation: generation)
  }

  private func runAutoReconnect(
    reason: GeminiRecoverableDisconnectReason,
    generation: Int
  ) async {
    defer {
      if sessionGeneration == generation {
        reconnectTask = nil
      }
    }

    while autoReconnectAttempts < maxAutoReconnectAttempts {
      guard shouldContinueAutoReconnect(generation: generation), !Task.isCancelled else { return }
      autoReconnectAttempts += 1
      let attempt = autoReconnectAttempts
      let delayNanoseconds = UInt64(Double(attempt) * 750_000_000)

      try? await Task.sleep(nanoseconds: delayNanoseconds)
      guard shouldContinueAutoReconnect(generation: generation), !Task.isCancelled else { return }

      await recordTelemetry(
        "gemini_live_auto_reconnect_attempt",
        stage: "retrying",
        payload: [
          "attempt": attempt,
          "max_attempts": maxAutoReconnectAttempts,
          "reason": reason.message
        ]
      )

      let fallbackInstruction = currentSessionInstruction
      guard let liveConfig = await resolveLiveSessionConfig(fallbackInstruction: fallbackInstruction) else {
        continue
      }
      guard shouldContinueAutoReconnect(generation: generation), !Task.isCancelled else { return }

      let didReconnect = await reconnectTransport(
        with: liveConfig,
        preserveTranscripts: true,
        resetOnFailure: false,
        requiredGeneration: generation
      )
      guard shouldContinueAutoReconnect(generation: generation), !Task.isCancelled else { return }

      if didReconnect {
        autoReconnectAttempts = 0
        await recordTelemetry(
          "gemini_live_auto_reconnect_succeeded",
          stage: "ready",
          payload: [
            "attempt": attempt,
            "reason": reason.message,
            "diagnostics_id": liveConfig.diagnosticsID ?? NSNull()
          ]
        )
        return
      }
    }

    guard shouldContinueAutoReconnect(generation: generation) else { return }
    reconnectTask = nil
    sessionIntent = .idle
    sessionGeneration += 1
    await resetToIdle(message: "Gemini connection lost: \(reason.message)")
  }

  @discardableResult
  private func reconnectTransport(
    with liveConfig: LiveSessionConfig,
    preserveTranscripts: Bool = false,
    resetOnFailure: Bool = true,
    requiredGeneration: Int? = nil
  ) async -> Bool {
    let wasActive = isGeminiActive
    isGeminiActive = false
    isAudioReady = false
    isModelSpeaking = false
    isStoppingSession = true
    clearGeminiCallbacks()
    audioManager.stopPlayback()
    await audioManager.stopCapture()
    await Task.yield()
    await geminiService.disconnectAndWaitForClose(timeout: 1.0)
    stateObservation?.cancel()
    stateObservation = nil
    isStoppingSession = false

    guard wasActive || shouldUseReconnectGeneration(requiredGeneration) else { return false }
    guard shouldUseReconnectGeneration(requiredGeneration) else { return false }

    errorMessage = nil
    if !preserveTranscripts {
      userTranscript = ""
      aiTranscript = ""
    }
    currentLiveCredential = liveConfig.credential
    currentSessionInstruction = liveConfig.systemInstruction
    lastDiagnosticsID = liveConfig.diagnosticsID

    configureRealtimeCallbacks()
    startStateObservation()

    do {
      try audioManager.setupAudioSession(useIPhoneMode: streamingMode == .iPhone)
    } catch {
      if resetOnFailure {
        await resetToIdle(message: "Audio setup failed: \(error.localizedDescription)")
      } else {
        errorMessage = "Audio setup failed: \(error.localizedDescription)"
      }
      return false
    }
    guard shouldUseReconnectGeneration(requiredGeneration) else { return false }

    let setupOk = await geminiService.connect(
      systemInstruction: liveConfig.systemInstruction,
      credential: liveConfig.credential
    )
    guard setupOk else {
      let message = liveConnectionError(
        fallback: "Failed to reconnect to Gemini",
        diagnosticsID: liveConfig.diagnosticsID
      )
      if resetOnFailure {
        await resetToIdle(message: message)
      } else {
        errorMessage = message
        await geminiService.disconnectAndWaitForClose(timeout: 1.0)
      }
      return false
    }
    guard shouldUseReconnectGeneration(requiredGeneration) else {
      await geminiService.disconnectAndWaitForClose(timeout: 1.0)
      return false
    }

    do {
      try audioManager.startCapture()
    } catch {
      if resetOnFailure {
        await resetToIdle(message: "Mic capture failed: \(error.localizedDescription)")
      } else {
        errorMessage = "Mic capture failed: \(error.localizedDescription)"
      }
      return false
    }
    guard shouldUseReconnectGeneration(requiredGeneration) else {
      return false
    }

    isGeminiActive = true
    isAudioReady = true
    return true
  }

  private func resolveLiveSessionConfig(fallbackInstruction: String?) async -> LiveSessionConfig? {
    guard let workerAdminAPI, GeminiConfig.isAdminConfigured else {
      await recordTelemetry(
        "gemini_live_token_failed",
        stage: "not_configured",
        payload: ["reason": "admin_api_unavailable"]
      )
      return nil
    }

    do {
      let token = try await workerAdminAPI.requestGeminiLiveToken(
        model: nil,
        sessionID: adminExecutionSessionID
      )
      let instruction = resolvedInstruction(
        serverInstruction: token.systemInstruction,
        fallbackInstruction: fallbackInstruction
      )
      await recordTelemetry(
        "gemini_live_token_received",
        stage: "ready",
        payload: [
          "model": token.credential.model,
          "provider": token.provider ?? "gemini",
          "expires_at": token.expiresAt,
          "diagnostics_id": token.diagnosticsID ?? NSNull()
        ]
      )
      return LiveSessionConfig(
        credential: token.credential,
        systemInstruction: instruction,
        diagnosticsID: token.diagnosticsID,
        provider: token.provider
      )
    } catch {
      let message = error.localizedDescription
      await recordTelemetry(
        "gemini_live_token_failed",
        stage: "failed",
        payload: ["error": message]
      )
      errorMessage = "Gemini token request failed: \(message)"
      return nil
    }
  }

  private func normalizedSystemInstruction(_ instruction: String?) -> String? {
    let trimmed = instruction?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
  }

  private func resolvedInstruction(
    serverInstruction: String?,
    fallbackInstruction: String?
  ) -> String {
    let server = normalizedSystemInstruction(serverInstruction)
    let fallback = normalizedSystemInstruction(fallbackInstruction)

    switch (server, fallback) {
    case let (server?, fallback?) where !server.contains(fallback):
      return """
      \(server)

      Local active-step context from the phone UI:
      \(fallback)
      """
    case let (server?, _):
      return server
    case let (nil, fallback?):
      return fallback
    default:
      return GeminiConfig.defaultSystemInstruction
    }
  }

  private func liveConnectionError(fallback: String, diagnosticsID: String?) -> String {
    let base: String
    if case .error(let err) = geminiService.connectionState {
      base = err
    } else {
      base = fallback
    }
    if let diagnosticsID, !diagnosticsID.isEmpty {
      return "\(base). Diagnostics: \(diagnosticsID)."
    }
    return base
  }

  private func resetToIdle(message: String?) async {
    isStoppingSession = true
    isGeminiActive = false
    isAudioReady = false
    isModelSpeaking = false
    autoReconnectAttempts = 0
    stateObservation?.cancel()
    stateObservation = nil
    clearGeminiCallbacks()
    audioManager.stopPlayback()
    // This is the Gemini-to-WebRTC hardware barrier: the engine graph and
    // accumulator finish before the socket is allowed to close.
    await audioManager.stopCapture()
    await Task.yield()
    await geminiService.disconnectAndWaitForClose(timeout: 1.0)

    connectionState = .disconnected
    userTranscript = ""
    aiTranscript = ""
    currentSessionInstruction = nil
    currentLiveCredential = nil
    errorMessage = normalizedSystemInstruction(message)
    isStoppingSession = false
  }

  private func clearGeminiCallbacks() {
    geminiService.onDisconnected = nil
    geminiService.onSocketClosed = nil
    geminiService.onRecoverableDisconnect = nil
    geminiService.onSocketOpened = nil
    geminiService.onAudioReceived = nil
    geminiService.onInterrupted = nil
    geminiService.onTurnComplete = nil
    geminiService.onInputTranscription = nil
    geminiService.onOutputTranscription = nil
  }

  private func recordTelemetry(
    _ name: String,
    stage: String,
    payload: [String: Any] = [:]
  ) async {
    await WorkerTelemetry.shared.record(
      name,
      source: "gemini_live",
      stage: stage,
      payload: payload
    )
  }
}
