import CryptoKit
import Foundation
import Security

enum GlassesBrokerPairingError: LocalizedError, Equatable {
  case invalidLink
  case invalidPayload
  case expired
  case unsupportedVersion

  var errorDescription: String? {
    switch self {
    case .invalidLink:
      return "This is not a VisionClaw broker pairing link."
    case .invalidPayload:
      return "The VisionClaw pairing offer is invalid."
    case .expired:
      return "The VisionClaw pairing offer expired. Create a new one on the Mac."
    case .unsupportedVersion:
      return "This VisionClaw pairing offer needs a newer app version."
    }
  }
}

struct GlassesBrokerPairingOffer: CustomStringConvertible {
  let version: Int
  let brokerID: String
  let endpoint: URL
  let tlsPublicKeyPinSHA256: Data
  let pairingSecret: String
  let expiresAt: Date

  var description: String {
    "GlassesBrokerPairingOffer(version=\(version), broker=\(brokerID), secret=<redacted>)"
  }

  static func parse(
    _ url: URL,
    now: Date = Date()
  ) throws -> GlassesBrokerPairingOffer {
    guard let components = URLComponents(
      url: url,
      resolvingAgainstBaseURL: false
    ),
    components.scheme?.lowercased() == "visionclaw",
    components.host?.lowercased() == "pair",
    components.user == nil,
    components.password == nil,
    components.port == nil,
    components.fragment == nil,
    components.path.isEmpty || components.path == "/",
    let items = components.queryItems,
    items.count == 1,
    items[0].name == "payload",
    let encoded = items[0].value,
    encoded.count <= 12 * 1024,
    let data = Data(glassesBrokerStrictBase64URL: encoded),
    data.count <= 8 * 1024,
    String(data: data, encoding: .utf8) != nil else {
      throw GlassesBrokerPairingError.invalidLink
    }

    let object: Any
    do {
      object = try JSONSerialization.jsonObject(with: data)
    } catch {
      throw GlassesBrokerPairingError.invalidPayload
    }
    guard let dictionary = object as? [String: Any],
          Set(dictionary.keys) == Set([
            "brokerID",
            "endpoint",
            "expiresAt",
            "pairingSecret",
            "tlsPinSHA256",
            "version",
          ]),
          let canonical = try? JSONSerialization.data(
            withJSONObject: dictionary,
            options: [.sortedKeys, .withoutEscapingSlashes]
          ),
          canonical == data else {
      throw GlassesBrokerPairingError.invalidPayload
    }

    let payload: PairingPayload
    do {
      payload = try JSONDecoder().decode(PairingPayload.self, from: data)
    } catch {
      throw GlassesBrokerPairingError.invalidPayload
    }
    guard payload.version == 1 else {
      throw GlassesBrokerPairingError.unsupportedVersion
    }
    guard isBrokerID(payload.brokerID),
          isPairingSecret(payload.pairingSecret),
          payload.tlsPinSHA256.range(
            of: #"^[a-f0-9]{64}$"#,
            options: .regularExpression
          ) != nil,
          let pin = Data(strictLowercaseHex: payload.tlsPinSHA256),
          pin.count == SHA256.byteCount,
          let endpoint = URL(string: payload.endpoint),
          isSafeBrokerEndpoint(endpoint) else {
      throw GlassesBrokerPairingError.invalidPayload
    }

    let nowMilliseconds = milliseconds(since1970: now)
    guard payload.expiresAt > nowMilliseconds else {
      throw GlassesBrokerPairingError.expired
    }
    guard payload.expiresAt <= nowMilliseconds + 10 * 60 * 1_000 else {
      throw GlassesBrokerPairingError.invalidPayload
    }

    return GlassesBrokerPairingOffer(
      version: payload.version,
      brokerID: payload.brokerID,
      endpoint: endpoint,
      tlsPublicKeyPinSHA256: pin,
      pairingSecret: payload.pairingSecret,
      expiresAt: Date(
        timeIntervalSince1970: Double(payload.expiresAt) / 1_000
      )
    )
  }
}

private struct PairingPayload: Codable {
  let brokerID: String
  let endpoint: String
  let expiresAt: Int64
  let pairingSecret: String
  let tlsPinSHA256: String
  let version: Int
}

struct GlassesBrokerPairedRecord: Codable, Equatable {
  let brokerID: String
  let endpoint: URL
  let tlsPublicKeyPinSHA256: Data
  let pairingID: String
  let grantedScopes: Set<String>
  let pairedAt: Date

  init(
    brokerID: String,
    endpoint: URL,
    tlsPublicKeyPinSHA256: Data,
    pairingID: String,
    grantedScopes: Set<String>,
    pairedAt: Date
  ) {
    self.brokerID = brokerID
    self.endpoint = endpoint
    self.tlsPublicKeyPinSHA256 = tlsPublicKeyPinSHA256
    self.pairingID = pairingID
    self.grantedScopes = grantedScopes
    self.pairedAt = pairedAt
  }

