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
  @Published var toolCallStatus: ToolCallStatus = .idle
  @Published var openClawConnectionState: OpenClawConnectionState = .notConfigured
  @Published var isInspectionActive: Bool = false
  @Published var isSafetyMonitorActive: Bool = false
  @Published var sessionContext: SessionContext?
  @Published var reportURLToShare: URL?

  weak var webrtcVM: WebRTCSessionViewModel?
  var frameProvider: (() -> UIImage?)?

  private let geminiService = GeminiLiveService()
  private let openClawBridge = OpenClawBridge()
  private var toolCallRouter: ToolCallRouter?
  private let audioManager = AudioManager()
  private let eventClient = OpenClawEventClient()
  private var lastVideoFrameTime: Date = .distantPast
  private var stateObservation: Task<Void, Never>?
  private var inspectionTimer: Task<Void, Never>?
  private var inspectionFocus: String?
  private var safetyTimer: Task<Void, Never>?
  private let locationService = LocationService()
  @Published var spatialService: SpatialLocalizationService?

  var streamingMode: StreamingMode = .glasses

  func startSession() async {
    guard !isGeminiActive else { return }

    guard GeminiConfig.isConfigured else {
      errorMessage = "Gemini API key not configured. Open GeminiConfig.swift and replace YOUR_GEMINI_API_KEY with your key from https://aistudio.google.com/apikey"
      return
    }

    isGeminiActive = true

    // Initialize session context
    let context = SessionContext()
    sessionContext = context
    locationService.requestPermissionAndStart()
    if let coord = locationService.currentCoordinate {
      context.coordinates = (lat: coord.latitude, lon: coord.longitude)
      context.reverseGeocodedAddress = locationService.currentAddress
    }

    // Start spatial localization (Multiset VPS if configured, else GPS fallback)
    let spatial = SpatialLocalizationService(locationService: locationService)
    spatialService = spatial
    spatial.start()
    context.spatialService = spatial

    geminiService.sessionContextString = context.contextString()

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
        // Clear user transcript when AI finishes responding
        self.userTranscript = ""
      }
    }

    geminiService.onInputTranscription = { [weak self] text in
      guard let self else { return }
      Task { @MainActor in
        self.userTranscript += text
        self.aiTranscript = ""
        // Broadcast to WebRTC viewers
        self.webrtcVM?.broadcastTranscript(speaker: "User", text: text)
      }
    }

    geminiService.onOutputTranscription = { [weak self] text in
      guard let self else { return }
      Task { @MainActor in
        self.aiTranscript += text
        // Broadcast to WebRTC viewers
        self.webrtcVM?.broadcastTranscript(speaker: "AI", text: text)
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

    // Wire router handlers
    toolCallRouter?.frameProvider = frameProvider
    toolCallRouter?.inspectionHandler = { [weak self] action, focus in
      guard let self else { return }
      if action == "start" {
        self.startInspection(focus: focus)
      } else {
        self.stopInspection()
      }
    }
    toolCallRouter?.safetyHandler = { [weak self] action in
      guard let self else { return }
      if action == "start" {
        self.startSafetyMonitor()
      } else {
        self.stopSafetyMonitor()
      }
    }
    toolCallRouter?.noteHandler = { [weak self] note, category in
      guard let self else { return }
      self.sessionContext?.addNote(note, category: category ?? "general")
    }
    toolCallRouter?.sessionContextProvider = { [weak self] in
      return self?.sessionContext
    }
    toolCallRouter?.reportShareHandler = { [weak self] url in
      self?.reportURLToShare = url
    }

    geminiService.onToolCall = { [weak self] toolCall in
      guard let self else { return }
      Task { @MainActor in
        for call in toolCall.functionCalls {
          self.toolCallRouter?.handleToolCall(call) { [weak self] response in
            self?.geminiService.sendToolResponse(response)
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
        // Update location in context
        if let coord = self.locationService.currentCoordinate {
          self.sessionContext?.coordinates = (lat: coord.latitude, lon: coord.longitude)
          self.sessionContext?.reverseGeocodedAddress = self.locationService.currentAddress
        }
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

    // Auto-start inspection if configured
    if SettingsManager.shared.inspectionAutoStart {
      startInspection(focus: nil)
    }

    // Auto-start safety monitor if configured
    if SettingsManager.shared.safetyMonitorAutoStart {
      startSafetyMonitor()
    }

    // Enter collaborative mode on WebRTC if active
    if let webrtc = webrtcVM, webrtc.isActive {
      webrtc.enterCollaborativeMode()
    }
  }

  func stopSession() {
    stopInspection()
    stopSafetyMonitor()
    spatialService?.stop()
    spatialService = nil
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
    sessionContext = nil
  }

  func sendVideoFrameIfThrottled(image: UIImage) {
    guard SettingsManager.shared.videoStreamingEnabled else { return }
    guard isGeminiActive, connectionState == .ready else { return }
    let now = Date()
    guard now.timeIntervalSince(lastVideoFrameTime) >= GeminiConfig.videoFrameInterval else { return }
    lastVideoFrameTime = now
    geminiService.sendVideoFrame(image: image)
  }

  // MARK: - Inspection Mode

  func startInspection(focus: String?) {
    guard !isInspectionActive else { return }
    isInspectionActive = true
    inspectionFocus = focus
    let interval = TimeInterval(SettingsManager.shared.inspectionInterval)
    NSLog("[Inspection] Started (interval: %.0fs, focus: %@)", interval, focus ?? "general")

    inspectionTimer = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        guard !Task.isCancelled else { break }
        guard let self, self.isGeminiActive, self.connectionState == .ready else { continue }
        var prompt = "[INSPECTION] Analyze the current camera view."
        if let focus = self.inspectionFocus {
          prompt += " Focus area: \(focus)."
        }
        prompt += " Only speak if you see something noteworthy. If nothing stands out, stay completely silent."
        self.geminiService.sendTextMessage(prompt)
      }
    }
  }

  func stopInspection() {
    guard isInspectionActive else { return }
    inspectionTimer?.cancel()
    inspectionTimer = nil
    isInspectionActive = false
    inspectionFocus = nil
    NSLog("[Inspection] Stopped")
  }

  // MARK: - Safety Monitor

  func startSafetyMonitor() {
    guard !isSafetyMonitorActive else { return }
    isSafetyMonitorActive = true
    let interval = TimeInterval(SettingsManager.shared.safetyMonitorInterval)
    NSLog("[Safety] Monitor started (interval: %.0fs)", interval)

    safetyTimer = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        guard !Task.isCancelled else { break }
        guard let self, self.isGeminiActive, self.connectionState == .ready else { continue }
        let prompt = "[SAFETY CHECK] Scan the current view for safety hazards. ONLY speak if you see a genuine danger — missing PPE, electrical hazards, fall risks, fire risks, or OSHA violations. If everything looks safe, stay completely silent."
        self.geminiService.sendTextMessage(prompt)
      }
    }
  }

  func stopSafetyMonitor() {
    guard isSafetyMonitorActive else { return }
    safetyTimer?.cancel()
    safetyTimer = nil
    isSafetyMonitorActive = false
    NSLog("[Safety] Monitor stopped")
  }
}
