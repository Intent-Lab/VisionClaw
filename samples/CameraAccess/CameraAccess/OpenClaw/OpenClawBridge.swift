import Foundation

enum OpenClawConnectionState: Equatable {
  case notConfigured
  case checking
  case connected
  case unreachable(String)
}

protocol OpenClawBridgeConfig {
  var host: String { get }
  var port: Int { get }
  var gatewayToken: String { get }
  var modelOverride: String { get }
  var thinkingOverride: String { get }
}

struct DefaultOpenClawBridgeConfig: OpenClawBridgeConfig {
  var host: String { GeminiConfig.openClawHost }
  var port: Int { GeminiConfig.openClawPort }
  var gatewayToken: String { GeminiConfig.openClawGatewayToken }
  var modelOverride: String { GeminiConfig.openClawModel }
  var thinkingOverride: String { GeminiConfig.openClawThinking }
}

@MainActor
class OpenClawBridge: ObservableObject {
  private enum AppliedSessionOverrideState: Equatable {
    case unknown
    case value(String)
    case cleared
  }

  @Published var lastToolCallStatus: ToolCallStatus = .idle
  @Published var connectionState: OpenClawConnectionState = .notConfigured

  private let session: URLSession
  private let pingSession: URLSession
  private let config: OpenClawBridgeConfig
  private let sessionKeyFactory: () -> String
  private var sessionKey: String
  private var conversationHistory: [[String: String]] = []
  private var appliedSessionModel: AppliedSessionOverrideState = .unknown
  private var appliedSessionThinking: AppliedSessionOverrideState = .unknown
  private let maxHistoryTurns = 10

  init(
    session: URLSession? = nil,
    pingSession: URLSession? = nil,
    config: OpenClawBridgeConfig = DefaultOpenClawBridgeConfig(),
    sessionKeyFactory: @escaping () -> String = OpenClawBridge.newSessionKey
  ) {
    if let session {
      self.session = session
    } else {
      let config = URLSessionConfiguration.default
      config.timeoutIntervalForRequest = 120
      self.session = URLSession(configuration: config)
    }

    if let pingSession {
      self.pingSession = pingSession
    } else {
      let pingConfig = URLSessionConfiguration.default
      pingConfig.timeoutIntervalForRequest = 5
      self.pingSession = URLSession(configuration: pingConfig)
    }

    self.config = config
    self.sessionKeyFactory = sessionKeyFactory
    self.sessionKey = sessionKeyFactory()
  }

  func checkConnection() async {
    guard isConfigured else {
      connectionState = .notConfigured
      return
    }
    connectionState = .checking
    guard let url = gatewayURL else {
      connectionState = .unreachable("Invalid URL")
      return
    }
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue("Bearer \(config.gatewayToken)", forHTTPHeaderField: "Authorization")
    do {
      let (_, response) = try await pingSession.data(for: request)
      if let http = response as? HTTPURLResponse {
        if (200...299).contains(http.statusCode) {
          connectionState = .connected
          NSLog("[OpenClaw] Gateway reachable (HTTP %d)", http.statusCode)
        } else {
          connectionState = .unreachable("HTTP \(http.statusCode)")
          NSLog("[OpenClaw] Gateway check failed (HTTP %d)", http.statusCode)
        }
      } else {
        connectionState = .unreachable("Unexpected response")
      }
    } catch {
      connectionState = .unreachable(error.localizedDescription)
      NSLog("[OpenClaw] Gateway unreachable: %@", error.localizedDescription)
    }
  }

  func resetSession() {
    sessionKey = sessionKeyFactory()
    conversationHistory = []
    appliedSessionModel = .unknown
    appliedSessionThinking = .unknown
    NSLog("[OpenClaw] New session: %@", sessionKey)
  }

  private func normalizedSessionOverride(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    return trimmed
  }

  private func parseAssistantContent(from data: Data) -> String? {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let choices = json["choices"] as? [[String: Any]],
          let first = choices.first,
          let message = first["message"] as? [String: Any],
          let content = message["content"] as? String else {
      return nil
    }
    return content
  }

  private var isConfigured: Bool {
    let token = config.gatewayToken.trimmingCharacters(in: .whitespacesAndNewlines)
    let host = config.host.trimmingCharacters(in: .whitespacesAndNewlines)
    return token != "YOUR_OPENCLAW_GATEWAY_TOKEN"
      && !token.isEmpty
      && host != "http://YOUR_MAC_HOSTNAME.local"
      && !host.isEmpty
  }

  private var gatewayURL: URL? {
    URL(string: "\(config.host):\(config.port)/v1/chat/completions")
  }