  private enum CodingKeys: String, CodingKey {
    case brokerID
    case endpoint
    case tlsPublicKeyPinSHA256
    case pairingID
    case grantedScopes
    case pairedAtMilliseconds
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    brokerID = try container.decode(String.self, forKey: .brokerID)
    endpoint = try container.decode(URL.self, forKey: .endpoint)
    tlsPublicKeyPinSHA256 = try container.decode(
      Data.self,
      forKey: .tlsPublicKeyPinSHA256
    )
    pairingID = try container.decode(String.self, forKey: .pairingID)
    grantedScopes = Set(
      try container.decode([String].self, forKey: .grantedScopes)
    )
    pairedAt = Date(
      timeIntervalSince1970: Double(
        try container.decode(Int64.self, forKey: .pairedAtMilliseconds)
      ) / 1_000
    )
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(brokerID, forKey: .brokerID)
    try container.encode(endpoint, forKey: .endpoint)
    try container.encode(
      tlsPublicKeyPinSHA256,
      forKey: .tlsPublicKeyPinSHA256
    )
    try container.encode(pairingID, forKey: .pairingID)
    try container.encode(grantedScopes.sorted(), forKey: .grantedScopes)
    try container.encode(
      milliseconds(since1970: pairedAt),
      forKey: .pairedAtMilliseconds
    )
  }
}

protocol GlassesBrokerSecureStoring: AnyObject {
  func data(for account: String) throws -> Data?
  func set(_ data: Data, for account: String) throws
  func remove(account: String) throws
}

enum GlassesBrokerCredentialError: LocalizedError, Equatable {
  case keychain(OSStatus)
  case invalidStoredIdentity
  case invalidStoredPairing

  var errorDescription: String? {
    switch self {
    case .keychain:
      return "The iPhone could not access the protected VisionClaw identity."
    case .invalidStoredIdentity:
      return "The protected VisionClaw phone identity is invalid."
    case .invalidStoredPairing:
      return "The protected VisionClaw broker pairing is invalid."
    }
  }
}

final class GlassesBrokerKeychainStore: GlassesBrokerSecureStoring {
  private let service: String

  init(service: String) {
    self.service = service
  }

  func data(for account: String) throws -> Data? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data else {
      throw GlassesBrokerCredentialError.keychain(status)
    }
    return data
  }

  func set(_ data: Data, for account: String) throws {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    let values: [String: Any] = [
      kSecValueData as String: data,
      kSecAttrAccessible as String:
        kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    let update = SecItemUpdate(query as CFDictionary, values as CFDictionary)
    if update == errSecSuccess { return }
    guard update == errSecItemNotFound else {
      throw GlassesBrokerCredentialError.keychain(update)
    }
    var insertion = query
    insertion.merge(values) { _, new in new }
    let add = SecItemAdd(insertion as CFDictionary, nil)
    guard add == errSecSuccess else {
      throw GlassesBrokerCredentialError.keychain(add)
    }
  }

  func remove(account: String) throws {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw GlassesBrokerCredentialError.keychain(status)
    }
  }
}

final class GlassesBrokerCredentialVault {
  private let secureStore: GlassesBrokerSecureStoring
  private let identityAccount: String
  private let pairingAccount: String
  private let lock = NSLock()

  init(
    secureStore: GlassesBrokerSecureStoring,
    namespace: String = "visionclaw.glasses-broker.v1"
  ) {
    self.secureStore = secureStore
    identityAccount = "\(namespace).phone-p256-private-key"
    pairingAccount = "\(namespace).paired-broker"
  }

  convenience init() {
    let service = "\(Bundle.main.bundleIdentifier ?? "VisionClaw").glasses-broker"
    self.init(secureStore: GlassesBrokerKeychainStore(service: service))
  }

  func phonePublicKeyDER() throws -> Data {
    try withLock {
      try phonePrivateKeyLocked().publicKey.derRepresentation
    }
  }

  func sign(_ data: Data) throws -> Data {
    try withLock {
      try phonePrivateKeyLocked().signature(for: data).derRepresentation
    }
  }

  func pairedBroker() throws -> GlassesBrokerPairedRecord? {
    try withLock {
      guard let data = try secureStore.data(for: pairingAccount) else {
        return nil
      }
      guard let record = try? JSONDecoder().decode(
        GlassesBrokerPairedRecord.self,
        from: data
      ),
      isValidPairedRecord(record) else {
        throw GlassesBrokerCredentialError.invalidStoredPairing
      }
      return record
    }
  }

  func savePairedBroker(_ record: GlassesBrokerPairedRecord) throws {
    guard isValidPairedRecord(record) else {
      throw GlassesBrokerCredentialError.invalidStoredPairing
    }
    try withLock {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      try secureStore.set(try encoder.encode(record), for: pairingAccount)
    }
  }

