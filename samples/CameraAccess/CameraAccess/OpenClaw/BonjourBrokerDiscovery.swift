import Combine
import CryptoKit
import Foundation
import Network

/// A bounded, untrusted snapshot made from a Bonjour browser result.
///
/// None of these fields prove the identity of a broker. They are suitable only
/// for presenting a pairing candidate to the user.
struct BonjourBrokerRawCandidate: Equatable, Sendable {
  let stableID: String
  let serviceName: String
  let endpointDescription: String
  let brokerIDHint: String?
  let versionHint: String?
  let tlsHint: String?

  init(
    stableID: String,
    serviceName: String,
    endpointDescription: String,
    brokerIDHint: String?,
    versionHint: String?,
    tlsHint: String?
  ) {
    self.stableID = BonjourBrokerDiscoveryPolicy.boundedString(
      stableID,
      maximumUTF8Bytes: BonjourBrokerDiscoveryPolicy.maximumStableIDBytes
    )
    self.serviceName = BonjourBrokerDiscoveryPolicy.boundedDisplayString(
      serviceName,
      maximumUTF8Bytes: BonjourBrokerDiscoveryPolicy.maximumServiceNameBytes
    )
    self.endpointDescription =
      BonjourBrokerDiscoveryPolicy.boundedDisplayString(
        endpointDescription,
        maximumUTF8Bytes:
          BonjourBrokerDiscoveryPolicy.maximumEndpointDescriptionBytes
      )
    self.brokerIDHint = brokerIDHint.map {
      BonjourBrokerDiscoveryPolicy.boundedDisplayString(
        $0,
        maximumUTF8Bytes: BonjourBrokerDiscoveryPolicy.maximumBrokerIDHintBytes
      )
    }
    self.versionHint = versionHint.map {
      BonjourBrokerDiscoveryPolicy.boundedDisplayString(
        $0,
        maximumUTF8Bytes: BonjourBrokerDiscoveryPolicy.maximumTXTValueBytes
      )
    }
    self.tlsHint = tlsHint.map {
      BonjourBrokerDiscoveryPolicy.boundedDisplayString(
        $0,
        maximumUTF8Bytes: BonjourBrokerDiscoveryPolicy.maximumTXTValueBytes
      )
    }
  }
}

/// A Bonjour result that can be shown in the pairing UI.
///
/// Bonjour is discovery, not authentication. These properties deliberately
/// cannot be promoted to trusted state by any TXT record or endpoint value.
struct BonjourBrokerCandidate: Identifiable, Equatable, Sendable {
  let stableID: String
  let serviceName: String
  let endpointDescription: String
  let brokerIDHint: String?
  let versionHint: String?
  let tlsHint: String?

  var id: String { stableID }
  var isAuthenticated: Bool { false }
  var isTrusted: Bool { false }

  fileprivate init(raw: BonjourBrokerRawCandidate) {
    stableID = raw.stableID
    serviceName = raw.serviceName
    endpointDescription = raw.endpointDescription
    brokerIDHint = raw.brokerIDHint
    versionHint = raw.versionHint
    tlsHint = raw.tlsHint
  }
}

enum BonjourBrokerDiscoveryPolicy {
  static let defaultCandidateLimit = 16
  static let maximumCandidateLimit = 64
  static let maximumRawResultsToInspect = 128

  static let maximumTXTRecordBytes = 2_048
  static let maximumStableIDBytes = 96
  static let maximumServiceNameBytes = 128
  static let maximumEndpointDescriptionBytes = 512
  static let maximumBrokerIDHintBytes = 160
  static let maximumTXTValueBytes = 32

