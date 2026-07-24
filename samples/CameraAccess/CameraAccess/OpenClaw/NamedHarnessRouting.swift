import Foundation

enum NamedHarnessBackend: String, Codable, Equatable {
  case openClaw
  case codexTasks
  case nativeMeta
}

enum NamedHarnessOperation: String, Codable, CaseIterable, Equatable {
  case execute
  case listTasks = "list_tasks"
  case readTask = "read_task"
  case taskStatus = "task_status"
  case prepareContinue = "prepare_continue"
  case operationStatus = "operation_status"
  case cancelOperation = "cancel_operation"
  case handoff
}

struct NamedHarness: Identifiable, Codable, Equatable {
  let id: String
  let displayName: String
  let aliases: [String]
  let backend: NamedHarnessBackend
  let routeTarget: String?
  let allowedOperations: Set<NamedHarnessOperation>

  var invocationNames: [String] {
    [displayName] + aliases
  }
}

struct NamedHarnessInvocation: Equatable {
  let harness: NamedHarness
  let request: String
}

private struct RecognizedHarnessAuthorization {
  let invocation: NamedHarnessInvocation
  let transcriptionEpoch: UInt64?
}

struct NamedHarnessRegistry: Equatable {
  let harnesses: [NamedHarness]
  let fallbackHarnessID: String?
  let wakePhrases: [String]

  init(
    harnesses: [NamedHarness],
    fallbackHarnessID: String?,
    wakePhrases: [String] = ["hey", "ok", "okay"]
  ) {
    self.harnesses = harnesses
    self.fallbackHarnessID = fallbackHarnessID
    self.wakePhrases = wakePhrases
  }

  var fallbackHarness: NamedHarness? {
    guard let fallbackHarnessID else { return nil }
    return harnesses.first { $0.id == fallbackHarnessID }
  }

  var promptDescription: String {
    harnesses.map { harness in
      let aliases = harness.aliases.isEmpty
        ? ""
        : " (also: \(harness.aliases.joined(separator: ", ")))"
      return "\(harness.displayName)\(aliases)"
    }.joined(separator: "; ")
  }

  func harness(named spokenName: String) -> NamedHarness? {
    let requested = Self.normalizedName(spokenName)
    guard !requested.isEmpty else { return nil }
    let matches = harnesses.filter { harness in
      harness.invocationNames.contains {
        Self.normalizedName($0) == requested
      }
    }
    return matches.count == 1 ? matches[0] : nil
  }

  /// Recognizes an optional wake phrase followed by any registered invocation
  /// name. Target names are data, not branches in this parser.
  func invocation(in transcript: String) -> NamedHarnessInvocation? {
    var candidate = Self.normalizedText(transcript)
    guard !candidate.isEmpty else { return nil }

    let orderedWakePhrases = wakePhrases.sorted { $0.count > $1.count }
    for wakePhrase in orderedWakePhrases {
      if let remainder = Self.removingInvocationPrefix(
        Self.normalizedText(wakePhrase),
        from: candidate
      ) {
        candidate = remainder
        break
      }
    }

    let invocationNames = harnesses.flatMap { harness in
      harness.invocationNames.map { (harness, Self.normalizedText($0)) }
    }.sorted { $0.1.count > $1.1.count }

    let matches = invocationNames.compactMap { harness, name -> (
      harness: NamedHarness,
      name: String,
      request: String
    )? in
      guard let request = Self.removingInvocationPrefix(name, from: candidate) else {
        return nil
      }
      return (harness, name, request)
    }
    guard let longestNameCount = matches.map({ $0.name.count }).max() else {
      return nil
    }
    let strongestMatches = matches.filter { $0.name.count == longestNameCount }
    let harnessIDs = Set(strongestMatches.map { $0.harness.id })
    guard harnessIDs.count == 1, let match = strongestMatches.first else {
      return nil
    }
    return NamedHarnessInvocation(harness: match.harness, request: match.request)
  }