  func removePairedBroker() throws {
    try withLock {
      try secureStore.remove(account: pairingAccount)
    }
  }

  private func phonePrivateKeyLocked() throws -> P256.Signing.PrivateKey {
    if let stored = try secureStore.data(for: identityAccount) {
      guard let privateKey = try? P256.Signing.PrivateKey(
        rawRepresentation: stored
      ) else {
        throw GlassesBrokerCredentialError.invalidStoredIdentity
      }
      return privateKey
    }
    let privateKey = P256.Signing.PrivateKey()
    try secureStore.set(
      privateKey.rawRepresentation,
      for: identityAccount
    )
    return privateKey
  }

  private func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try body()
  }
}

struct GlassesHarnessInvokeRequest: Encodable, Equatable {
  let clientRequestID: String
  let harnessID: String
  let instruction: String
}

private struct GlassesBrokerEmptyRequest: Encodable {}

struct GlassesBrokerSessionStatus: Codable, Equatable {
  let brokerID: String
  let ready: Bool
  let version: String
}

enum GlassesBrokerOperationStatus: String, Codable, Equatable {
  case started
  case pending
  case streaming
  case completed
  case aborted
  case failed
  case cancelled
  case unchanged
  case reconciliationRequired
}

struct GlassesHarnessInvocationStarted: Codable, Equatable {
  let clientRequestID: String
  let message: String
  let operationID: String
  let status: GlassesBrokerOperationStatus
}

struct GlassesHarnessOperationUpdate: Codable, Equatable {
  let error: String?
  let operationID: String
  let response: String?
  let sequence: Int
  let status: GlassesBrokerOperationStatus
}

struct GlassesHarnessCancellation: Codable, Equatable {
  let operationID: String
  let status: GlassesBrokerOperationStatus
}

struct GlassesCodexTaskSummary: Codable, Equatable {
  let preview: String
  let status: String
  let taskReference: String
  let title: String
  let updatedAt: Int64?
  let workspace: String?
}

struct GlassesCodexPreparedAction: Codable, Equatable {
  let actionID: String
  let clientRequestID: String
  let confirmationNonce: String
  let expiresAt: Int64
  let taskReference: String
  let taskTitle: String
  let workspace: String?

  init(
    actionID: String,
    clientRequestID: String,
    confirmationNonce: String,
    expiresAt: Int64,
    taskReference: String,
    taskTitle: String = "Untitled Codex task",
    workspace: String? = nil
  ) {
    self.actionID = actionID
    self.clientRequestID = clientRequestID
    self.confirmationNonce = confirmationNonce
    self.expiresAt = expiresAt
    self.taskReference = taskReference
    self.taskTitle = taskTitle
    self.workspace = workspace
  }
}

struct GlassesCodexContinuationReceipt: Codable, Equatable {
  let acceptedAt: Int64
  let forkedTaskReference: String
  let status: String
  let turnReference: String
}

struct GlassesCodexCancellation: Codable, Equatable {
  let cancelled: Bool
  let status: GlassesBrokerOperationStatus
}

enum GlassesCodexActionState: String, Codable, Equatable {
  case prepared
  case validating
  case committing
  case forkDispatching = "fork-dispatching"
  case forkRecoveryRequired = "fork-recovery-required"
  case forked
  case turnStarting = "turn-starting"
  case turnRecoveryRequired = "turn-recovery-required"
  case completed
  case cancelled
  case stale
  case expired
}

struct GlassesCodexOperationStatus: Codable, Equatable {
  let receipt: GlassesCodexContinuationReceipt?
  let state: GlassesCodexActionState
}

enum GlassesBrokerConnectionError: LocalizedError, Equatable {
  case notPaired
  case alreadyPaired
  case pairingExpired
  case brokerIdentityChanged
  case missingScope(String)
  case randomGenerationFailed
  case invalidRequest
  case invalidResponse
  case http(status: Int, code: String, message: String)

  var errorDescription: String? {
    switch self {
    case .notPaired:
      return "Pair VisionClaw with the Mac broker first."
    case .alreadyPaired:
      return "Forget the current Mac pairing before pairing another Mac."
    case .pairingExpired:
      return "The broker pairing offer expired. Create a new one on the Mac."
    case .brokerIdentityChanged:
      return "The broker identity did not match the pairing offer."
    case .missingScope:
      return "This iPhone pairing does not allow that broker action."
    case .randomGenerationFailed:
      return "The iPhone could not securely prepare the broker request."
    case .invalidRequest:
      return "The broker request is invalid."
    case .invalidResponse:
      return "The broker returned an invalid response."
    case .http(_, _, let message):
      return message
    }
  }
}

@MainActor
final class GlassesBrokerConnection {
  private let credentialVault: GlassesBrokerCredentialVault
  private let transport: SecureBrokerTransporting
  private let now: () -> Date
  private let nonce: () throws -> Data

