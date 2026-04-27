package com.meta.wearable.dat.externalsampleapps.cameraaccess.openclaw

import android.util.Log
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject

class ToolCallRouter(
    private val bridge: OpenClawBridge,
    private val scope: CoroutineScope
) {
    companion object {
        private const val TAG = "ToolCallRouter"
        private const val MAX_CONSECUTIVE_FAILURES = 3
    }

    private val inFlightJobs = mutableMapOf<String, Job>()
    // Concurrent tool calls update this from independent coroutines;
    // a plain Int can lose updates under contention.
    private val consecutiveFailures = AtomicInteger(0)

    fun handleToolCall(
        call: GeminiFunctionCall,
        sendResponse: (JSONObject) -> Unit
    ) {
        val callId = call.id
        val callName = call.name

        Log.d(TAG, "Received: $callName (id: $callId) args: ${call.args}")

        // Circuit breaker: stop sending tool calls after repeated failures
        val failureCount = consecutiveFailures.get()
        if (failureCount >= MAX_CONSECUTIVE_FAILURES) {
            Log.d(TAG, "Circuit breaker open ($failureCount consecutive failures), rejecting $callId")
            val errorResult = ToolResult.Failure(
                "Tool execution is temporarily unavailable after $failureCount consecutive failures. " +
                "Please tell the user you cannot complete this action right now and suggest they check their OpenClaw gateway connection."
            )
            sendResponse(buildToolResponse(callId, callName, errorResult))
            return
        }

        val job = scope.launch {
            val taskDesc = call.args["task"]?.toString() ?: call.args.toString()
            val result = bridge.delegateTask(task = taskDesc, toolName = callName)

            if (!coroutineContext[Job]!!.isCancelled) {
                Log.d(TAG, "Result for $callName (id: $callId): $result")

                when (result) {
                    is ToolResult.Success -> consecutiveFailures.set(0)
                    is ToolResult.Failure -> consecutiveFailures.incrementAndGet()
                }

                val response = buildToolResponse(callId, callName, result)
                sendResponse(response)
            } else {
                Log.d(TAG, "Task $callId was cancelled, skipping response")
            }

            inFlightJobs.remove(callId)
        }

        inFlightJobs[callId] = job
    }

    fun cancelToolCalls(ids: List<String>) {
        for (id in ids) {
            inFlightJobs[id]?.let { job ->
                Log.d(TAG, "Cancelling in-flight call: $id")
                job.cancel()
                inFlightJobs.remove(id)
            }
        }
        bridge.setToolCallStatus(ToolCallStatus.Cancelled(ids.firstOrNull() ?: "unknown"))
    }

    fun cancelAll() {
        for ((id, job) in inFlightJobs) {
            Log.d(TAG, "Cancelling in-flight call: $id")
            job.cancel()
        }
        inFlightJobs.clear()
        consecutiveFailures.set(0)
    }

    private fun buildToolResponse(
        callId: String,
        name: String,
        result: ToolResult
    ): JSONObject {
        return JSONObject().apply {
            put("toolResponse", JSONObject().apply {
                put("functionResponses", JSONArray().put(JSONObject().apply {
                    put("id", callId)
                    put("name", name)
                    put("response", result.toJSON())
                }))
            })
        }
    }
}
