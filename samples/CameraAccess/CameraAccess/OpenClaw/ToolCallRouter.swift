import Foundation
import UIKit

@MainActor
class ToolCallRouter {
  private let bridge: OpenClawBridge
  private var inFlightTasks: [String: Task<Void, Never>] = [:]
  private var consecutiveFailures = 0
  private let maxConsecutiveFailures = 3
  var frameProvider: (() -> UIImage?)?
  var inspectionHandler: ((_ action: String, _ focus: String?) -> Void)?
  var safetyHandler: ((_ action: String) -> Void)?
  var noteHandler: ((_ note: String, _ category: String?) -> Void)?
  var sessionContextProvider: (() -> SessionContext?)?
  var reportShareHandler: ((URL) -> Void)?

  init(bridge: OpenClawBridge) {
    self.bridge = bridge
  }

  func handleToolCall(
    _ call: GeminiFunctionCall,
    sendResponse: @escaping ([String: Any]) -> Void
  ) {
    let callId = call.id
    let callName = call.name

    NSLog("[ToolCall] Received: %@ (id: %@) args: %@",
          callName, callId, String(describing: call.args))

    // Local tools — no OpenClaw round-trip needed

    if callName == "save_photo" {
      let task = Task { @MainActor in
        let result = await handleSavePhoto(call)
        let response = self.buildToolResponse(callId: callId, name: callName, result: result)
        sendResponse(response)
        self.inFlightTasks.removeValue(forKey: callId)
      }
      inFlightTasks[callId] = task
      return
    }

    if callName == "generate_report" {
      let task = Task { @MainActor in
        let result = await self.handleGenerateReport(call)
        let response = self.buildToolResponse(callId: callId, name: callName, result: result)
        sendResponse(response)
        self.inFlightTasks.removeValue(forKey: callId)
      }
      inFlightTasks[callId] = task
      return
    }

    if callName == "knowledge_lookup" {
      let task = Task { @MainActor in
        let result = await self.handleKnowledgeLookup(call)
        let response = self.buildToolResponse(callId: callId, name: callName, result: result)
        sendResponse(response)
        self.inFlightTasks.removeValue(forKey: callId)
      }
      inFlightTasks[callId] = task
      return
    }

    if callName == "save_note" {
      let note = call.args["note"] as? String ?? ""
      let category = call.args["category"] as? String
      noteHandler?(note, category)
      let response = buildToolResponse(callId: callId, name: callName,
        result: .success("Note saved: \(note)"))
      sendResponse(response)
      return
    }

    if callName == "start_inspection" {
      let focus = call.args["focus"] as? String
      inspectionHandler?("start", focus)
      let response = buildToolResponse(callId: callId, name: callName,
        result: .success("Inspection mode started\(focus.map { ". Focus: \($0)" } ?? "")"))
      sendResponse(response)
      return
    }

    if callName == "stop_inspection" {
      inspectionHandler?("stop", nil)
      let response = buildToolResponse(callId: callId, name: callName,
        result: .success("Inspection mode stopped"))
      sendResponse(response)
      return
    }

    if callName == "start_safety_monitor" {
      safetyHandler?("start")
      let response = buildToolResponse(callId: callId, name: callName,
        result: .success("Safety monitoring activated. Watching for hazards, PPE violations, and unsafe conditions."))
      sendResponse(response)
      return
    }

    if callName == "stop_safety_monitor" {
      safetyHandler?("stop")
      let response = buildToolResponse(callId: callId, name: callName,
        result: .success("Safety monitoring deactivated"))
      sendResponse(response)
      return
    }

    // Circuit breaker: stop sending remote tool calls after repeated failures
    if consecutiveFailures >= maxConsecutiveFailures {
      NSLog("[ToolCall] Circuit breaker open (%d consecutive failures), rejecting %@",
            consecutiveFailures, callId)
      let errorResult: ToolResult = .failure(
        "Tool execution is temporarily unavailable after \(consecutiveFailures) consecutive failures. " +
        "Please tell the user you cannot complete this action right now and suggest they check their OpenClaw gateway connection."
      )
      let response = buildToolResponse(callId: callId, name: callName, result: errorResult)
      sendResponse(response)
      return
    }

    let task = Task { @MainActor in
      let taskDesc = call.args["task"] as? String ?? String(describing: call.args)
      let result = await bridge.delegateTask(task: taskDesc, toolName: callName)

      guard !Task.isCancelled else {
        NSLog("[ToolCall] Task %@ was cancelled, skipping response", callId)
        return
      }

      switch result {
      case .success:
        self.consecutiveFailures = 0
      case .failure:
        self.consecutiveFailures += 1
      }

      NSLog("[ToolCall] Result for %@ (id: %@): %@",
            callName, callId, String(describing: result))

      let response = self.buildToolResponse(callId: callId, name: callName, result: result)
      sendResponse(response)

      self.inFlightTasks.removeValue(forKey: callId)
    }

    inFlightTasks[callId] = task
  }