  /// Deduplicates by a stable, bounded identity and returns a deterministic,
  /// capped list. The first occurrence wins, but no discovery hint gains trust.
  static func boundedCandidates(
    from rawCandidates: [BonjourBrokerRawCandidate],
    limit requestedLimit: Int = defaultCandidateLimit
  ) -> [BonjourBrokerCandidate] {
    guard requestedLimit > 0 else { return [] }
    let limit = min(requestedLimit, maximumCandidateLimit)
    var unique: [String: BonjourBrokerCandidate] = [:]

    for raw in rawCandidates.prefix(maximumRawResultsToInspect) {
      guard !raw.stableID.isEmpty, unique[raw.stableID] == nil else {
        continue
      }
      unique[raw.stableID] = BonjourBrokerCandidate(raw: raw)
    }

    return unique.values
      .sorted {
        if $0.serviceName != $1.serviceName {
          return $0.serviceName.localizedStandardCompare($1.serviceName)
            == .orderedAscending
        }
        return $0.stableID < $1.stableID
      }
      .prefix(limit)
      .map { $0 }
  }

  static func rawCandidate(
    from result: NWBrowser.Result
  ) -> BonjourBrokerRawCandidate {
    let endpointDescription = boundedDisplayString(
      result.endpoint.debugDescription,
      maximumUTF8Bytes: maximumEndpointDescriptionBytes
    )
    let serviceName: String
    switch result.endpoint {
    case .service(let name, _, _, _):
      serviceName = boundedDisplayString(
        name,
        maximumUTF8Bytes: maximumServiceNameBytes
      )
    default:
      serviceName = endpointDescription
    }

    let txtHints = boundedTXTHints(from: result.metadata)
    return BonjourBrokerRawCandidate(
      stableID: stableID(for: result.endpoint),
      serviceName: serviceName,
      endpointDescription: endpointDescription,
      brokerIDHint: txtHints["id"],
      versionHint: txtHints["v"],
      tlsHint: txtHints["tls"]
    )
  }

  static func boundedString(
    _ value: String,
    maximumUTF8Bytes: Int
  ) -> String {
    guard maximumUTF8Bytes > 0 else { return "" }
    let utf8 = value.utf8
    guard utf8.count > maximumUTF8Bytes else { return value }

    var bytes = Array(utf8.prefix(maximumUTF8Bytes))
    while !bytes.isEmpty {
      if let bounded = String(bytes: bytes, encoding: .utf8) {
        return bounded
      }
      bytes.removeLast()
    }
    return ""
  }

  static func boundedDisplayString(
    _ value: String,
    maximumUTF8Bytes: Int
  ) -> String {
    let safeScalars = value.unicodeScalars.map { scalar -> UnicodeScalar in
      CharacterSet.controlCharacters.contains(scalar) ? " " : scalar
    }
    return boundedString(
      String(String.UnicodeScalarView(safeScalars)),
      maximumUTF8Bytes: maximumUTF8Bytes
    )
  }

  private static func boundedTXTHints(
    from metadata: NWBrowser.Result.Metadata
  ) -> [String: String] {
    guard case .bonjour(let record) = metadata,
          record.data.count <= maximumTXTRecordBytes else {
      return [:]
    }

    var hints: [String: String] = [:]
    for key in ["id", "v", "tls"] {
      guard let value = record[key] else { continue }
      hints[key] = boundedDisplayString(
        value,
        maximumUTF8Bytes: key == "id"
          ? maximumBrokerIDHintBytes
          : maximumTXTValueBytes
      )
    }
    return hints
  }

  private static func stableID(for endpoint: NWEndpoint) -> String {
    let identity: String
    switch endpoint {
    case .service(let name, let type, let domain, let interface):
      identity = [
        name,
        type,
        domain,
        interface.map { String($0.index) } ?? "",
      ].joined(separator: "\u{001F}")
    default:
      identity = endpoint.debugDescription
    }

    let digest = SHA256.hash(data: Data(identity.utf8))
    return "bonjour-" + digest.map { String(format: "%02x", $0) }.joined()
  }
}

@MainActor
final class BonjourBrokerDiscovery: ObservableObject {
  enum State: Equatable, Sendable {
    case idle
    case browsing
    case ready
    case failed(String)
  }

