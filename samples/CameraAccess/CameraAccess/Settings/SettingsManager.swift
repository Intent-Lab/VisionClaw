import Foundation
import Security

final class SettingsManager {
  static let shared = SettingsManager()

  private enum RuntimeURL {
    static let adminBaseURL = "https://admin.embarcaderolabs.cloud"
    static let opsBaseURL = "https://admin.embarcaderolabs.cloud"
    static let signalBaseURL = "https://signal.embarcaderolabs.cloud"
  }

  private let defaults = UserDefaults.standard
  private let keychain = KeychainStore(
    service: Bundle.main.bundleIdentifier ?? "com.embarcaderolabs.visionclaw"
  )

  private enum Key: String {
    case deviceID
    case workerLoginCode
    case workerLoginCodeMigratedFromFastFoodDefault
    case workerEmail
    case workerAPIBearerToken
    case opsBaseURL
    case adminBaseURL
    case signalBaseURL
    case webrtcSignalingURL
    case speakerOutputEnabled
    case videoStreamingEnabled
    case videoStreamingDefaultMigratedToOnDemand
    case proactiveNotificationsEnabled
  }

  private init() {
    migrateOnDemandVideoDefaultIfNeeded()
  }

  private func migrateOnDemandVideoDefaultIfNeeded() {
    guard !defaults.bool(forKey: Key.videoStreamingDefaultMigratedToOnDemand.rawValue) else { return }
    if defaults.object(forKey: Key.videoStreamingEnabled.rawValue) != nil {
      defaults.set(false, forKey: Key.videoStreamingEnabled.rawValue)
    }
    defaults.set(true, forKey: Key.videoStreamingDefaultMigratedToOnDemand.rawValue)
  }

  // MARK: - Worker

  var deviceID: String {
    get {
      if let stored = defaults.string(forKey: Key.deviceID.rawValue), !stored.isEmpty {
        return stored
      }

      if !Secrets.deviceID.isEmpty, Secrets.deviceID != "YOUR_DEVICE_UUID" {
        defaults.set(Secrets.deviceID, forKey: Key.deviceID.rawValue)
        return Secrets.deviceID
      }

      let generated = UUID().uuidString
      defaults.set(generated, forKey: Key.deviceID.rawValue)
      return generated
    }
    set { defaults.set(newValue, forKey: Key.deviceID.rawValue) }
  }

  var workerLoginCode: String {
    get {
      if let stored = defaults.string(forKey: Key.workerLoginCode.rawValue) {
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.caseInsensitiveCompare("EMBC-0001") == .orderedSame,
           Secrets.workerLoginCode.caseInsensitiveCompare("EMBC-0001") != .orderedSame,
           defaults.bool(forKey: Key.workerLoginCodeMigratedFromFastFoodDefault.rawValue) == false {
          defaults.set(Secrets.workerLoginCode, forKey: Key.workerLoginCode.rawValue)
          defaults.set(true, forKey: Key.workerLoginCodeMigratedFromFastFoodDefault.rawValue)
          return Secrets.workerLoginCode
        }

        return stored
      }

      return Secrets.workerLoginCode
    }
    set { defaults.set(newValue, forKey: Key.workerLoginCode.rawValue) }
  }

  var workerEmail: String {
    get { defaults.string(forKey: Key.workerEmail.rawValue) ?? Secrets.workerEmail }
    set { defaults.set(newValue, forKey: Key.workerEmail.rawValue) }
  }

