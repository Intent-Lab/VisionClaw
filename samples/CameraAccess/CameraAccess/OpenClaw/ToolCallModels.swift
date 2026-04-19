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
    case .cancelled: return ""
    }
  }

  var isActive: Bool {
    if case .executing = self { return true }
    return false
  }
}

// MARK: - Tool Declarations (for Gemini setup message)

enum ToolDeclarations {

  static func allDeclarations() -> [[String: Any]] {
    return [execute, savePhoto, saveNote, generateReport, knowledgeLookup, startInspection, stopInspection, startSafetyMonitor, stopSafetyMonitor]
  }

  static let savePhoto: [String: Any] = [
    "name": "save_photo",
    "description": "Save what you currently see through the glasses camera to the user's photo library. Use when the user asks to capture, save, snap, or photograph what they're looking at.",
    "parameters": [
      "type": "object",
      "properties": [
        "description": [
          "type": "string",
          "description": "Brief description of what's being captured for the user's confirmation"
        ]
      ],
      "required": ["description"]
    ] as [String: Any],
    "behavior": "BLOCKING"
  ]

  static let saveNote: [String: Any] = [
    "name": "save_note",
    "description": "Save an observation, measurement, hazard, or action item as a field note for the current job session. Use whenever the worker mentions something worth recording, or when inspection mode detects something noteworthy. Always save important findings.",
    "parameters": [
      "type": "object",
      "properties": [
        "note": [
          "type": "string",
          "description": "The observation or note to save"
        ],
        "category": [
          "type": "string",
          "description": "Category: observation, hazard, measurement, or action_item"
        ]
      ],
      "required": ["note"]
    ] as [String: Any],
    "behavior": "BLOCKING"
  ]

  static let generateReport: [String: Any] = [
    "name": "generate_report",
    "description": "Generate a structured PDF field report from the current session. Compiles all job context, notes, GPS location, and timestamps into a professional report document. Use when the user says 'generate my field report', 'create a report', 'compile my findings', 'write up my report', etc.",
    "parameters": [
      "type": "object",
      "properties": [
        "title": [
          "type": "string",
          "description": "Optional custom title for the report. Defaults to 'Field Report' if not provided."
        ]
      ],
      "required": []
    ] as [String: Any],
    "behavior": "BLOCKING"
  ]

  static let knowledgeLookup: [String: Any] = [
    "name": "knowledge_lookup",
    "description": "Look up technical information, specs, part numbers, model details, or any reference material. Use when the user says 'look this up', 'what is this', 'find the specs', 'search for this part number', etc. Read any visible text from the camera first, then search for detailed information about it.",
    "parameters": [
      "type": "object",
      "properties": [
        "query": [
          "type": "string",
          "description": "The search query — include part numbers, model names, manufacturer, or any text read from the camera"
        ],
        "context": [
          "type": "string",
          "description": "Brief description of what the worker is looking at for context"
        ]
      ],
      "required": ["query"]
    ] as [String: Any],
    "behavior": "BLOCKING"
  ]

  static let startInspection: [String: Any] = [
    "name": "start_inspection",
    "description": "Start proactive inspection mode. The AI will continuously analyze the camera feed and speak up when it spots damage, safety hazards, code violations, wear, or anything noteworthy. Use when the user says 'start inspection', 'begin inspection', 'inspect this', or similar.",
    "parameters": [
      "type": "object",
      "properties": [
        "focus": [
          "type": "string",
          "description": "Optional focus area for the inspection (e.g. 'electrical', 'plumbing', 'structural', 'safety'). Leave empty for general inspection."
        ]
      ],
      "required": []
    ] as [String: Any],
    "behavior": "BLOCKING"
  ]

  static let stopInspection: [String: Any] = [
    "name": "stop_inspection",
    "description": "Stop proactive inspection mode. Use when the user says 'stop inspection', 'end inspection', 'done inspecting', or similar.",
    "parameters": [
      "type": "object",
      "properties": [:],
      "required": []
    ] as [String: Any],
    "behavior": "BLOCKING"
  ]

  static let startSafetyMonitor: [String: Any] = [
    "name": "start_safety_monitor",
    "description": "Start continuous safety monitoring. The AI will actively watch for safety hazards, OSHA violations, missing PPE, electrical dangers, fall risks, chemical exposure, fire risks, and unsafe conditions. Use when the user says 'enable safety', 'start safety monitoring', 'watch for hazards', or similar.",
    "parameters": [
      "type": "object",
      "properties": [:],
      "required": []
    ] as [String: Any],
    "behavior": "BLOCKING"
  ]

  static let stopSafetyMonitor: [String: Any] = [
    "name": "stop_safety_monitor",
    "description": "Stop safety monitoring. Use when the user says 'stop safety monitoring', 'disable safety', or similar.",
    "parameters": [
      "type": "object",
      "properties": [:],
      "required": []
    ] as [String: Any],
    "behavior": "BLOCKING"
  ]

  static let execute: [String: Any] = [
    "name": "execute",
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
}
