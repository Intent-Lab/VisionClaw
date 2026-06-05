package com.meta.wearable.dat.externalsampleapps.cameraaccess.chat

import android.content.Context
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

object ChatHistoryStore {
    private const val TAG = "ChatHistoryStore"
    private const val FILENAME = "chat_history.json"
    private const val MAX_MESSAGES = 500

    fun save(context: Context, messages: List<ChatMessage>) {
        try {
            val json = JSONArray()
            for (msg in messages.takeLast(MAX_MESSAGES)) {
                json.put(JSONObject().apply {
                    put("id", msg.id)
                    put("role", serializeRole(msg.role))
                    put("text", msg.text)
                    put("timestamp", msg.timestamp)
                    put("status", serializeStatus(msg.status))
                })
            }
            File(context.filesDir, FILENAME).writeText(json.toString())
        } catch (e: Exception) {
            Log.e(TAG, "Failed to save: ${e.message}")
        }
    }

    fun load(context: Context): List<ChatMessage> {
        val file = File(context.filesDir, FILENAME)
        if (!file.exists()) return emptyList()
        return try {
            val json = JSONArray(file.readText())
            val messages = mutableListOf<ChatMessage>()
            for (i in 0 until json.length()) {
                val obj = json.getJSONObject(i)
                val rawStatus = obj.optString("status", "complete")
                val text = obj.optString("text", "")
                // Fix stale "Executing..." messages from interrupted sessions
                val fixedText = if (rawStatus == "streaming" && text == "Executing...") "Cancelled" else text
                messages.add(ChatMessage(
                    id = obj.getString("id"),
                    role = deserializeRole(obj.getString("role")),
                    text = fixedText,
                    timestamp = obj.getLong("timestamp"),
                    status = deserializeStatus(rawStatus),
                ))
            }
            Log.d(TAG, "Loaded ${messages.size} messages")
            messages
        } catch (e: Exception) {
            Log.e(TAG, "Failed to load: ${e.message}")
            emptyList()
        }
    }

    private fun serializeRole(role: ChatMessageRole): String = when (role) {
        is ChatMessageRole.User -> "user"
        is ChatMessageRole.Assistant -> "assistant"
        is ChatMessageRole.ToolCall -> "tool:${role.name}"
        is ChatMessageRole.SessionDivider -> "divider"
    }

    private fun deserializeRole(s: String): ChatMessageRole = when {
        s == "user" -> ChatMessageRole.User
        s == "assistant" -> ChatMessageRole.Assistant
        s == "divider" -> ChatMessageRole.SessionDivider
        s.startsWith("tool:") -> ChatMessageRole.ToolCall(s.removePrefix("tool:"))
        else -> ChatMessageRole.Assistant
    }

    private fun serializeStatus(status: ChatMessageStatus): String = when (status) {
        is ChatMessageStatus.Streaming -> "streaming"
        is ChatMessageStatus.Complete -> "complete"
        is ChatMessageStatus.Error -> "error:${status.message}"
    }

    private fun deserializeStatus(s: String): ChatMessageStatus = when {
        s == "complete" -> ChatMessageStatus.Complete
        s == "streaming" -> ChatMessageStatus.Complete // treat stale streaming as complete
        s.startsWith("error:") -> ChatMessageStatus.Error(s.removePrefix("error:"))
        else -> ChatMessageStatus.Complete
    }
}