  static func standard() -> NamedHarnessRegistry {
    NamedHarnessRegistry(
      harnesses: [
        NamedHarness(
          id: "eva",
          displayName: "Eva",
          aliases: ["OpenClaw"],
          backend: .openClaw,
          routeTarget: nil,
          allowedOperations: [.execute]
        ),
        NamedHarness(
          id: "codex",
          displayName: "Codex",
          aliases: [],
          backend: .codexTasks,
          routeTarget: nil,
          allowedOperations: [
            .listTasks,
            .readTask,
            .taskStatus,
            .prepareContinue,
            .operationStatus,
            .cancelOperation
          ]
        ),
        NamedHarness(
          id: "meta",
          displayName: "Meta",
          aliases: ["Hey Meta"],
          backend: .nativeMeta,
          routeTarget: nil,
          allowedOperations: [.handoff]
        )
      ],
      fallbackHarnessID: "eva"
    )
  }

  /// Compatibility for older callers. Routing targets are selected only by
  /// the paired Mac broker and are never accepted from the iPhone.
  static func standard(
    openClawAgentTarget _: String
  ) -> NamedHarnessRegistry {
    standard()
  }

  private static func normalizedName(_ value: String) -> String {
    normalizedText(value)
      .trimmingCharacters(in: invocationSeparators)
  }

  private static func normalizedText(_ value: String) -> String {
    value
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      .lowercased()
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func removingInvocationPrefix(
    _ prefix: String,
    from value: String
  ) -> String? {
    guard !prefix.isEmpty, value.hasPrefix(prefix) else { return nil }
    let end = value.index(value.startIndex, offsetBy: prefix.count)
    if end != value.endIndex {
      let boundary = value[end]
      guard boundary.isWhitespace || invocationSeparators.contains(boundary.unicodeScalars.first!)
      else { return nil }
    }
    return String(value[end...])
      .trimmingCharacters(in: invocationSeparators)
  }

  private static let invocationSeparators = CharacterSet
    .whitespacesAndNewlines
    .union(CharacterSet(charactersIn: ",:;.!?-"))
}

struct NamedHarnessRouteRequest: Equatable {
  let targetName: String
  let operation: NamedHarnessOperation?
  let task: String
  let taskReference: String?
  let actionReference: String?
  let clientRequestID: String?

  init(
    targetName: String,
    operation: NamedHarnessOperation?,
    task: String,
    taskReference: String?,
    actionReference: String? = nil,
    clientRequestID: String?
  ) {
    self.targetName = targetName
    self.operation = operation
    self.task = task
    self.taskReference = taskReference
    self.actionReference = actionReference
    self.clientRequestID = clientRequestID
  }
}

enum NamedHarnessRoutingState: Equatable {
  case idle
  case recognized(String)
  case routing(String)
  case active(String)
  case confirmationRequired(String, String)
  case fallback(requested: String, selected: String?, reason: String)
  case unavailable(String, String)

  var displayText: String {
    switch self {
    case .idle:
      return ""
    case .recognized(let target):
      return "\(target) selected"
    case .routing(let target):
      return "Routing to \(target)…"
    case .active(let target):
      return "\(target) active"
    case .confirmationRequired(let target, _):
      return "\(target) needs confirmation"
    case .fallback(_, let selected, _):
      return selected.map { "Fallback: \($0)" } ?? "No fallback"
    case .unavailable(let target, _):
      return "\(target) unavailable"
    }
  }
}

enum GlassesSessionFeaturePolicy {
  static let voiceSnapshotEnabled = true
}

@MainActor
final class NamedHarnessRouter: ObservableObject {
  @Published private(set) var state: NamedHarnessRoutingState = .idle

  let registry: NamedHarnessRegistry
  private let harnessBridge: ScopedHarnessBridgeTransport?
  private let codexBridge: CodexTaskBridgeTransport?
  private let harnessUnavailableReason: String?
  private let codexUnavailableReason: String?
  private let invocationRequestID: () -> String
  private var recognizedAuthorization: RecognizedHarnessAuthorization?
  private var latestConsumedTranscriptionEpoch: UInt64?

