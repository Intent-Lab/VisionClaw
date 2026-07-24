import Foundation
import Security

final class SettingsManager {
  static let shared = SettingsManager()

  private let defaults = UserDefaults.standard
  private let credentials = SecureCredentialStore(
    service: Bundle.main.bundleIdentifier ?? "VisionClaw"
  )

  private enum Key: String {
    case geminiAPIKey
    case openClawHost
    case openClawPort
    case openClawAgentTarget
    case openClawHookToken
    case openClawGatewayToken
    case geminiSystemPrompt
    case webrtcSignalingURL
    case speakerOutputEnabled
    case videoStreamingEnabled
    case proactiveNotificationsEnabled
  }

  private init() {}

  // MARK: - Gemini

  var geminiAPIKey: String {
    get { secureValue(for: Key.geminiAPIKey) }
    set { setSecureValue(newValue, for: Key.geminiAPIKey) }
  }

  var geminiSystemPrompt: String {
    get {
      guard let stored = defaults.string(forKey: Key.geminiSystemPrompt.rawValue),
            !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return GeminiConfig.defaultSystemInstruction
      }
      return stored
    }
    set {
      if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        defaults.removeObject(forKey: Key.geminiSystemPrompt.rawValue)
      } else {
        defaults.set(newValue, forKey: Key.geminiSystemPrompt.rawValue)
      }
    }
  }

  // MARK: - OpenClaw

  var openClawHost: String {
    get { defaults.string(forKey: Key.openClawHost.rawValue) ?? Secrets.openClawHost }
    set { defaults.set(newValue, forKey: Key.openClawHost.rawValue) }
  }

  var openClawPort: Int {
    get {
      let stored = defaults.integer(forKey: Key.openClawPort.rawValue)
      return stored != 0 ? stored : Secrets.openClawPort
    }
    set { defaults.set(newValue, forKey: Key.openClawPort.rawValue) }
  }

  var openClawAgentTarget: String {
    get {
      guard let stored = defaults.string(forKey: Key.openClawAgentTarget.rawValue)?
        .trimmingCharacters(in: .whitespacesAndNewlines),
        !stored.isEmpty else {
        return "openclaw"
      }
      return stored
    }
    set {
      let target = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
      if target.isEmpty || target == "openclaw" {
        defaults.removeObject(forKey: Key.openClawAgentTarget.rawValue)
      } else {
        defaults.set(target, forKey: Key.openClawAgentTarget.rawValue)
      }
    }
  }

  var openClawHookToken: String {
    get { secureValue(for: Key.openClawHookToken) }
    set { setSecureValue(newValue, for: Key.openClawHookToken) }
  }

  var openClawGatewayToken: String {
    get { secureValue(for: Key.openClawGatewayToken) }
    set { setSecureValue(newValue, for: Key.openClawGatewayToken) }
  }

  // MARK: - WebRTC

  var webrtcSignalingURL: String {
    get { defaults.string(forKey: Key.webrtcSignalingURL.rawValue) ?? Secrets.webrtcSignalingURL }
    set { defaults.set(newValue, forKey: Key.webrtcSignalingURL.rawValue) }
  }

  // MARK: - Audio

  var speakerOutputEnabled: Bool {
    get { defaults.bool(forKey: Key.speakerOutputEnabled.rawValue) }
    set { defaults.set(newValue, forKey: Key.speakerOutputEnabled.rawValue) }
  }

  // MARK: - Video

  var videoStreamingEnabled: Bool {
    get { defaults.object(forKey: Key.videoStreamingEnabled.rawValue) as? Bool ?? true }
    set { defaults.set(newValue, forKey: Key.videoStreamingEnabled.rawValue) }
  }

  // MARK: - Notifications

  var proactiveNotificationsEnabled: Bool {
    get { defaults.object(forKey: Key.proactiveNotificationsEnabled.rawValue) as? Bool ?? true }
    set { defaults.set(newValue, forKey: Key.proactiveNotificationsEnabled.rawValue) }
  }

  // MARK: - Reset

  func resetAll() {
    for key in [Key.geminiAPIKey, .geminiSystemPrompt, .openClawHost, .openClawPort,
                .openClawAgentTarget,
                .openClawHookToken, .openClawGatewayToken, .webrtcSignalingURL,
                .speakerOutputEnabled, .videoStreamingEnabled,
                .proactiveNotificationsEnabled] {
      defaults.removeObject(forKey: key.rawValue)
    }
    credentials.remove(account: Key.geminiAPIKey.rawValue)
    credentials.remove(account: Key.openClawHookToken.rawValue)
    credentials.remove(account: Key.openClawGatewayToken.rawValue)
  }

  private func secureValue(for key: Key) -> String {
    if let secure = credentials.string(account: key.rawValue) {
      return secure
    }
    if let legacy = defaults.string(forKey: key.rawValue) {
      if credentials.set(legacy, account: key.rawValue) {
        defaults.removeObject(forKey: key.rawValue)
      }
      return legacy
    }
    return ""
  }

  private func setSecureValue(_ value: String, for key: Key) {
    if value.isEmpty {
      credentials.remove(account: key.rawValue)
      defaults.removeObject(forKey: key.rawValue)
      return
    }
    if credentials.set(value, account: key.rawValue) {
      defaults.removeObject(forKey: key.rawValue)
    } else {
      NSLog("[Settings] Keychain write failed for %@", key.rawValue)
    }
  }
}

private final class SecureCredentialStore {
  private let service: String

  init(service: String) {
    self.service = service
  }

  func string(account: String) -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
          let data = item as? Data else {
      return nil
    }
    return String(data: data, encoding: .utf8)
  }

  @discardableResult
  func set(_ value: String, account: String) -> Bool {
    let data = Data(value.utf8)
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account
    ]
    let update: [String: Any] = [
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    ]
    let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
    if status == errSecSuccess {
      return true
    }
    if status == errSecItemNotFound {
      var add = query
      add.merge(update) { _, new in new }
      return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
    return false
  }

  func remove(account: String) {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account
    ]
    SecItemDelete(query as CFDictionary)
  }
}
