import Foundation

enum GeminiConfig {




  // User-configurable values (Settings screen overrides, falling back to Secrets.swift)
  static var apiKey: String { SettingsManager.shared.geminiAPIKey }
  static var openClawHost: String { SettingsManager.shared.openClawHost }
  static var openClawPort: Int { SettingsManager.shared.openClawPort }
  static var openClawHookToken: String { SettingsManager.shared.openClawHookToken }
  static var openClawGatewayToken: String { SettingsManager.shared.openClawGatewayToken }


  static var isConfigured: Bool {
    return apiKey != "YOUR_GEMINI_API_KEY" && !apiKey.isEmpty
  }

  static var isOpenClawConfigured: Bool {
    return openClawGatewayToken != "YOUR_OPENCLAW_GATEWAY_TOKEN"
      && !openClawGatewayToken.isEmpty
      && openClawHost != "http://YOUR_MAC_HOSTNAME.local"
  }

  // MARK: - Action agent backend (self-hosted OpenClaw or cloud gateway)

  static var agentBackend: AgentBackend { SettingsManager.shared.agentBackend }

  /// Base URL of the active agent backend, scheme included.
  static var agentBaseURL: String {
    switch agentBackend {
    case .selfHosted: return "\(openClawHost):\(openClawPort)"
    case .cloud: return SettingsManager.shared.cloudGatewayURL
    }
  }

  static var agentToken: String {
    switch agentBackend {
    case .selfHosted: return openClawGatewayToken
    case .cloud: return SettingsManager.shared.cloudGatewayToken
    }
  }

  static var isAgentConfigured: Bool {
    switch agentBackend {
    case .selfHosted:
      return isOpenClawConfigured
    case .cloud:
      let url = SettingsManager.shared.cloudGatewayURL
      let token = SettingsManager.shared.cloudGatewayToken
      // An unfilled Secrets.swift.example placeholder is not empty, so without
      // this a fresh clone reports "configured" and then fails with a 401 that
      // looks like a server problem rather than a missing token.
      return !url.isEmpty && url.hasPrefix("http") && !token.isEmpty && !token.hasPrefix("YOUR_")
    }
  }
}
