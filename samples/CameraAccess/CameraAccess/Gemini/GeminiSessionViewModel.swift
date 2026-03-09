import CoreLocation
import Foundation
import SwiftUI

struct MeetingLine: Identifiable {
  let id = UUID()
  let speaker: String
  var text: String
  let time: Date
}

struct GolfState {
  var currentHole: Int = 1
  var par: Int = 0
  var scoreToPar: Int = 0
  var totalScore: Int = 0
  var wind: String = ""
  var windSpeed: Double?       // mph
  var windDirection: String = "" // e.g. "NW"
  var lastClub: String = ""
  var recommendedClub: String = ""
  var courseName: String = ""
  // V2: course data + distance
  var courseId: String = ""
  var distanceToGreen: Int?
  var holeYardage: Int?
  var courseLoaded: Bool = false
  var courseConfirmed: Bool = false
  var pendingCourseName: String = ""  // course detected, awaiting confirmation
  var nearbyCoursesForPicker: [GolfCourse] = []
  var holesData: [GolfHoleData] = []
  var lastHoleAskedForScore: Int = 0
  var holeStartTime: Date?
  var holeStartCoord: CLLocationCoordinate2D?
  var showMiniMap: Bool = false
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
  @Published var sessionMode: SessionMode = .normal
  /// Running meeting transcript lines for UI display (meeting mode only)
  @Published var meetingLines: [MeetingLine] = []
  /// Golf round state for UI display (golf mode only)
  @Published var golfState: GolfState?
  /// Translation lines for UI display (translation mode only)
  @Published var translationLines: [TranslationLine] = []
  /// Translation output mode (text/audio/both)
  @Published var translationOutputMode: TranslationOutputMode = .both
  @Published var showDiscordSharePrompt: Bool = false
  var pendingDiscordSummary: DiscordWebhookService.SessionSummary?
  private let geminiService = GeminiLiveService()
  private let openClawBridge = OpenClawBridge()
  private var toolCallRouter: ToolCallRouter?
  private let audioManager = AudioManager()
  private let locationManager = LocationManager()
  private var gpsInjectionTask: Task<Void, Never>?
  private var lastVideoFrameTime: Date = .distantPast
  private var stateObservation: Task<Void, Never>?
  private var eagerPollingTask: Task<Void, Never>?
  private var reconnectTask: Task<Void, Never>?
  private var reconnectAttempts: Int = 0
  private let maxReconnectAttempts: Int = 5
  private var sessionLog: [(timestamp: Date, role: String, text: String)] = []
  private var sessionStartTime: Date?

  var streamingMode: StreamingMode = .glasses

  /// Closure that returns the current video frame from the stream.
  /// Set by StreamSessionView when wiring ViewModels together.
  var currentFrameProvider: (() -> UIImage?)?

