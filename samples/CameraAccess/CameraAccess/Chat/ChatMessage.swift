import Foundation

struct ChatMessage: Identifiable, Equatable {
  let id: String
  let role: ChatMessageRole
  var text: String
  let timestamp: Date
  var status: ChatMessageStatus

  init(role: ChatMessageRole, text: String, status: ChatMessageStatus = .complete) {
    self.id = UUID().uuidString
    self.role = role
    self.text = text
    self.timestamp = Date()
    self.status = status
  }

  init(id: String, role: ChatMessageRole, text: String, timestamp: Date, status: ChatMessageStatus = .complete) {
    self.id = id
    self.role = role
    self.text = text
    self.timestamp = timestamp
    self.status = status
  }
}

enum ChatMessageRole: Equatable {
  case user
  case assistant
  case toolCall(String) // tool name
  case sessionDivider  // separator between sessions
}

enum ChatMessageStatus: Equatable {
  case streaming
  case complete
  case error(String)
}
