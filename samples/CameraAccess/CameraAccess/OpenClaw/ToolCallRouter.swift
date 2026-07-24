import Foundation

@MainActor
class ToolCallRouter {
  typealias DelegateTask = @MainActor (
    _ task: String,
    _ toolName: String
  ) async -> ToolResult
  typealias RouteHarness = @MainActor (
    _ request: NamedHarnessRouteRequest,
    _ toolName: String
  ) async -> ToolResult
  typealias CaptureMedia = @MainActor (
    _ request: GlassesMediaRequest,
    _ callID: String,
    _ transcriptionEpoch: UInt64
  ) async -> ToolResult

  private struct PendingBatch {
    let orderedCallIDs: [String]
    var pendingCallIDs: Set<String>
    var functionResponses: [String: [String: Any]] = [:]
    let sendResponse: ([String: Any]) -> Void
  }

  private let bridge: OpenClawBridge
  private let delegateTask: DelegateTask
  private let routeHarness: RouteHarness?
  private let captureMedia: CaptureMedia?
  private var inFlightTasks: [String: Task<Void, Never>] = [:]
  private var batchIDsByCallID: [String: UUID] = [:]
  private var pendingBatches: [UUID: PendingBatch] = [:]

  init(
    bridge: OpenClawBridge,
    delegateTask: DelegateTask? = nil,
    routeHarness: RouteHarness? = nil,
    captureMedia: CaptureMedia? = nil
  ) {
    self.bridge = bridge
    self.delegateTask = delegateTask ?? { task, toolName in
      await bridge.delegateTask(task: task, toolName: toolName)
    }
    self.routeHarness = routeHarness
    self.captureMedia = captureMedia
  }

  /// Route a tool call from Gemini to OpenClaw. Calls sendResponse with the
  /// JSON dictionary to send back as a toolResponse message.
  func handleToolCalls(
    _ calls: [GeminiFunctionCall],
    mediaAuthorizationEpoch: UInt64? = nil,
    sendResponse: @escaping ([String: Any]) -> Void
  ) {
    guard !calls.isEmpty else { return }
    let callIDs = calls.map(\.id)

    for call in calls {
      NSLog("[ToolCall] Received: %@ (id: %@)", call.name, call.id)
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
        let result = await self.execute(
          call,
          mediaAuthorizationEpoch: mediaAuthorizationEpoch
        )

        guard !Task.isCancelled else {
          self.finishCancelledCall(callID: call.id, batchID: batchID)
          return
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
  }

  // MARK: - Private

  private func execute(
    _ call: GeminiFunctionCall,
    mediaAuthorizationEpoch: UInt64?
  ) async -> ToolResult {
    switch call.name {
    case "execute":
      let task = call.args["task"] as? String ?? String(describing: call.args)
      return await delegateTask(task, call.name)

    case "route_harness":
      guard let routeHarness,
            let target = call.args["target"] as? String else {
        return .failure(
          "Named harness routing is not securely paired. No action was taken."
        )
      }
      let operation = (call.args["operation"] as? String)
        .flatMap(NamedHarnessOperation.init(rawValue:))
      let suppliedRequestID = call.args["clientRequestID"] as? String
      let needsGeneratedRequestID =
        operation == .execute || operation == .prepareContinue
      let clientRequestID = needsGeneratedRequestID
        ? suppliedRequestID ?? call.id
        : suppliedRequestID
      let request = NamedHarnessRouteRequest(
        targetName: target,
        operation: operation,
        task: call.args["task"] as? String ?? "",
        taskReference: call.args["taskReference"] as? String,
        actionReference: call.args["actionReference"] as? String,
        clientRequestID: clientRequestID
      )
      return await routeHarness(request, call.name)

    case "capture_media":
      guard let captureMedia,
            let request = GlassesMediaRequest(args: call.args),
            let mediaAuthorizationEpoch else {
        return .failure(
          "The glasses media request is unavailable or invalid. No media was captured."
        )
      }
      return await captureMedia(
        request,
        call.id,
        mediaAuthorizationEpoch
      )

    default:
      return .failure(
        "Unsupported tool \(call.name). No external request was sent."
      )
    }
  }

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

  static func blockedProactiveToolResponse(
    for calls: [GeminiFunctionCall]
  ) -> [String: Any] {
    let responses = calls.map { call in
      buildFunctionResponse(
        callId: call.id,
        name: call.name,
        result: .failure(
          "Tools are disabled while speaking an untrusted backend status update. " +
          "Wait for a new spoken request."
        )
      )
    }
    return buildToolResponse(functionResponses: responses)
  }
}
