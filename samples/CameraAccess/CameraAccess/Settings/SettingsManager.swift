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
    case openClawTunnelURL
    case webrtcSignalingURL
    case translationTargetLanguage
    case translationOutputMode
    case golfCourseAPIKey
    case golfSevenIronCarry
    case discordVisionClawWebhook
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

  var openClawTunnelURL: String {
    get { defaults.string(forKey: Key.openClawTunnelURL.rawValue) ?? Secrets.openClawTunnelURL }
    set { defaults.set(newValue, forKey: Key.openClawTunnelURL.rawValue) }
  }

  // MARK: - WebRTC

  var webrtcSignalingURL: String {
    get { defaults.string(forKey: Key.webrtcSignalingURL.rawValue) ?? Secrets.webrtcSignalingURL }
    set { defaults.set(newValue, forKey: Key.webrtcSignalingURL.rawValue) }
  }

  // MARK: - Translation

  var translationTargetLanguage: String {
    get { defaults.string(forKey: Key.translationTargetLanguage.rawValue) ?? "English" }
    set { defaults.set(newValue, forKey: Key.translationTargetLanguage.rawValue) }
  }

  var translationOutputMode: String {
    get { defaults.string(forKey: Key.translationOutputMode.rawValue) ?? "both" }
    set { defaults.set(newValue, forKey: Key.translationOutputMode.rawValue) }
  }

  // MARK: - Golf

  var golfCourseAPIKey: String {
    get { defaults.string(forKey: Key.golfCourseAPIKey.rawValue) ?? "" }
    set { defaults.set(newValue, forKey: Key.golfCourseAPIKey.rawValue) }
  }

  /// 7-iron carry distance in yards — used to extrapolate all club distances
  var golfSevenIronCarry: Int {
    get {
      let stored = defaults.integer(forKey: Key.golfSevenIronCarry.rawValue)
      return stored > 0 ? stored : 140
    }
    set { defaults.set(newValue, forKey: Key.golfSevenIronCarry.rawValue) }
  }

  // MARK: - Discord

  var discordVisionClawWebhook: String {
    get { defaults.string(forKey: Key.discordVisionClawWebhook.rawValue) ?? "" }
    set { defaults.set(newValue, forKey: Key.discordVisionClawWebhook.rawValue) }
  }

  // MARK: - Reset

  func resetAll() {
    for key in [Key.geminiAPIKey, .geminiSystemPrompt, .openClawHost, .openClawPort,
                .openClawHookToken, .openClawGatewayToken, .openClawTunnelURL, .webrtcSignalingURL,
                .translationTargetLanguage, .translationOutputMode, .golfCourseAPIKey,
                .golfSevenIronCarry, .discordVisionClawWebhook] {
      defaults.removeObject(forKey: key.rawValue)
    }
  }
}
