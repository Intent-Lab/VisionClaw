import Foundation
import UIKit

@MainActor
class ToolCallRouter {
  private let bridge: OpenClawBridge
  private var inFlightTasks: [String: Task<Void, Never>] = [:]

  /// Closure that returns the current video frame. Set by GeminiSessionViewModel.
  var currentFrameProvider: (() -> UIImage?)?

  init(bridge: OpenClawBridge) {
    self.bridge = bridge
  }

  /// Route a tool call from Gemini to OpenClaw. Calls sendResponse with the
  /// JSON dictionary to send back as a toolResponse message.
  func handleToolCall(
    _ call: GeminiFunctionCall,
    sendResponse: @escaping ([String: Any]) -> Void
  ) {
    let callId = call.id
    let callName = call.name

    NSLog("[ToolCall] Received: %@ (id: %@) args: %@",
          callName, callId, String(describing: call.args))

    let task = Task { @MainActor in
      let result: ToolResult

      if callName == "capture_and_send" {
        result = await self.handleCaptureAndSend(call)
      } else {
        let taskDesc = call.args["task"] as? String ?? String(describing: call.args)
        result = await bridge.delegateTask(task: taskDesc, toolName: callName)
      }

      guard !Task.isCancelled else {
        NSLog("[ToolCall] Task %@ was cancelled, skipping response", callId)
        return
      }

      NSLog("[ToolCall] Result for %@ (id: %@): %@",
            callName, callId, String(describing: result))

      let response = self.buildToolResponse(callId: callId, name: callName, result: result)
      sendResponse(response)

      self.inFlightTasks.removeValue(forKey: callId)
    }

    inFlightTasks[callId] = task
  }

  // MARK: - capture_and_send handler

  private func handleCaptureAndSend(_ call: GeminiFunctionCall) async -> ToolResult {
    let recipient = call.args["recipient"] as? String ?? "unknown"
    let message = call.args["message"] as? String ?? ""
    let platform = call.args["platform"] as? String ?? "whatsapp"

    // Grab the current video frame instantly
    guard let frame = currentFrameProvider?() else {
      NSLog("[ToolCall] capture_and_send: No video frame available")
      return .failure("No camera frame available. The camera may not be streaming.")
    }

    NSLog("[ToolCall] capture_and_send: Captured frame for %@ via %@", recipient, platform)

    // Build the task description for OpenClaw
    var taskParts: [String] = []
    taskParts.append("Send the attached photo to \(recipient) via \(platform).")
    if !message.isEmpty {
      taskParts.append("Include this caption/message: \"\(message)\"")
    }
    taskParts.append("The photo was just captured from smart glasses. Send it now.")

    let taskDesc = taskParts.joined(separator: " ")
    return await bridge.delegateTaskWithImage(task: taskDesc, image: frame, toolName: "capture_and_send")
  }

  /// Cancel specific in-flight tool calls (from toolCallCancellation)
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

  /// Cancel all in-flight tool calls (on session stop)
  func cancelAll() {
    for (id, task) in inFlightTasks {
      NSLog("[ToolCall] Cancelling in-flight call: %@", id)
      task.cancel()
    }
    inFlightTasks.removeAll()
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
