package com.meta.wearable.dat.externalsampleapps.cameraaccess.gemini

import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.GlobalScope
import kotlinx.coroutines.launch
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.util.concurrent.TimeUnit

/// Sends conversation events to the logging server for persistent logging.
/// All methods are fire-and-forget -- logging never blocks the UI or conversation flow.
object RemoteLogger {
    private const val TAG = "RemoteLogger"
    private val JSON_MEDIA = "application/json".toMediaType()

    private val client = OkHttpClient.Builder()
        .connectTimeout(5, TimeUnit.SECONDS)
        .readTimeout(5, TimeUnit.SECONDS)
        .writeTimeout(5, TimeUnit.SECONDS)
        .build()

    private var sequenceNumber = 0

    private val baseURL: String?
        get() {
            return if (GeminiConfig.isOpenClawConfigured) {
                "${GeminiConfig.openClawHost}:8080"
            } else {
                null
            }
        }

    /// Log a conversation event. Types:
    /// - "voice:user" -- user speech transcript from Gemini
    /// - "voice:ai" -- Gemini voice response transcript
    /// - "voice:tool_call" -- Gemini triggered execute tool
    /// - "voice:tool_result" -- tool result sent back to Gemini
    /// - "session:start" -- voice session started
    /// - "session:end" -- voice session ended
    fun log(type: String, data: Map<String, String> = emptyMap()) {
        val url = baseURL ?: return
        val loggingUrl = "$url/api/logs"

        sequenceNumber++
        val eventData = JSONObject().apply {
            put("event", type)
            put("seq", sequenceNumber)
            data.forEach { (k, v) -> put(k, v) }
        }

        val payload = JSONObject().apply {
            put("type", "event")
            put("session", "android-client")
            put("data", eventData)
        }

        // Fire and forget
        GlobalScope.launch(Dispatchers.IO) {
            try {
                val request = Request.Builder()
                    .url(loggingUrl)
                    .post(payload.toString().toRequestBody(JSON_MEDIA))
                    .addHeader("Content-Type", "application/json")
                    .addHeader("x-api-token", GeminiConfig.openClawGatewayToken)
                    .build()

                client.newCall(request).execute().use { /* close */ }
            } catch (e: Exception) {
                Log.d(TAG, "Failed to log event: ${e.message}")
            }
        }
    }
}