  private func sendSessionCommand(
    command: String,
    label: String
  ) async -> ToolResult {
    guard let url = gatewayURL else {
      return .failure("Invalid gateway URL")
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("Bearer \(config.gatewayToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(sessionKey, forHTTPHeaderField: "x-openclaw-session-key")

    let body: [String: Any] = [
      "model": "openclaw",
      "messages": [["role": "user", "content": command]],
      "stream": false
    ]

    do {
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
      let (data, response) = try await session.data(for: request)
      let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
      guard (200...299).contains(statusCode) else {
        return .failure("OpenClaw \(label) override failed (HTTP \(statusCode))")
      }

      guard let content = parseAssistantContent(from: data)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !content.isEmpty else {
        return .failure("OpenClaw \(label) override failed: empty response")
      }

      let lower = content.lowercased()
      if lower.contains("not allowed") || lower.contains("failed") || lower.contains("invalid") {
        return .failure("OpenClaw \(label) override failed: \(content)")
      }
      return .success(content)
    } catch {
      return .failure("OpenClaw \(label) override error: \(error.localizedDescription)")
    }
  }

  private func sendFirstSuccessfulSessionCommand(
    commands: [String],
    label: String
  ) async -> ToolResult {
    var lastError = "OpenClaw \(label) override failed"
    for command in commands {
      switch await sendSessionCommand(command: command, label: label) {
      case .success(let response):
        return .success(response)
      case .failure(let error):
        lastError = error
      }
    }
    return .failure(lastError)
  }

  private func applySessionOverridesIfNeeded(toolName: String) async -> ToolResult? {
    let desiredModel = normalizedSessionOverride(config.modelOverride)
    let desiredThinking = normalizedSessionOverride(config.thinkingOverride)?.lowercased()

    if let model = desiredModel {
      if appliedSessionModel != .value(model) {
        switch await sendSessionCommand(command: "/model \(model)", label: "model") {
        case .success:
          appliedSessionModel = .value(model)
        case .failure(let error):
          lastToolCallStatus = .failed(toolName, error)
          return .failure(error)
        }
      }
    } else if appliedSessionModel != .cleared {
      switch await sendFirstSuccessfulSessionCommand(
        commands: ["/model default", "/model reset", "/model clear"],
        label: "model clear"
      ) {
      case .success:
        appliedSessionModel = .cleared
      case .failure(let error):
        lastToolCallStatus = .failed(toolName, error)
        return .failure(error)
      }
    }

    if let thinking = desiredThinking {
      if appliedSessionThinking != .value(thinking) {
        switch await sendSessionCommand(command: "/think \(thinking)", label: "thinking") {
        case .success:
          appliedSessionThinking = .value(thinking)
        case .failure(let error):
          lastToolCallStatus = .failed(toolName, error)
          return .failure(error)
        }
      }
    } else if appliedSessionThinking != .cleared {
      switch await sendFirstSuccessfulSessionCommand(
        commands: ["/think default", "/think off"],
        label: "thinking clear"
      ) {
      case .success:
        appliedSessionThinking = .cleared
      case .failure(let error):
        lastToolCallStatus = .failed(toolName, error)
        return .failure(error)
      }
    }

    return nil
  }

  private nonisolated static func newSessionKey() -> String {
    let ts = ISO8601DateFormatter().string(from: Date())
    return "agent:main:glass:\(ts)"
  }

  // MARK: - Agent Chat (session continuity via x-openclaw-session-key header)

  func delegateTask(
    task: String,
    toolName: String = "execute"
  ) async -> ToolResult {
    lastToolCallStatus = .executing(toolName)

    guard let url = gatewayURL else {
      lastToolCallStatus = .failed(toolName, "Invalid URL")
      return .failure("Invalid gateway URL")
    }

    if let overrideFailure = await applySessionOverridesIfNeeded(toolName: toolName) {
      return overrideFailure
    }

    // Append the new user message to conversation history
    conversationHistory.append(["role": "user", "content": task])

    // Trim history to keep only the most recent turns (user+assistant pairs)
    if conversationHistory.count > maxHistoryTurns * 2 {
      conversationHistory = Array(conversationHistory.suffix(maxHistoryTurns * 2))
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("Bearer \(config.gatewayToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(sessionKey, forHTTPHeaderField: "x-openclaw-session-key")

    let body: [String: Any] = [
      "model": "openclaw",
      "messages": conversationHistory,
      "stream": false
    ]

    NSLog("[OpenClaw] Sending %d messages in conversation", conversationHistory.count)

    do {
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
      let (data, response) = try await session.data(for: request)
      let httpResponse = response as? HTTPURLResponse

      guard let statusCode = httpResponse?.statusCode, (200...299).contains(statusCode) else {
        let code = httpResponse?.statusCode ?? 0
        let bodyStr = String(data: data, encoding: .utf8) ?? "no body"
        NSLog("[OpenClaw] Chat failed: HTTP %d - %@", code, String(bodyStr.prefix(200)))
        lastToolCallStatus = .failed(toolName, "HTTP \(code)")
        if code == 401 {
          return .failure("OpenClaw unauthorized (HTTP 401). Check OpenClaw Gateway Token in Settings.")
        }
        if code == 403 {
          return .failure("OpenClaw forbidden (HTTP 403). Check gateway auth mode/token.")
        }
        return .failure("Agent returned HTTP \(code)")
      }

      if let content = parseAssistantContent(from: data) {
        // Append assistant response to history for continuity
        conversationHistory.append(["role": "assistant", "content": content])
        NSLog("[OpenClaw] Agent result: %@", String(content.prefix(200)))
        lastToolCallStatus = .completed(toolName)
        return .success(content)
      }

      let raw = String(data: data, encoding: .utf8) ?? "OK"
      conversationHistory.append(["role": "assistant", "content": raw])
      NSLog("[OpenClaw] Agent raw: %@", String(raw.prefix(200)))
      lastToolCallStatus = .completed(toolName)
      return .success(raw)
    } catch {
      NSLog("[OpenClaw] Agent error: %@", error.localizedDescription)
      lastToolCallStatus = .failed(toolName, error.localizedDescription)
      return .failure("Agent error: \(error.localizedDescription)")
    }
  }
}