  init(
    registry: NamedHarnessRegistry,
    harnessBridge: ScopedHarnessBridgeTransport? = nil,
    codexBridge: CodexTaskBridgeTransport? = nil,
    harnessUnavailableReason: String? = nil,
    codexUnavailableReason: String? = nil,
    invocationRequestID: @escaping () -> String = {
      "vcg_" + UUID().uuidString
        .replacingOccurrences(of: "-", with: "")
        .lowercased()
    }
  ) {
    self.registry = registry
    self.harnessBridge = harnessBridge
    self.codexBridge = codexBridge
    self.harnessUnavailableReason = harnessUnavailableReason
    self.codexUnavailableReason = codexUnavailableReason
    self.invocationRequestID = invocationRequestID
  }

  func recognize(
    transcript: String,
    transcriptionEpoch: UInt64? = nil
  ) {
    if let transcriptionEpoch,
       let latestConsumedTranscriptionEpoch,
       transcriptionEpoch <= latestConsumedTranscriptionEpoch {
      return
    }
    guard let invocation = registry.invocation(in: transcript) else { return }
    recognizedAuthorization = RecognizedHarnessAuthorization(
      invocation: invocation,
      transcriptionEpoch: transcriptionEpoch
    )
    state = .recognized(invocation.harness.displayName)
  }

  func clearRecognition() {
    recognizedAuthorization = nil
    state = .idle
  }

  func reset() {
    clearRecognition()
    latestConsumedTranscriptionEpoch = nil
  }

