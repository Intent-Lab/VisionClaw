import Foundation

final class SettingsManager {
  static let shared = SettingsManager()

  private let defaults = UserDefaults.standard

  private enum Key: String {
    case geminiAPIKey
    case openClawHost
    case openClawPort
    case openClawHookToken
    case openClawGatewayToken
    case geminiSystemPrompt
    case webrtcSignalingURL
    case speakerOutputEnabled
    case videoStreamingEnabled
    case proactiveNotificationsEnabled
    case inspectionInterval
    case inspectionAutoStart
    case safetyMonitorInterval
    case safetyMonitorAutoStart
    case workerName
    case defaultJobId
    case defaultJobDescription
    case defaultSiteAddress
    case multisetClientId
    case multisetClientSecret
    case multisetMapCode
    case multisetEnabled
  }

  private init() {}

  // MARK: - Gemini

  var geminiAPIKey: String {
    get { defaults.string(forKey: Key.geminiAPIKey.rawValue) ?? Secrets.geminiAPIKey }
    set { defaults.set(newValue, forKey: Key.geminiAPIKey.rawValue) }
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
    get { defaults.string(forKey: Key.openClawHookToken.rawValue) ?? Secrets.openClawHookToken }
    set { defaults.set(newValue, forKey: Key.openClawHookToken.rawValue) }
  }

  var openClawGatewayToken: String {
    get { defaults.string(forKey: Key.openClawGatewayToken.rawValue) ?? Secrets.openClawGatewayToken }
    set { defaults.set(newValue, forKey: Key.openClawGatewayToken.rawValue) }
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

  // MARK: - Inspection

  var inspectionInterval: Int {
    get {
      let stored = defaults.integer(forKey: Key.inspectionInterval.rawValue)
      return stored != 0 ? stored : 10
    }
    set { defaults.set(newValue, forKey: Key.inspectionInterval.rawValue) }
  }

  var inspectionAutoStart: Bool {
    get { defaults.bool(forKey: Key.inspectionAutoStart.rawValue) }
    set { defaults.set(newValue, forKey: Key.inspectionAutoStart.rawValue) }
  }

  // MARK: - Safety Monitor

  var safetyMonitorInterval: Int {
    get {
      let stored = defaults.integer(forKey: Key.safetyMonitorInterval.rawValue)
      return stored != 0 ? stored : 15
    }
    set { defaults.set(newValue, forKey: Key.safetyMonitorInterval.rawValue) }
  }

  var safetyMonitorAutoStart: Bool {
    get { defaults.bool(forKey: Key.safetyMonitorAutoStart.rawValue) }
    set { defaults.set(newValue, forKey: Key.safetyMonitorAutoStart.rawValue) }
  }

  // MARK: - Field Worker

  var workerName: String {
    get { defaults.string(forKey: Key.workerName.rawValue) ?? "" }
    set { defaults.set(newValue, forKey: Key.workerName.rawValue) }
  }

  var defaultJobId: String {
    get { defaults.string(forKey: Key.defaultJobId.rawValue) ?? "" }
    set { defaults.set(newValue, forKey: Key.defaultJobId.rawValue) }
  }

  var defaultJobDescription: String {
    get { defaults.string(forKey: Key.defaultJobDescription.rawValue) ?? "" }
    set { defaults.set(newValue, forKey: Key.defaultJobDescription.rawValue) }
  }

  var defaultSiteAddress: String {
    get { defaults.string(forKey: Key.defaultSiteAddress.rawValue) ?? "" }
    set { defaults.set(newValue, forKey: Key.defaultSiteAddress.rawValue) }
  }

  // MARK: - Multiset VPS

  var multisetClientId: String {
    get { defaults.string(forKey: Key.multisetClientId.rawValue) ?? Secrets.multisetClientId }
    set { defaults.set(newValue, forKey: Key.multisetClientId.rawValue) }
  }

  var multisetClientSecret: String {
    get { defaults.string(forKey: Key.multisetClientSecret.rawValue) ?? Secrets.multisetClientSecret }
    set { defaults.set(newValue, forKey: Key.multisetClientSecret.rawValue) }
  }

  var multisetMapCode: String {
    get { defaults.string(forKey: Key.multisetMapCode.rawValue) ?? Secrets.multisetMapCode }
    set { defaults.set(newValue, forKey: Key.multisetMapCode.rawValue) }
  }

  var multisetEnabled: Bool {
    get { defaults.object(forKey: Key.multisetEnabled.rawValue) as? Bool ?? true }
    set { defaults.set(newValue, forKey: Key.multisetEnabled.rawValue) }
  }

  /// True when all Multiset credentials + a map code are present and VPS is enabled.
  var isMultisetConfigured: Bool {
    return multisetEnabled
      && !multisetClientId.isEmpty
      && !multisetClientSecret.isEmpty
      && !multisetMapCode.isEmpty
  }

  // MARK: - Reset

  func resetAll() {
    for key in [Key.geminiAPIKey, .geminiSystemPrompt, .openClawHost, .openClawPort,
                .openClawHookToken, .openClawGatewayToken, .webrtcSignalingURL,
                .speakerOutputEnabled, .videoStreamingEnabled,
                .proactiveNotificationsEnabled,
                .inspectionInterval, .inspectionAutoStart,
                .safetyMonitorInterval, .safetyMonitorAutoStart,
                .workerName, .defaultJobId, .defaultJobDescription, .defaultSiteAddress,
                .multisetClientId, .multisetClientSecret, .multisetMapCode, .multisetEnabled] {
      defaults.removeObject(forKey: key.rawValue)
    }
  }
}