  /// Called from StreamView.onAppear — checks OpenClaw connectivity immediately
  /// and starts a lightweight polling loop for the status indicator.
  func checkOpenClawOnAppear() {
    guard GeminiConfig.isOpenClawConfigured else {
      openClawConnectionState = .notConfigured
      return
    }
    // Run connection check in background
    Task { await openClawBridge.checkConnection() }
    // Start lightweight polling for OpenClaw status (stops when session starts)
    guard eagerPollingTask == nil else { return }
    eagerPollingTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
        guard !Task.isCancelled, let self else { break }
        // Stop if a full session is active (stateObservation takes over)
        if self.isGeminiActive { break }
        self.openClawConnectionState = self.openClawBridge.connectionState
      }
    }
  }

  func startSession() async {
    guard !isGeminiActive else { return }

    guard GeminiConfig.isConfigured else {
      errorMessage = "Gemini API key not configured. Open GeminiConfig.swift and replace YOUR_GEMINI_API_KEY with your key from https://aistudio.google.com/apikey"
      return
    }

    // Stop eager polling — the 100ms stateObservation loop takes over
    eagerPollingTask?.cancel()
    eagerPollingTask = nil

    isGeminiActive = true
    sessionLog = []
    sessionStartTime = Date()

    // Pass session mode to the service layer
    geminiService.sessionMode = sessionMode

    // Wire audio callbacks
    audioManager.onAudioCaptured = { [weak self] data in
      guard let self else { return }
      Task { @MainActor in
        // iPhone mode: mute mic while model speaks to prevent echo feedback
        // (loudspeaker + co-located mic overwhelms iOS echo cancellation)
        if self.streamingMode == .iPhone && self.geminiService.isModelSpeaking { return }
        self.geminiService.sendAudio(data: data)
      }
    }

    geminiService.onAudioReceived = { [weak self] data in
      guard let self else { return }
      // Meeting mode: never play audio — AI is silent note-taker
      if self.sessionMode == .meeting { return }
      // Translation mode: suppress audio when textOnly
      if self.sessionMode == .liveTranslation && self.translationOutputMode == .textOnly { return }
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
        self.sessionLog.append((timestamp: Date(), role: "You", text: text))
        // Append to meeting transcript for live UI
        if self.sessionMode == .meeting {
          self.appendMeetingLine(speaker: "Speaker", text: text)
        }
        // Append original speech to translation lines
        if self.sessionMode == .liveTranslation {
          self.appendTranslationLine(text: text, isTranslation: false)
        }
      }
    }

    geminiService.onOutputTranscription = { [weak self] text in
      guard let self else { return }
      Task { @MainActor in
        self.aiTranscript += text
        self.sessionLog.append((timestamp: Date(), role: "AI", text: text))
        // In meeting mode, AI text = notes/summary (TEXT modality)
        if self.sessionMode == .meeting {
          self.appendMeetingLine(speaker: "Notes", text: text)
        }
        // Append translated text to translation lines
        if self.sessionMode == .liveTranslation {
          self.appendTranslationLine(text: text, isTranslation: true)
        }
      }
    }

    // Handle unexpected disconnection with auto-reconnect
    geminiService.onDisconnected = { [weak self] reason in
      guard let self else { return }
      Task { @MainActor in
        guard self.isGeminiActive else { return }
        NSLog("[GeminiSession] Disconnected: %@. Attempting reconnect...", reason ?? "unknown")
        self.audioManager.stopCapture()
        self.geminiService.disconnect()
        self.connectionState = .connecting
        self.aiTranscript = "Reconnecting..."
        await self.attemptReconnect()
      }
    }

    // In meeting and translation modes: skip OpenClaw and tool wiring entirely
    // Golf mode needs tools (execute) for scorecard/weather/course lookup
    if sessionMode != .meeting && sessionMode != .liveTranslation {
      // Check OpenClaw connectivity in background — don't block Gemini startup
      openClawBridge.resetSession()
      openClawBridge.startHealthCheck()
      Task { await self.openClawBridge.checkConnection() }

      // Wire tool call handling
      toolCallRouter = ToolCallRouter(bridge: openClawBridge)
      toolCallRouter?.currentFrameProvider = currentFrameProvider

      geminiService.onToolCall = { [weak self] toolCall in
        guard let self else { return }
        Task { @MainActor in
          for call in toolCall.functionCalls {
            let argsStr = (try? JSONSerialization.data(withJSONObject: call.args)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            self.sessionLog.append((timestamp: Date(), role: "Tool", text: "\(call.name)(\(argsStr))"))
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

    // Setup audio — meeting mode uses backgroundMix so it coexists with other apps
    do {
      try audioManager.setupAudioSession(
        useIPhoneMode: streamingMode == .iPhone,
        backgroundMix: sessionMode == .meeting
      )
    } catch {
      errorMessage = "Audio setup failed: \(error.localizedDescription)"
      isGeminiActive = false
      return
    }

    // Handle audio interruptions (phone call, Siri, etc.)
    audioManager.onInterruptionStateChanged = { [weak self] interrupted in
      guard let self else { return }
      Task { @MainActor in
        if interrupted {
          self.aiTranscript = "Audio paused (another app)"
          NSLog("[GeminiSession] Audio interrupted — session still alive")
        } else {
          self.aiTranscript = ""
          NSLog("[GeminiSession] Audio resumed")
        }
      }
    }

    // Connect to Gemini and wait for setupComplete
    let setupOk = await geminiService.connect()

    if !setupOk {
      let msg: String
      if case .error(let err) = geminiService.connectionState {
        msg = "Gemini error: \(err)"
      } else {
        msg = "Failed to connect to Gemini (state: \(geminiService.connectionState))"
      }
      NSLog("[GeminiSession] Connection failed: %@", msg)
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
  }

  func stopSession() {
    // Golf mode: stop GPS, clear course data, save final scorecard
    if sessionMode == .golf {
      gpsInjectionTask?.cancel()
      gpsInjectionTask = nil
      locationManager.stop()
      GolfCourseAPIService.shared.clearActiveCourse()
      saveGolfScorecard()
    }

    // Snapshot session data for Discord share prompt before clearing state
    let duration = sessionStartTime.map { Int(Date().timeIntervalSince($0)) } ?? 0
    let hasContent = !sessionLog.isEmpty || !meetingLines.isEmpty || !translationLines.isEmpty || golfState != nil
    if hasContent {
      pendingDiscordSummary = DiscordWebhookService.SessionSummary(
        mode: sessionMode,
        streamingMode: streamingMode,
        startTime: sessionStartTime,
        durationSeconds: duration,
        sessionLog: sessionLog,
        meetingLines: meetingLines,
        golfState: golfState,
        translationLines: translationLines
      )
    }

    saveSessionTranscript()
    saveSessionToOpenClaw()
    openClawBridge.stopHealthCheck()
    reconnectTask?.cancel()
    reconnectTask = nil
    reconnectAttempts = 0
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
    meetingLines = []
    translationLines = []
    golfState = nil
    sessionMode = .normal

    // Show Discord share prompt if we have session data
    if pendingDiscordSummary != nil {
      showDiscordSharePrompt = true
    }
  }

  func shareToDiscord() {
    guard let summary = pendingDiscordSummary else { return }
    pendingDiscordSummary = nil
    showDiscordSharePrompt = false
    Task {
      let posted = await DiscordWebhookService.post(summary: summary)
      if !posted {
        NSLog("[Discord] Direct webhook failed, trying via OpenClaw...")
        await shareToDiscordViaOpenClaw(summary: summary)
      }
    }
  }

  func dismissDiscordShare() {
    pendingDiscordSummary = nil
    showDiscordSharePrompt = false
  }

  private func shareToDiscordViaOpenClaw(summary: DiscordWebhookService.SessionSummary) async {
    let state = openClawBridge.connectionState
    guard state == .connected || state == .connectedViaTunnel else { return }
    let modeLabel: String
    switch summary.mode {
    case .meeting: modeLabel = "meeting notes"
    case .golf: modeLabel = "golf round summary"
    case .liveTranslation: modeLabel = "translation session"
    case .normal: modeLabel = "session notes"
    }
    let logText = summary.sessionLog.map { "\($0.role): \($0.text)" }.joined(separator: "\n")
    let _ = await openClawBridge.delegateTask(
      task: "Post the following \(modeLabel) to the #visionclaw Discord channel:\n\(logText)",
      toolName: "discord_share"
    )
  }

  private func appendMeetingLine(speaker: String, text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    // Consolidate consecutive lines from same speaker
    if let last = meetingLines.last, last.speaker == speaker {
      meetingLines[meetingLines.count - 1].text += " " + trimmed
    } else {
      meetingLines.append(MeetingLine(speaker: speaker, text: trimmed, time: Date()))
    }
    // Keep last 50 lines to avoid memory bloat
    if meetingLines.count > 50 {
      meetingLines.removeFirst(meetingLines.count - 50)
    }
  }

  private func appendTranslationLine(text: String, isTranslation: Bool) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    // Consolidate consecutive lines of same type
    if let last = translationLines.last, last.isTranslation == isTranslation {
      var updated = translationLines
      let combined = TranslationLine(time: last.time, text: last.text + " " + trimmed, isTranslation: isTranslation)
      updated[updated.count - 1] = combined
      translationLines = updated
    } else {
      translationLines.append(TranslationLine(time: Date(), text: trimmed, isTranslation: isTranslation))
    }
    // Keep last 40 lines to avoid memory bloat
    if translationLines.count > 40 {
      translationLines.removeFirst(translationLines.count - 40)
    }
  }

  private func saveSessionTranscript() {
    guard !sessionLog.isEmpty else { return }

    let dateFormatter = DateFormatter()
    dateFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
    let timeFormatter = DateFormatter()
    timeFormatter.dateFormat = "HH:mm:ss"

    let startStr = sessionStartTime.map { dateFormatter.string(from: $0) } ?? "unknown"
    let duration = sessionStartTime.map { Int(Date().timeIntervalSince($0)) } ?? 0
    let minutes = duration / 60
    let seconds = duration % 60

    // Consolidate consecutive same-role entries
    var consolidated: [(timestamp: Date, role: String, text: String)] = []
    for entry in sessionLog {
      if let last = consolidated.last, last.role == entry.role {
        consolidated[consolidated.count - 1].text += entry.text
      } else {
        consolidated.append(entry)
      }
    }

    let filePrefix: String
    switch sessionMode {
    case .meeting:         filePrefix = "meeting"
    case .golf:            filePrefix = "golf_round"
    case .liveTranslation: filePrefix = "translation"
    case .normal:          filePrefix = "session"
    }
    let modeLabel: String
    switch sessionMode {
    case .meeting:         modeLabel = "Meeting"
    case .golf:            modeLabel = "Golf"
    case .liveTranslation: modeLabel = "Translation"
    case .normal:          modeLabel = streamingMode == .iPhone ? "iPhone" : "Glasses"
    }

    var lines: [String] = []

    if sessionMode == .meeting {
      // Structured meeting transcript header
      let displayDateFormatter = DateFormatter()
      displayDateFormatter.dateFormat = "MMMM d, yyyy 'at' h:mm a"
      let displayDate = sessionStartTime.map { displayDateFormatter.string(from: $0) } ?? "Unknown"

      // Identify unique speakers from transcript
      let speakers = Array(Set(consolidated.filter { $0.role == "You" || $0.role == "AI" }.map { $0.role }))
      let speakerList = speakers.isEmpty ? "Unknown" : speakers.joined(separator: ", ")

      lines.append("# Meeting Notes — \(startStr)")
      lines.append("**Date:** \(displayDate)")
      lines.append("**Duration:** \(minutes)m \(seconds)s")
      lines.append("**Mode:** \(modeLabel)")
      lines.append("**Speakers detected:** \(speakerList)")
      lines.append("")
      lines.append("---")
      lines.append("")
      lines.append("## Full Transcript")
      lines.append("")
    } else {
      lines.append("# VisionClaw Session — \(startStr)")
      lines.append("Duration: \(minutes)m \(seconds)s | Mode: \(modeLabel)")
      lines.append("---\n")
    }

    for entry in consolidated {
      let time = timeFormatter.string(from: entry.timestamp)
      if sessionMode == .meeting {
        // Cleaner meeting transcript format
        let speaker = entry.role == "You" ? "Speaker" : entry.role == "AI" ? "AI Notes" : "System"
        lines.append("**[\(time)] \(speaker):** \(entry.text)\n")
      } else {
        let icon = entry.role == "You" ? "🗣" : entry.role == "AI" ? "🤖" : "⚡️"
        lines.append("[\(time)] \(icon) **\(entry.role):** \(entry.text)\n")
      }
    }

    let content = lines.joined(separator: "\n")

    // Save to Documents/VisionClaw/
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    let dir = docs.appendingPathComponent("VisionClaw", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("\(filePrefix)_\(startStr).md")

    do {
      try content.write(to: file, atomically: true, encoding: .utf8)
      NSLog("[GeminiSession] %@ transcript saved: %@", sessionMode == .meeting ? "Meeting" : sessionMode == .golf ? "Golf" : "Session", file.lastPathComponent)
    } catch {
      NSLog("[GeminiSession] Failed to save transcript: %@", error.localizedDescription)
    }
  }

  private func attemptReconnect() async {
    guard isGeminiActive else { return }
    reconnectAttempts += 1

    if reconnectAttempts > maxReconnectAttempts {
      NSLog("[GeminiSession] Max reconnect attempts (%d) reached. Stopping.", maxReconnectAttempts)
      stopSession()
      errorMessage = "Connection lost after \(maxReconnectAttempts) reconnect attempts"
      return
    }

    let delay = min(UInt64(reconnectAttempts) * 2_000_000_000, 10_000_000_000) // 2s, 4s, 6s, 8s, 10s
    NSLog("[GeminiSession] Reconnect attempt %d/%d in %.0fs...", reconnectAttempts, maxReconnectAttempts, Double(delay) / 1_000_000_000)
    aiTranscript = "Reconnecting (\(reconnectAttempts)/\(maxReconnectAttempts))..."

    try? await Task.sleep(nanoseconds: delay)
    guard isGeminiActive else { return }

    let setupOk = await geminiService.connect()

    if setupOk {
      NSLog("[GeminiSession] Reconnected successfully!")
      reconnectAttempts = 0
      aiTranscript = ""
      do {
        try audioManager.startCapture()
      } catch {
        NSLog("[GeminiSession] Mic restart failed: %@", error.localizedDescription)
        stopSession()
        errorMessage = "Reconnected but mic failed: \(error.localizedDescription)"
      }
    } else {
      NSLog("[GeminiSession] Reconnect attempt %d failed", reconnectAttempts)
      await attemptReconnect()
    }
  }

  private func saveSessionToOpenClaw() {
    guard !sessionLog.isEmpty, GeminiConfig.isOpenClawConfigured else { return }

    let dateFormatter = DateFormatter()
    dateFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
    let timeFormatter = DateFormatter()
    timeFormatter.dateFormat = "HH:mm:ss"

    let startStr = sessionStartTime.map { dateFormatter.string(from: $0) } ?? "unknown"
    let duration = sessionStartTime.map { Int(Date().timeIntervalSince($0)) } ?? 0
    let minutes = duration / 60
    let seconds = duration % 60

    // Consolidate consecutive same-role entries
    var consolidated: [(timestamp: Date, role: String, text: String)] = []
    for entry in sessionLog {
      if let last = consolidated.last, last.role == entry.role {
        consolidated[consolidated.count - 1].text += entry.text
      } else {
        consolidated.append(entry)
      }
    }

    let filePrefix: String
    switch sessionMode {
    case .meeting:         filePrefix = "meeting"
    case .golf:            filePrefix = "golf_round"
    case .liveTranslation: filePrefix = "translation"
    case .normal:          filePrefix = "session"
    }
    let modeLabel: String
    switch sessionMode {
    case .meeting:         modeLabel = "Meeting"
    case .golf:            modeLabel = "Golf"
    case .liveTranslation: modeLabel = "Translation"
    case .normal:          modeLabel = streamingMode == .iPhone ? "iPhone" : "Glasses"
    }

    var lines: [String] = []
    let typeLabel: String
    switch sessionMode {
    case .meeting:         typeLabel = "Meeting"
    case .golf:            typeLabel = "Golf Round"
    case .liveTranslation: typeLabel = "Translation"
    case .normal:          typeLabel = "Session"
    }
    lines.append("# VisionClaw \(typeLabel) — \(startStr)")
    lines.append("Duration: \(minutes)m \(seconds)s | Mode: \(modeLabel)")
    lines.append("---\n")

    for entry in consolidated {
      let time = timeFormatter.string(from: entry.timestamp)
      let icon = entry.role == "You" ? "[USER]" : entry.role == "AI" ? "[AI]" : "[TOOL]"
      lines.append("[\(time)] \(icon) \(entry.text)\n")
    }

    let transcript = lines.joined(separator: "\n")
    let filename = "visionclaw_\(filePrefix)_\(startStr).md"

    // Fire-and-forget: send transcript to OpenClaw to save in workspace
    let bridge = self.openClawBridge
    let meetingMode = self.sessionMode == .meeting
    Task {
      let saveType = meetingMode ? "meeting notes" : "session transcript"
      let command = """
      Save the following VisionClaw \(saveType) to the workspace. \
      Write it to the file: recordings/\(filename)
      Create the recordings/ directory if it doesn't exist.
      Do NOT summarize or modify the content — save it exactly as provided.
      After saving, respond only with: "Transcript saved: \(filename)"

      ---TRANSCRIPT START---
      \(transcript)
      ---TRANSCRIPT END---
      """
      let result = await bridge.delegateTask(task: command)
      switch result {
      case .success(let msg):
        NSLog("[GeminiSession] OpenClaw saved transcript: %@", msg)
      case .failure(let err):
        NSLog("[GeminiSession] OpenClaw save failed: %@", err)
      }
    }
  }

  /// Start a session in meeting mode (note-taking only, no tools, no commands).
  func startMeetingSession() async {
    sessionMode = .meeting
    await startSession()
    guard isGeminiActive else {
      sessionMode = .normal
      return
    }
  }

  /// Start a session in live translation mode (simultaneous interpretation, no tools).
  func startTranslationSession() async {
    sessionMode = .liveTranslation
    translationOutputMode = TranslationOutputMode(rawValue: SettingsManager.shared.translationOutputMode) ?? .both
    await startSession()
    guard isGeminiActive else {
      sessionMode = .normal
      return
    }
  }

  /// Start a session in golf caddie mode (GPS + vision + course data + scorecard).
  func startGolfSession() async {
    sessionMode = .golf
    golfState = GolfState()
    locationManager.startGolfMode()
    await startSession()

    // If Gemini connection failed, clean up golf state and bail
    guard isGeminiActive else {
      locationManager.stop()
      golfState = nil
      sessionMode = .normal
      return
    }

    await loadCourseFromGPS()
    startGPSInjection()
  }

  /// Periodically send GPS coordinates + distance to green to Gemini as text context.
  private func startGPSInjection() {
    gpsInjectionTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 15_000_000_000) // 15 seconds
        guard !Task.isCancelled, let self else { break }
        guard self.isGeminiActive, self.connectionState == .ready else { continue }
        if let coord = self.locationManager.lastCoordinate {
          // Calculate distance to green
          var distText = ""
          if let holeData = self.currentHoleData() {
            let dist = GolfCourseAPIService.shared.estimateDistanceToGreen(
              from: coord,
              hole: holeData,
              teeCoord: self.golfState?.holeStartCoord
            )
            if let dist {
              self.golfState?.distanceToGreen = dist
              distText = " | Distance to green: \(dist) yards"
              // Update recommended club
              let carry = SettingsManager.shared.golfSevenIronCarry
              let rec = ClubDistanceModel.recommend(distanceYards: dist, sevenIronCarry: carry)
              self.golfState?.recommendedClub = rec.name
            }
          }

          // Include wind in GPS context if available
          var windText = ""
          if let state = self.golfState, !state.wind.isEmpty {
            windText = " | Wind: \(state.wind)"
          }

          let text = "[SYSTEM GPS UPDATE] Current location: \(String(format: "%.6f", coord.latitude)),\(String(format: "%.6f", coord.longitude))\(distText)\(windText)"
          self.geminiService.sendTextContext(text)
          NSLog("[GolfGPS] Sent: %.4f, %.4f%@", coord.latitude, coord.longitude, distText)

          // Check for hole transition
          self.checkForHoleTransition(currentCoord: coord)
        }
      }
    }
  }

  /// Request OpenClaw to generate a final golf scorecard summary when session ends.
  private func saveGolfScorecard() {
    guard GeminiConfig.isOpenClawConfigured else { return }
    let dateFormatter = DateFormatter()
    dateFormatter.dateFormat = "yyyy-MM-dd"
    let dateStr = dateFormatter.string(from: sessionStartTime ?? Date())
    let filename = "golf_round_\(dateStr).md"
    let bridge = self.openClawBridge
    Task {
      let command = """
      Read the file recordings/\(filename) if it exists. \
      Add a final summary section at the bottom with: total score, score to par, \
      total putts, fairways hit out of 14, greens in regulation out of 18, \
      and any notable stats. If the file doesn't exist, create a blank scorecard template. \
      After updating, respond only with: "Golf round saved: \(filename)"
      """
      let result = await bridge.delegateTask(task: command)
      switch result {
      case .success(let msg):
        NSLog("[GolfSession] OpenClaw saved scorecard: %@", msg)
      case .failure(let err):
        NSLog("[GolfSession] OpenClaw scorecard save failed: %@", err)
      }
    }
  }

  // MARK: - Golf V2: Course Data + Hole Transition

  /// Wait for GPS fix and load nearest course via API
  private func loadCourseFromGPS() async {
    guard GolfCourseAPIService.shared.isConfigured else {
      NSLog("[GolfSession] Golf Course API not configured, skipping course load")
      return
    }

    // Wait up to 10 seconds for GPS fix
    var coord: CLLocationCoordinate2D?
    for _ in 0..<20 {
      if let c = locationManager.lastCoordinate {
        coord = c
        break
      }
      try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
    }

    guard let coord else {
      NSLog("[GolfSession] No GPS fix after 10s, course load skipped")
      return
    }

    guard let course = await GolfCourseAPIService.shared.loadNearestCourse(lat: coord.latitude, lng: coord.longitude) else {
      NSLog("[GolfSession] No course found near GPS")
      return
    }

    // Store all nearby courses for picker, then show confirmation
    let allCourses = await GolfCourseAPIService.shared.searchNearbyCourses(lat: coord.latitude, lng: coord.longitude)
    golfState?.nearbyCoursesForPicker = allCourses
    golfState?.pendingCourseName = course.name
    golfState?.courseId = course.id
    golfState?.courseName = course.name
    golfState?.courseLoaded = true
    golfState?.holesData = course.holes
    golfState?.holeStartCoord = coord

    // Set par for first hole
    if let firstHole = course.holes.first(where: { $0.number == 1 }) {
      golfState?.par = firstHole.par
      golfState?.holeYardage = firstHole.yardage
    }

    NSLog("[GolfSession] Course loaded: %@ (%d holes)", course.name, course.holes.count)

    // Inject course data to Gemini
    injectCourseDataToGemini(course: course)

    // Fetch wind conditions
    await fetchWindConditions(lat: coord.latitude, lng: coord.longitude)
  }

  /// Send full course data as system context to Gemini
  private func injectCourseDataToGemini(course: GolfCourse) {
    var lines: [String] = []
    lines.append("[SYSTEM COURSE DATA]")
    lines.append("Course: \(course.name)")
    lines.append("Location: \(course.city), \(course.state), \(course.country)")
    lines.append("Holes:")
    for hole in course.holes {
      var holeLine = "  Hole \(hole.number): Par \(hole.par), \(hole.yardage) yards"
      if let hcp = hole.handicapIndex { holeLine += ", HCP \(hcp)" }
      if let lat = hole.greenLatitude, let lng = hole.greenLongitude {
        holeLine += ", Green: \(String(format: "%.6f", lat)),\(String(format: "%.6f", lng))"
      }
      lines.append(holeLine)
    }
    let text = lines.joined(separator: "\n")
    geminiService.sendTextContext(text)
  }

  /// Get hole data for current hole number
  private func currentHoleData() -> GolfHoleData? {
    guard let state = golfState else { return nil }
    return state.holesData.first(where: { $0.number == state.currentHole })
  }

  /// Detect when golfer has finished a hole (near green then moves away)
  private func checkForHoleTransition(currentCoord: CLLocationCoordinate2D) {
    guard let state = golfState, state.courseLoaded else { return }
    guard let holeData = currentHoleData() else { return }
    guard state.lastHoleAskedForScore < state.currentHole else { return }

    // Check if near the green (within 20 yards) using green coords or distance estimate
    if let dist = GolfCourseAPIService.shared.distanceToGreen(from: currentCoord, hole: holeData) {
      // If we were near the green (< 20y) and now moving away (> 40y), likely hole complete
      if dist > 40 && (state.distanceToGreen ?? 999) < 25 {
        triggerHoleComplete()
      }
    } else if let dist = state.distanceToGreen, dist < 10 {
      // Without green coords, use the estimate — if distance is very small, golfer is on green
      // We'll rely on distance increasing significantly on next check
      // For now, mark that we've been on the green
    }
  }

  /// Send hole complete prompt and ask for score
  private func triggerHoleComplete() {
    guard let state = golfState else { return }
    let holeNum = state.currentHole
    golfState?.lastHoleAskedForScore = holeNum

    let text = "[SYSTEM HOLE COMPLETE] The golfer appears to have finished hole \(holeNum) (par \(state.par)). Ask them for their score on this hole."
    geminiService.sendTextContext(text)
    NSLog("[GolfSession] Hole %d complete — asking for score", holeNum)
  }

  /// Advance to next hole and inject context
  func advanceToNextHole() {
    guard var state = golfState else { return }
    let nextHole = state.currentHole + 1
    guard nextHole <= 18 else { return }

    state.currentHole = nextHole
    state.holeStartTime = Date()
    state.holeStartCoord = locationManager.lastCoordinate
    state.distanceToGreen = nil

    if let holeData = state.holesData.first(where: { $0.number == nextHole }) {
      state.par = holeData.par
      state.holeYardage = holeData.yardage
    }

    golfState = state

    // Inject next hole context
    var text = "[SYSTEM NEXT HOLE] Now on hole \(nextHole)"
    if let holeData = currentHoleData() {
      text += ", par \(holeData.par), \(holeData.yardage) yards"
    }
    geminiService.sendTextContext(text)
    NSLog("[GolfSession] Advanced to hole %d", nextHole)
  }

  // MARK: - Golf: Course Confirmation

  /// Confirm the auto-detected course
  func confirmGolfCourse() {
    golfState?.courseConfirmed = true
  }

  /// Switch to a different nearby course
  func selectGolfCourse(_ course: GolfCourse) async {
    // Load full details if needed
    let detailed: GolfCourse
    if course.holes.isEmpty, let d = await GolfCourseAPIService.shared.getCourseDetails(courseId: course.id) {
      detailed = d
    } else {
      detailed = course
    }
    GolfCourseAPIService.shared.activeCourse = detailed
    golfState?.courseId = detailed.id
    golfState?.courseName = detailed.name
    golfState?.holesData = detailed.holes
    golfState?.courseConfirmed = true
    if let firstHole = detailed.holes.first(where: { $0.number == 1 }) {
      golfState?.par = firstHole.par
      golfState?.holeYardage = firstHole.yardage
    }
    injectCourseDataToGemini(course: detailed)
  }

  /// Toggle the mini satellite map
  func toggleMiniMap() {
    golfState?.showMiniMap.toggle()
  }

  // MARK: - Golf: Wind Conditions

  /// Fetch wind from Open-Meteo (free, no API key needed)
  private func fetchWindConditions(lat: Double, lng: Double) async {
    let urlString = "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lng)&current=wind_speed_10m,wind_direction_10m&wind_speed_unit=mph"
    guard let url = URL(string: urlString) else { return }

    do {
      let (data, response) = try await URLSession.shared.data(from: url)
      guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else { return }
      guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let current = json["current"] as? [String: Any] else { return }

      let speed = current["wind_speed_10m"] as? Double ?? 0
      let direction = current["wind_direction_10m"] as? Double ?? 0

      let dirLabel = Self.windDirectionLabel(degrees: direction)
      let windStr: String
      if speed < 3 {
        windStr = "Calm"
      } else {
        windStr = "\(dirLabel) \(Int(speed))mph"
      }

      golfState?.wind = windStr
      golfState?.windSpeed = speed
      golfState?.windDirection = dirLabel

      // Inject wind to Gemini
      let windContext = "[SYSTEM WEATHER] Wind: \(windStr) (\(String(format: "%.0f", speed)) mph from \(dirLabel), direction \(Int(direction))°)"
      geminiService.sendTextContext(windContext)
      NSLog("[GolfSession] Wind loaded: %@", windStr)
    } catch {
      NSLog("[GolfSession] Wind fetch failed: %@", error.localizedDescription)
    }
  }

  private static func windDirectionLabel(degrees: Double) -> String {
    let dirs = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
                "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
    let idx = Int((degrees + 11.25).truncatingRemainder(dividingBy: 360) / 22.5)
    return dirs[idx % 16]
  }

  func sendVideoFrameIfThrottled(image: UIImage) {
    guard isGeminiActive, connectionState == .ready else { return }
    let now = Date()
    guard now.timeIntervalSince(lastVideoFrameTime) >= GeminiConfig.videoFrameInterval else { return }
    lastVideoFrameTime = now
    geminiService.sendVideoFrame(image: image)
  }

}
