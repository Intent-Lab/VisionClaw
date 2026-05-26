// app/src/main/java/com/meta/wearable/dat/externalsampleapps/cameraaccess/openclaw/ToolCallRouter.kt
package com.meta.wearable.dat.externalsampleapps.cameraaccess.openclaw

import android.graphics.Bitmap
import android.util.Log
import com.meta.wearable.dat.externalsampleapps.cameraaccess.settings.SettingsManager
import java.io.ByteArrayOutputStream
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancel
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject

class ToolCallRouter(
    private val bridge: OpenClawBridge,
    private val scope: CoroutineScope,
    private val latestFrameProvider: () -> Bitmap?,
    private val originalInstructionProvider: () -> String?
) {
    companion object {
        private const val TAG = "ToolCallRouter"
        private const val JPEG_QUALITY_FOR_UPLOAD = 92
        private const val MAX_CONSECUTIVE_FAILURES = 3
    }

    /** Callback for local capture_photo handling. */
    var onCapturePhoto: ((description: String?, completion: (ToolResult) -> Unit) -> Unit)? = null

    /** Callback to auto-save frame to gallery when image is attached to execute call. */
    var onAutoSaveFrame: ((Bitmap, String?) -> Unit)? = null

    private val inFlightJobs = mutableMapOf<String, Job>()
    private val pendingDuplicateExecuteResponses = mutableListOf<PendingDuplicateExecute>()
    private var activeExecuteCallId: String? = null
    private var consecutiveFailures = 0

    private data class PendingDuplicateExecute(
        val callId: String,
        val callName: String,
        val sendResponse: (JSONObject) -> Unit
    )

    fun handleToolCall(
        call: GeminiFunctionCall,
        sendResponse: (JSONObject) -> Unit
    ) {
        val callId = call.id
        val callName = call.name

        Log.d(TAG, "Received: $callName (id: $callId) args: ${call.args}")

        // Local tool: capture_photo; handle on-device and do not send to OpenClaw.
        if (callName == "capture_photo") {
            val description = call.args["description"]?.toString()
            onCapturePhoto?.invoke(description) { result ->
                Log.d(TAG, "capture_photo result: $result")
                val response = buildToolResponse(callId, callName, result)
                sendResponse(response)
            } ?: run {
                val response = buildToolResponse(callId, callName, ToolResult.Failure("capture_photo handler not configured"))
                sendResponse(response)
            }
            return
        }

        // Circuit breaker: stop sending tool calls after repeated failures
        if (consecutiveFailures >= MAX_CONSECUTIVE_FAILURES) {
            Log.d(TAG, "Circuit breaker open ($consecutiveFailures consecutive failures), rejecting $callId")
            val errorResult = ToolResult.Failure(
                "Tool execution is temporarily unavailable after $consecutiveFailures consecutive failures. " +
                "Please tell the user you cannot complete this action right now and suggest they check their OpenClaw gateway connection."
            )
            sendResponse(buildToolResponse(callId, callName, errorResult))
            return
        }

        if (callName == "execute" && activeExecuteCallId != null) {
            Log.w(TAG, "Coalescing duplicate execute call $callId into active call $activeExecuteCallId")
            pendingDuplicateExecuteResponses.add(
                PendingDuplicateExecute(
                    callId = callId,
                    callName = callName,
                    sendResponse = sendResponse
                )
            )
            return
        }

        if (callName == "execute") {
            activeExecuteCallId = callId
        }

        val job = scope.launch {
            // Gemini-provided task text after tool-call argument rewriting.
            val rewrittenTask = call.args["task"]?.toString() ?: call.args.toString()

            // Original transcript captured before Gemini rewrote the tool arguments.
            val original = originalInstructionProvider()
                ?.trim()
                ?.takeIf { it.isNotEmpty() }

            // Attach image only when Gemini explicitly sets include_image=true
            val includeImage = call.args["include_image"] as? Boolean ?: false
            val bitmap = if (includeImage) latestFrameProvider() else null
            Log.d(TAG, "include_image=$includeImage, bitmapNull=${bitmap == null}")

            val imageBase64: String? = if (includeImage && bitmap != null) {
                try {
                    // Auto-save to gallery
                    onAutoSaveFrame?.invoke(bitmap, rewrittenTask.take(100))
                    val baos = ByteArrayOutputStream()
                    bitmap.compress(Bitmap.CompressFormat.JPEG, JPEG_QUALITY_FOR_UPLOAD, baos)
                    android.util.Base64.encodeToString(baos.toByteArray(), android.util.Base64.NO_WRAP)
                } catch (e: Exception) {
                    Log.w(TAG, "Image encoding failed for tool-call $callId: ${e.message}")
                    null
                }
            } else {
                null
            }

            // Build task payload with original instruction context
            val taskPayload = buildString {
                if (original != null) {
                    append("[original_instruction]\n")
                    append(original)
                    append("\n\n")
                }
                append("[gemini_rewritten_instruction]\n")
                append(rewrittenTask)
            }

            val result = bridge.delegateTask(task = taskPayload, toolName = callName, imageBase64 = imageBase64)

            // Do not send a tool response for cancelled calls.
            if (!isActive) {
                Log.d(TAG, "Task $callId cancelled; skipping response")
                return@launch
            }

            when (result) {
                is ToolResult.Success -> consecutiveFailures = 0
                is ToolResult.Failure -> consecutiveFailures++
            }

            val response = buildToolResponse(callId, callName, result)
            sendResponse(response)

            if (callName == "execute") {
                val duplicates = pendingDuplicateExecuteResponses.toList()
                pendingDuplicateExecuteResponses.clear()
                activeExecuteCallId = null
                for (duplicate in duplicates) {
                    duplicate.sendResponse(
                        buildToolResponse(
                            callId = duplicate.callId,
                            name = duplicate.callName,
                            result = result
                        )
                    )
                }
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
        bridge.cancelInFlight("tool cancellation ids=$ids")
        bridge.setToolCallStatus(ToolCallStatus.Cancelled(ids.firstOrNull() ?: "unknown"))
        pendingDuplicateExecuteResponses.removeAll { it.callId in ids }
        if (activeExecuteCallId in ids) {
            activeExecuteCallId = null
            pendingDuplicateExecuteResponses.clear()
        }
    }

    fun cancelAll() {
        for ((id, job) in inFlightJobs) {
            Log.d(TAG, "Cancelling in-flight call: $id")
            job.cancel()
        }
        inFlightJobs.clear()
        activeExecuteCallId = null
        pendingDuplicateExecuteResponses.clear()
        bridge.cancelInFlight("cancelAll")
        consecutiveFailures = 0
    }

    private fun buildToolResponse(
        callId: String,
        name: String,
        result: ToolResult
    ): JSONObject {
        return JSONObject().apply {
            put(
                "toolResponse",
                JSONObject().apply {
                    put(
                        "functionResponses",
                        JSONArray().put(
                            JSONObject().apply {
                                put("id", callId)
                                put("name", name)
                                put("response", result.toJSON().apply {
                                    put("scheduling", "INTERRUPT")
                                })
                            }
                        )
                    )
                }
            )
        }
    }
}
