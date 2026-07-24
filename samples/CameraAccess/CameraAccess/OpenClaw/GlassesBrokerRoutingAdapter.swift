import Combine
import Foundation
import UIKit

enum GlassesBrokerSessionState: Equatable {
  case unpaired
  case pairing
  case paired(String)
  case checking(String)
  case reachable(String)
  case pairedOffline(String)
  case unauthorized(String)
  case blockedPairing(String)
  case failed(String)

  var displayText: String {
    switch self {
    case .unpaired:
      return "Not paired"
    case .pairing:
      return "Pairing…"
    case .paired:
      return "Paired"
    case .checking:
      return "Checking Mac…"
    case .reachable:
      return "Mac reachable"
    case .pairedOffline:
      return "Paired — Mac offline"
    case .unauthorized:
      return "Pairing needs repair"
    case .blockedPairing:
      return "Pairing data is unreadable"
    case .failed(let message):
      return message
    }
  }
}

struct GlassesBrokerRoutingSnapshot {
  let registry: NamedHarnessRegistry
  let namedRoutingEnabled: Bool
  let harnessBridge: ScopedHarnessBridgeTransport?
  let codexBridge: CodexTaskBridgeTransport?
  let harnessUnavailableReason: String?
  let codexUnavailableReason: String?

  static let legacy = GlassesBrokerRoutingSnapshot(
    registry: .standard(),
    namedRoutingEnabled: false,
    harnessBridge: nil,
    codexBridge: nil,
    harnessUnavailableReason: nil,
    codexUnavailableReason: nil
  )
}

struct GlassesBrokerPairingConfirmation: Identifiable, Equatable {
  let id: UUID
  let privateMacAddress: String
  let brokerSuffix: String
  let tlsFingerprintSHA256: String

  init(
    offer: GlassesBrokerPairingOffer,
    id: UUID = UUID()
  ) {
    self.id = id
    let port = offer.endpoint.port ?? 443
    privateMacAddress = "\(offer.endpoint.host ?? "Unknown"):\(port)"
    brokerSuffix = String(offer.brokerID.suffix(6))
    tlsFingerprintSHA256 = offer.tlsPublicKeyPinSHA256.map {
      String(format: "%02X", $0)
    }.joined(separator: ":")
  }
}

struct CodexContinuationConfirmation: Identifiable, Equatable {
  let id: UUID
  let taskTitle: String
  let workspace: String?
  let taskReference: String
  let instruction: String
  let expiresAt: Date
}

enum CodexTrustedConfirmationError: LocalizedError, Equatable {
  case noPreparedAction
  case confirmationMismatch
  case expired

  var errorDescription: String? {
    switch self {
    case .noPreparedAction:
      return "Prepare the Codex continuation again. No action was taken."
    case .confirmationMismatch:
      return "This Codex approval is no longer current. No action was taken."
    case .expired:
      return "The Codex confirmation expired. Prepare it again. No action was taken."
    }
  }
}

struct CodexTrustedConfirmationStore {
  private struct PendingAction {
    let confirmationID: UUID
    let actionID: String
    let clientRequestID: String
    let taskTitle: String
    let workspace: String?
    let taskReference: String
    let instruction: String
    let confirmationNonce: String
    let expiresAt: Int64
  }

  private var pendingAction: PendingAction?

  var hasPendingAction: Bool {
    pendingAction != nil
  }

  @discardableResult
  mutating func prepare(
    _ prepared: GlassesCodexPreparedAction,
    instruction: String,
    confirmationID: UUID = UUID()
  ) -> CodexContinuationConfirmation {
    pendingAction = PendingAction(
      confirmationID: confirmationID,
      actionID: prepared.actionID,
      clientRequestID: prepared.clientRequestID,
      taskTitle: prepared.taskTitle,
      workspace: prepared.workspace,
      taskReference: prepared.taskReference,
      instruction: instruction,
      confirmationNonce: prepared.confirmationNonce,
      expiresAt: prepared.expiresAt
    )
    return CodexContinuationConfirmation(
      id: confirmationID,
      taskTitle: prepared.taskTitle,
      workspace: prepared.workspace,
      taskReference: prepared.taskReference,
      instruction: instruction,
      expiresAt: Date(
        timeIntervalSince1970: Double(prepared.expiresAt) / 1_000
      )
    )
  }

