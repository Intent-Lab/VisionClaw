import Foundation
import SwiftUI

struct ToolAudioCancellationResult: Equatable {
  let removedCurrentCall: Bool
  let hasPendingCalls: Bool

  var drainedCurrentCalls: Bool {
    removedCurrentCall && !hasPendingCalls
  }
}

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
  mutating func cancel(
    callIDs: [String]
  ) -> ToolAudioCancellationResult {
    let removedCurrentCall =
      !pendingCallIDs.intersection(callIDs).isEmpty
    pendingCallIDs.subtract(callIDs)
    return ToolAudioCancellationResult(
      removedCurrentCall: removedCurrentCall,
      hasPendingCalls: hasPendingCalls
    )
  }

  mutating func reset() {
    pendingCallIDs.removeAll()
  }
}

struct PostToolTurnWatchdogState {
  private(set) var isAwaiting = false
  private(set) var activeGeneration: UInt64?
  private var generation: UInt64 = 0

  mutating func begin() -> UInt64 {
    generation &+= 1
    isAwaiting = true
    activeGeneration = generation
    return generation
  }

  @discardableResult
  mutating func resolve() -> Bool {
    guard let activeGeneration else { return false }
    return resolve(generation: activeGeneration)
  }

  @discardableResult
  mutating func resolve(generation expectedGeneration: UInt64) -> Bool {
    guard isAwaiting, activeGeneration == expectedGeneration else {
      return false
    }
    isAwaiting = false
    activeGeneration = nil
    generation &+= 1
    return true
  }

  mutating func timeout(generation expectedGeneration: UInt64) -> Bool {
    resolve(generation: expectedGeneration)
  }
}

struct ProactiveTurnWatchdogState {
  private(set) var isInFlight = false
  private(set) var activeGeneration: UInt64?
  private var generation: UInt64 = 0

  mutating func begin() -> UInt64 {
    generation &+= 1
    isInFlight = true
    activeGeneration = generation
    return generation
  }

  @discardableResult
  mutating func resolveCurrent() -> Bool {
    guard isInFlight else { return false }
    isInFlight = false
    activeGeneration = nil
    generation &+= 1
    return true
  }

  @discardableResult
  mutating func resolve(generation expectedGeneration: UInt64) -> Bool {
    guard isInFlight, activeGeneration == expectedGeneration else {
      return false
    }
    isInFlight = false
    activeGeneration = nil
    generation &+= 1
    return true
  }

  mutating func timeout(generation expectedGeneration: UInt64) -> Bool {
    resolve(generation: expectedGeneration)
  }
}

struct GeminiSessionStartGate {
  private var generation: UInt64 = 0
  private(set) var inFlightGeneration: UInt64?
  private var validGeneration: UInt64?

  var isInFlight: Bool {
    inFlightGeneration != nil
  }

  mutating func begin(isSessionActive: Bool) -> UInt64? {
    guard !isSessionActive, inFlightGeneration == nil else { return nil }
    generation &+= 1
    inFlightGeneration = generation
    validGeneration = generation
    return generation
  }

  func permits(_ expectedGeneration: UInt64) -> Bool {
    inFlightGeneration == expectedGeneration
      && validGeneration == expectedGeneration
  }

  mutating func invalidate() {
    validGeneration = nil
    generation &+= 1
  }

  @discardableResult
  mutating func finish(generation expectedGeneration: UInt64) -> Bool {
    guard inFlightGeneration == expectedGeneration else { return false }
    inFlightGeneration = nil
    if validGeneration == expectedGeneration {
      validGeneration = nil
    }
    return true
  }
}

enum LogicalVoiceTranscriptionDisposition: Equatable {
  case beganTurn
  case appended
  case rejectedCompletedEpoch
  case rejectedPriorTranscript
}

private enum SpokenMediaCaptureIntent {
  case none
  case snapshot
  case video
  case ambiguous
  case rejected
}

private enum SpokenMediaCaptureAuthorizationAttempt {
  case pending
  case authorized
  case rejected
}