  init(
    credentialVault: GlassesBrokerCredentialVault =
      GlassesBrokerCredentialVault(),
    transport: SecureBrokerTransporting = SecureBrokerTransport(),
    now: @escaping () -> Date = Date.init,
    nonce: @escaping () throws -> Data = {
      var bytes = Data(count: 18)
      let status: OSStatus = bytes.withUnsafeMutableBytes { buffer in
        guard let address = buffer.baseAddress else {
          return errSecParam
        }
        return SecRandomCopyBytes(
          kSecRandomDefault,
          buffer.count,
          address
        )
      }
      guard status == errSecSuccess else {
        throw GlassesBrokerConnectionError.randomGenerationFailed
      }
      return bytes
    }
  ) {
    self.credentialVault = credentialVault
    self.transport = transport
    self.now = now
    self.nonce = nonce
  }

  var pairedBroker: GlassesBrokerPairedRecord? {
    get throws {
      try credentialVault.pairedBroker()
    }
  }

  func checkPairedStatus() async throws -> GlassesBrokerSessionStatus {
    try Task.checkCancellation()
    guard let record = try credentialVault.pairedBroker() else {
      throw GlassesBrokerConnectionError.notPaired
    }
    let body = try GlassesBrokerCanonicalJSON.encode(
      GlassesBrokerEmptyRequest()
    )
    let status: GlassesBrokerSessionStatus = try await postSigned(
      record: record,
      path: "/v1/session/status",
      bodyData: body,
      authorization: nil,
      expectedStatus: 200,
      allowedResponseKeys: ["brokerID", "ready", "version"],
      timeoutInterval: 2
    )
    guard status.brokerID == record.brokerID,
          status.ready,
          !status.version.isEmpty,
          status.version.count <= 32 else {
      throw GlassesBrokerConnectionError.invalidResponse
    }
    return status
  }

  func completePairing(
    offer: GlassesBrokerPairingOffer,
    deviceName: String
  ) async throws -> GlassesBrokerPairedRecord {
    try Task.checkCancellation()
    guard try credentialVault.pairedBroker() == nil else {
      throw GlassesBrokerConnectionError.alreadyPaired
    }
    guard offer.expiresAt > now() else {
      throw GlassesBrokerConnectionError.pairingExpired
    }
    let safeName = try boundedText(deviceName, maximum: 80)
    let body = PairingCompletionRequest(
      deviceName: safeName,
      pairingSecret: offer.pairingSecret,
      phonePublicKeyDER:
        try credentialVault.phonePublicKeyDER().glassesBrokerBase64URLString()
    )
    let response: PairingCompletionResponse = try await postUnprotected(
      endpoint: offer.endpoint,
      path: "/v1/pairing/complete",
      pin: .publicKeySHA256(offer.tlsPublicKeyPinSHA256),
      body: body,
      expectedStatus: 201,
      allowedResponseKeys: [
        "brokerID", "grantedScopes", "pairedAt", "pairingID",
      ]
    )
    guard response.brokerID == offer.brokerID else {
      throw GlassesBrokerConnectionError.brokerIdentityChanged
    }
    let record = GlassesBrokerPairedRecord(
      brokerID: response.brokerID,
      endpoint: offer.endpoint,
      tlsPublicKeyPinSHA256: offer.tlsPublicKeyPinSHA256,
      pairingID: response.pairingID,
      grantedScopes: Set(response.grantedScopes),
      pairedAt: Date(
        timeIntervalSince1970: Double(response.pairedAt) / 1_000
      )
    )
    guard isValidPairedRecord(record) else {
      throw GlassesBrokerConnectionError.invalidResponse
    }
    try credentialVault.savePairedBroker(record)
    return record
  }

  func invokeHarness(
    harnessID: String,
    instruction: String,
    clientRequestID: String
  ) async throws -> GlassesHarnessInvocationStarted {
    let body = GlassesHarnessInvokeRequest(
      clientRequestID: try identifier(clientRequestID),
      harnessID: try identifier(harnessID),
      instruction: try boundedText(instruction, maximum: 4_000)
    )
    return try await postProtected(
      route: .harnessInvoke,
      body: body,
      allowedResponseKeys: [
        "clientRequestID", "message", "operationID", "status",
      ]
    )
  }

  func pollHarness(
    operationID: String,
    afterSequence: Int
  ) async throws -> GlassesHarnessOperationUpdate {
    guard (0...1_000_000_000).contains(afterSequence) else {
      throw GlassesBrokerConnectionError.invalidRequest
    }
    return try await postProtected(
      route: .harnessPoll,
      body: HarnessPollRequest(
        afterSequence: afterSequence,
        operationID: try identifier(operationID)
      ),
      allowedResponseKeys: [
        "error", "operationID", "response", "sequence", "status",
      ]
    )
  }

