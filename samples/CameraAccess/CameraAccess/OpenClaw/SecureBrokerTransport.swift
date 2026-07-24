import CryptoKit
import Foundation
import Security

enum GlassesBrokerTLSPin: Equatable {
  case certificateSHA256(Data)
  case publicKeySHA256(Data)

  fileprivate var digest: Data {
    switch self {
    case .certificateSHA256(let digest),
         .publicKeySHA256(let digest):
      return digest
    }
  }
}

enum GlassesBrokerPinValidator {
  static func matches(
    pin: GlassesBrokerTLSPin,
    leafCertificateDER: Data,
    leafPublicKeyDER: Data
  ) -> Bool {
    let actual: Data
    switch pin {
    case .certificateSHA256:
      actual = Data(SHA256.hash(data: leafCertificateDER))
    case .publicKeySHA256:
      actual = Data(SHA256.hash(data: leafPublicKeyDER))
    }
    return constantTimeEqual(actual, pin.digest)
  }

  private static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
    guard lhs.count == rhs.count else { return false }
    var difference: UInt8 = 0
    for (left, right) in zip(lhs, rhs) {
      difference |= left ^ right
    }
    return difference == 0
  }
}

protocol SecureBrokerTransporting: AnyObject {
  func data(
    for request: URLRequest,
    expectedHost: String,
    pin: GlassesBrokerTLSPin
  ) async throws -> (Data, HTTPURLResponse)
}

enum SecureBrokerTransportError: LocalizedError, Equatable {
  case invalidEndpoint
  case invalidPin
  case nonHTTPResponse
  case oversizedResponse

  var errorDescription: String? {
    switch self {
    case .invalidEndpoint:
      return "The paired broker endpoint is invalid."
    case .invalidPin:
      return "The paired broker identity is invalid."
    case .nonHTTPResponse:
      return "The paired broker returned an invalid response."
    case .oversizedResponse:
      return "The paired broker response exceeded the safe size limit."
    }
  }
}

/// A one-request HTTPS transport. The broker's QR/public pairing record is the
/// trust root; system CA or hostname validation alone never authorizes a peer.
final class SecureBrokerTransport: SecureBrokerTransporting {
  static let maximumResponseBytes = 64 * 1024

  private let configurationFactory: () -> URLSessionConfiguration

  init(
    configurationFactory: @escaping () -> URLSessionConfiguration = {
      URLSessionConfiguration.ephemeral
    }
  ) {
    self.configurationFactory = configurationFactory
  }

  func data(
    for request: URLRequest,
    expectedHost: String,
    pin: GlassesBrokerTLSPin
  ) async throws -> (Data, HTTPURLResponse) {
    try Task.checkCancellation()
    guard pin.digest.count == SHA256.byteCount else {
      throw SecureBrokerTransportError.invalidPin
    }
    guard request.url?.scheme?.lowercased() == "https",
          normalizedHost(request.url?.host) == normalizedHost(expectedHost),
          !expectedHost.isEmpty else {
      throw SecureBrokerTransportError.invalidEndpoint
    }

    let configuration = configurationFactory()
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    configuration.timeoutIntervalForRequest = 15
    configuration.timeoutIntervalForResource = 20
    configuration.waitsForConnectivity = false
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.httpMaximumConnectionsPerHost = 2

    let delegate = SecureBrokerURLSessionDelegate(
      expectedHost: expectedHost,
      pin: pin
    )
    let session = URLSession(
      configuration: configuration,
      delegate: delegate,
      delegateQueue: nil
    )
    defer {
      session.finishTasksAndInvalidate()
    }

    let (data, response) = try await session.data(for: request)
    try Task.checkCancellation()
    guard data.count <= Self.maximumResponseBytes else {
      throw SecureBrokerTransportError.oversizedResponse
    }
    guard let http = response as? HTTPURLResponse else {
      throw SecureBrokerTransportError.nonHTTPResponse
    }
    return (data, http)
  }
}

private final class SecureBrokerURLSessionDelegate: NSObject,
  URLSessionDelegate, URLSessionTaskDelegate
{
  private let expectedHost: String
  private let pin: GlassesBrokerTLSPin

  init(expectedHost: String, pin: GlassesBrokerTLSPin) {
    self.expectedHost = expectedHost
    self.pin = pin
  }

  func urlSession(
    _ session: URLSession,
    didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (
      URLSession.AuthChallengeDisposition,
      URLCredential?
    ) -> Void
  ) {
    guard challenge.protectionSpace.authenticationMethod
            == NSURLAuthenticationMethodServerTrust,
          normalizedHost(challenge.protectionSpace.host)
            == normalizedHost(expectedHost),
          let trust = challenge.protectionSpace.serverTrust,
          let identity = Self.leafIdentity(from: trust),
          GlassesBrokerPinValidator.matches(
            pin: pin,
            leafCertificateDER: identity.certificateDER,
            leafPublicKeyDER: identity.publicKeyDER
          ) else {
      completionHandler(.cancelAuthenticationChallenge, nil)
      return
    }

    completionHandler(.useCredential, URLCredential(trust: trust))
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }

  private static func leafIdentity(
    from trust: SecTrust
  ) -> (certificateDER: Data, publicKeyDER: Data)? {
    guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
          let leaf = chain.first,
          let key = SecCertificateCopyKey(leaf) else {
      return nil
    }
    let certificateDER = SecCertificateCopyData(leaf) as Data
    var error: Unmanaged<CFError>?
    guard let external = SecKeyCopyExternalRepresentation(key, &error) as Data?
    else {
      return nil
    }

    let publicKeyDER: Data
    if let key = try? P256.Signing.PublicKey(
      x963Representation: external
    ) {
      publicKeyDER = key.derRepresentation
    } else if let key = try? P256.Signing.PublicKey(
      derRepresentation: external
    ) {
      publicKeyDER = key.derRepresentation
    } else {
      return nil
    }
    return (certificateDER, publicKeyDER)
  }
}

enum GlassesBrokerCanonicalJSON {
  static func encode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
  }
}

struct GlassesBrokerDeviceProofRequest: Encodable, Equatable {
  let bodyHash: String
  let method: String
  let nonce: String
  let pairingID: String
  let path: String
  let timestamp: Int64
}

extension Data {
  func glassesBrokerBase64URLString() -> String {
    base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  init?(glassesBrokerStrictBase64URL value: String) {
    guard !value.isEmpty,
          value.count <= 16 * 1024,
          value.range(
            of: #"^[A-Za-z0-9_-]+$"#,
            options: .regularExpression
          ) != nil else {
      return nil
    }
    var standard = value
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    standard += String(
      repeating: "=",
      count: (4 - standard.count % 4) % 4
    )
    guard let decoded = Data(base64Encoded: standard),
          decoded.glassesBrokerBase64URLString() == value else {
      return nil
    }
    self = decoded
  }
}

private func normalizedHost(_ host: String?) -> String {
  (host ?? "")
    .trimmingCharacters(in: .whitespacesAndNewlines)
    .lowercased()
    .trimmingCharacters(in: CharacterSet(charactersIn: "."))
}