  mutating func consumeForCommit(
    confirmationID: UUID,
    nowMilliseconds: Int64
  ) throws -> CodexTrustedContinuationCredentials {
    guard let pendingAction else {
      throw CodexTrustedConfirmationError.noPreparedAction
    }
    guard pendingAction.confirmationID == confirmationID else {
      throw CodexTrustedConfirmationError.confirmationMismatch
    }
    guard pendingAction.expiresAt > nowMilliseconds else {
      self.pendingAction = nil
      throw CodexTrustedConfirmationError.expired
    }

    self.pendingAction = nil
    return CodexTrustedContinuationCredentials(
      actionID: pendingAction.actionID,
      clientRequestID: pendingAction.clientRequestID,
      confirmationNonce: pendingAction.confirmationNonce
    )
  }

  mutating func consumeForCancellation(
    confirmationID: UUID
  ) throws -> CodexTrustedContinuationCredentials {
    guard let pendingAction else {
      throw CodexTrustedConfirmationError.noPreparedAction
    }
    guard pendingAction.confirmationID == confirmationID else {
      throw CodexTrustedConfirmationError.confirmationMismatch
    }
    self.pendingAction = nil
    return CodexTrustedContinuationCredentials(
      actionID: pendingAction.actionID,
      clientRequestID: pendingAction.clientRequestID,
      confirmationNonce: pendingAction.confirmationNonce
    )
  }

  mutating func reset() {
    pendingAction = nil
  }
}

struct CodexTrustedContinuationCredentials: Equatable {
  let actionID: String
  let clientRequestID: String
  let confirmationNonce: String
}

@MainActor
final class GlassesBrokerConnectionModel: ObservableObject {
  @Published private(set) var state: GlassesBrokerSessionState = .unpaired
  @Published private(set) var pairedBroker: GlassesBrokerPairedRecord?
  @Published private(set) var nearbyBrokers: [BonjourBrokerCandidate] = []
  @Published private(set) var shouldPresentPairingResult = false
  @Published private(set) var pairingResultMessage = ""
  @Published private(set) var pendingPairingConfirmation:
    GlassesBrokerPairingConfirmation?
  @Published private(set) var pendingCodexConfirmation:
    CodexContinuationConfirmation?
  @Published private(set) var glassesSessionLaunchRequestID: UUID?

  let discovery: BonjourBrokerDiscovery

  private let credentialVault: GlassesBrokerCredentialVault
  private let connection: GlassesBrokerConnection
  private var discoveryObservation: AnyCancellable?
  private var reachabilityGeneration: UInt64 = 0
  private var pendingPairingOffer: GlassesBrokerPairingOffer?
  private lazy var harnessBridge = GlassesBrokerHarnessBridge(
    connection: connection
  )
  private lazy var codexBridge: GlassesBrokerCodexBridge = {
    let bridge = GlassesBrokerCodexBridge(connection: connection)
    bridge.confirmationHandler = { [weak self] confirmation in
      self?.pendingCodexConfirmation = confirmation
    }
    return bridge
  }()

  init(
    credentialVault: GlassesBrokerCredentialVault =
      GlassesBrokerCredentialVault(),
    connection: GlassesBrokerConnection? = nil,
    discovery: BonjourBrokerDiscovery? = nil
  ) {
    let resolvedDiscovery = discovery ?? BonjourBrokerDiscovery()
    self.credentialVault = credentialVault
    self.connection = connection ?? GlassesBrokerConnection(
      credentialVault: credentialVault
    )
    self.discovery = resolvedDiscovery
    discoveryObservation = resolvedDiscovery.$candidates.sink {
      [weak self] value in
      self?.nearbyBrokers = value
    }
    reloadPairing()
  }