  func cancelHarness(
    operationID: String,
    clientRequestID: String
  ) async throws -> GlassesHarnessCancellation {
    try await postProtected(
      route: .harnessCancel,
      body: HarnessCancelRequest(
        clientRequestID: try identifier(clientRequestID),
        operationID: try identifier(operationID)
      ),
      allowedResponseKeys: ["operationID", "status"]
    )
  }

  func listCodexTasks(limit: Int = 10) async throws
    -> [GlassesCodexTaskSummary]
  {
    guard (1...20).contains(limit) else {
      throw GlassesBrokerConnectionError.invalidRequest
    }
    let response: CodexTaskListResponse = try await postProtected(
      route: .codexList,
      body: CodexListRequest(limit: limit),
      allowedResponseKeys: ["tasks"]
    )
    return response.tasks
  }

  func readCodexTask(
    taskReference: String
  ) async throws -> GlassesCodexTaskSummary {
    try await postProtected(
      route: .codexRead,
      body: CodexTaskReferenceRequest(
        taskReference: try identifier(taskReference)
      ),
      allowedResponseKeys: [
        "preview", "status", "taskReference", "title", "updatedAt",
        "workspace",
      ]
    )
  }

  func codexTaskStatus(
    taskReference: String
  ) async throws -> GlassesCodexTaskSummary {
    try await postProtected(
      route: .codexStatus,
      body: CodexTaskReferenceRequest(
        taskReference: try identifier(taskReference)
      ),
      allowedResponseKeys: [
        "preview", "status", "taskReference", "title", "updatedAt",
        "workspace",
      ]
    )
  }

  func prepareCodexContinuation(
    taskReference: String,
    instruction: String,
    clientRequestID: String
  ) async throws -> GlassesCodexPreparedAction {
    let requestedTaskReference = try identifier(taskReference)
    let requestedClientRequestID = try identifier(clientRequestID)
    let requestedInstruction = try boundedText(
      instruction,
      maximum: 4_000
    )
    let prepared: GlassesCodexPreparedAction = try await postProtected(
      route: .codexPrepare,
      body: CodexPrepareRequest(
        clientRequestID: requestedClientRequestID,
        instruction: requestedInstruction,
        taskReference: requestedTaskReference
      ),
      allowedResponseKeys: [
        "actionID", "clientRequestID", "confirmationNonce", "expiresAt",
        "taskReference", "taskTitle", "workspace",
      ]
    )
    guard isIdentifier(prepared.actionID),
          isIdentifier(prepared.clientRequestID),
          isIdentifier(prepared.confirmationNonce),
          isIdentifier(prepared.taskReference),
          prepared.clientRequestID == requestedClientRequestID,
          prepared.taskReference == requestedTaskReference,
          prepared.expiresAt > 0,
          isSafeBrokerDisplayText(prepared.taskTitle, maximum: 160),
          prepared.workspace.map({
            isSafeBrokerDisplayText($0, maximum: 160)
          }) ?? true else {
      throw GlassesBrokerConnectionError.invalidResponse
    }
    return prepared
  }

  func commitCodexContinuation(
    actionID: String,
    confirmationNonce: String,
    clientRequestID: String
  ) async throws -> GlassesCodexContinuationReceipt {
    try await postProtected(
      route: .codexCommit,
      body: CodexCommitRequest(
        actionID: try identifier(actionID),
        clientRequestID: try identifier(clientRequestID),
        confirmationNonce: try identifier(confirmationNonce)
      ),
      allowedResponseKeys: [
        "acceptedAt", "forkedTaskReference", "status", "turnReference",
      ]
    )
  }

  func cancelCodexContinuation(
    actionID: String,
    clientRequestID: String
  ) async throws -> GlassesCodexCancellation {
    try await postProtected(
      route: .codexCancel,
      body: CodexCancelRequest(
        actionID: try identifier(actionID),
        clientRequestID: try identifier(clientRequestID)
      ),
      allowedResponseKeys: ["cancelled", "status"]
    )
  }

  func codexOperationStatus(
    actionID: String,
    clientRequestID: String
  ) async throws -> GlassesCodexOperationStatus {
    try await postProtected(
      route: .codexOperationStatus,
      body: CodexActionRequest(
        actionID: try identifier(actionID),
        clientRequestID: try identifier(clientRequestID)
      ),
      allowedResponseKeys: ["receipt", "state"]
    )
  }