  @Published private(set) var candidates: [BonjourBrokerCandidate] = []
  @Published private(set) var state: State = .idle

  var isBrowsing: Bool {
    browser != nil
  }

  private let candidateLimit: Int
  private let debounceNanoseconds: UInt64
  private let browserQueue: DispatchQueue
  private var browser: NWBrowser?
  private var runID: UUID?
  private var publishTask: Task<Void, Never>?

  init(
    candidateLimit: Int =
      BonjourBrokerDiscoveryPolicy.defaultCandidateLimit,
    debounceInterval: TimeInterval = 0.15
  ) {
    self.candidateLimit = max(
      1,
      min(
        candidateLimit,
        BonjourBrokerDiscoveryPolicy.maximumCandidateLimit
      )
    )
    let boundedDebounce = min(max(debounceInterval, 0.05), 1)
    debounceNanoseconds = UInt64(boundedDebounce * 1_000_000_000)
    browserQueue = DispatchQueue(
      label: "com.visionclaw.bonjour-broker-discovery",
      qos: .utility
    )
  }

  func start() {
    guard browser == nil else { return }

    let currentRunID = UUID()
    runID = currentRunID
    state = .browsing

    let parameters = NWParameters.tcp
    parameters.includePeerToPeer = true
    let browser = NWBrowser(
      for: .bonjourWithTXTRecord(
        type: "_visionclaw._tcp",
        domain: "local."
      ),
      using: parameters
    )
    self.browser = browser

    browser.stateUpdateHandler = { [weak self] browserState in
      Task { @MainActor [weak self] in
        self?.handle(
          browserState: browserState,
          for: currentRunID
        )
      }
    }
    browser.browseResultsChangedHandler = { [weak self] results, _ in
      let rawCandidates = results
        .prefix(BonjourBrokerDiscoveryPolicy.maximumRawResultsToInspect)
        .map(BonjourBrokerDiscoveryPolicy.rawCandidate(from:))
      Task { @MainActor [weak self] in
        self?.schedulePublish(
          rawCandidates,
          for: currentRunID
        )
      }
    }
    browser.start(queue: browserQueue)
  }

  func stop() {
    runID = nil
    publishTask?.cancel()
    publishTask = nil
    browser?.stateUpdateHandler = nil
    browser?.browseResultsChangedHandler = nil
    browser?.cancel()
    browser = nil
    candidates = []
    state = .idle
  }

  private func handle(
    browserState: NWBrowser.State,
    for callbackRunID: UUID
  ) {
    guard callbackRunID == runID, browser != nil else { return }

    switch browserState {
    case .setup, .waiting:
      state = .browsing
    case .ready:
      state = .ready
    case .failed(let error):
      publishTask?.cancel()
      publishTask = nil
      browser = nil
      runID = nil
      candidates = []
      state = .failed(
        BonjourBrokerDiscoveryPolicy.boundedDisplayString(
          error.localizedDescription,
          maximumUTF8Bytes: 256
        )
      )
    case .cancelled:
      publishTask?.cancel()
      publishTask = nil
      browser = nil
      runID = nil
      candidates = []
      state = .idle
    @unknown default:
      state = .browsing
    }
  }

  private func schedulePublish(
    _ rawCandidates: [BonjourBrokerRawCandidate],
    for callbackRunID: UUID
  ) {
    guard callbackRunID == runID, browser != nil else { return }

    publishTask?.cancel()
    let delay = debounceNanoseconds
    publishTask = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(nanoseconds: delay)
      } catch {
        return
      }
      guard let self,
            !Task.isCancelled,
            callbackRunID == self.runID,
            self.browser != nil else {
        return
      }

      let bounded = BonjourBrokerDiscoveryPolicy.boundedCandidates(
        from: rawCandidates,
        limit: self.candidateLimit
      )
      if bounded != self.candidates {
        self.candidates = bounded
      }
      self.publishTask = nil
    }
  }
}
