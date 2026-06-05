import Foundation
import UIKit

@MainActor
class ToolCallRouter {
  private let bridge: OpenClawBridge
  private var inFlightTasks: [String: Task<Void, Never>] = [:]
  private var consecutiveFailures = 0
  private let maxConsecutiveFailures = 3

  /// Callback for local capture_photo handling. Called with (description, completion).
  var onCapturePhoto: ((_ description: String?, _ completion: @escaping (ToolResult) -> Void) -> Void)?

  /// Latest camera frame for include_image on execute tool calls.
  var latestFrame: UIImage?

  /// Callback to auto-save frame to gallery when image is attached to execute call.
  var onAutoSaveFrame: ((_ image: UIImage, _ description: String?) -> Void)?

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

    // Local tool: capture_photo; handle on-device and do not send to OpenClaw.
    if callName == "capture_photo" {
      let description = call.args["description"] as? String
      if let onCapturePhoto {
        onCapturePhoto(description) { [weak self] result in
          guard let self else { return }
          NSLog("[ToolCall] capture_photo result: %@", String(describing: result))
          let response = self.buildToolResponse(callId: callId, name: callName, result: result)
          sendResponse(response)
        }
      } else {
        let response = buildToolResponse(
          callId: callId,
          name: callName,
          result: .failure("capture_photo handler not configured")
        )
        sendResponse(response)
      }
      return
    }

    // Circuit breaker: stop sending tool calls after repeated failures
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
      // Attach image only when Gemini explicitly sets include_image=true
      let includeImage = call.args["include_image"] as? Bool ?? false
      let image: UIImage? = includeImage ? latestFrame : nil
      // Auto-save to gallery when image is attached
      if let image {
        onAutoSaveFrame?(image, String(taskDesc.prefix(100)))
      }
      let result = await bridge.delegateTask(task: taskDesc, toolName: callName, image: image)

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
    consecutiveFailures = 0
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
            "response": result.responseValue.merging(["scheduling": "INTERRUPT"]) { _, new in new }
          ]
        ]
      ]
    ]
  }
}