  private func postProtected<Request: Encodable, Response: Decodable>(
    route: BrokerRoute,
    body: Request,
    allowedResponseKeys: Set<String>
  ) async throws -> Response {
    try Task.checkCancellation()
    guard let record = try credentialVault.pairedBroker() else {
      throw GlassesBrokerConnectionError.notPaired
    }
    guard record.grantedScopes.contains(route.scope) else {
      throw GlassesBrokerConnectionError.missingScope(route.scope)
    }
    let bodyData = try GlassesBrokerCanonicalJSON.encode(body)
    let capabilityBody = CapabilityRequest(
      bodyHash: Data(SHA256.hash(data: bodyData))
        .glassesBrokerBase64URLString(),
      method: "POST",
      path: route.path,
      scope: route.scope
    )
    let capability: CapabilityResponse = try await postSigned(
      record: record,
      path: "/v1/capabilities",
      bodyData: try GlassesBrokerCanonicalJSON.encode(capabilityBody),
      authorization: nil,
      expectedStatus: 201,
      allowedResponseKeys: ["capability"]
    )
    guard capability.capability.range(
      of: #"^[A-Za-z0-9._~-]{16,8192}$"#,
      options: .regularExpression
    ) != nil else {
      throw GlassesBrokerConnectionError.invalidResponse
    }
    return try await postSigned(
      record: record,
      path: route.path,
      bodyData: bodyData,
      authorization: "Bearer \(capability.capability)",
      expectedStatus: 200,
      allowedResponseKeys: allowedResponseKeys
    )
  }

  private func postUnprotected<Request: Encodable, Response: Decodable>(
    endpoint: URL,
    path: String,
    pin: GlassesBrokerTLSPin,
    body: Request,
    expectedStatus: Int,
    allowedResponseKeys: Set<String>
  ) async throws -> Response {
    let bodyData = try GlassesBrokerCanonicalJSON.encode(body)
    let request = try makeRequest(
      endpoint: endpoint,
      path: path,
      body: bodyData,
      authorization: nil,
      proofHeaders: [:]
    )
    let (data, response) = try await transport.data(
      for: request,
      expectedHost: try endpointHost(endpoint),
      pin: pin
    )
    return try decodeResponse(
      data: data,
      response: response,
      expectedStatus: expectedStatus,
      allowedKeys: allowedResponseKeys
    )
  }

  private func postSigned<Response: Decodable>(
    record: GlassesBrokerPairedRecord,
    path: String,
    bodyData: Data,
    authorization: String?,
    expectedStatus: Int,
    allowedResponseKeys: Set<String>,
    timeoutInterval: TimeInterval = 15
  ) async throws -> Response {
    let proofHeaders = try makeProofHeaders(
      pairingID: record.pairingID,
      path: path,
      body: bodyData
    )
    let request = try makeRequest(
      endpoint: record.endpoint,
      path: path,
      body: bodyData,
      authorization: authorization,
      proofHeaders: proofHeaders,
      timeoutInterval: timeoutInterval
    )
    let (data, response) = try await transport.data(
      for: request,
      expectedHost: try endpointHost(record.endpoint),
      pin: .publicKeySHA256(record.tlsPublicKeyPinSHA256)
    )
    return try decodeResponse(
      data: data,
      response: response,
      expectedStatus: expectedStatus,
      allowedKeys: allowedResponseKeys
    )
  }

  private func makeProofHeaders(
    pairingID: String,
    path: String,
    body: Data
  ) throws -> [String: String] {
    let nonceData = try nonce()
    guard nonceData.count >= 12, nonceData.count <= 64 else {
      throw GlassesBrokerConnectionError.invalidRequest
    }
    let nonceValue = nonceData.glassesBrokerBase64URLString()
    let timestamp = milliseconds(since1970: now())
    let proofRequest = GlassesBrokerDeviceProofRequest(
      bodyHash: Data(SHA256.hash(data: body))
        .glassesBrokerBase64URLString(),
      method: "POST",
      nonce: nonceValue,
      pairingID: pairingID,
      path: path,
      timestamp: timestamp
    )
    let signature = try credentialVault.sign(
      try GlassesBrokerCanonicalJSON.encode(proofRequest)
    )
    return [
      "X-VisionClaw-Device-Proof":
        signature.glassesBrokerBase64URLString(),
      "X-VisionClaw-Pairing-ID": pairingID,
      "X-VisionClaw-Proof-Nonce": nonceValue,
      "X-VisionClaw-Proof-Timestamp": String(timestamp),
    ]
  }