private struct SpokenMediaCaptureAuthorizationState {
  private var activeEpoch: UInt64?
  private var authorizedKind: GlassesMediaKind?
  private var latestCompletedEpoch: UInt64 = 0
  private var terminalEpochs: Set<UInt64> = []

  mutating func receive(
    transcript: String,
    epoch: UInt64
  ) {
    guard epoch > latestCompletedEpoch,
          !terminalEpochs.contains(epoch) else {
      return
    }
    if activeEpoch != epoch {
      activeEpoch = epoch
      authorizedKind = nil
    }

    switch Self.intent(in: transcript) {
    case .none:
      return
    case .snapshot:
      authorizedKind = .snapshot
    case .video:
      authorizedKind = .video
    case .ambiguous, .rejected:
      authorizedKind = nil
      terminalEpochs.insert(epoch)
    }
  }

  mutating func consume(
    kind requestedKind: GlassesMediaKind,
    expectedEpoch: UInt64
  ) -> SpokenMediaCaptureAuthorizationAttempt {
    guard expectedEpoch > latestCompletedEpoch,
          !terminalEpochs.contains(expectedEpoch) else {
      return .rejected
    }
    guard let activeEpoch else {
      return .pending
    }
    guard activeEpoch == expectedEpoch else {
      return activeEpoch < expectedEpoch ? .pending : .rejected
    }
    guard let authorizedKind else {
      return .pending
    }

    // Any model capture attempt consumes the one-shot authorization, including
    // a mismatched kind, so a model cannot probe and retry within one utterance.
    self.authorizedKind = nil
    terminalEpochs.insert(expectedEpoch)
    return authorizedKind == requestedKind ? .authorized : .rejected
  }

  mutating func reject(epoch: UInt64) {
    terminalEpochs.insert(epoch)
    if activeEpoch == epoch {
      authorizedKind = nil
    }
  }

  mutating func finish(epoch completedEpoch: UInt64) {
    latestCompletedEpoch = max(latestCompletedEpoch, completedEpoch)
    if let activeEpoch, activeEpoch <= completedEpoch {
      self.activeEpoch = nil
      authorizedKind = nil
    }
    terminalEpochs = Set(
      terminalEpochs.filter { $0 > completedEpoch }
    )
  }

  mutating func reset() {
    activeEpoch = nil
    authorizedKind = nil
    latestCompletedEpoch = 0
    terminalEpochs.removeAll()
  }

  private static func intent(
    in transcript: String
  ) -> SpokenMediaCaptureIntent {
    let normalizedTranscript = transcript
      .folding(
        options: [.caseInsensitive, .diacriticInsensitive],
        locale: .current
      )
      .lowercased()
      .replacingOccurrences(of: "'", with: "")
      .replacingOccurrences(of: "\u{2019}", with: "")
    let words = Set(
      normalizedTranscript
        .split { !$0.isLetter && !$0.isNumber }
        .map(String.init)
    )
    let rejectionWords: Set<String> = [
      "avoid", "cancel", "canceled", "cancelled", "cannot", "cant", "dont",
      "never", "no", "not", "stop", "without", "wont",
    ]
    guard words.isDisjoint(with: rejectionWords) else {
      return .rejected
    }
    let captureVerbs: Set<String> = [
      "capture", "make", "record", "save", "shoot", "snap", "snapshot",
      "take",
    ]
    guard !words.isDisjoint(with: captureVerbs) else {
      return .none
    }

    let snapshotNouns: Set<String> = [
      "image", "photo", "photograph", "picture", "snapshot", "still",
    ]
    let videoNouns: Set<String> = [
      "clip", "movie", "recording", "video",
    ]
    let requestsSnapshot = !words.isDisjoint(with: snapshotNouns)
    let requestsVideo = !words.isDisjoint(with: videoNouns)
    switch (requestsSnapshot, requestsVideo) {
    case (true, false):
      return .snapshot
    case (false, true):
      return .video
    case (true, true):
      return .ambiguous
    case (false, false):
      return .none
    }
  }
}

