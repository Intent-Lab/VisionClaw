import Foundation

enum ChatHistoryStore {
  private static let filename = "chat_history.json"
  private static let maxMessages = 500

  private static var fileURL: URL {
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    return docs.appendingPathComponent(filename)
  }

  static func save(_ messages: [ChatMessage]) {
    let toSave = Array(messages.suffix(maxMessages))
    let records: [[String: Any]] = toSave.map { msg in
      [
        "id": msg.id,
        "role": serializeRole(msg.role),
        "text": msg.text,
        "timestamp": msg.timestamp.timeIntervalSince1970,
        "status": serializeStatus(msg.status)
      ]
    }
    guard let data = try? JSONSerialization.data(withJSONObject: records) else { return }
    try? data.write(to: fileURL)
  }

  static func load() -> [ChatMessage] {
    guard FileManager.default.fileExists(atPath: fileURL.path),
          let data = try? Data(contentsOf: fileURL),
          let records = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
      return []
    }
    return records.compactMap { obj in
      guard let id = obj["id"] as? String,
            let roleStr = obj["role"] as? String,
            let timestamp = obj["timestamp"] as? TimeInterval else { return nil }
      let text = obj["text"] as? String ?? ""
      let statusStr = obj["status"] as? String ?? "complete"
      return ChatMessage(
        id: id,
        role: deserializeRole(roleStr),
        text: text,
        timestamp: Date(timeIntervalSince1970: timestamp),
        status: deserializeStatus(statusStr)
      )
    }
  }

  // MARK: - Serialization

  private static func serializeRole(_ role: ChatMessageRole) -> String {
    switch role {
    case .user: return "user"
    case .assistant: return "assistant"
    case .toolCall(let name): return "tool:\(name)"
    case .sessionDivider: return "divider"
    }
  }

  private static func deserializeRole(_ s: String) -> ChatMessageRole {
    switch s {
    case "user": return .user
    case "assistant": return .assistant
    case "divider": return .sessionDivider
    default:
      if s.hasPrefix("tool:") { return .toolCall(String(s.dropFirst(5))) }
      return .assistant
    }
  }

  private static func serializeStatus(_ status: ChatMessageStatus) -> String {
    switch status {
    case .streaming: return "streaming"
    case .complete: return "complete"
    case .error(let msg): return "error:\(msg)"
    }
  }

  private static func deserializeStatus(_ s: String) -> ChatMessageStatus {
    switch s {
    case "complete": return .complete
    case "streaming": return .complete // treat stale streaming as complete
    default:
      if s.hasPrefix("error:") { return .error(String(s.dropFirst(6))) }
      return .complete
    }
  }
}