  private func makeRequest(
    endpoint: URL,
    path: String,
    body: Data,
    authorization: String?,
    proofHeaders: [String: String],
    timeoutInterval: TimeInterval = 15
  ) throws -> URLRequest {
    guard body.count <= 64 * 1024,
          (1...30).contains(timeoutInterval),
          path.hasPrefix("/v1/"),
          let url = brokerURL(endpoint: endpoint, path: path) else {
      throw GlassesBrokerConnectionError.invalidRequest
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpBody = body
    request.timeoutInterval = timeoutInterval
    request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    request.setValue(
      "application/json",
      forHTTPHeaderField: "Content-Type"
    )
    request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
    request.setValue(
      UUID().uuidString.lowercased(),
      forHTTPHeaderField: "X-Request-ID"
    )
    if let authorization {
      request.setValue(authorization, forHTTPHeaderField: "Authorization")
    }
    for (name, value) in proofHeaders {
      request.setValue(value, forHTTPHeaderField: name)
    }
    return request
  }

  private func decodeResponse<Response: Decodable>(
    data: Data,
    response: HTTPURLResponse,
    expectedStatus: Int,
    allowedKeys: Set<String>
  ) throws -> Response {
    guard data.count <= 64 * 1024,
          response.mimeType?.lowercased() == "application/json" else {
      throw GlassesBrokerConnectionError.invalidResponse
    }
    guard response.statusCode == expectedStatus else {
      throw safeHTTPError(data: data, status: response.statusCode)
    }
    let object: Any
    do {
      object = try JSONSerialization.jsonObject(with: data)
    } catch {
      throw GlassesBrokerConnectionError.invalidResponse
    }
    guard let dictionary = object as? [String: Any],
          Set(dictionary.keys).isSubset(of: allowedKeys),
          let canonical = try? JSONSerialization.data(
            withJSONObject: dictionary,
            options: [.sortedKeys, .withoutEscapingSlashes]
          ),
          canonical == data,
          let result = try? JSONDecoder().decode(Response.self, from: data)
    else {
      throw GlassesBrokerConnectionError.invalidResponse
    }
    return result
  }

  private func safeHTTPError(
    data: Data,
    status: Int
  ) -> GlassesBrokerConnectionError {
    guard let envelope = try? JSONDecoder().decode(
      BrokerErrorEnvelope.self,
      from: data
    ),
    envelope.error.code.range(
      of: #"^[a-z][a-z0-9_]{1,63}$"#,
      options: .regularExpression
    ) != nil,
    envelope.error.message.count <= 300,
    !hasUnsafeControlCharacters(envelope.error.message) else {
      return .http(
        status: status,
        code: "broker_error",
        message: "The paired broker could not complete the request."
      )
    }
    return .http(
      status: status,
      code: envelope.error.code,
      message: envelope.error.message
    )
  }
}

private enum BrokerRoute {
  case harnessInvoke
  case harnessPoll
  case harnessCancel
  case codexList
  case codexRead
  case codexStatus
  case codexPrepare
  case codexCommit
  case codexCancel
  case codexOperationStatus

  var path: String {
    switch self {
    case .harnessInvoke: return "/v1/harness/invoke"
    case .harnessPoll: return "/v1/harness/poll"
    case .harnessCancel: return "/v1/harness/cancel"
    case .codexList: return "/v1/codex/list"
    case .codexRead: return "/v1/codex/read"
    case .codexStatus: return "/v1/codex/status"
    case .codexPrepare: return "/v1/codex/prepare"
    case .codexCommit: return "/v1/codex/commit"
    case .codexCancel: return "/v1/codex/cancel"
    case .codexOperationStatus: return "/v1/codex/operation-status"
    }
  }

  var scope: String {
    switch self {
    case .harnessInvoke: return "harness:invoke"
    case .harnessPoll: return "harness:read"
    case .harnessCancel: return "harness:cancel"
    case .codexList: return "tasks:list"
    case .codexRead: return "tasks:read"
    case .codexStatus: return "tasks:status"
    case .codexPrepare: return "tasks:continue"
    case .codexCommit: return "tasks:continue:commit"
    case .codexCancel: return "tasks:cancel"
    case .codexOperationStatus: return "tasks:operation:status"
    }
  }
}

private struct PairingCompletionRequest: Encodable {
  let deviceName: String
  let pairingSecret: String
  let phonePublicKeyDER: String
}

private struct PairingCompletionResponse: Decodable {
  let brokerID: String
  let grantedScopes: [String]
  let pairedAt: Int64
  let pairingID: String
}

private struct CapabilityRequest: Encodable {
  let bodyHash: String
  let method: String
  let path: String
  let scope: String
}

private struct CapabilityResponse: Decodable {
  let capability: String
}

private struct HarnessPollRequest: Encodable {
  let afterSequence: Int
  let operationID: String
}

private struct HarnessCancelRequest: Encodable {
  let clientRequestID: String
  let operationID: String
}

private struct CodexListRequest: Encodable {
  let limit: Int
}

private struct CodexTaskListResponse: Decodable {
  let tasks: [GlassesCodexTaskSummary]
}

private struct CodexTaskReferenceRequest: Encodable {
  let taskReference: String
}

private struct CodexPrepareRequest: Encodable {
  let clientRequestID: String
  let instruction: String
  let taskReference: String
}

private struct CodexCommitRequest: Encodable {
  let actionID: String
  let clientRequestID: String
  let confirmationNonce: String
}

private struct CodexCancelRequest: Encodable {
  let actionID: String
  let clientRequestID: String
}

private struct CodexActionRequest: Encodable {
  let actionID: String
  let clientRequestID: String
}

private struct BrokerErrorEnvelope: Decodable {
  struct SafeError: Decodable {
    let code: String
    let message: String
  }