@MainActor
final class LogicalVoiceTurnCoordinator {
  private(set) var transcript = ""
  private(set) var activeEpoch: UInt64?
  private(set) var latestCompletedEpoch: UInt64 = 0
  private var completedNormalizedTranscripts: [String] = []
  private var taintedEpochs: Set<UInt64> = []
  private var mediaCaptureAuthorization =
    SpokenMediaCaptureAuthorizationState()

  @discardableResult
  func receive(
    _ event: GeminiInputTranscriptionEvent,
    namedHarnessRouter: NamedHarnessRouter?,
    codexBridge: CodexTaskBridgeTransport?
  ) -> LogicalVoiceTranscriptionDisposition {
    guard event.epoch > latestCompletedEpoch else {
      return .rejectedCompletedEpoch
    }

    let beginsNewTurn =
      activeEpoch != event.epoch || transcript.isEmpty
    if beginsNewTurn {
      transcript = ""
      activeEpoch = event.epoch
      namedHarnessRouter?.clearRecognition()
      codexBridge?.beginUserVoiceTurn()
    }

    transcript += event.text
    let normalizedTranscript = Self.normalized(transcript)
    if taintedEpochs.contains(event.epoch)
        || isPriorTranscriptReplay(normalizedTranscript) {
      taintedEpochs.insert(event.epoch)
      mediaCaptureAuthorization.reject(epoch: event.epoch)
      namedHarnessRouter?.clearRecognition()
      codexBridge?.updateUserVoiceTranscript("")
      return .rejectedPriorTranscript
    }

    mediaCaptureAuthorization.receive(
      transcript: transcript,
      epoch: event.epoch
    )
    // A bare wake name is not sufficient authorization. Wait for at least one
    // request word so a delayed single-word "Eva" cannot reopen a route.
    if normalizedTranscript.split(separator: " ").count >= 2 {
      namedHarnessRouter?.recognize(
        transcript: transcript,
        transcriptionEpoch: event.epoch
      )
    }
    codexBridge?.updateUserVoiceTranscript(transcript)
    return beginsNewTurn ? .beganTurn : .appended
  }

  @discardableResult
  func finish(
    completedEpoch: UInt64,
    namedHarnessRouter: NamedHarnessRouter,
    codexBridge: CodexTaskBridgeTransport?,
    invalidateCodexConfirmation: Bool
  ) -> Bool {
    latestCompletedEpoch = max(latestCompletedEpoch, completedEpoch)
    mediaCaptureAuthorization.finish(epoch: completedEpoch)
    if let activeEpoch, activeEpoch > completedEpoch {
      return false
    }

    if let activeEpoch,
       !taintedEpochs.contains(activeEpoch) {
      rememberCompletedTranscript(transcript)
    }
    transcript = ""
    activeEpoch = nil
    taintedEpochs = Set(
      taintedEpochs.filter { $0 > completedEpoch }
    )
    namedHarnessRouter.clearRecognition()
    if invalidateCodexConfirmation {
      codexBridge?.resetUserConfirmation()
    } else {
      // Clear any phrase captured in the completed turn while preserving a
      // prepared Codex action for its explicitly separate confirmation turn.
      codexBridge?.updateUserVoiceTranscript("")
    }
    return true
  }

  func performAuthorizedMediaCapture(
    _ request: GlassesMediaRequest,
    expectedEpoch: UInt64,
    handler: @MainActor (GlassesMediaRequest) async -> ToolResult
  ) async -> ToolResult {
    for _ in 0..<5 {
      guard !Task.isCancelled else {
        return .failure(
          "Capture was cancelled before authorization. No media was captured."
        )
      }
      switch mediaCaptureAuthorization.consume(
        kind: request.kind,
        expectedEpoch: expectedEpoch
      ) {
      case .authorized:
        return await handler(request)
      case .rejected:
        return Self.blockedMediaCaptureResult
      case .pending:
        do {
          try await Task.sleep(nanoseconds: 100_000_000)
        } catch {
          return .failure(
            "Capture was cancelled before authorization. No media was captured."
          )
        }
      }
    }
    guard !Task.isCancelled else {
      return .failure(
        "Capture was cancelled before authorization. No media was captured."
      )
    }
    switch mediaCaptureAuthorization.consume(
      kind: request.kind,
      expectedEpoch: expectedEpoch
    ) {
    case .authorized:
      return await handler(request)
    case .pending, .rejected:
      return Self.blockedMediaCaptureResult
    }
  }