  var workerAPIBearerToken: String {
    get {
      let current = secureString(for: .workerAPIBearerToken, fallback: Secrets.workerAPIBearerToken)
      if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return current
      }
      if let legacy = keychain.string(for: "openClawBearerToken"),
         !legacy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        keychain.set(legacy, for: Key.workerAPIBearerToken.rawValue)
        keychain.removeValue(for: "openClawBearerToken")
        return legacy
      }
      if let legacy = defaults.string(forKey: "openClawBearerToken"),
         !legacy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        keychain.set(legacy, for: Key.workerAPIBearerToken.rawValue)
        defaults.removeObject(forKey: "openClawBearerToken")
        return legacy
      }
      return current
    }
    set { setSecureString(newValue, for: .workerAPIBearerToken) }
  }

  var opsBaseURL: String {
    get {
      if let stored = defaults.string(forKey: Key.opsBaseURL.rawValue),
         Self.isUsableRuntimeURL(stored) {
        return migratedRuntimeURL(stored, for: .opsBaseURL)
      }
      return migratedRuntimeURL(Secrets.opsBaseURL, for: .opsBaseURL)
    }
    set { defaults.set(newValue, forKey: Key.opsBaseURL.rawValue) }
  }

  var adminBaseURL: String {
    get {
      if let stored = defaults.string(forKey: Key.adminBaseURL.rawValue),
         Self.isUsableRuntimeURL(stored) {
        return migratedRuntimeURL(stored, for: .adminBaseURL)
      }
      return migratedRuntimeURL(Secrets.adminBaseURL, for: .adminBaseURL)
    }
    set { defaults.set(newValue, forKey: Key.adminBaseURL.rawValue) }
  }

  var signalBaseURL: String {
    get {
      if let stored = defaults.string(forKey: Key.signalBaseURL.rawValue),
         Self.isUsableRuntimeURL(stored) {
        return migratedRuntimeURL(stored, for: .signalBaseURL)
      }
      if let legacy = defaults.string(forKey: Key.webrtcSignalingURL.rawValue),
         Self.isUsableRuntimeURL(legacy) {
        return migratedRuntimeURL(Self.normalizeSignalBaseURL(legacy), for: .signalBaseURL)
      }
      return migratedRuntimeURL(Secrets.signalBaseURL, for: .signalBaseURL)
    }
    set { defaults.set(newValue, forKey: Key.signalBaseURL.rawValue) }
  }

  // MARK: - WebRTC

  var webrtcSignalingURL: String {
    get { Self.normalizeWebSocketURL(signalBaseURL) }
    set {
      let normalized = Self.normalizeSignalBaseURL(newValue)
      defaults.set(normalized, forKey: Key.signalBaseURL.rawValue)
      defaults.set(normalized, forKey: Key.webrtcSignalingURL.rawValue)
    }
  }

  // MARK: - Audio

  var speakerOutputEnabled: Bool {
    get { defaults.bool(forKey: Key.speakerOutputEnabled.rawValue) }
    set { defaults.set(newValue, forKey: Key.speakerOutputEnabled.rawValue) }
  }

  // MARK: - Video

  var videoStreamingEnabled: Bool {
    get { defaults.object(forKey: Key.videoStreamingEnabled.rawValue) as? Bool ?? false }
    set { defaults.set(newValue, forKey: Key.videoStreamingEnabled.rawValue) }
  }

  // MARK: - Notifications

  var proactiveNotificationsEnabled: Bool {
    get { defaults.object(forKey: Key.proactiveNotificationsEnabled.rawValue) as? Bool ?? true }
    set { defaults.set(newValue, forKey: Key.proactiveNotificationsEnabled.rawValue) }
  }

  // MARK: - Reset

  func resetAll() {
    for key in [Key.workerLoginCode, .workerLoginCodeMigratedFromFastFoodDefault, .workerEmail, .opsBaseURL, .adminBaseURL, .signalBaseURL,
                .webrtcSignalingURL,
                .deviceID, .speakerOutputEnabled, .videoStreamingEnabled,
                .proactiveNotificationsEnabled] {
      defaults.removeObject(forKey: key.rawValue)
    }
    for key in [Key.workerAPIBearerToken] {
      defaults.removeObject(forKey: key.rawValue)
      keychain.removeValue(for: key.rawValue)
    }
    for legacy in [
      "geminiAPIKey",
      "openClawBearerToken",
      "openClawHookToken",
      "openClawGatewayToken",
      "openClawHost",
      "openClawPort",
      "openClawTailscaleIP",
      "geminiSystemPrompt"
    ] {
      defaults.removeObject(forKey: legacy)
      keychain.removeValue(for: legacy)
    }
  }

  private func secureString(for key: Key, fallback: String) -> String {
    if let stored = keychain.string(for: key.rawValue), !stored.isEmpty {
      return stored
    }

    if let legacy = defaults.string(forKey: key.rawValue), !legacy.isEmpty {
      keychain.set(legacy, for: key.rawValue)
      defaults.removeObject(forKey: key.rawValue)
      return legacy
    }

    if !fallback.isEmpty, !fallback.contains("YOUR_") {
      keychain.set(fallback, for: key.rawValue)
      return fallback
    }

    return fallback
  }

  private func setSecureString(_ value: String, for key: Key) {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    defaults.removeObject(forKey: key.rawValue)
    if trimmed.isEmpty {
      keychain.removeValue(for: key.rawValue)
    } else {
      keychain.set(trimmed, for: key.rawValue)
    }
  }

  private func migratedRuntimeURL(_ raw: String, for key: Key) -> String {
    let migrated = Self.migrateRuntimeURL(raw, for: key)
    if migrated != raw {
      defaults.set(migrated, forKey: key.rawValue)
      if key == .signalBaseURL {
        defaults.set(migrated, forKey: Key.webrtcSignalingURL.rawValue)
      }
    }
    return migrated
  }

  private static func migrateRuntimeURL(_ raw: String, for key: Key) -> String {
    let normalized = normalizeSignalBaseURL(raw)
    let lowercased = normalized.lowercased()

    if lowercased.contains("embarcadero-admin-705096377819.us-central1.run.app") {
      if key == .signalBaseURL {
        return RuntimeURL.signalBaseURL
      }
      if key == .opsBaseURL {
        return RuntimeURL.opsBaseURL
      }
      return RuntimeURL.adminBaseURL
    }

    if lowercased.contains("embarcadero-signal-705096377819.us-central1.run.app") {
      return RuntimeURL.signalBaseURL
    }

    return normalized
  }

  private static func normalizeSignalBaseURL(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return trimmed }
    if trimmed.hasPrefix("wss://") {
      return "https://" + String(trimmed.dropFirst("wss://".count))
    }
    if trimmed.hasPrefix("ws://") {
      return "http://" + String(trimmed.dropFirst("ws://".count))
    }
    if trimmed.hasPrefix("https://") || trimmed.hasPrefix("http://") {
      return trimmed
    }
    return "https://\(trimmed)"
  }

  private static func isUsableRuntimeURL(_ raw: String) -> Bool {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }

    let blockedMarkers = [
      "YOUR_",
      "YOUR_MAC_IP",
      "example.com",
    ]

    return !blockedMarkers.contains { trimmed.localizedCaseInsensitiveContains($0) }
  }

  private static func normalizeWebSocketURL(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return trimmed }
    if trimmed.hasPrefix("wss://") || trimmed.hasPrefix("ws://") {
      return trimmed
    }
    if trimmed.hasPrefix("https://") {
      return "wss://" + String(trimmed.dropFirst("https://".count))
    }
    if trimmed.hasPrefix("http://") {
      return "ws://" + String(trimmed.dropFirst("http://".count))
    }
    return "wss://\(trimmed)"
  }
}

private struct KeychainStore {
  let service: String

  func string(for key: String) -> String? {
    var query = baseQuery(for: key)
    query[kSecReturnData as String] = kCFBooleanTrue
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess,
          let data = result as? Data,
          let value = String(data: data, encoding: .utf8)
    else {
      return nil
    }
    return value
  }

  func set(_ value: String, for key: String) {
    let data = Data(value.utf8)
    let query = baseQuery(for: key)
    let attributes = [kSecValueData as String: data]
    let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

    if status == errSecItemNotFound {
      var item = query
      item[kSecValueData as String] = data
      item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      SecItemAdd(item as CFDictionary, nil)
    }
  }

  func removeValue(for key: String) {
    SecItemDelete(baseQuery(for: key) as CFDictionary)
  }

  private func baseQuery(for key: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: key,
    ]
  }
}
