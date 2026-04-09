import Foundation

// MARK: - Gemini Tool Call (parsed from server JSON)

struct GeminiFunctionCall {
  let id: String
  let name: String
  let args: [String: Any]
}

struct GeminiToolCall {
  let functionCalls: [GeminiFunctionCall]

  init?(json: [String: Any]) {
    guard let toolCall = json["toolCall"] as? [String: Any],
          let calls = toolCall["functionCalls"] as? [[String: Any]] else {
      return nil
    }
    self.functionCalls = calls.compactMap { call in
      guard let id = call["id"] as? String,
            let name = call["name"] as? String else { return nil }
      let args = call["args"] as? [String: Any] ?? [:]
      return GeminiFunctionCall(id: id, name: name, args: args)
    }
  }
}

// MARK: - Gemini Tool Call Cancellation

struct GeminiToolCallCancellation {
  let ids: [String]

  init?(json: [String: Any]) {
    guard let cancellation = json["toolCallCancellation"] as? [String: Any],
          let ids = cancellation["ids"] as? [String] else {
      return nil
    }
    self.ids = ids
  }
}

// MARK: - Tool Result

enum ToolResult {
  case success(String)
  case failure(String)

  var responseValue: [String: Any] {
    switch self {
    case .success(let result):
      return ["result": result]
    case .failure(let error):
      return ["error": error]
    }
  }
}

// MARK: - Tool Call Status (for UI)

enum ToolCallStatus: Equatable {
  case idle
  case executing(String)
  case completed(String)
  case failed(String, String)
  case cancelled(String)

  var displayText: String {
    switch self {
    case .idle: return ""
    case .executing(let name): return "Running: \(name)..."
    case .completed(let name): return "Done: \(name)"
    case .failed(let name, let err): return "Failed: \(name) - \(err)"
    case .cancelled(let name): return "Cancelled: \(name)"
    }
  }

  var isActive: Bool {
    if case .executing = self { return true }
    return false
  }
}

// MARK: - Tool Declarations (for Gemini setup message)

enum ToolDeclarations {
  static let executeName = "execute"
  static let extractEntityName = "extract_entity"

  static func allDeclarations(conferenceModeEnabled: Bool = false) -> [[String: Any]] {
    var declarations = [execute]
    if conferenceModeEnabled {
      declarations.append(extractEntity)
    }
    return declarations
  }

  static let execute: [String: Any] = [
    "name": executeName,
    "description": "Your only way to take action. You have no memory, storage, or ability to do anything on your own -- use this tool for everything: sending messages, searching the web, adding to lists, setting reminders, creating notes, research, drafts, scheduling, smart home control, app interactions, or any request that goes beyond answering a question. When in doubt, use this tool.",
    "parameters": [
      "type": "object",
      "properties": [
        "task": [
          "type": "string",
          "description": "Clear, detailed description of what to do. Include all relevant context: names, content, platforms, quantities, etc."
        ]
      ],
      "required": ["task"]
    ] as [String: Any],
    "behavior": "BLOCKING"
  ]

  static let extractEntity: [String: Any] = [
    "name": extractEntityName,
    "description": "Local-only conference mode extraction tool. Use it to silently report a detected badge, business card, booth sign, or slide without speaking.",
    "parameters": [
      "type": "object",
      "properties": [
        "name": [
          "type": "string",
          "description": "Detected person or entity name."
        ],
        "company": [
          "type": "string",
          "description": "Detected company or organization name."
        ],
        "role": [
          "type": "string",
          "description": "Detected job title or role."
        ],
        "source_type": [
          "type": "string",
          "enum": ConferenceSourceType.allCases.map(\.rawValue),
          "description": "Where the entity was detected."
        ],
        "confidence": [
          "type": "number",
          "description": "Confidence score from 0.0 to 1.0."
        ],
        "observed_text": [
          "type": "string",
          "description": "Optional raw snippet seen in the frame."
        ]
      ],
      "required": ["name", "source_type", "confidence"]
    ] as [String: Any],
    "behavior": "NON_BLOCKING"
  ]
}
