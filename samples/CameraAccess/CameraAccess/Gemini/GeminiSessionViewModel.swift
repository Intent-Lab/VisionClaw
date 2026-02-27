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
  var lastClub: String = ""
  var courseName: String = ""
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
  private let geminiService = GeminiLiveService()
  private let openClawBridge = OpenClawBridge()
  private var toolCallRouter: ToolCallRouter?
  private let audioManager = AudioManager()
  private let locationManager = LocationManager()
  private var gpsInjectionTask: Task<Void, Never>?
  private var lastVideoFrameTime: Date = .distantPast
  private var stateObservation: Task<Void, Never>?
  private var reconnectTask: Task<Void, Never>?
  private var reconnectAttempts: Int = 0
  private let maxReconnectAttempts: Int = 5
  private var sessionLog: [(timestamp: Date, role: String, text: String)] = []
  private var sessionStartTime: Date?

  var streamingMode: StreamingMode = .glasses

  /// Closure that returns the current video frame from the stream.
  /// Set by StreamSessionView when wiring ViewModels together.
  var currentFrameProvider: (() -> UIImage?)?

  func startSession() async {
    guard !isGeminiActive else { return }

    guard GeminiConfig.isConfigured else {
      errorMessage = "Gemini API key not configured. Open GeminiConfig.swift and replace YOUR_GEMINI_API_KEY with your key from https://aistudio.google.com/apikey"
      return
    }

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

    // In meeting mode: skip OpenClaw and tool wiring entirely
    // Golf mode needs tools (execute) for scorecard/weather/course lookup
    if sessionMode != .meeting {
      // Check OpenClaw connectivity and start fresh session
      await openClawBridge.checkConnection()
      openClawBridge.resetSession()

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
    // Golf mode: stop GPS and save final scorecard
    if sessionMode == .golf {
      gpsInjectionTask?.cancel()
      gpsInjectionTask = nil
      locationManager.stop()
      saveGolfScorecard()
    }
    saveSessionTranscript()
    saveSessionToOpenClaw()
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
    golfState = nil
    sessionMode = .normal
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
    case .meeting: filePrefix = "meeting"
    case .golf:    filePrefix = "golf_round"
    case .normal:  filePrefix = "session"
    }
    let modeLabel: String
    switch sessionMode {
    case .meeting: modeLabel = "Meeting"
    case .golf:    modeLabel = "Golf"
    case .normal:  modeLabel = streamingMode == .iPhone ? "iPhone" : "Glasses"
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
    case .meeting: filePrefix = "meeting"
    case .golf:    filePrefix = "golf_round"
    case .normal:  filePrefix = "session"
    }
    let modeLabel: String
    switch sessionMode {
    case .meeting: modeLabel = "Meeting"
    case .golf:    modeLabel = "Golf"
    case .normal:  modeLabel = streamingMode == .iPhone ? "iPhone" : "Glasses"
    }

    var lines: [String] = []
    let typeLabel: String
    switch sessionMode {
    case .meeting: typeLabel = "Meeting"
    case .golf:    typeLabel = "Golf Round"
    case .normal:  typeLabel = "Session"
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
  }

  /// Start a session in golf caddie mode (GPS tracking, scorecard, club recommendations).
  func startGolfSession() async {
    sessionMode = .golf
    golfState = GolfState()
    locationManager.requestPermissionAndStart()
    await startSession()
    startGPSInjection()
  }

  /// Periodically send GPS coordinates to Gemini as text context.
  private func startGPSInjection() {
    gpsInjectionTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 30_000_000_000) // 30 seconds
        guard !Task.isCancelled, let self else { break }
        guard self.isGeminiActive, self.connectionState == .ready else { continue }
        if let coord = self.locationManager.lastCoordinate {
          let text = "[SYSTEM GPS UPDATE] Current location: \(String(format: "%.6f", coord.latitude)),\(String(format: "%.6f", coord.longitude))"
          self.geminiService.sendTextContext(text)
          NSLog("[GolfGPS] Sent: %.4f, %.4f", coord.latitude, coord.longitude)
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

  func sendVideoFrameIfThrottled(image: UIImage) {
    guard isGeminiActive, connectionState == .ready else { return }
    let now = Date()
    guard now.timeIntervalSince(lastVideoFrameTime) >= GeminiConfig.videoFrameInterval else { return }
    lastVideoFrameTime = now
    geminiService.sendVideoFrame(image: image)
  }

}
