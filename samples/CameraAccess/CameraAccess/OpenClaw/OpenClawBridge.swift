import Foundation
import UIKit

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

  /// Set by GeminiSessionViewModel so we can send image tasks via WebSocket
  var eventClient: OpenClawEventClient?

  private let session: URLSession
  private let pingSession: URLSession
  private var sessionKey: String
  private var conversationHistory: [[String: Any]] = []
  private let maxHistoryTurns = 10

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

  func checkConnection() async {
    guard GeminiConfig.isOpenClawConfigured else {
      connectionState = .notConfigured
      return
    }
    connectionState = .checking
    guard let url = URL(string: "\(GeminiConfig.openClawHost):\(GeminiConfig.openClawPort)/v1/chat/completions") else {
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
    conversationHistory = []
    NSLog("[OpenClaw] Session reset (key retained: %@)", sessionKey)
  }

  // MARK: - Agent Chat (session continuity via x-openclaw-session-key header)

  func delegateTask(
    task: String,
    toolName: String = "execute",
    image: UIImage? = nil
  ) async -> ToolResult {
    lastToolCallStatus = .executing(toolName)

    // If image is provided, route through WebSocket chat.send (only working method)
    if let image = image, let jpegData = image.jpegData(compressionQuality: 0.8) {
      let base64 = jpegData.base64EncodedString()
      if let ec = eventClient {
        NSLog("[OpenClaw] Sending image task via WebSocket chat.send (%d KB)", jpegData.count / 1024)
        return await sendViaWebSocket(eventClient: ec, task: task, imageBase64: base64, toolName: toolName)
      } else {
        NSLog("[OpenClaw] Image task but no event client, falling back to text-only HTTP")
      }
    }

    guard let url = URL(string: "\(GeminiConfig.openClawHost):\(GeminiConfig.openClawPort)/v1/chat/completions") else {
      lastToolCallStatus = .failed(toolName, "Invalid URL")
      return .failure("Invalid gateway URL")
    }

    let userMessage: [String: Any] = ["role": "user", "content": task]
    conversationHistory.append(userMessage)

    // Trim history to keep only the most recent turns (user+assistant pairs)
    if conversationHistory.count > maxHistoryTurns * 2 {
      conversationHistory = Array(conversationHistory.suffix(maxHistoryTurns * 2))
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("Bearer \(GeminiConfig.openClawGatewayToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(sessionKey, forHTTPHeaderField: "x-openclaw-session-key")
    request.setValue("glass", forHTTPHeaderField: "x-openclaw-message-channel")

    let body: [String: Any] = [
      "model": "openclaw",
      "messages": conversationHistory,
      "stream": false
    ]

    NSLog("[OpenClaw] Sending %d messages in conversation%@", conversationHistory.count, image != nil ? " (with image)" : "")

    do {
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
      let (data, response) = try await session.data(for: request)
      let httpResponse = response as? HTTPURLResponse

      guard let statusCode = httpResponse?.statusCode, (200...299).contains(statusCode) else {
        let code = httpResponse?.statusCode ?? 0
        let bodyStr = String(data: data, encoding: .utf8) ?? "no body"
        NSLog("[OpenClaw] Chat failed: HTTP %d - %@", code, String(bodyStr.prefix(200)))
        lastToolCallStatus = .failed(toolName, "HTTP \(code)")
        return .failure("Agent returned HTTP \(code)")
      }

      if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
         let choices = json["choices"] as? [[String: Any]],
         let first = choices.first,
         let message = first["message"] as? [String: Any],
         let content = message["content"] as? String {
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

  /// Upload JPEG to the upload server so the agent can access the file on disk.
  func uploadImageFile(_ imageBase64: String) -> String? {
    let uploadPort = GeminiConfig.openClawPort + 6 // upload server runs on gateway port + 6
    guard let url = URL(string: "\(GeminiConfig.openClawHost):\(uploadPort)/upload") else { return nil }
    guard let jpegData = Data(base64Encoded: imageBase64) else { return nil }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
    request.httpBody = jpegData
    request.timeoutInterval = 10

    let semaphore = DispatchSemaphore(value: 0)
    var filePath: String?

    let task = URLSession.shared.dataTask(with: request) { data, response, _ in
      if let data,
         let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
         let path = json["path"] as? String {
        filePath = path
        NSLog("[OpenClaw] Image uploaded to: %@", path)
      }
      semaphore.signal()
    }
    task.resume()
    semaphore.wait()
    return filePath
  }

  /// Send a task with image via WebSocket chat.send RPC.
  /// Also uploads the image file to disk so the agent can access it.
  private func sendViaWebSocket(
    eventClient: OpenClawEventClient,
    task: String,
    imageBase64: String,
    toolName: String
  ) async -> ToolResult {
    // Upload image to disk so agent can read/copy/save the file
    let filePath = uploadImageFile(imageBase64)
    let taskWithPath = filePath != nil ? "\(task)\n\n[image_file_path]\n\(filePath!)" : task

    return await withCheckedContinuation { continuation in
      eventClient.sendChatMessage(
        sessionKey: sessionKey,
        message: taskWithPath,
        imageBase64: imageBase64
      ) { [weak self] reply in
        guard let self else {
          continuation.resume(returning: .failure("Session ended"))
          return
        }
        if let reply {
          self.conversationHistory.append(["role": "user", "content": task])
          self.conversationHistory.append(["role": "assistant", "content": reply])
          NSLog("[OpenClaw] WebSocket chat.send result: %@", String(reply.prefix(200)))
          self.lastToolCallStatus = .completed(toolName)
          continuation.resume(returning: .success(reply))
        } else {
          self.lastToolCallStatus = .failed(toolName, "WebSocket chat.send failed")
          continuation.resume(returning: .failure("Failed to send image via WebSocket"))
        }
      }
    }
  }
}