  func cancelToolCalls(ids: [String]) {
    for id in ids {
      if let task = inFlightTasks[id] {
        NSLog("[ToolCall] Cancelling in-flight call: %@", id)
        task.cancel()
        inFlightTasks.removeValue(forKey: id)
      }
    }
    bridge.lastToolCallStatus = .cancelled(ids.first ?? "unknown")
  }

  func cancelAll() {
    for (id, task) in inFlightTasks {
      NSLog("[ToolCall] Cancelling in-flight call: %@", id)
      task.cancel()
    }
    inFlightTasks.removeAll()
    consecutiveFailures = 0
  }

  // MARK: - Local Tool Handlers

  private func handleKnowledgeLookup(_ call: GeminiFunctionCall) async -> ToolResult {
    let query = call.args["query"] as? String ?? ""
    let context = call.args["context"] as? String
    guard !query.isEmpty else { return .failure("No search query provided.") }
    NSLog("[ToolCall] knowledge_lookup: query='%@' context='%@'", query, context ?? "none")
    let result: ToolResult
    if GeminiConfig.isOpenClawConfigured {
      let searchTask = "Search for technical information, specs, or documentation about: \(query)" + (context.map { ". Context: \($0)" } ?? "")
      result = await bridge.delegateTask(task: searchTask, toolName: "knowledge_lookup")
    } else {
      let searchResult = await WebSearchService.search(query)
      switch searchResult {
      case .success(let text): result = .success(text)
      case .failure(let error): result = .failure("Search failed: \(error.localizedDescription)")
      }
    }
    if case .success(let text) = result {
      noteHandler?("Lookup: \(query) — \(String(text.prefix(300)))", "reference")
    }
    return result
  }

  private func handleGenerateReport(_ call: GeminiFunctionCall) async -> ToolResult {
    guard let context = sessionContextProvider?() else {
      return .failure("No active session context. Start a session first.")
    }
    let title = call.args["title"] as? String ?? "Field Report"
    NSLog("[ToolCall] generate_report: creating PDF (%@)", title)
    let generator = ReportGenerator(context: context)
    let result = await generator.generatePDF(title: title)
    switch result {
    case .success(let fileURL):
      reportShareHandler?(fileURL)
      return .success("Report generated with \(context.notes.count) notes and \(context.photosSaved) photos. The share sheet is now open so the user can send it via AirDrop, email, or save to Files.")
    case .failure(let error):
      return .failure("Report generation failed: \(error.localizedDescription)")
    }
  }

  private func handleSavePhoto(_ call: GeminiFunctionCall) async -> ToolResult {
    guard let image = frameProvider?() else {
      NSLog("[ToolCall] save_photo: no frame available")
      return .failure("No video frame available to save. Make sure the camera is streaming.")
    }
    let description = call.args["description"] as? String ?? "photo"
    NSLog("[ToolCall] save_photo: saving frame (%@)", description)
    let result = await PhotoSaver.save(image)
    switch result {
    case .success:
      sessionContextProvider?()?.addPhoto(image: image, description: description)
      return .success("Photo saved to camera roll: \(description)")
    case .failure(let error):
      return .failure("Failed to save photo: \(error.localizedDescription)")
    }
  }

  // MARK: - Private

  private func buildToolResponse(
    callId: String,
    name: String,
    result: ToolResult
  ) -> [String: Any] {
    return [
      "toolResponse": [
        "functionResponses": [
          [
            "id": callId,
            "name": name,
            "response": result.responseValue
          ]
        ]
      ]
    ]
  }
}