  var pairedBrokerName: String? {
    guard let brokerID = pairedBroker?.brokerID else { return nil }
    return "Mac " + String(brokerID.suffix(6))
  }

  var isSecureRoutingReady: Bool {
    routingSnapshot().harnessBridge != nil
  }

  var hasStoredPairing: Bool {
    if pairedBroker != nil {
      return true
    }
    if case .blockedPairing = state {
      return true
    }
    return false
  }

  func routingSnapshot() -> GlassesBrokerRoutingSnapshot {
    guard let pairedBroker else {
      if case .unpaired = state {
        return .legacy
      }
      let reason =
        "The protected Mac pairing cannot be used. Forget it explicitly before using legacy routing."
      return GlassesBrokerRoutingSnapshot(
        registry: .standard(),
        namedRoutingEnabled: true,
        harnessBridge: nil,
        codexBridge: nil,
        harnessUnavailableReason: reason,
        codexUnavailableReason: reason
      )
    }
    let harnessScopes = Set([
      GlassesRelayScope.harnessInvoke.rawValue,
      GlassesRelayScope.harnessRead.rawValue,
    ])
    guard harnessScopes.isSubset(of: pairedBroker.grantedScopes) else {
      return GlassesBrokerRoutingSnapshot(
        registry: .standard(),
        namedRoutingEnabled: true,
        harnessBridge: nil,
        codexBridge: nil,
        harnessUnavailableReason:
          "This pairing does not grant the required Eva scopes. Re-pair VisionClaw.",
        codexUnavailableReason:
          "This pairing does not grant the required Codex scopes. Re-pair VisionClaw."
      )
    }

    guard case .reachable(let reachableBrokerID) = state,
          reachableBrokerID == pairedBroker.brokerID else {
      let reason: String
      switch state {
      case .checking:
        reason = "The paired Mac is still being checked. Try again in a moment."
      case .unauthorized:
        reason = "The Mac rejected this pairing. Revoke it on the Mac and pair again."
      case .reachable:
        reason =
          "The reachable Mac does not match the current pairing. Re-pair VisionClaw."
      default:
        reason =
          "The paired Mac is offline or unreachable. No external request was sent."
      }
      return GlassesBrokerRoutingSnapshot(
        registry: .standard(),
        namedRoutingEnabled: true,
        harnessBridge: nil,
        codexBridge: nil,
        harnessUnavailableReason: reason,
        codexUnavailableReason: reason
      )
    }

    let codexScopes = Set([
      GlassesRelayScope.tasksList.rawValue,
      GlassesRelayScope.tasksRead.rawValue,
      GlassesRelayScope.tasksStatus.rawValue,
      GlassesRelayScope.tasksContinue.rawValue,
      GlassesRelayScope.tasksContinueCommit.rawValue,
      GlassesRelayScope.tasksOperationStatus.rawValue,
      GlassesRelayScope.tasksCancel.rawValue,
    ])
    return GlassesBrokerRoutingSnapshot(
      registry: .standard(),
      namedRoutingEnabled: true,
      harnessBridge: harnessBridge,
      codexBridge: codexScopes.isSubset(of: pairedBroker.grantedScopes)
        ? codexBridge
        : nil,
      harnessUnavailableReason: nil,
      codexUnavailableReason: codexScopes.isSubset(
        of: pairedBroker.grantedScopes
      )
        ? nil
        : "This pairing does not grant all required Codex scopes. Re-pair VisionClaw."
    )
  }

  func setCompletionHandler(
    _ handler: (@MainActor (String) -> Void)?
  ) {
    harnessBridge.completionHandler = handler
    codexBridge.completionHandler = handler
  }

  func stopOperationMonitoring() {
    harnessBridge.stopMonitoring()
    codexBridge.stopMonitoring()
    setCompletionHandler(nil)
  }

  func startDiscovery() {
    discovery.start()
  }

  func stopDiscovery() {
    discovery.stop()
  }

