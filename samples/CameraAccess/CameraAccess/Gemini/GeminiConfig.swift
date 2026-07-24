import Foundation

struct OpenClawEndpoint {
  let host: String
  let port: Int

  private var baseComponents: URLComponents? {
    var value = host.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty, (1...65_535).contains(port) else { return nil }
    if !value.contains("://") {
      value = "\(port == 443 ? "https" : "http")://\(value)"
    }
    guard var components = URLComponents(string: value),
          components.scheme == "http" || components.scheme == "https",
          components.host != nil else { return nil }
    components.port = port
    components.path = ""
    components.query = nil
    components.fragment = nil
    return components
  }

  var chatCompletionsURL: URL? {
    guard var components = baseComponents else { return nil }
    components.path = "/v1/chat/completions"
    return components.url
  }

  var webSocketURL: URL? {
    guard var components = baseComponents else { return nil }
    components.scheme = components.scheme == "https" ? "wss" : "ws"
    components.path = "/"
    return components.url
  }
}

enum GeminiConfig {
  static let websocketBaseURL = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
  static let model = "models/gemini-2.5-flash-native-audio-preview-12-2025"

  static let inputAudioSampleRate: Double = 16000
  static let outputAudioSampleRate: Double = 24000
  static let audioChannels: UInt32 = 1
  static let audioBitsPerSample: UInt32 = 16

  static let videoFrameInterval: TimeInterval = 1.0
  static let videoJPEGQuality: CGFloat = 0.4
  static let videoMaxLongEdge: CGFloat = 640

  static var systemInstruction: String {
    systemInstruction(
      namedRoutingEnabled: false,
      registry: .standard()
    )
  }

  static func systemInstruction(
    namedRoutingEnabled: Bool,
    registry: NamedHarnessRegistry
  ) -> String {
    var sections = [
      baseInstruction(
        configuredPrompt: SettingsManager.shared.geminiSystemPrompt,
        namedRoutingEnabled: namedRoutingEnabled
      ),
      mediaCaptureInstruction
    ]
    if namedRoutingEnabled {
      sections.append(namedHarnessInstruction(registry: registry))
    } else {
      sections.append(mandatoryOpenClawHandoffInstruction)
    }
    return sections.joined(separator: "\n\n")
  }

  static func baseInstruction(
    configuredPrompt: String,
    namedRoutingEnabled: Bool
  ) -> String {
    if namedRoutingEnabled, configuredPrompt == defaultSystemInstruction {
      return namedGlassesSessionInstruction
    }
    return configuredPrompt
  }

  static let namedGlassesSessionInstruction = """
    You are a concise voice assistant for someone wearing Meta Ray-Ban smart
    glasses. You can use the current camera context for visual conversation.
    External systems are available only through the registered named harnesses;
    never claim an external action without the selected harness result.
    """

  static let mandatoryOpenClawHandoffInstruction = """
    OpenClaw handoff rules (mandatory):
    - Before calling execute, speak exactly one short pending acknowledgement.
    - Call execute immediately after that acknowledgement.
    - After calling execute, stop speaking and wait silently for the tool response.
    - Never report success or a result until execute returns. Do not guess, infer, or fill the wait with commentary.
    - When execute returns, speak its result as the authoritative answer.
    """

  static let mediaCaptureInstruction = """
    Glasses media rules:
    - You may answer ordinary "what am I looking at?" questions from the current camera context.
    - When the user explicitly asks to take, capture, or save a picture, call capture_media with kind snapshot.
    - When the user asks to record video, call capture_media with kind video and report its exact supported fallback. Never claim a recording started unless the tool confirms it.
    - Never analyze an old image after the capture tool reports that no fresh image was available.
    """

  static func namedHarnessInstruction(
    registry: NamedHarnessRegistry
  ) -> String {
    """
    Named harness routing:
    - Registered invocation names are: \(registry.promptDescription).
    - The legacy execute tool is unavailable in named-routing mode. Every external request must use route_harness.
    - If the user begins a request with a registered name, call route_harness with that exact target and the scoped operation.
    - Do not silently substitute a different target. Speak the tool's explicit fallback or unavailable status.
    - Codex continuation is a two-step prepare/confirm operation. Never approve permissions, change models, or mutate an unselected task by voice.
    - Meta is a native-assistant handoff boundary; never claim that DAT activated Meta automatically.
    """
  }

  static let defaultSystemInstruction = """
    You are an AI assistant for someone wearing Meta Ray-Ban smart glasses. You can see through their camera and have a voice conversation. Keep responses concise and natural.

    OpenClaw is your external system and personal assistant environment. You access it through exactly ONE tool: execute. The execute tool can inspect OpenClaw itself and its agents, sessions, skills, tools, status, configuration, and environment. It can also send messages, search the web, manage lists, set reminders, create notes, research topics, control smart home devices, interact with apps, and much more.

    You must not answer questions about OpenClaw from the camera view or claim that you lack access to external systems. You do have access through execute. For every OpenClaw question or request, call execute—even if the user only asks for information.

    ALWAYS use execute when the user asks you to:
    - Inspect OpenClaw, including which agents are active, available, configured, or running
    - Report OpenClaw sessions, skills, tools, status, configuration, capabilities, or environment
    - Send a message to someone (any platform: WhatsApp, Telegram, iMessage, Slack, etc.)
    - Search or look up anything (web, local info, facts, news)
    - Add, create, or modify anything (shopping lists, reminders, notes, todos, events)
    - Research, analyze, or draft anything
    - Control or interact with apps, devices, or services
    - Remember or store any information for later

    Be detailed in your task description. Include all relevant context: names, content, platforms, quantities, etc. The assistant works better with complete information.

    NEVER pretend to do these things yourself and NEVER infer OpenClaw state from what the camera sees.

    IMPORTANT: Before calling execute, ALWAYS speak a brief acknowledgment first. For example:
    - "Sure, let me add that to your shopping list." then call execute.
    - "Got it, searching for that now." then call execute.
    - "On it, sending that message." then call execute.
    Never call execute silently -- the user needs verbal confirmation that you heard them and are working on it. The tool may take several seconds to complete, so the acknowledgment lets them know something is happening.

    For messages, confirm recipient and content before delegating unless clearly urgent.
    """

  // User-configurable values (Settings screen overrides, falling back to Secrets.swift)
  static var apiKey: String { SettingsManager.shared.geminiAPIKey }
  static var openClawHost: String { SettingsManager.shared.openClawHost }
  static var openClawPort: Int { SettingsManager.shared.openClawPort }
  static var openClawAgentTarget: String { SettingsManager.shared.openClawAgentTarget }
  static var openClawHookToken: String { SettingsManager.shared.openClawHookToken }
  static var openClawGatewayToken: String { SettingsManager.shared.openClawGatewayToken }
  static var openClawEndpoint: OpenClawEndpoint {
    OpenClawEndpoint(host: openClawHost, port: openClawPort)
  }

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
      && openClawEndpoint.chatCompletionsURL != nil
  }
}