  func resetSecurityState() {
    transcript = ""
    activeEpoch = nil
    latestCompletedEpoch = 0
    completedNormalizedTranscripts.removeAll()
    taintedEpochs.removeAll()
    mediaCaptureAuthorization.reset()
  }

  private func rememberCompletedTranscript(_ value: String) {
    let normalized = Self.normalized(value)
    guard !normalized.isEmpty else { return }
    completedNormalizedTranscripts.append(normalized)
    if completedNormalizedTranscripts.count > 4 {
      completedNormalizedTranscripts.removeFirst(
        completedNormalizedTranscripts.count - 4
      )
    }
  }

  private func isPriorTranscriptReplay(_ candidate: String) -> Bool {
    guard !candidate.isEmpty else { return false }
    let candidateWordCount = candidate.split(separator: " ").count
    guard candidateWordCount >= 2 else { return false }
    return completedNormalizedTranscripts.contains { completed in
      completed == candidate
        || completed.hasPrefix(candidate + " ")
        || candidate.hasPrefix(completed + " ")
    }
  }

  private static func normalized(_ value: String) -> String {
    value
      .folding(
        options: [.caseInsensitive, .diacriticInsensitive],
        locale: .current
      )
      .lowercased()
      .split { !$0.isLetter && !$0.isNumber }
      .joined(separator: " ")
  }

  private static var blockedMediaCaptureResult: ToolResult {
    .failure(
      """
      Capture was blocked because no matching spoken photo or video request \
      was recognized in the current voice turn. No media was captured.
      """
    )
  }
}

enum SessionMediaGatePolicy {
  static func canRelease(
    hasPendingToolCalls: Bool,
    awaitingPostToolTurn: Bool,
    isProactiveTurnInFlight: Bool
  ) -> Bool {
    !hasPendingToolCalls
      && !awaitingPostToolTurn
      && !isProactiveTurnInFlight
  }
}

@MainActor
class GeminiSessionViewModel: ObservableObject {
  typealias MediaCaptureHandler = @MainActor (
    _ request: GlassesMediaRequest
  ) async -> ToolResult

  @Published var isGeminiActive: Bool = false
  @Published var connectionState: GeminiConnectionState = .disconnected
  @Published var isModelSpeaking: Bool = false
  @Published var errorMessage: String?
  @Published var userTranscript: String = ""
  @Published var aiTranscript: String = ""
  @Published var toolCallStatus: ToolCallStatus = .idle
  @Published var openClawConnectionState: OpenClawConnectionState = .notConfigured
  @Published var audioRouteStatus: AudioRouteStatus = .unknown
  @Published var harnessRoutingState: NamedHarnessRoutingState = .idle
  private let geminiService = GeminiLiveService()
  private let openClawBridge: OpenClawBridge
  private var namedHarnessRouter: NamedHarnessRouter
  private var brokerConnectionModel: GlassesBrokerConnectionModel?
  private var routingSnapshot = GlassesBrokerRoutingSnapshot.legacy
  private var toolCallRouter: ToolCallRouter?
  private let audioManager = AudioManager()
  private let eventClient = OpenClawEventClient()
  private var toolAudioGate = ToolAudioGate()
  private var lastVideoFrameTime: Date = .distantPast
  private var stateObservation: Task<Void, Never>?
  private var isInputAudioPaused = false
  private var pendingProactiveNotifications: [String] = []
  private let logicalVoiceTurn = LogicalVoiceTurnCoordinator()
  private var proactiveTurnState = ProactiveTurnWatchdogState()
  private var proactiveTurnWatchdogTask: Task<Void, Never>?
  private var postToolTurnState = PostToolTurnWatchdogState()
  private var postToolTurnWatchdogTask: Task<Void, Never>?
  private var postToolGenerationByCallID: [String: UInt64] = [:]
  private var lastConversationActivity: Date = .distantPast
  private var sessionStartGate = GeminiSessionStartGate()