  func refreshReachability() async {
    if case .pairing = state {
      return
    }
    guard let pairedBroker else {
      invalidateReachability()
      if case .blockedPairing = state {
        return
      }
      state = .unpaired
      return
    }
    let generation = beginReachabilityAttempt()
    let harnessScopes = Set([
      GlassesRelayScope.harnessInvoke.rawValue,
      GlassesRelayScope.harnessRead.rawValue,
    ])
    guard harnessScopes.isSubset(of: pairedBroker.grantedScopes) else {
      state = .unauthorized(pairedBroker.brokerID)
      return
    }

    state = .checking(pairedBroker.brokerID)
    do {
      let status = try await connection.checkPairedStatus()
      guard isCurrentReachabilityAttempt(
        generation,
        pairedBroker: pairedBroker
      ) else {
        return
      }
      guard status.brokerID == pairedBroker.brokerID, status.ready else {
        state = .unauthorized(pairedBroker.brokerID)
        return
      }
      state = .reachable(pairedBroker.brokerID)
    } catch let error as GlassesBrokerConnectionError {
      guard isCurrentReachabilityAttempt(
        generation,
        pairedBroker: pairedBroker
      ) else {
        return
      }
      switch error {
      case .http(let status, _, _) where status == 401 || status == 403:
        state = .unauthorized(pairedBroker.brokerID)
      case .brokerIdentityChanged, .invalidResponse:
        state = .unauthorized(pairedBroker.brokerID)
      default:
        state = .pairedOffline(pairedBroker.brokerID)
      }
    } catch {
      guard isCurrentReachabilityAttempt(
        generation,
        pairedBroker: pairedBroker
      ) else {
        return
      }
      state = .pairedOffline(pairedBroker.brokerID)
    }
  }

  func handlePairingLink(_ url: URL) async {
    guard canStageNewPairing else {
      pendingPairingOffer = nil
      pendingPairingConfirmation = nil
      pairingResultMessage =
        "A protected Mac pairing already exists. Use Forget Mac Pairing before pairing another Mac."
      shouldPresentPairingResult = true
      return
    }

    do {
      let offer = try GlassesBrokerPairingOffer.parse(url)
      pendingPairingOffer = offer
      pendingPairingConfirmation = GlassesBrokerPairingConfirmation(
        offer: offer
      )
    } catch {
      pendingPairingOffer = nil
      pendingPairingConfirmation = nil
      pairingResultMessage = error.localizedDescription
      shouldPresentPairingResult = true
    }
  }

  func confirmPendingPairing(
    confirmationID: UUID
  ) async {
    guard canStageNewPairing,
          let offer = pendingPairingOffer,
          pendingPairingConfirmation?.id == confirmationID else {
      cancelPendingPairing()
      pairingResultMessage =
        "This pairing confirmation is no longer current. No connection was made."
      shouldPresentPairingResult = true
      return
    }

    pendingPairingOffer = nil
    pendingPairingConfirmation = nil
    invalidateReachability()
    state = .pairing
    do {
      let record = try await connection.completePairing(
        offer: offer,
        deviceName: UIDevice.current.name
      )
      invalidateReachability()
      pairedBroker = record
      state = .reachable(record.brokerID)
      pairingResultMessage =
        "Your iPhone is securely paired with the VisionClaw Mac broker."
    } catch {
      reloadPairing()
      pairingResultMessage = error.localizedDescription
    }
    shouldPresentPairingResult = true
  }

  func cancelPendingPairing() {
    pendingPairingOffer = nil
    pendingPairingConfirmation = nil
  }

  func handleDeepLink(_ url: URL) async -> Bool {
    guard url.scheme?.lowercased() == "visionclaw" else { return false }
    switch url.host?.lowercased() {
    case "pair":
      await handlePairingLink(url)
      return true
    case "glasses-session":
      requestGlassesSession()
      return true
    default:
      return false
    }
  }

  func dismissPairingResult() {
    shouldPresentPairingResult = false
  }

  func requestGlassesSession() {
    glassesSessionLaunchRequestID = UUID()
  }

  @discardableResult
  func consumeGlassesSessionLaunchRequest(_ requestID: UUID) -> Bool {
    guard glassesSessionLaunchRequestID == requestID else { return false }
    glassesSessionLaunchRequestID = nil
    return true
  }

