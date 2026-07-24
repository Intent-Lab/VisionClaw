import Foundation

@MainActor
final class OpenClawRequestGate {
  private var isAcquired = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func acquire() async {
    if !isAcquired {
      isAcquired = true
      return
    }
    await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }

  func release() {
    guard !waiters.isEmpty else {
      isAcquired = false
      return
    }
    waiters.removeFirst().resume()
  }
}

enum OpenClawConnectionState: Equatable {
  case notConfigured
  case checking
  case connected
  case unreachable(String)
}

@MainActor
class OpenClawBridge: ObservableObject {
  @Published var lastToolCallStatus: ToolCallStatus = .idle
  @Published var connectionState: OpenClawConnectionState = .notConfigured

  private let session: URLSession
  private let pingSession: URLSession
  private let requestGate = OpenClawRequestGate()
  private var conversationID: String

  static func makeConversationID() -> String {
    "visionclaw-glass-\(UUID().uuidString.lowercased())"
  }

  static func makeRequestBody(
    task: String,
    agentTarget: String = GeminiConfig.openClawAgentTarget,
    conversationID: String
  ) -> [String: Any] {
    [
      "model": agentTarget,
      "messages": [["role": "user", "content": task]],
      "stream": false,
      "user": conversationID
    ]
  }

  init() {
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 120
    self.session = URLSession(configuration: config)

    let pingConfig = URLSessionConfiguration.default
    pingConfig.timeoutIntervalForRequest = 5
    self.pingSession = URLSession(configuration: pingConfig)

    self.conversationID = OpenClawBridge.makeConversationID()
  }

  func checkConnection() async {
    guard GeminiConfig.isOpenClawConfigured else {
      connectionState = .notConfigured
      return
    }
    connectionState = .checking
    guard let url = GeminiConfig.openClawEndpoint.chatCompletionsURL else {
      connectionState = .unreachable("Invalid URL")
      return
    }
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue("Bearer \(GeminiConfig.openClawGatewayToken)", forHTTPHeaderField: "Authorization")
    request.setValue("glass", forHTTPHeaderField: "x-openclaw-message-channel")
    do {
      let (_, response) = try await pingSession.data(for: request)
      if let http = response as? HTTPURLResponse, (200...499).contains(http.statusCode) {
        connectionState = .connected
        NSLog("[OpenClaw] Gateway reachable (HTTP %d)", http.statusCode)
      } else {
        connectionState = .unreachable("Unexpected response")
      }
    } catch {
      connectionState = .unreachable(error.localizedDescription)
      NSLog("[OpenClaw] Gateway unreachable: %@", error.localizedDescription)
    }
  }

  func resetSession() {
    conversationID = OpenClawBridge.makeConversationID()
    NSLog("[OpenClaw] Conversation reset")
  }

  // MARK: - Agent Chat

  func delegateTask(
    task: String,
    toolName: String = "execute"
  ) async -> ToolResult {
    lastToolCallStatus = .executing(toolName)

    await requestGate.acquire()
    defer { requestGate.release() }

    guard !Task.isCancelled else {
      lastToolCallStatus = .cancelled(toolName)
      return .failure("Agent request was cancelled")
    }

    let agentTarget = GeminiConfig.openClawAgentTarget
    guard let url = GeminiConfig.openClawEndpoint.chatCompletionsURL else {
      lastToolCallStatus = .failed(toolName, "Invalid URL")
      return .failure("Invalid gateway URL")
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("Bearer \(GeminiConfig.openClawGatewayToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("glass", forHTTPHeaderField: "x-openclaw-message-channel")

    // OpenClaw derives an agent-scoped session from `user`. Avoid constructing
    // explicit session keys from model aliases because `openclaw`,
    // `openclaw/default`, `openclaw:<id>`, and `agent:<id>` route differently.
    let body = OpenClawBridge.makeRequestBody(
      task: task,
      agentTarget: agentTarget,
      conversationID: conversationID)
    NSLog("[OpenClaw] Delegating to %@", agentTarget)

    do {
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
      let (data, response) = try await session.data(for: request)
      let httpResponse = response as? HTTPURLResponse

      guard let statusCode = httpResponse?.statusCode, (200...299).contains(statusCode) else {
        let code = httpResponse?.statusCode ?? 0
        NSLog("[OpenClaw] Chat failed: HTTP %d (%d bytes)", code, data.count)
        lastToolCallStatus = .failed(toolName, "HTTP \(code)")
        return .failure("Agent returned HTTP \(code)")
      }

      if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
         let choices = json["choices"] as? [[String: Any]],
         let first = choices.first,
         let message = first["message"] as? [String: Any],
         let content = message["content"] as? String {
        NSLog("[OpenClaw] Agent returned %d characters", content.count)
        lastToolCallStatus = .completed(toolName)
        return .success(content)
      }

      let raw = String(data: data, encoding: .utf8) ?? "OK"
      NSLog("[OpenClaw] Agent returned an unstructured %d-byte response", data.count)
      lastToolCallStatus = .completed(toolName)
      return .success(raw)
    } catch {
      NSLog("[OpenClaw] Agent error: %@", error.localizedDescription)
      lastToolCallStatus = .failed(toolName, error.localizedDescription)
      return .failure("Agent error: \(error.localizedDescription)")
    }
  }
}
