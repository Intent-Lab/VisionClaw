import Foundation

final class SettingsManager {
  static let shared = SettingsManager()

  private let defaults = UserDefaults.standard

  // Keys for secrets (stored in Keychain)
  private enum SecretKey: String {
    case geminiAPIKey
    case openClawHookToken
    case openClawGatewayToken
  }

  // Keys for non-sensitive settings (stored in UserDefaults)
  private enum Key: String {
    case openClawHost
    case openClawPort
    case geminiSystemPrompt
    case webrtcSignalingURL
    case speakerOutputEnabled
    case videoStreamingEnabled
    case proactiveNotificationsEnabled
  }

  private init() {
    migrateSecretsFromUserDefaults()
  }

  /// One-time migration: move secrets from UserDefaults to Keychain.
  /// Runs on first launch after update — old UserDefaults entries are deleted.
  private func migrateSecretsFromUserDefaults() {
    let migrationKey = "secrets_migrated_to_keychain"
    guard !defaults.bool(forKey: migrationKey) else { return }

    for key in [SecretKey.geminiAPIKey, .openClawHookToken, .openClawGatewayToken] {
      if let value = defaults.string(forKey: key.rawValue), !value.isEmpty {
        KeychainManager.set(key.rawValue, value: value)
        defaults.removeObject(forKey: key.rawValue)
        NSLog("[Settings] Migrated %@ from UserDefaults to Keychain", key.rawValue)
      }
    }

    defaults.set(true, forKey: migrationKey)
  }

  // MARK: - Gemini (secrets in Keychain)

  var geminiAPIKey: String {
    get { KeychainManager.get(SecretKey.geminiAPIKey.rawValue) ?? Secrets.geminiAPIKey }
    set { KeychainManager.set(SecretKey.geminiAPIKey.rawValue, value: newValue) }
  }

  var geminiSystemPrompt: String {
    get { defaults.string(forKey: Key.geminiSystemPrompt.rawValue) ?? GeminiConfig.defaultSystemInstruction }
    set { defaults.set(newValue, forKey: Key.geminiSystemPrompt.rawValue) }
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

  var openClawHookToken: String {
    get { KeychainManager.get(SecretKey.openClawHookToken.rawValue) ?? Secrets.openClawHookToken }
    set { KeychainManager.set(SecretKey.openClawHookToken.rawValue, value: newValue) }
  }

  var openClawGatewayToken: String {
    get { KeychainManager.get(SecretKey.openClawGatewayToken.rawValue) ?? Secrets.openClawGatewayToken }
    set { KeychainManager.set(SecretKey.openClawGatewayToken.rawValue, value: newValue) }
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
    KeychainManager.deleteAll()
    for key in [Key.geminiSystemPrompt, .openClawHost, .openClawPort,
                .webrtcSignalingURL, .speakerOutputEnabled, .videoStreamingEnabled,
                .proactiveNotificationsEnabled] {
      defaults.removeObject(forKey: key.rawValue)
    }
  }
}
