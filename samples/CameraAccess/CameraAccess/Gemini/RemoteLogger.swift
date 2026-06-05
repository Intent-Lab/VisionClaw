import Foundation

/// Sends conversation events to the logging server for persistent logging.
/// All methods are fire-and-forget -- logging never blocks the UI or conversation flow.
final class RemoteLogger {
  static let shared = RemoteLogger()

  private let session: URLSession
  private var sequenceNumber = 0

  private init() {
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 5
    self.session = URLSession(configuration: config)
  }

  /// The base URL for the logging server (same host as OpenClaw, port 8080).
  private var baseURL: String? {
    guard GeminiConfig.isOpenClawConfigured else { return nil }
    let host = GeminiConfig.openClawHost
    return "\(host):8080"
  }

  /// Log a conversation event. Types:
  /// - "voice:user" -- user speech transcript from Gemini
  /// - "voice:ai" -- Gemini voice response transcript
  /// - "voice:tool_call" -- Gemini triggered execute tool
  /// - "voice:tool_result" -- tool result sent back to Gemini
  /// - "session:start" -- voice session started
  /// - "session:end" -- voice session ended
  func log(_ type: String, data: [String: String] = [:]) {
    guard let baseURL else { return }
    guard let url = URL(string: "\(baseURL)/api/logs") else { return }

    sequenceNumber += 1
    let eventData: [String: Any] = [
      "event": type,
      "seq": sequenceNumber
    ].merging(data) { _, new in new }

    let payload: [String: Any] = [
      "type": "event",
      "session": "ios-client",
      "data": eventData
    ]

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(GeminiConfig.openClawGatewayToken, forHTTPHeaderField: "x-api-token")

    do {
      request.httpBody = try JSONSerialization.data(withJSONObject: payload)
    } catch { return }

    // Fire and forget
    Task.detached(priority: .utility) { [session] in
      _ = try? await session.data(for: request)
    }
  }
}
