import Foundation

enum GlassesRelayScope: String, Codable, CaseIterable {
  case tasksList = "tasks:list"
  case tasksRead = "tasks:read"
  case tasksContinue = "tasks:continue"
  case tasksContinueCommit = "tasks:continue:commit"
  case tasksStatus = "tasks:status"
  case tasksOperationStatus = "tasks:operation:status"
  case tasksCancel = "tasks:cancel"
  case harnessInvoke = "harness:invoke"
  case harnessRead = "harness:read"
  case harnessCancel = "harness:cancel"
}

struct ScopedHarnessInvocationRequest: Equatable {
  let harnessID: String
  let instruction: String
  let clientRequestID: String?
}

@MainActor
protocol ScopedHarnessBridgeTransport {
  func perform(_ request: ScopedHarnessInvocationRequest) async -> ToolResult
}

/// An in-memory, short-lived capability created by an authenticated pairing
/// flow. It is intentionally not Codable and must never be written to
/// UserDefaults, logs, model context, or tool responses.
struct GlassesRelaySessionCapability: CustomStringConvertible {
  let relayURL: URL
  let scopes: Set<GlassesRelayScope>
  let expiresAt: Date
  private let bearerToken: String

  init?(
    relayURL: URL,
    bearerToken: String,
    scopes: Set<GlassesRelayScope>,
    expiresAt: Date,
    now: Date = Date()
  ) {
    guard ["https", "wss"].contains(relayURL.scheme?.lowercased()),
          !bearerToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          expiresAt > now else {
      return nil
    }
    self.relayURL = relayURL
    self.bearerToken = bearerToken
    self.scopes = scopes
    self.expiresAt = expiresAt
  }

  var description: String {
    "GlassesRelaySessionCapability(relay=\(relayURL.host ?? "unknown"), token=<redacted>)"
  }

  func authorizationHeader(
    requiring scope: GlassesRelayScope,
    now: Date = Date()
  ) -> String? {
    guard expiresAt > now, scopes.contains(scope) else { return nil }
    return "Bearer \(bearerToken)"
  }
}

enum SecureHarnessRouteSource: Equatable {
  case bonjourLAN
  case authenticatedRelay
}

struct SecureHarnessRouteCandidate: Equatable {
  let source: SecureHarnessRouteSource
  let endpoint: URL
  let isAuthenticated: Bool
  let isPeerTrusted: Bool
  let measuredLatencyMilliseconds: Int?
}

enum SecureHarnessRouteSelection: Equatable {
  case selected(SecureHarnessRouteCandidate)
  case unavailable(String)
}

enum SecureHarnessRouteSelector {
  /// Prefer a paired, TLS-protected Bonjour peer on LAN, then an authenticated
  /// outbound relay. Plain HTTP/WS and untrusted peers are never selected.
  static func select(
    from candidates: [SecureHarnessRouteCandidate]
  ) -> SecureHarnessRouteSelection {
    let valid = candidates.filter(isSafe)
    let ordered = valid.sorted { lhs, rhs in
      if lhs.source != rhs.source {
        return lhs.source == .bonjourLAN
      }
      return (lhs.measuredLatencyMilliseconds ?? .max)
        < (rhs.measuredLatencyMilliseconds ?? .max)
    }
    guard let selected = ordered.first else {
      return .unavailable(
        "No paired TLS LAN peer or authenticated remote relay is available."
      )
    }
    return .selected(selected)
  }

  private static func isSafe(_ candidate: SecureHarnessRouteCandidate) -> Bool {
    let scheme = candidate.endpoint.scheme?.lowercased()
    guard ["https", "wss"].contains(scheme),
          candidate.isAuthenticated,
          candidate.isPeerTrusted else {
      return false
    }
    return true
  }
}

enum CodexTaskBridgeOperation: String, Codable, Equatable {
  case list
  case read
  case status
  case prepareContinue
  case operationStatus
  case cancel
}

struct CodexTaskControlRequest: Equatable {
  let operation: CodexTaskBridgeOperation
  let taskReference: String?
  let actionReference: String?
  let instruction: String
  let clientRequestID: String?

  init?(
    operation: NamedHarnessOperation,
    taskReference: String?,
    actionReference: String? = nil,
    instruction: String,
    clientRequestID: String?
  ) {
    let codexOperation: CodexTaskBridgeOperation
    switch operation {
    case .listTasks: codexOperation = .list
    case .readTask: codexOperation = .read
    case .taskStatus: codexOperation = .status
    case .prepareContinue: codexOperation = .prepareContinue
    case .operationStatus: codexOperation = .operationStatus
    case .cancelOperation: codexOperation = .cancel
    case .execute, .handoff: return nil
    }
    self.operation = codexOperation
    self.taskReference = taskReference
    self.actionReference = actionReference
    self.instruction = instruction
    self.clientRequestID = clientRequestID
  }
}

enum CodexTaskScopeError: LocalizedError, Equatable {
  case missingTaskReference
  case missingActionReference
  case missingInstruction
  case oversizedInstruction
  case missingClientRequestID

  var errorDescription: String? {
    switch self {
    case .missingTaskReference:
      return "Select one exact Codex task before continuing. No action was taken."
    case .missingActionReference:
      return "Use the exact prepared Codex action before continuing. No action was taken."
    case .missingInstruction:
      return "Say what Codex should do before continuing. No action was taken."
    case .oversizedInstruction:
      return "The Codex instruction is too long for voice control. No action was taken."
    case .missingClientRequestID:
      return "The Codex request is missing its replay-safe request ID. No action was taken."
    }
  }
}

enum CodexTaskScopePolicy {
  static let maxInstructionCharacters = 2_000

  static func validate(_ request: CodexTaskControlRequest) throws {
    let taskReference = request.taskReference?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let actionReference = request.actionReference?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let instruction = request.instruction
      .trimmingCharacters(in: .whitespacesAndNewlines)

    switch request.operation {
    case .list:
      return
    case .read, .status:
      guard taskReference?.isEmpty == false else {
        throw CodexTaskScopeError.missingTaskReference
      }
    case .prepareContinue:
      guard taskReference?.isEmpty == false else {
        throw CodexTaskScopeError.missingTaskReference
      }
      guard !instruction.isEmpty else {
        throw CodexTaskScopeError.missingInstruction
      }
      guard instruction.count <= maxInstructionCharacters else {
        throw CodexTaskScopeError.oversizedInstruction
      }
      guard hasValue(request.clientRequestID) else {
        throw CodexTaskScopeError.missingClientRequestID
      }
    case .operationStatus, .cancel:
      guard actionReference?.isEmpty == false else {
        throw CodexTaskScopeError.missingActionReference
      }
      guard hasValue(request.clientRequestID) else {
        throw CodexTaskScopeError.missingClientRequestID
      }
    }
  }

  private static func hasValue(_ value: String?) -> Bool {
    guard let value else { return false }
    return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
}

@MainActor
protocol CodexTaskBridgeTransport {
  func perform(_ request: CodexTaskControlRequest) async -> ToolResult
  func beginUserVoiceTurn()
  func updateUserVoiceTranscript(_ transcript: String)
  func resetUserConfirmation()
}

extension CodexTaskBridgeTransport {
  func beginUserVoiceTurn() {}
  func updateUserVoiceTranscript(_: String) {}
  func resetUserConfirmation() {}
}
