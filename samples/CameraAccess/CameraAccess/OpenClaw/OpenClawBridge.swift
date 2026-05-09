import Foundation

enum OpenClawConnectionState: Equatable {
  case notConfigured
  case checking
  case connected
  case unreachable(String)
}

enum GatewayMode: Equatable {
  case local
  case remote
  case none
}

@MainActor
class OpenClawBridge: ObservableObject {
  @Published var lastToolCallStatus: ToolCallStatus = .idle
  @Published var connectionState: OpenClawConnectionState = .notConfigured
  @Published var gatewayMode: GatewayMode = .none

  private let session: URLSession
  private let pingSession: URLSession
  private var sessionKey: String
  private var conversationHistory: [[String: String]] = []
  private let maxHistoryTurns = 10

  /// Cached resolved base URL — set once during checkConnection(), reused by delegateTask()
  private var resolvedBaseURL: String?

  private static let stableSessionKey = "agent:main:glass"

  init() {
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 120
    self.session = URLSession(configuration: config)

    let pingConfig = URLSessionConfiguration.default
    pingConfig.timeoutIntervalForRequest = 5
    self.pingSession = URLSession(configuration: pingConfig)

    self.sessionKey = OpenClawBridge.stableSessionKey
  }

  // MARK: - Connection check with remote fallback

  func checkConnection() async {
    guard GeminiConfig.isOpenClawConfigured else {
      connectionState = .notConfigured
      gatewayMode = .none
      resolvedBaseURL = nil
      return
    }
    connectionState = .checking

    // Build candidate URLs: remote first (Tailscale/public), then local
    var candidates: [(String, GatewayMode)] = []

    let remote = SettingsManager.shared.openClawRemoteURL
    if !remote.isEmpty {
      candidates.append((remote, .remote))
    }

    let local = "\(GeminiConfig.openClawHost):\(GeminiConfig.openClawPort)"
    candidates.append((local, .local))

    for (baseURL, mode) in candidates {
      let result = await probeGateway(baseURL)
      switch result {
      case .reachable:
        resolvedBaseURL = baseURL
        gatewayMode = mode
        connectionState = .connected
        NSLog("[OpenClaw] Connected via %@ → %@", mode == .remote ? "REMOTE" : "LOCAL", baseURL)
        return
      case .authFailed(let msg):
        // Auth issues apply to all candidates — stop trying
        resolvedBaseURL = nil
        gatewayMode = .none
        connectionState = .unreachable(msg)
        return
      case .endpointDisabled:
        resolvedBaseURL = nil
        gatewayMode = .none
        connectionState = .unreachable("chatCompletions endpoint disabled — enable it in openclaw.json")
        return
      case .unreachable:
        // Try next candidate
        continue
      }
    }

    // All candidates failed
    resolvedBaseURL = nil
    gatewayMode = .none
    let tried = candidates.map { $0.0 }.joined(separator: ", ")
    connectionState = .unreachable("No reachable gateway (tried: \(tried))")
    NSLog("[OpenClaw] All gateway endpoints unreachable")
  }

  /// The resolved gateway base URL for use by EventClient and other components.
  var resolvedGatewayBaseURL: String? { resolvedBaseURL }

  func resetSession() {
    conversationHistory = []
    NSLog("[OpenClaw] Session reset (key retained: %@)", sessionKey)
  }

  // MARK: - Agent Chat