  func forgetPairing() {
    stopOperationMonitoring()
    cancelPendingPairing()
    invalidateReachability()
    do {
      try credentialVault.removePairedBroker()
      pairedBroker = nil
      state = .unpaired
    } catch {
      pairedBroker = nil
      state = .blockedPairing(error.localizedDescription)
    }
  }

  func confirmPendingCodexContinuation(
    confirmationID: UUID
  ) async {
    let result = await codexBridge.confirmPendingContinuation(
      confirmationID: confirmationID
    )
    presentTrustedCodexResult(result)
  }

  func cancelPendingCodexContinuation(
    confirmationID: UUID
  ) async {
    let result = await codexBridge.cancelPendingContinuation(
      confirmationID: confirmationID
    )
    if case .failure = result {
      presentTrustedCodexResult(result)
    }
  }

  private func reloadPairing() {
    invalidateReachability()
    do {
      pairedBroker = try credentialVault.pairedBroker()
      if let pairedBroker {
        state = .paired(pairedBroker.brokerID)
      } else {
        state = .unpaired
      }
    } catch {
      pairedBroker = nil
      state = .blockedPairing(error.localizedDescription)
    }
  }

  private var canStageNewPairing: Bool {
    guard pairedBroker == nil else { return false }
    if case .unpaired = state {
      return true
    }
    return false
  }

  private func presentTrustedCodexResult(_ result: ToolResult) {
    switch result {
    case .success(let message):
      pairingResultMessage = message
    case .failure(let message):
      pairingResultMessage = message
    }
    shouldPresentPairingResult = true
  }

  private func beginReachabilityAttempt() -> UInt64 {
    invalidateReachability()
    return reachabilityGeneration
  }

  private func invalidateReachability() {
    reachabilityGeneration &+= 1
  }

  private func isCurrentReachabilityAttempt(
    _ generation: UInt64,
    pairedBroker: GlassesBrokerPairedRecord
  ) -> Bool {
    generation == reachabilityGeneration
      && self.pairedBroker == pairedBroker
  }
}

@MainActor
final class GlassesBrokerHarnessBridge: ScopedHarnessBridgeTransport {
  typealias CompletionHandler = @MainActor (String) -> Void

  var completionHandler: CompletionHandler?

  private let connection: GlassesBrokerConnection
  private var monitoringTasks: [String: Task<Void, Never>] = [:]

  init(connection: GlassesBrokerConnection) {
    self.connection = connection
  }

  func perform(_ request: ScopedHarnessInvocationRequest) async -> ToolResult {
    let clientRequestID = request.clientRequestID ?? UUID().uuidString.lowercased()
    do {
      let started = try await connection.invokeHarness(
        harnessID: request.harnessID,
        instruction: request.instruction,
        clientRequestID: clientRequestID
      )
      startMonitoring(
        operationID: started.operationID
      )
      return .success(started.message)
    } catch {
      return .failure(error.localizedDescription)
    }
  }

  func stopMonitoring() {
    for task in monitoringTasks.values {
      task.cancel()
    }
    monitoringTasks.removeAll()
  }

  private func startMonitoring(
    operationID: String
  ) {
    monitoringTasks[operationID]?.cancel()
    monitoringTasks[operationID] = Task { @MainActor [weak self] in
      guard let self else { return }
      var sequence = 0
      var transientFailures = 0

      while !Task.isCancelled {
        do {
          let update = try await self.connection.pollHarness(
            operationID: operationID,
            afterSequence: sequence
          )
          sequence = max(sequence, update.sequence)
          transientFailures = 0

          switch update.status {
          case .completed:
            self.completionHandler?(
              Self.spokenCompletion(
                prefix: "Eva finished.",
                detail: update.response
              )
            )
            self.monitoringTasks.removeValue(forKey: operationID)
            return
          case .failed, .aborted, .cancelled, .reconciliationRequired:
            self.completionHandler?(
              Self.spokenCompletion(
                prefix: "Eva could not finish the request.",
                detail: update.error
              )
            )
            self.monitoringTasks.removeValue(forKey: operationID)
            return
          case .started, .pending, .streaming, .unchanged:
            try await Task.sleep(nanoseconds: 400_000_000)
          }
        } catch is CancellationError {
          return
        } catch {
          transientFailures += 1
          guard transientFailures < 4 else {
            self.completionHandler?(
              "Eva is still working, but VisionClaw lost the broker connection."
            )
            self.monitoringTasks.removeValue(forKey: operationID)
            return
          }
          try? await Task.sleep(
            nanoseconds: UInt64(transientFailures) * 500_000_000
          )
        }
      }
    }
  }

