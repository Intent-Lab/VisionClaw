import Foundation

struct GeminiLiveCredential: Equatable {
  let token: String
  let queryParameterName: String
  let websocketBaseURL: String
  let model: String
}

enum GeminiConfig {
  static let ephemeralTokenWebsocketBaseURL = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1alpha.GenerativeService.BidiGenerateContentConstrained"
  static let model = "models/gemini-live-2.5-flash-native-audio"

  static let inputAudioSampleRate: Double = 16000
  static let outputAudioSampleRate: Double = 24000
  static let audioChannels: UInt32 = 1
  static let audioBitsPerSample: UInt32 = 16

  static let videoFrameInterval: TimeInterval = 3.0
  static let videoJPEGQuality: CGFloat = 0.5

  static let defaultSystemInstruction = """
    You are a live frontline worker copilot for SOP execution sessions.

    Your job is to converse naturally with the worker, guide the current task step by step, and use connected tools when they help move the job forward.

    Rules:
    - Ground answers in the live camera feed, the current SOP context, and the worker's request.
    - If visual evidence is insufficient, say what you need to see next.
    - Keep spoken responses short, clear, and useful for hands-free work.
    - Offer direct next actions instead of long explanations.
    - Use available tools for task execution, logging, and memory when appropriate.
    - Never pretend you verified something you could not actually observe or infer.
    """

  // User-configurable values (Settings screen overrides, falling back to Secrets.swift)
  static var deviceID: String { SettingsManager.shared.deviceID }
  static var workerLoginCode: String { SettingsManager.shared.workerLoginCode }
  static var workerEmail: String { SettingsManager.shared.workerEmail }
  static var opsBaseURL: String { SettingsManager.shared.opsBaseURL }
  static var adminBaseURL: String { SettingsManager.shared.adminBaseURL }
  static var signalBaseURL: String { SettingsManager.shared.signalBaseURL }
  static var workerAPIBearerToken: String { SettingsManager.shared.workerAPIBearerToken }

  static func websocketURL(credential: GeminiLiveCredential) -> URL? {
    guard var components = URLComponents(string: credential.websocketBaseURL) else { return nil }
    var queryItems = components.queryItems ?? []
    queryItems.append(
      URLQueryItem(name: credential.queryParameterName, value: credential.token)
    )
    components.queryItems = queryItems
    return components.url
  }

  static var isOpsConfigured: Bool {
    let trimmed = opsBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    return !trimmed.isEmpty && !trimmed.contains("YOUR_")
  }

  static var isAdminConfigured: Bool {
    let trimmed = adminBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    return !trimmed.isEmpty && !trimmed.contains("YOUR_")
  }
}
