import Foundation

/// Which action-agent backend the app talks to. Both speak the same protocol;
/// only the endpoint and token differ.
/// Order matters: `allCases` drives the picker, and the first segment reads as
/// the primary option. Cloud leads because it is the default.
enum AgentBackend: String, CaseIterable {
  case cloud = "Cloud"
  case selfHosted = "Self-hosted"
}


/// Which realtime model answers. The choice travels to the agent worker as
/// room-token metadata; the phone never talks to either provider directly.
enum IntelligenceEngine: String, CaseIterable {
  case gemini = "gemini"
  case openai = "openai"

  static let defaultsKey = "intelligenceEngine"

  var label: String {
    switch self {
    case .gemini: return "Gemini"
    case .openai: return "OpenAI"
    }
  }
}

/// Where video comes from. The app is a vision assistant first -- it opens
/// looking at the world through the phone -- and glasses are one capture
/// source, selected here, rather than a mode the user must decide about at
/// launch. Raw values are stored in UserDefaults under `captureSource`, which
/// views also observe via @AppStorage so a change applies without a relaunch.
enum CaptureSource: String, CaseIterable {
  case iPhoneCamera = "iphone"
  case glasses = "glasses"

  static let defaultsKey = "captureSource"

  var label: String {
    switch self {
    case .iPhoneCamera: return "iPhone Camera"
    case .glasses: return "Glasses"
    }
  }
}

final class SettingsManager {
  static let shared = SettingsManager()

  private let defaults = UserDefaults.standard

  private enum SecretKey: String, CaseIterable {
    case geminiAPIKey
    case openClawHookToken
    case openClawGatewayToken
    case cloudGatewayToken
  }

  private enum Key: String {
    case agentBackend
    case openClawHost
    case openClawPort
    case cloudGatewayURL
    case accountEmail
    case accountStatus
    case geminiSystemPrompt
    case speakerOutputEnabled
    case videoStreamingEnabled
    case proactiveNotificationsEnabled
  }

  private init() {
    migrateSecretsFromUserDefaults()
  }

  private func migrateSecretsFromUserDefaults() {
    let migrationKey = "secrets_migrated_to_keychain"
    guard !defaults.bool(forKey: migrationKey) else { return }

    for key in SecretKey.allCases {
      if let value = defaults.string(forKey: key.rawValue), !value.isEmpty {
        if KeychainManager.set(key.rawValue, value: value) {
          defaults.removeObject(forKey: key.rawValue)
        }
      }
    }

    defaults.set(true, forKey: migrationKey)
  }

  // MARK: - Gemini

  var geminiAPIKey: String {
    get { KeychainManager.get(SecretKey.geminiAPIKey.rawValue) ?? Secrets.geminiAPIKey }
    set { KeychainManager.set(SecretKey.geminiAPIKey.rawValue, value: newValue) }
  }

  var geminiSystemPrompt: String {
    get { defaults.string(forKey: Key.geminiSystemPrompt.rawValue) ?? "" }
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

  // MARK: - Agent backend selection

  var intelligenceEngine: IntelligenceEngine {
    get {
      guard let raw = defaults.string(forKey: IntelligenceEngine.defaultsKey),
            let engine = IntelligenceEngine(rawValue: raw) else { return .gemini }
      return engine
    }
    set { defaults.set(newValue.rawValue, forKey: IntelligenceEngine.defaultsKey) }
  }

  var captureSource: CaptureSource {
    get {
      guard let raw = defaults.string(forKey: CaptureSource.defaultsKey),
            let source = CaptureSource(rawValue: raw) else { return .iPhoneCamera }
      return source
    }
    set { defaults.set(newValue.rawValue, forKey: CaptureSource.defaultsKey) }
  }

  static let showCaptionsKey = "showCaptions"

  var showCaptions: Bool {
    get { defaults.object(forKey: Self.showCaptionsKey) as? Bool ?? true }
    set { defaults.set(newValue, forKey: Self.showCaptionsKey) }
  }

  /// Cloud by default: the hosted gateway needs nothing installed and keeps
  /// working with the phone away from home, which self-hosting cannot do.
  var agentBackend: AgentBackend {
    get {
      guard let raw = defaults.string(forKey: Key.agentBackend.rawValue),
            let backend = AgentBackend(rawValue: raw) else { return .cloud }
      return backend
    }
    set { defaults.set(newValue.rawValue, forKey: Key.agentBackend.rawValue) }
  }

  /// Full base URL of the hosted gateway, scheme included (e.g. "https://gw.example.com" or "http://1.2.3.4:8788").
  var cloudGatewayURL: String {
    get { defaults.string(forKey: Key.cloudGatewayURL.rawValue) ?? Secrets.cloudGatewayURL }
    set { defaults.set(newValue, forKey: Key.cloudGatewayURL.rawValue) }
  }

  var cloudGatewayToken: String {
    get { KeychainManager.get(SecretKey.cloudGatewayToken.rawValue) ?? Secrets.cloudGatewayToken }
    set { KeychainManager.set(SecretKey.cloudGatewayToken.rawValue, value: newValue) }
  }

  // MARK: - Account (Google sign-in)

  /// Email of the Google account that created this app's gateway credential.
  var accountEmail: String? {
    get { defaults.string(forKey: Key.accountEmail.rawValue) }
    set { defaults.set(newValue, forKey: Key.accountEmail.rawValue) }
  }

  /// approved | pending | revoked, as last reported by the gateway.
  var accountStatus: String? {
    get { defaults.string(forKey: Key.accountStatus.rawValue) }
    set { defaults.set(newValue, forKey: Key.accountStatus.rawValue) }
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
    for key in [Key.geminiSystemPrompt, .agentBackend, .openClawHost, .openClawPort,
                .cloudGatewayURL,
                .accountEmail, .accountStatus,
                .speakerOutputEnabled, .videoStreamingEnabled,
                .proactiveNotificationsEnabled] {
      defaults.removeObject(forKey: key.rawValue)
    }
  }
}