  private static func spokenCompletion(
    prefix: String,
    detail: String?
  ) -> String {
    let clean = detail?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !clean.isEmpty else { return prefix }
    return prefix + " " + String(clean.prefix(4_000))
  }
}

@MainActor
final class GlassesBrokerCodexBridge: CodexTaskBridgeTransport {
  typealias CompletionHandler = @MainActor (String) -> Void
  typealias ConfirmationHandler = @MainActor (
    CodexContinuationConfirmation?
  ) -> Void

  var completionHandler: CompletionHandler?
  var confirmationHandler: ConfirmationHandler?

  private let connection: GlassesBrokerConnection
  private var monitoringTasks: [String: Task<Void, Never>] = [:]
  private var confirmationStore = CodexTrustedConfirmationStore()

  init(connection: GlassesBrokerConnection) {
    self.connection = connection
  }

  func perform(_ request: CodexTaskControlRequest) async -> ToolResult {
    do {
      switch request.operation {
      case .list:
        let tasks = try await connection.listCodexTasks()
        guard !tasks.isEmpty else {
          return .success("Codex has no available tasks.")
        }
        return .success(
          tasks.map(Self.taskDescription).joined(separator: "\n\n")
        )

      case .read:
        let task = try await connection.readCodexTask(
          taskReference: try Self.required(request.taskReference)
        )
        return .success(Self.taskDescription(task))

      case .status:
        let task = try await connection.codexTaskStatus(
          taskReference: try Self.required(request.taskReference)
        )
        return .success(Self.taskDescription(task))

      case .prepareContinue:
        guard !confirmationStore.hasPendingAction else {
          return .failure(
            "A Codex continuation is already waiting for review on the iPhone. No new continuation was prepared."
          )
        }
        let prepared = try await connection.prepareCodexContinuation(
          taskReference: try Self.required(request.taskReference),
          instruction: request.instruction,
          clientRequestID: try Self.required(request.clientRequestID)
        )
        let confirmation = confirmationStore.prepare(
          prepared,
          instruction: request.instruction
        )
        confirmationHandler?(confirmation)
        return .success(
          """
          Codex continuation is prepared but has not started. VisionClaw is \
          showing the exact task and full instruction in a trusted iPhone \
          confirmation sheet. Only the physical Confirm button can start it.
          """
        )

      case .operationStatus:
        let status = try await connection.codexOperationStatus(
          actionID: try Self.required(request.actionReference),
          clientRequestID: try Self.required(request.clientRequestID)
        )
        return .success(Self.operationDescription(status))

      case .cancel:
        let actionReference = try Self.required(request.actionReference)
        let clientRequestID = try Self.required(request.clientRequestID)
        let cancellation = try await connection.cancelCodexContinuation(
          actionID: actionReference,
          clientRequestID: clientRequestID
        )
        return .success(
          cancellation.cancelled
            ? "The prepared Codex action was cancelled."
            : "The Codex action was unchanged."
        )
      }
    } catch {
      return .failure(error.localizedDescription)
    }
  }

  func stopMonitoring() {
    for task in monitoringTasks.values {
      task.cancel()
    }
    monitoringTasks.removeAll()
    confirmationStore.reset()
    confirmationHandler?(nil)
  }

