import Foundation

@MainActor
class ToolCallRouter {
  private let bridge: OpenClawBridge
  private var inFlightTasks: [String: Task<Void, Never>] = [:]
  private var timedOutCalls = Set<String>()
  private var consecutiveFailures = 0
  private let maxConsecutiveFailures = 3
  private let geminiToolResponseBudgetNs: UInt64 = 20_000_000_000

  init(bridge: OpenClawBridge) {
    self.bridge = bridge
  }

  /// Route a tool call from Gemini to OpenClaw. Calls sendResponse with the
  /// JSON dictionary to send back as a toolResponse message.
  func handleToolCall(
    _ call: GeminiFunctionCall,
    sendResponse: @escaping ([String: Any]) -> Void,
    sendFollowUp: ((String) -> Void)? = nil
  ) {
    let callId = call.id
    let callName = call.name

    NSLog("[ToolCall] Received: %@ (id: %@) args: %@",
          callName, callId, String(describing: call.args))

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

    let taskDesc = call.args["task"] as? String ?? String(describing: call.args)

    let watchdog = Task { @MainActor in
      try? await Task.sleep(nanoseconds: geminiToolResponseBudgetNs)
      guard !Task.isCancelled, self.inFlightTasks[callId] != nil else { return }

      self.timedOutCalls.insert(callId)
      NSLog("[ToolCall] %@ exceeded Gemini response budget; sending interim response", callId)
      let interim: ToolResult = .success(
        "OpenClaw is still working on this. Tell the user it is taking longer than expected, " +
        "and that you will speak the final result when it comes back."
      )
      sendResponse(self.buildToolResponse(callId: callId, name: callName, result: interim))
    }

    let task = Task { @MainActor in
      let result = await bridge.delegateTask(task: taskDesc, toolName: callName)
      watchdog.cancel()

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

      if self.timedOutCalls.remove(callId) != nil {
        if let sendFollowUp {
          sendFollowUp(self.followUpText(for: result))
        }
      } else {
        let response = self.buildToolResponse(callId: callId, name: callName, result: result)
        sendResponse(response)
      }

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
    timedOutCalls.removeAll()
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
            "response": result.responseValue
          ]
        ]
      ]
    ]
  }

  private func followUpText(for result: ToolResult) -> String {
    switch result {
    case .success(let text):
      return "[OpenClaw finished the execute request. Speak this result to the user.]\n\n\(text)"
    case .failure(let error):
      return "[OpenClaw execute failed after the user was told it was still working. Explain this briefly.]\n\n\(error)"
    }
  }
}