  func route(_ request: NamedHarnessRouteRequest) async -> ToolResult {
    guard let harness = registry.harness(named: request.targetName) else {
      let fallback = registry.fallbackHarness
      state = .fallback(
        requested: request.targetName,
        selected: fallback?.displayName,
        reason: "The requested name is not registered."
      )
      let suggestion = fallback.map { " Say \($0.displayName) to use that harness." } ?? ""
      return .failure(
        "No harness named \(request.targetName) is registered. No action was taken.\(suggestion)"
      )
    }

    let spokenAuthorization = await waitForRecognizedAuthorization()
    guard !Task.isCancelled else {
      return cancelledRouteResult(for: harness)
    }
    guard let spokenAuthorization else {
      state = .unavailable(
        harness.displayName,
        "No registered invocation name was recognized at the start of the request."
      )
      return .failure(
        "Say the registered harness name first. No action was taken."
      )
    }
    // A recognized spoken invocation authorizes at most one routed tool call.
    // Consume its transcription epoch before awaiting any backend. Later
    // fragments may complete the displayed transcript, but cannot re-arm a
    // second route from the same physical utterance.
    recognizedAuthorization = nil
    if let consumedEpoch = spokenAuthorization.transcriptionEpoch {
      latestConsumedTranscriptionEpoch = max(
        latestConsumedTranscriptionEpoch ?? 0,
        consumedEpoch
      )
    }
    let spokenInvocation = spokenAuthorization.invocation
    guard spokenInvocation.harness.id == harness.id else {
      state = .fallback(
        requested: harness.displayName,
        selected: spokenInvocation.harness.displayName,
        reason: "The requested tool target did not match the spoken invocation name."
      )
      return .failure(
        "The spoken target was \(spokenInvocation.harness.displayName), not " +
        "\(harness.displayName). No action was taken."
      )
    }

    let operation = request.operation ?? defaultOperation(for: harness.backend)
    guard harness.allowedOperations.contains(operation) else {
      state = .unavailable(
        harness.displayName,
        "Operation \(operation.rawValue) is outside this harness scope."
      )
      return .failure(
        "\(harness.displayName) does not allow \(operation.rawValue). No action was taken."
      )
    }

    state = .routing(harness.displayName)

    switch harness.backend {
    case .openClaw:
      let instruction = spokenInvocation.request
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard !instruction.isEmpty else {
        let reason = "No spoken request followed the invocation name."
        state = .unavailable(harness.displayName, reason)
        return .failure(
          "Say \(harness.displayName) followed by the request. No action was taken."
        )
      }
      guard let harnessBridge else {
        let reason = harnessUnavailableReason
          ?? "The scoped OpenClaw relay is not securely paired."
        state = .unavailable(
          harness.displayName,
          reason
        )
        return .failure(
          "\(harness.displayName) is unavailable. \(reason)"
        )
      }
      let clientRequestID = invocationRequestID()
      guard clientRequestID.range(
        of: #"^vcg_[a-f0-9]{32}$"#,
        options: .regularExpression
      ) != nil else {
        let reason = "VisionClaw could not create a safe request identifier."
        state = .unavailable(harness.displayName, reason)
        return .failure("\(reason) No action was taken.")
      }
      guard !Task.isCancelled else {
        return cancelledRouteResult(for: harness)
      }
      let result = await harnessBridge.perform(
        ScopedHarnessInvocationRequest(
          harnessID: harness.id,
          instruction: instruction,
          clientRequestID: clientRequestID
        )
      )
      updateState(after: result, harness: harness)
      return result

    case .codexTasks:
      guard let codexBridge else {
        let reason = codexUnavailableReason
          ?? "The scoped Codex relay is not paired."
        state = .unavailable(
          harness.displayName,
          reason
        )
        return .failure(
          "Codex task control is unavailable. \(reason) No Codex task was changed."
        )
      }

      guard let codexRequest = CodexTaskControlRequest(
        operation: operation,
        taskReference: request.taskReference,
        actionReference: request.actionReference,
        instruction: request.task,
        clientRequestID: request.clientRequestID
      ) else {
        state = .unavailable(harness.displayName, "Invalid scoped task request.")
        return .failure("The Codex task request was invalid. No action was taken.")
      }

      do {
        try CodexTaskScopePolicy.validate(codexRequest)
      } catch {
        state = .confirmationRequired(harness.displayName, error.localizedDescription)
        return .failure(error.localizedDescription)
      }

      guard !Task.isCancelled else {
        return cancelledRouteResult(for: harness)
      }
      let result = await codexBridge.perform(codexRequest)
      updateState(after: result, harness: harness)
      return result

    case .nativeMeta:
      state = .fallback(
        requested: harness.displayName,
        selected: "Meta native assistant",
        reason: "DAT does not expose a supported assistant-invocation API."
      )
      return .success(
        "Meta fallback selected. VisionClaw cannot activate the native Meta assistant " +
        "through DAT. Tell the user to use “Hey Meta” or the glasses touch control; " +
        "do not claim that Meta was activated automatically."
      )
    }
  }

  private func defaultOperation(
    for backend: NamedHarnessBackend
  ) -> NamedHarnessOperation {
    switch backend {
    case .openClaw: return .execute
    case .codexTasks: return .listTasks
    case .nativeMeta: return .handoff
    }
  }

  private func waitForRecognizedAuthorization() async
    -> RecognizedHarnessAuthorization? {
    for _ in 0..<5 {
      guard !Task.isCancelled else { return nil }
      if let recognizedAuthorization {
        return recognizedAuthorization
      }
      do {
        try await Task.sleep(nanoseconds: 100_000_000)
      } catch {
        return nil
      }
    }
    guard !Task.isCancelled else { return nil }
    return recognizedAuthorization
  }

  private func cancelledRouteResult(
    for harness: NamedHarness
  ) -> ToolResult {
    let reason = "The route was cancelled before dispatch."
    state = .unavailable(harness.displayName, reason)
    return .failure("\(reason) No action was taken.")
  }

  private func updateState(after result: ToolResult, harness: NamedHarness) {
    switch result {
    case .success:
      state = .active(harness.displayName)
    case .failure(let message):
      state = .unavailable(harness.displayName, message)
    }
  }
}
