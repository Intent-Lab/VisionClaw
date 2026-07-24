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

// MARK: - Local glasses media requests

enum GlassesMediaKind: String, Equatable {
  case snapshot
  case video
}

struct GlassesMediaRequest: Equatable {
  let kind: GlassesMediaKind
  let requestedDurationSeconds: Int?

  init?(args: [String: Any]) {
    guard let rawKind = args["kind"] as? String,
          let kind = GlassesMediaKind(rawValue: rawKind) else {
      return nil
    }
    self.kind = kind
    if let duration = args["durationSeconds"] as? Int {
      self.requestedDurationSeconds = min(max(duration, 1), 30)
    } else if let duration = args["durationSeconds"] as? Double {
      self.requestedDurationSeconds = min(max(Int(duration.rounded()), 1), 30)
    } else {
      self.requestedDurationSeconds = nil
    }
  }
}

// MARK: - Tool Result

enum ToolResult {
  case success(String)
  case failure(String)

  static let maxResponseCharacters = 12_000

  private static func bounded(_ value: String) -> String {
    guard value.count > maxResponseCharacters else { return value }
    let marker = "\n\n[response truncated]"
    return String(value.prefix(maxResponseCharacters - marker.count)) + marker
  }

  var responseValue: [String: Any] {
    switch self {
    case .success(let result):
      return ["result": Self.bounded(result)]
    case .failure(let error):
      return ["error": Self.bounded(error)]
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

  static func allDeclarations(
    namedRoutingEnabled: Bool = false,
    registry: NamedHarnessRegistry = .standard()
  ) -> [[String: Any]] {
    var declarations: [[String: Any]]
    if namedRoutingEnabled {
      declarations = [routeHarness(registry: registry)]
    } else {
      declarations = [execute]
    }
    if GlassesSessionFeaturePolicy.voiceSnapshotEnabled {
      declarations.append(captureMedia)
    }
    return declarations
  }

  static let execute: [String: Any] = [
    "name": "execute",
    "description": "Your mandatory connection to OpenClaw and all external systems. Use it to inspect OpenClaw agents, sessions, skills, tools, status, configuration, capabilities, and environment, and for actions such as messages, web search, lists, reminders, notes, research, drafts, scheduling, smart-home control, and app interactions. For every OpenClaw question or request, call this tool; never infer the answer from the camera. Speak exactly one short pending acknowledgement before calling. After the call, stop speaking and wait; never report success or a result until this tool returns. When in doubt, use this tool.",
    "parameters": [
      "type": "object",
      "properties": [
        "task": [
          "type": "string",
          "description": "Clear, detailed description of what to do. Include all relevant context: names, content, platforms, quantities, etc."
        ]
      ],
      "required": ["task"]
    ] as [String: Any]
  ]

  static let captureMedia: [String: Any] = [
    "name": "capture_media",
    "description": "Capture media from the active glasses session. Use snapshot for a fresh still image before answering a visual request that explicitly asks to take or save a picture. Video recording is not available through DAT 0.8; calling video returns an explicit native Meta fallback instead of pretending to record.",
    "parameters": [
      "type": "object",
      "properties": [
        "kind": [
          "type": "string",
          "enum": ["snapshot", "video"],
          "description": "The requested media type."
        ],
        "durationSeconds": [
          "type": "integer",
          "minimum": 1,
          "maximum": 30,
          "description": "Requested video duration. Ignored for snapshots."
        ]
      ],
      "required": ["kind"]
    ] as [String: Any]
  ]

  static func routeHarness(
    registry: NamedHarnessRegistry
  ) -> [String: Any] {
    [
      "name": "route_harness",
      "description": "Route a request to one registered named harness. Available names: \(registry.promptDescription). Use the name spoken by the user. Never silently substitute another harness; return the explicit fallback or unavailable status.",
      "parameters": [
        "type": "object",
        "properties": [
          "target": [
            "type": "string",
            "description": "Registered invocation name spoken by the user."
          ],
          "operation": [
            "type": "string",
            "enum": NamedHarnessOperation.allCases.map(\.rawValue),
            "description": "Scoped operation. Eva uses execute; Meta uses handoff; Codex uses only the listed task operations."
          ],
          "task": [
            "type": "string",
            "description": "The user's request or Codex continuation instruction."
          ],
          "taskReference": [
            "type": "string",
            "description": "Opaque task reference returned by the scoped Codex bridge."
          ],
          "actionReference": [
            "type": "string",
            "description": "Opaque action reference used only for operation_status and cancel_operation. Prepared continuations are confirmed exclusively in VisionClaw's trusted iPhone sheet."
          ],
          "clientRequestID": [
            "type": "string",
            "description": "Replay-safe request ID returned by prepare_continue. Reuse it unchanged only for that action's status or cancellation; continuation approval is available exclusively in VisionClaw's trusted iPhone sheet."
          ],
        ],
        "required": ["target", "operation"]
      ] as [String: Any]
    ]
  }
}
