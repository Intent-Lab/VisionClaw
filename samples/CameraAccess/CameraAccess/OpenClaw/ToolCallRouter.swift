import Foundation

@MainActor
class ToolCallRouter {
  typealias DelegateTask = @MainActor (
    _ task: String,
    _ toolName: String
  ) async -> ToolResult

  private struct PendingBatch {
    let orderedCallIDs: [String]
    var pendingCallIDs: Set<String>
    var functionResponses: [String: [String: Any]] = [:]
    let sendResponse: ([String: Any]) -> Void
  }

  private let bridge: OpenClawBridge
  private let delegateTask: DelegateTask
  private var inFlightTasks: [String: Task<Void, Never>] = [:]
  private var batchIDsByCallID: [String: UUID] = [:]
  private var pendingBatches: [UUID: PendingBatch] = [:]
  private var consecutiveFailures = 0
  private let maxConsecutiveFailures = 3

  init(
    bridge: OpenClawBridge,
    delegateTask: DelegateTask? = nil
  ) {
    self.bridge = bridge
    self.delegateTask = delegateTask ?? { task, toolName in
      await bridge.delegateTask(task: task, toolName: toolName)
    }
  }

  /// Route a tool call from Gemini to OpenClaw. Calls sendResponse with the
  /// JSON dictionary to send back as a toolResponse message.
  func handleToolCalls(
    _ calls: [GeminiFunctionCall],
    sendResponse: @escaping ([String: Any]) -> Void
  ) {
    guard !calls.isEmpty else { return }
    let callIDs = calls.map(\.id)

    for call in calls {
      NSLog("[ToolCall] Received: %@ (id: %@)", call.name, call.id)
    }

    // Circuit breaker: stop sending tool calls after repeated failures
    if consecutiveFailures >= maxConsecutiveFailures {
      NSLog("[ToolCall] Circuit breaker open (%d consecutive failures), rejecting batch",
            consecutiveFailures)
      let errorResult: ToolResult = .failure(
        "Tool execution is temporarily unavailable after \(consecutiveFailures) consecutive failures. " +
        "Please tell the user you cannot complete this action right now and suggest they check their OpenClaw gateway connection."
      )
      let entries = calls.map {
        Self.buildFunctionResponse(callId: $0.id, name: $0.name, result: errorResult)
      }
      sendResponse(Self.buildToolResponse(functionResponses: entries))
      return
    }

    let batchID = UUID()
    pendingBatches[batchID] = PendingBatch(
      orderedCallIDs: callIDs,
      pendingCallIDs: Set(callIDs),
      sendResponse: sendResponse)

    for call in calls {
      batchIDsByCallID[call.id] = batchID
      let task = Task { @MainActor in
        guard !Task.isCancelled else {
          self.finishCancelledCall(callID: call.id, batchID: batchID)
          return
        }
        let taskDesc = call.args["task"] as? String ?? String(describing: call.args)
        let result = await self.delegateTask(taskDesc, call.name)

        guard !Task.isCancelled else {
          self.finishCancelledCall(callID: call.id, batchID: batchID)
          return
        }

        switch result {
        case .success:
          self.consecutiveFailures = 0
        case .failure:
          self.consecutiveFailures += 1
        }

        let succeeded: Bool
        if case .success = result {
          succeeded = true
        } else {
          succeeded = false
        }
        NSLog("[ToolCall] Completed: %@ (id: %@, success: %@)",
              call.name, call.id, succeeded ? "yes" : "no")
        self.finishCall(call, result: result, batchID: batchID)
      }
      inFlightTasks[call.id] = task
    }
  }

  /// Cancel specific in-flight tool calls (from toolCallCancellation)
  func cancelToolCalls(ids: [String]) {
    for id in ids {
      if let task = inFlightTasks[id],
         let batchID = batchIDsByCallID[id] {
        NSLog("[ToolCall] Cancelling in-flight call: %@", id)
        task.cancel()
        finishCancelledCall(callID: id, batchID: batchID)
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
    batchIDsByCallID.removeAll()
    pendingBatches.removeAll()
    consecutiveFailures = 0
  }

  // MARK: - Private

  private func finishCall(
    _ call: GeminiFunctionCall,
    result: ToolResult,
    batchID: UUID
  ) {
    inFlightTasks.removeValue(forKey: call.id)
    batchIDsByCallID.removeValue(forKey: call.id)

    guard var batch = pendingBatches[batchID],
          batch.pendingCallIDs.remove(call.id) != nil else { return }

    batch.functionResponses[call.id] = Self.buildFunctionResponse(
      callId: call.id,
      name: call.name,
      result: result)
    finishBatchIfReady(batch, batchID: batchID)
  }

  private func finishCancelledCall(callID: String, batchID: UUID) {
    inFlightTasks.removeValue(forKey: callID)
    batchIDsByCallID.removeValue(forKey: callID)

    guard var batch = pendingBatches[batchID],
          batch.pendingCallIDs.remove(callID) != nil else { return }

    NSLog("[ToolCall] Cancelled call %@; allowing sibling calls to continue", callID)
    finishBatchIfReady(batch, batchID: batchID)
  }

  private func finishBatchIfReady(_ batch: PendingBatch, batchID: UUID) {
    guard batch.pendingCallIDs.isEmpty else {
      pendingBatches[batchID] = batch
      return
    }

    pendingBatches.removeValue(forKey: batchID)
    let orderedResponses = batch.orderedCallIDs.compactMap {
      batch.functionResponses[$0]
    }
    guard !orderedResponses.isEmpty else { return }
    batch.sendResponse(Self.buildToolResponse(functionResponses: orderedResponses))
  }

  static func buildFunctionResponse(
    callId: String,
    name: String,
    result: ToolResult
  ) -> [String: Any] {
    [
      "id": callId,
      "name": name,
      "response": result.responseValue
    ]
  }

  static func buildToolResponse(functionResponses: [[String: Any]]) -> [String: Any] {
    [
      "toolResponse": [
        "functionResponses": functionResponses
      ]
    ]
  }
}
