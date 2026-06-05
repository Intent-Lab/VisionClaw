package com.meta.wearable.dat.externalsampleapps.cameraaccess.openclaw

import org.json.JSONArray
import org.json.JSONObject

// Gemini Tool Call (parsed from server JSON)

data class GeminiFunctionCall(
    val id: String,
    val name: String,
    val args: Map<String, Any?>
)

data class GeminiToolCall(
    val functionCalls: List<GeminiFunctionCall>
) {
    companion object {
        fun fromJSON(json: JSONObject): GeminiToolCall? {
            val toolCall = json.optJSONObject("toolCall") ?: return null
            val calls = toolCall.optJSONArray("functionCalls") ?: return null
            val functionCalls = mutableListOf<GeminiFunctionCall>()
            for (i in 0 until calls.length()) {
                val call = calls.getJSONObject(i)
                val id = call.optString("id", "")
                val name = call.optString("name", "")
                if (id.isEmpty() || name.isEmpty()) continue
                val argsObj = call.optJSONObject("args")
                val args = mutableMapOf<String, Any?>()
                if (argsObj != null) {
                    for (key in argsObj.keys()) {
                        args[key] = argsObj.opt(key)
                    }
                }
                functionCalls.add(GeminiFunctionCall(id, name, args))
            }
            return if (functionCalls.isNotEmpty()) GeminiToolCall(functionCalls) else null
        }
    }
}

// Gemini Tool Call Cancellation

data class GeminiToolCallCancellation(
    val ids: List<String>
) {
    companion object {
        fun fromJSON(json: JSONObject): GeminiToolCallCancellation? {
            val cancellation = json.optJSONObject("toolCallCancellation") ?: return null
            val idsArray = cancellation.optJSONArray("ids") ?: return null
            val ids = mutableListOf<String>()
            for (i in 0 until idsArray.length()) {
                ids.add(idsArray.getString(i))
            }
            return if (ids.isNotEmpty()) GeminiToolCallCancellation(ids) else null
        }
    }
}

// Tool Result

sealed class ToolResult {
    data class Success(val result: String) : ToolResult()
    data class Failure(val error: String) : ToolResult()

    fun toJSON(): JSONObject = when (this) {
        is Success -> JSONObject().put("result", result)
        is Failure -> JSONObject().put("error", error)
    }
}

// Tool Call Status (for UI)

sealed class ToolCallStatus {
    data object Idle : ToolCallStatus()
    data class Executing(val name: String, val progressText: String? = null) : ToolCallStatus()
    data class Completed(val name: String) : ToolCallStatus()
    data class Failed(val name: String, val error: String) : ToolCallStatus()
    data class Cancelled(val name: String) : ToolCallStatus()

    val displayText: String
        get() = when (this) {
            is Idle -> ""
            is Executing -> progressText ?: "OpenClaw is working"
            is Completed -> "Done: $name"
            is Failed -> "Failed: $name - $error"
            is Cancelled -> "Cancelled: $name"
        }

    val isActive: Boolean
        get() = this is Executing
}

// OpenClaw Connection State

sealed class OpenClawConnectionState {
    data object NotConfigured : OpenClawConnectionState()
    data object Checking : OpenClawConnectionState()
    data object Connected : OpenClawConnectionState()
    data class Unreachable(val message: String) : OpenClawConnectionState()
}

// Tool Declarations (for Gemini setup message)

object ToolDeclarations {
    fun allDeclarationsJSON(): JSONArray {
        return JSONArray().apply {
            put(executeJSON())
            put(capturePhotoJSON())
        }
    }

    private fun capturePhotoJSON(): JSONObject {
        return JSONObject().apply {
            put("name", "capture_photo")
            put("description", "Capture and save the current camera frame as a photo. Use when the user asks to take a photo, capture what they see, save a picture, or snap a photo.")
            put("parameters", JSONObject().apply {
                put("type", "object")
                put("properties", JSONObject().apply {
                    put("description", JSONObject().apply {
                        put("type", "string")
                        put("description", "Brief description of what is in the photo")
                    })
                })
                put("required", JSONArray())
            })
        }
    }

    private fun executeJSON(): JSONObject {
        return JSONObject().apply {
            put("name", "execute")
            put("behavior", "NON_BLOCKING")
            put("description", "Your only way to take action. You have no memory, storage, or ability to do anything on your own -- use this tool for everything: sending messages, searching the web, adding to lists, setting reminders, creating notes, research, drafts, scheduling, smart home control, app interactions, or any request that goes beyond answering a question. When in doubt, use this tool.")
            put("parameters", JSONObject().apply {
                put("type", "object")
                put("properties", JSONObject().apply {
                    put("task", JSONObject().apply {
                        put("type", "string")
                        put("description", "Clear, detailed description of what to do. Include all relevant context: names, content, platforms, quantities, etc.")
                    })
                    put("include_image", JSONObject().apply {
                        put("type", "boolean")
                        put("description", "Set to true ONLY when the task requires the agent to see the current camera image (e.g. editing a photo, identifying a product by appearance, reading text from a sign). Do NOT set for tasks that can be described in text alone.")
                    })
                })
                put("required", JSONArray().put("task"))
            })
        }
    }
}