  private var isProactiveTurnInFlight: Bool {
    proactiveTurnState.isInFlight
  }

  private var awaitingPostToolTurn: Bool {
    postToolTurnState.isAwaiting
  }

  var streamingMode: StreamingMode = .glasses
  var mediaCaptureHandler: MediaCaptureHandler?
  var isNamedRoutingActive: Bool {
    isGeminiActive && routingSnapshot.namedRoutingEnabled
  }

  init(
    brokerConnectionModel: GlassesBrokerConnectionModel? = nil
  ) {
    let bridge = OpenClawBridge()
    self.openClawBridge = bridge
    self.brokerConnectionModel = brokerConnectionModel
    self.namedHarnessRouter = NamedHarnessRouter(
      registry: .standard()
    )
  }

  func configureBrokerConnection(
    _ brokerConnectionModel: GlassesBrokerConnectionModel
  ) {
    guard !isGeminiActive, !sessionStartGate.isInFlight else { return }
    self.brokerConnectionModel = brokerConnectionModel
  }

  func startSession() async {
    guard let startGeneration = sessionStartGate.begin(
      isSessionActive: isGeminiActive
    ) else { return }
    defer {
      sessionStartGate.finish(generation: startGeneration)
    }

    guard GeminiConfig.isConfigured else {
      errorMessage = "Gemini API key not configured. Open Settings and add your Gemini API key."
      return
    }

    await brokerConnectionModel?.refreshReachability()
    guard sessionStartGate.permits(startGeneration) else { return }
    routingSnapshot =
      brokerConnectionModel?.routingSnapshot() ?? .legacy
    namedHarnessRouter = NamedHarnessRouter(
      registry: routingSnapshot.registry,
      harnessBridge: routingSnapshot.harnessBridge,
      codexBridge: routingSnapshot.codexBridge,
      harnessUnavailableReason: routingSnapshot.harnessUnavailableReason,
      codexUnavailableReason: routingSnapshot.codexUnavailableReason
    )
    logicalVoiceTurn.resetSecurityState()
    userTranscript = ""
    brokerConnectionModel?.setCompletionHandler { [weak self] text in
      guard let self, self.isGeminiActive else { return }
      self.enqueueProactiveNotification(text)
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

    geminiService.onInterrupted = { [weak self] completedEpoch in
      guard let self else { return }
      self.lastConversationActivity = Date()
      self.resolveProactiveTurnWait()
      self.resolvePostToolTurnWait()
      self.finishLogicalVoiceTurn(
        completedEpoch: completedEpoch,
        invalidateCodexConfirmation: true
      )
      self.audioManager.stopPlayback(reason: "Gemini interruption")
      self.releaseMediaGatesIfPossible()
    }

    geminiService.onTurnComplete = { [weak self] completedEpoch in
      guard let self else { return }
      self.lastConversationActivity = Date()
      self.resolveProactiveTurnWait()
      self.resolvePostToolTurnWait()
      self.finishLogicalVoiceTurn(
        completedEpoch: completedEpoch,
        invalidateCodexConfirmation: false
      )
      self.releaseMediaGatesIfPossible()
    }

    geminiService.onInputTranscription = { [weak self] event in
      guard let self else { return }
      self.lastConversationActivity = Date()
      let namedRouter =
        self.routingSnapshot.namedRoutingEnabled
          ? self.namedHarnessRouter
          : nil
      let disposition = self.logicalVoiceTurn.receive(
        event,
        namedHarnessRouter: namedRouter,
        codexBridge: self.routingSnapshot.codexBridge
      )
      guard disposition == .beganTurn || disposition == .appended else {
        NSLog(
          "[Gemini] Ignored stale input transcription in epoch %llu",
          event.epoch
        )
        return
      }
      self.aiTranscript = ""
      self.userTranscript = self.logicalVoiceTurn.transcript
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
    if routingSnapshot.namedRoutingEnabled {
      openClawBridge.connectionState =
        routingSnapshot.harnessBridge != nil
          ? .connected
          : .unreachable(
            routingSnapshot.harnessUnavailableReason
              ?? "The paired Mac is unavailable."
          )
    } else {
      await openClawBridge.checkConnection()
      guard sessionStartGate.permits(startGeneration) else { return }
      openClawBridge.resetSession()
    }

    // Wire tool call handling
    toolCallRouter = ToolCallRouter(
      bridge: openClawBridge,
      routeHarness: { [weak self] request, _ in
        guard let self else {
          return .failure("The glasses session ended before routing completed.")
        }
        return await self.namedHarnessRouter.route(request)
      },
      captureMedia: { [weak self] request, _, expectedEpoch in
        guard let self, let handler = self.mediaCaptureHandler else {
          return .failure(
            "The glasses camera is not ready for voice capture. No media was captured."
          )
        }
        return await self.logicalVoiceTurn.performAuthorizedMediaCapture(
          request,
          expectedEpoch: expectedEpoch,
          handler: handler
        )
      }
    )

    geminiService.onToolCall = { [weak self] toolCall in
      guard let self else { return }
      Task { @MainActor in
        self.lastConversationActivity = Date()
        let callIDs = toolCall.functionCalls.map(\.id)
        if self.isProactiveTurnInFlight {
          let proactiveGeneration =
            self.proactiveTurnState.activeGeneration
          self.namedHarnessRouter.clearRecognition()
          let response = ToolCallRouter.blockedProactiveToolResponse(
            for: toolCall.functionCalls
          )
          self.geminiService.sendToolResponse(response) { [weak self] sent in
            guard let self, !sent, let proactiveGeneration else { return }
            self.failProactiveTurn(
              generation: proactiveGeneration,
              message:
                "A backend status update tried to call a tool and was blocked."
            )
          }
          return
        }
        guard let toolCallRouter = self.toolCallRouter else {
          let cancellation = self.toolAudioGate.cancel(callIDs: callIDs)
          if cancellation.drainedCurrentCalls {
            self.releaseMediaGatesIfPossible()
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

        toolCallRouter.handleToolCalls(
          toolCall.functionCalls,
          mediaAuthorizationEpoch:
            self.geminiService.currentInputTranscriptionEpoch
        ) { [weak self] response in
          guard let self else { return }
          let watchdogGeneration = self.beginPostToolTurnWait(
            callIDs: callIDs
          )
          self.startPostToolTurnWatchdog(
            generation: watchdogGeneration
          )
          self.geminiService.sendToolResponse(response) { [weak self] sent in
            guard let self else { return }
            for callID in callIDs {
              self.toolAudioGate.finish(callID: callID)
            }
            self.releaseMediaGatesIfPossible()
            if !sent {
              guard self.resolvePostToolTurnWait(
                generation: watchdogGeneration
              ) else { return }
              self.finishLogicalVoiceTurn(
                invalidateCodexConfirmation: true
              )
              self.releaseMediaGatesIfPossible()
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
        let audioCancellation = self.toolAudioGate.cancel(
          callIDs: cancellation.ids
        )
        guard audioCancellation.drainedCurrentCalls else { return }

        if let activeGeneration =
          self.postToolTurnState.activeGeneration {
          let matchesActiveWait = cancellation.ids.contains {
            self.postToolGenerationByCallID[$0] == activeGeneration
          }
          guard matchesActiveWait,
                self.resolvePostToolTurnWait(
                  generation: activeGeneration
                ) else { return }
        }
        self.finishLogicalVoiceTurn(
          invalidateCodexConfirmation: true
        )
        self.releaseMediaGatesIfPossible()
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

        let nextHarnessState = self.namedHarnessRouter.state
        if self.harnessRoutingState != nextHarnessState {
          self.harnessRoutingState = nextHarnessState
        }

        self.deliverPendingNotificationIfIdle()
      }
    }

    // Setup audio
    audioManager.onRouteChanged = { [weak self] status in
      Task { @MainActor in
        self?.audioRouteStatus = status
      }
    }
    do {
      try audioManager.setupAudioSession(useIPhoneMode: streamingMode == .iPhone)
    } catch {
      let message = "Audio setup failed: \(error.localizedDescription)"
      stopSession()
      errorMessage = message
      return
    }

    // Connect to Gemini and wait for setupComplete
    let liveConfiguration = GeminiLiveSessionConfiguration(
      systemInstruction: GeminiConfig.systemInstruction(
        namedRoutingEnabled: routingSnapshot.namedRoutingEnabled,
        registry: routingSnapshot.registry
      ),
      toolDeclarations: ToolDeclarations.allDeclarations(
        namedRoutingEnabled: routingSnapshot.namedRoutingEnabled,
        registry: routingSnapshot.registry
      )
    )
    let setupOk = await geminiService.connect(
      configuration: liveConfiguration
    )
    guard sessionStartGate.permits(startGeneration) else {
      // stopSession() may have invalidated this attempt while connect() was
      // suspended. No replacement start is admitted until this one unwinds,
      // so it is safe and necessary to retire any late socket here.
      geminiService.disconnect()
      return
    }

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
    if SettingsManager.shared.proactiveNotificationsEnabled,
       !routingSnapshot.namedRoutingEnabled {
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
    sessionStartGate.invalidate()
    eventClient.disconnect()
    brokerConnectionModel?.stopOperationMonitoring()
    toolCallRouter?.cancelAll()
    toolCallRouter = nil
    toolAudioGate.reset()
    isInputAudioPaused = false
    pendingProactiveNotifications.removeAll()
    resolveProactiveTurnWait()
    resolvePostToolTurnWait()
    postToolGenerationByCallID.removeAll()
    finishLogicalVoiceTurn(invalidateCodexConfirmation: true)
    audioManager.stopPlayback(reason: "AI session stopped")
    audioManager.stopCapture()
    geminiService.disconnect()
    stateObservation?.cancel()
    stateObservation = nil
    isGeminiActive = false
    connectionState = .disconnected
    isModelSpeaking = false
    aiTranscript = ""
    toolCallStatus = .idle
    audioRouteStatus = .unknown
    namedHarnessRouter.reset()
    harnessRoutingState = .idle
    routingSnapshot = .legacy
  }

  func sendVideoFrameIfThrottled(image: UIImage) {
    guard SettingsManager.shared.videoStreamingEnabled else { return }
    guard isGeminiActive, connectionState == .ready else { return }
    let now = Date()
    guard now.timeIntervalSince(lastVideoFrameTime) >= GeminiConfig.videoFrameInterval else { return }
    lastVideoFrameTime = now
    geminiService.sendVideoFrame(image: image)
  }

  func sendPriorityVisionSnapshot(image: UIImage) async -> Bool {
    guard isGeminiActive, connectionState == .ready else { return false }
    return await geminiService.sendPriorityVideoFrame(image: image)
  }

  private func pauseInputAudioIfNeeded() {
    guard !isInputAudioPaused else { return }
    isInputAudioPaused = true
    geminiService.sendAudioStreamEnd()
  }

  private func finishLogicalVoiceTurn(
    completedEpoch: UInt64? = nil,
    invalidateCodexConfirmation: Bool
  ) {
    let epoch =
      completedEpoch ?? geminiService.closeInputTranscriptionEpoch()
    _ = logicalVoiceTurn.finish(
      completedEpoch: epoch,
      namedHarnessRouter: namedHarnessRouter,
      codexBridge: routingSnapshot.codexBridge,
      invalidateCodexConfirmation: invalidateCodexConfirmation
    )
    userTranscript = logicalVoiceTurn.transcript
  }

  private func releaseMediaGatesIfPossible() {
    guard SessionMediaGatePolicy.canRelease(
      hasPendingToolCalls: toolAudioGate.hasPendingCalls,
      awaitingPostToolTurn: awaitingPostToolTurn,
      isProactiveTurnInFlight: isProactiveTurnInFlight
    ) else { return }
    isInputAudioPaused = false
    geminiService.setVideoStreamingPaused(false)
  }

  private func enqueueProactiveNotification(_ text: String) {
    pendingProactiveNotifications.append(text)
    if pendingProactiveNotifications.count > 10 {
      pendingProactiveNotifications.removeFirst(pendingProactiveNotifications.count - 10)
    }
    deliverPendingNotificationIfIdle()
  }

  private func beginPostToolTurnWait(callIDs: [String]) -> UInt64 {
    postToolTurnWatchdogTask?.cancel()
    postToolTurnWatchdogTask = nil
    if let replacedGeneration = postToolTurnState.activeGeneration {
      removePostToolCallMappings(generation: replacedGeneration)
    }
    let generation = postToolTurnState.begin()
    for callID in callIDs {
      postToolGenerationByCallID[callID] = generation
    }
    return generation
  }

  @discardableResult
  private func resolvePostToolTurnWait(
    generation: UInt64? = nil
  ) -> Bool {
    guard let targetGeneration =
      generation ?? postToolTurnState.activeGeneration,
      postToolTurnState.resolve(generation: targetGeneration)
    else { return false }
    postToolTurnWatchdogTask?.cancel()
    postToolTurnWatchdogTask = nil
    removePostToolCallMappings(generation: targetGeneration)
    return true
  }

  private func removePostToolCallMappings(generation: UInt64) {
    postToolGenerationByCallID = postToolGenerationByCallID.filter {
      $0.value != generation
    }
  }

  private func beginProactiveTurn() -> UInt64 {
    proactiveTurnWatchdogTask?.cancel()
    proactiveTurnWatchdogTask = nil
    return proactiveTurnState.begin()
  }

  private func resolveProactiveTurnWait() {
    proactiveTurnWatchdogTask?.cancel()
    proactiveTurnWatchdogTask = nil
    _ = proactiveTurnState.resolveCurrent()
  }

  private func failProactiveTurn(
    generation: UInt64,
    message: String
  ) {
    guard proactiveTurnState.resolve(generation: generation) else {
      return
    }
    proactiveTurnWatchdogTask?.cancel()
    proactiveTurnWatchdogTask = nil
    finishLogicalVoiceTurn(invalidateCodexConfirmation: false)
    releaseMediaGatesIfPossible()
    errorMessage = message
    deliverPendingNotificationIfIdle()
  }

  private func startProactiveTurnWatchdog(generation: UInt64) {
    proactiveTurnWatchdogTask?.cancel()
    proactiveTurnWatchdogTask = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: 8_000_000_000)
      guard !Task.isCancelled, let self,
            self.proactiveTurnState.timeout(
              generation: generation
            ) else { return }
      self.proactiveTurnWatchdogTask = nil
      self.finishLogicalVoiceTurn(
        invalidateCodexConfirmation: false
      )
      self.releaseMediaGatesIfPossible()
      self.errorMessage =
        "The backend status turn did not finish. Audio is ready again."
      self.deliverPendingNotificationIfIdle()
    }
  }

  private func startPostToolTurnWatchdog(generation: UInt64) {
    postToolTurnWatchdogTask?.cancel()
    postToolTurnWatchdogTask = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: 8_000_000_000)
      guard !Task.isCancelled, let self,
            self.postToolTurnState.timeout(
              generation: generation
            ) else { return }
      self.postToolTurnWatchdogTask = nil
      self.removePostToolCallMappings(generation: generation)
      self.finishLogicalVoiceTurn(
        invalidateCodexConfirmation: true
      )
      self.releaseMediaGatesIfPossible()
      self.errorMessage =
        "The assistant did not finish the tool-response turn. Audio is ready again."
      self.deliverPendingNotificationIfIdle()
    }
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

    let generation = beginProactiveTurn()
    lastConversationActivity = Date()
    let text = pendingProactiveNotifications.removeFirst()
    pauseInputAudioIfNeeded()
    geminiService.setVideoStreamingPaused(true)
    finishLogicalVoiceTurn(invalidateCodexConfirmation: false)
    startProactiveTurnWatchdog(generation: generation)
    geminiService.sendStatusMessage(text) { [weak self] sent in
      guard let self, !sent else { return }
      self.failProactiveTurn(
        generation: generation,
        message: "The backend status update could not be sent to Gemini."
      )
    }
  }

}
