package com.meta.wearable.dat.externalsampleapps.cameraaccess.openclaw

import com.meta.wearable.dat.externalsampleapps.cameraaccess.conference.ConferenceSourceType
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
    data class Executing(val name: String) : ToolCallStatus()
    data class Completed(val name: String) : ToolCallStatus()
    data class Failed(val name: String, val error: String) : ToolCallStatus()
    data class Cancelled(val name: String) : ToolCallStatus()

    val displayText: String
        get() = when (this) {
            is Idle -> ""
            is Executing -> "Running: $name..."
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
    const val EXECUTE_NAME = "execute"
    const val EXTRACT_ENTITY_NAME = "extract_entity"

    data class ToolDeclaration(
        val name: String,
        val description: String,
        val parameters: Map<String, Any>,
        val behavior: String,
    )

    fun allDeclarations(conferenceModeEnabled: Boolean = false): List<ToolDeclaration> {
        return buildList {
            add(executeDeclaration())
            if (conferenceModeEnabled) {
                add(extractEntityDeclaration())
            }
        }
    }

    fun allDeclarationsJSON(conferenceModeEnabled: Boolean = false): JSONArray {
        return JSONArray().apply {
            allDeclarations(conferenceModeEnabled).forEach { declaration ->
                put(declaration.toJSON())
            }
        }
    }

    private fun executeDeclaration(): ToolDeclaration {
        return ToolDeclaration(
            name = EXECUTE_NAME,
            description = "Your only way to take action. You have no memory, storage, or ability to do anything on your own -- use this tool for everything: sending messages, searching the web, adding to lists, setting reminders, creating notes, research, drafts, scheduling, smart home control, app interactions, or any request that goes beyond answering a question. When in doubt, use this tool.",
            parameters = mapOf(
                "type" to "object",
                "properties" to mapOf(
                    "task" to mapOf(
                        "type" to "string",
                        "description" to "Clear, detailed description of what to do. Include all relevant context: names, content, platforms, quantities, etc.",
                    ),
                ),
                "required" to listOf("task"),
            ),
            behavior = "BLOCKING",
        )
    }

    private fun extractEntityDeclaration(): ToolDeclaration {
        return ToolDeclaration(
            name = EXTRACT_ENTITY_NAME,
            description = "Local-only conference mode extraction tool. Use it to silently report a detected badge, business card, booth sign, or slide without speaking.",
            parameters = mapOf(
                "type" to "object",
                "properties" to mapOf(
                    "name" to mapOf(
                        "type" to "string",
                        "description" to "Detected person or entity name.",
                    ),
                    "company" to mapOf(
                        "type" to "string",
                        "description" to "Detected company or organization name.",
                    ),
                    "role" to mapOf(
                        "type" to "string",
                        "description" to "Detected job title or role.",
                    ),
                    "source_type" to mapOf(
                        "type" to "string",
                        "enum" to ConferenceSourceType.entries.map { it.wireValue },
                        "description" to "Where the entity was detected.",
                    ),
                    "confidence" to mapOf(
                        "type" to "number",
                        "description" to "Confidence score from 0.0 to 1.0.",
                    ),
                    "observed_text" to mapOf(
                        "type" to "string",
                        "description" to "Optional raw snippet seen in the frame.",
                    ),
                ),
                "required" to listOf("name", "source_type", "confidence"),
            ),
            behavior = "NON_BLOCKING",
        )
    }

    private fun ToolDeclaration.toJSON(): JSONObject {
        return JSONObject().apply {
            put("name", name)
            put("description", description)
            put("parameters", parameters.toJSONObject())
            put("behavior", behavior)
        }
    }

    private fun Map<String, *>.toJSONObject(): JSONObject {
        return JSONObject().apply {
            entries.forEach { (key, value) ->
                put(key, value.toJsonValue())
            }
        }
    }

    private fun Any?.toJsonValue(): Any {
        return when (this) {
            null -> JSONObject.NULL
            is Map<*, *> -> {
                val mapped = entries.associate { (key, value) -> key.toString() to value }
                mapped.toJSONObject()
            }
            is List<*> -> JSONArray().apply {
                this@toJsonValue.forEach { item ->
                    put(item.toJsonValue())
                }
            }
            else -> this
        }
    }
}