  func delegateTask(
    task: String,
    toolName: String = "execute"
  ) async -> ToolResult {
    lastToolCallStatus = .executing(toolName)

    // Use cached URL — no re-resolution per call (fast for demo)
    guard let baseURL = resolvedBaseURL,
          let url = URL(string: "\(baseURL)/v1/chat/completions") else {
      lastToolCallStatus = .failed(toolName, "No reachable gateway")
      return .failure("Gateway not connected. Check Settings → OpenClaw.")
    }

    conversationHistory.append(["role": "user", "content": task])

    if conversationHistory.count > maxHistoryTurns * 2 {
      conversationHistory = Array(conversationHistory.suffix(maxHistoryTurns * 2))
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("Bearer \(GeminiConfig.openClawGatewayToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(sessionKey, forHTTPHeaderField: "x-openclaw-session-key")
    request.setValue("glass", forHTTPHeaderField: "x-openclaw-message-channel")
    request.setValue("operator.write", forHTTPHeaderField: "x-openclaw-scopes")

    let body: [String: Any] = [
      "model": "openclaw",
      "messages": conversationHistory,
      "stream": false
    ]

    NSLog("[OpenClaw] Sending %d messages via %@", conversationHistory.count, baseURL)

    do {
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
      let (data, response) = try await session.data(for: request)
      let httpResponse = response as? HTTPURLResponse

      guard let statusCode = httpResponse?.statusCode, (200...299).contains(statusCode) else {
        let code = httpResponse?.statusCode ?? 0
        let bodyStr = String(data: data, encoding: .utf8) ?? "no body"
        NSLog("[OpenClaw] Chat failed: HTTP %d - %@", code, String(bodyStr.prefix(200)))

        // If remote fails, try re-resolving on next call
        if code == 0 || code >= 500 {
          resolvedBaseURL = nil
        }

        lastToolCallStatus = .failed(toolName, "HTTP \(code)")
        return .failure("Agent returned HTTP \(code)")
      }

      if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
         let choices = json["choices"] as? [[String: Any]],
         let first = choices.first,
         let message = first["message"] as? [String: Any],
         let content = message["content"] as? String {
        conversationHistory.append(["role": "assistant", "content": content])
        NSLog("[OpenClaw] Agent result: %@", String(content.prefix(200)))
        lastToolCallStatus = .completed(toolName)
        return .success(content)
      }

      let raw = String(data: data, encoding: .utf8) ?? "OK"
      conversationHistory.append(["role": "assistant", "content": raw])
      lastToolCallStatus = .completed(toolName)
      return .success(raw)
    } catch {
      NSLog("[OpenClaw] Agent error: %@", error.localizedDescription)
      // Network error — invalidate cache so next call re-resolves
      resolvedBaseURL = nil
      lastToolCallStatus = .failed(toolName, error.localizedDescription)
      return .failure("Agent error: \(error.localizedDescription)")
    }
  }

  // MARK: - Private

  private enum ProbeResult {
    case reachable
    case authFailed(String)
    case endpointDisabled
    case unreachable
  }

  private func probeGateway(_ baseURL: String) async -> ProbeResult {
    // Step 1: Health check
    guard let healthURL = URL(string: "\(baseURL)/health") else { return .unreachable }
    var healthReq = URLRequest(url: healthURL)
    healthReq.httpMethod = "GET"
    do {
      let (_, resp) = try await pingSession.data(for: healthReq)
      if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
        return .unreachable
      }
    } catch {
      return .unreachable
    }

    // Step 2: Verify chat completions endpoint
    guard let chatURL = URL(string: "\(baseURL)/v1/chat/completions") else { return .unreachable }
    var chatReq = URLRequest(url: chatURL)
    chatReq.httpMethod = "GET"
    chatReq.setValue("Bearer \(GeminiConfig.openClawGatewayToken)", forHTTPHeaderField: "Authorization")
    chatReq.setValue("glass", forHTTPHeaderField: "x-openclaw-message-channel")
    do {
      let (_, resp) = try await pingSession.data(for: chatReq)
      if let http = resp as? HTTPURLResponse {
        switch http.statusCode {
        case 200...299, 405:
          return .reachable
        case 401, 403:
          return .authFailed("Authentication failed (HTTP \(http.statusCode)) — check your gateway token")
        case 404:
          return .endpointDisabled
        default:
          return .unreachable
        }
      }
    } catch {
      return .unreachable
    }
    return .unreachable
  }
}