  let error: SafeError
  let requestID: String?
}

private func brokerURL(endpoint: URL, path: String) -> URL? {
  guard isSafeBrokerEndpoint(endpoint),
        var components = URLComponents(
          url: endpoint,
          resolvingAgainstBaseURL: false
        ) else {
    return nil
  }
  components.path = path
  return components.url
}

private func endpointHost(_ endpoint: URL) throws -> String {
  guard isSafeBrokerEndpoint(endpoint), let host = endpoint.host else {
    throw GlassesBrokerConnectionError.invalidRequest
  }
  return host
}

private func isSafeBrokerEndpoint(_ endpoint: URL) -> Bool {
  guard endpoint.scheme?.lowercased() == "https",
        let host = endpoint.host,
        isRFC1918IPv4Address(host),
        endpoint.user == nil,
        endpoint.password == nil,
        endpoint.query == nil,
        endpoint.fragment == nil,
        endpoint.path.isEmpty || endpoint.path == "/" else {
    return false
  }
  return true
}

private func isRFC1918IPv4Address(_ host: String) -> Bool {
  let components = host.split(separator: ".", omittingEmptySubsequences: false)
  guard components.count == 4 else { return false }

  var octets: [UInt8] = []
  octets.reserveCapacity(4)
  for component in components {
    guard !component.isEmpty,
          component.allSatisfy(\.isNumber),
          component.count == 1 || component.first != "0",
          let value = UInt8(component) else {
      return false
    }
    octets.append(value)
  }

  return octets[0] == 10
    || (octets[0] == 172 && (16...31).contains(octets[1]))
    || (octets[0] == 192 && octets[1] == 168)
}

private func isValidPairedRecord(
  _ record: GlassesBrokerPairedRecord
) -> Bool {
  isBrokerID(record.brokerID)
    && isSafeBrokerEndpoint(record.endpoint)
    && record.tlsPublicKeyPinSHA256.count == SHA256.byteCount
    && isIdentifier(record.pairingID)
    && record.grantedScopes.count <= 32
    && record.grantedScopes.allSatisfy {
      $0.range(
        of: #"^[a-z][a-z0-9:-]{1,63}$"#,
        options: .regularExpression
      ) != nil
    }
    && record.pairedAt.timeIntervalSince1970 > 0
}

private func isBrokerID(_ value: String) -> Bool {
  value.range(
    of: #"^broker_[A-Za-z0-9_-]{32,128}$"#,
    options: .regularExpression
  ) != nil
}

private func isPairingSecret(_ value: String) -> Bool {
  value.range(
    of: #"^[A-Za-z0-9_-]{40,256}$"#,
    options: .regularExpression
  ) != nil
}

private func isIdentifier(_ value: String) -> Bool {
  value.range(
    of: #"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$"#,
    options: .regularExpression
  ) != nil
}

private func identifier(_ value: String) throws -> String {
  guard isIdentifier(value) else {
    throw GlassesBrokerConnectionError.invalidRequest
  }
  return value
}

private func boundedText(
  _ value: String,
  maximum: Int
) throws -> String {
  let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !result.isEmpty,
        result.count <= maximum,
        !hasUnsafeControlCharacters(result) else {
    throw GlassesBrokerConnectionError.invalidRequest
  }
  return result
}

private func isSafeBrokerDisplayText(
  _ value: String,
  maximum: Int
) -> Bool {
  let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
  return !trimmed.isEmpty
    && trimmed == value
    && value.count <= maximum
    && !hasUnsafeBrokerDisplayScalars(value)
}

private func hasUnsafeBrokerDisplayScalars(_ value: String) -> Bool {
  value.unicodeScalars.contains { scalar in
    let codePoint = scalar.value
    if codePoint <= 0x1f || (0x7f...0x9f).contains(codePoint) {
      return true
    }
    switch scalar.properties.generalCategory {
    case .control, .format, .lineSeparator, .paragraphSeparator:
      return true
    default:
      return false
    }
  }
}

private func hasUnsafeControlCharacters(_ value: String) -> Bool {
  value.unicodeScalars.contains {
    ($0.value <= 0x1f && $0.value != 0x09 && $0.value != 0x0a)
      || $0.value == 0x7f
  }
}

private func milliseconds(since1970 date: Date) -> Int64 {
  Int64((date.timeIntervalSince1970 * 1_000).rounded(.down))
}

private extension Data {
  init?(strictLowercaseHex value: String) {
    guard value.count.isMultiple(of: 2),
          value.range(
            of: #"^[a-f0-9]+$"#,
            options: .regularExpression
          ) != nil else {
      return nil
    }
    var bytes = Data()
    bytes.reserveCapacity(value.count / 2)
    var index = value.startIndex
    while index < value.endIndex {
      let next = value.index(index, offsetBy: 2)
      guard let byte = UInt8(value[index..<next], radix: 16) else {
        return nil
      }
      bytes.append(byte)
      index = next
    }
    self = bytes
  }
}
