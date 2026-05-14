import Foundation

enum GeminiConfig {
  static let websocketBaseURL = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
  static let model = "models/gemini-2.5-flash-native-audio-preview-12-2025"

  static let inputAudioSampleRate: Double = 16000
  static let outputAudioSampleRate: Double = 24000
  static let audioChannels: UInt32 = 1
  static let audioBitsPerSample: UInt32 = 16

  static let videoFrameInterval: TimeInterval = 1.0
  static let videoJPEGQuality: CGFloat = 0.5

  static var systemInstruction: String { SettingsManager.shared.geminiSystemPrompt }

  static let defaultSystemInstruction = """
    You are the voice-facing layer for Omen, a full OpenClaw assistant running through Meta Ray-Ban smart glasses. Keep responses concise, natural, and spoken-word friendly.

    Video may or may not be available. Do not claim you can see unless you have actually received visual context in this session.

    You have exactly one tool: execute. Use it to delegate work to the full OpenClaw assistant, which has access to tools, memory, workflows, messaging, web search, notes, reminders, research, and the user's broader assistant context.

    ALWAYS use execute when the user asks you to:
    - send messages or contact someone
    - search, look something up, or research anything
    - add, create, update, delete, or save anything
    - remember something, recall prior context, or check personal/project memory
    - control apps, services, devices, or workflows
    - perform any task where accuracy depends on OpenClaw's tools or memory

    When a request is purely conversational and needs no tools, respond directly.

    Be detailed in your execute task description. Include names, platforms, message content, deadlines, constraints, and any context the user already gave you.

    Never pretend you completed a real-world action without using execute.

    IMPORTANT: Before calling execute, always say a short acknowledgment out loud first, so the user knows you're working on it.

    For messages, confirm recipient and content before delegating unless the request is already unambiguous or clearly urgent.
    """

  // User-configurable values (Settings screen overrides, falling back to Secrets.swift)
  static var apiKey: String { SettingsManager.shared.geminiAPIKey }
  static var openClawHost: String { SettingsManager.shared.openClawHost }
  static var openClawPort: Int { SettingsManager.shared.openClawPort }
  static var openClawHookToken: String { SettingsManager.shared.openClawHookToken }
  static var openClawGatewayToken: String { SettingsManager.shared.openClawGatewayToken }

  static func websocketURL() -> URL? {
    guard apiKey != "YOUR_GEMINI_API_KEY" && !apiKey.isEmpty else { return nil }
    return URL(string: "\(websocketBaseURL)?key=\(apiKey)")
  }

  static var isConfigured: Bool {
    return apiKey != "YOUR_GEMINI_API_KEY" && !apiKey.isEmpty
  }

  static var isOpenClawConfigured: Bool {
    return openClawGatewayToken != "YOUR_OPENCLAW_GATEWAY_TOKEN"
      && !openClawGatewayToken.isEmpty
      && openClawHost != "http://YOUR_MAC_HOSTNAME.local"
  }
}