  func confirmPendingContinuation(
    confirmationID: UUID,
    nowMilliseconds: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)
  ) async -> ToolResult {
    do {
      let credentials = try confirmationStore.consumeForCommit(
        confirmationID: confirmationID,
        nowMilliseconds: nowMilliseconds
      )
      confirmationHandler?(nil)
      let receipt = try await connection.commitCodexContinuation(
        actionID: credentials.actionID,
        confirmationNonce: credentials.confirmationNonce,
        clientRequestID: credentials.clientRequestID
      )
      startMonitoring(
        actionReference: credentials.actionID,
        clientRequestID: credentials.clientRequestID
      )
      return .success(
        """
        Codex accepted the continuation on a forked task. \
        Forked task \(receipt.forkedTaskReference); status \(receipt.status).
        """
      )
    } catch {
      confirmationHandler?(nil)
      return .failure(error.localizedDescription)
    }
  }

  func cancelPendingContinuation(
    confirmationID: UUID
  ) async -> ToolResult {
    do {
      let credentials = try confirmationStore.consumeForCancellation(
        confirmationID: confirmationID
      )
      confirmationHandler?(nil)
      let cancellation = try await connection.cancelCodexContinuation(
        actionID: credentials.actionID,
        clientRequestID: credentials.clientRequestID
      )
      return .success(
        cancellation.cancelled
          ? "The prepared Codex continuation was cancelled."
          : "The prepared Codex continuation was already inactive."
      )
    } catch {
      confirmationHandler?(nil)
      return .failure(error.localizedDescription)
    }
  }

  private func startMonitoring(
    actionReference: String,
    clientRequestID: String
  ) {
    monitoringTasks[actionReference]?.cancel()
    monitoringTasks[actionReference] = Task { @MainActor [weak self] in
      guard let self else { return }
      var transientFailures = 0

      while !Task.isCancelled {
        do {
          let status = try await self.connection.codexOperationStatus(
            actionID: actionReference,
            clientRequestID: clientRequestID
          )
          transientFailures = 0
          if Self.isTerminal(status) {
            self.completionHandler?(
              "Codex update. " + Self.operationDescription(status)
            )
            self.monitoringTasks.removeValue(forKey: actionReference)
            return
          }
          try await Task.sleep(nanoseconds: 750_000_000)
        } catch is CancellationError {
          return
        } catch {
          transientFailures += 1
          guard transientFailures < 4 else {
            self.completionHandler?(
              "Codex is still working, but VisionClaw lost the broker connection."
            )
            self.monitoringTasks.removeValue(forKey: actionReference)
            return
          }
          try? await Task.sleep(
            nanoseconds: UInt64(transientFailures) * 750_000_000
          )
        }
      }
    }
  }

  private static func required(_ value: String?) throws -> String {
    guard let value,
          !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw GlassesBrokerConnectionError.invalidRequest
    }
    return value
  }

  private static func taskDescription(
    _ task: GlassesCodexTaskSummary
  ) -> String {
    var values = [
      "title \(task.title)",
      "status \(task.status)",
      "taskReference \(task.taskReference)",
      "preview \(task.preview)",
    ]
    if let workspace = task.workspace, !workspace.isEmpty {
      values.append("workspace \(workspace)")
    }
    return values.joined(separator: "; ")
  }

  private static func operationDescription(
    _ operation: GlassesCodexOperationStatus
  ) -> String {
    guard let receipt = operation.receipt else {
      return "Codex state \(operation.state.rawValue)."
    }
    return """
      Codex state \(operation.state.rawValue); forkedTaskReference \
      \(receipt.forkedTaskReference); turnReference \(receipt.turnReference); \
      turn status \(receipt.status).
      """
  }

  private static func isTerminal(
    _ operation: GlassesCodexOperationStatus
  ) -> Bool {
    let states = Set(["cancelled", "completed", "failed"])
    let turnStatuses = Set([
      "cancelled", "canceled", "completed", "failed", "interrupted",
    ])
    return states.contains(operation.state.rawValue.lowercased())
      || turnStatuses.contains(operation.receipt?.status.lowercased() ?? "")
  }
}
