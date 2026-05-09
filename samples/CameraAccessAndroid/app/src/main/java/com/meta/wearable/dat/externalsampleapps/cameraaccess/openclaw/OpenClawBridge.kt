package com.meta.wearable.dat.externalsampleapps.cameraaccess.openclaw

import android.util.Log
import com.meta.wearable.dat.externalsampleapps.cameraaccess.gemini.GeminiConfig
import com.meta.wearable.dat.externalsampleapps.cameraaccess.settings.SettingsManager
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject

enum class GatewayMode { LOCAL, REMOTE, NONE }

class OpenClawBridge {
    companion object {
        private const val TAG = "OpenClawBridge"
        private const val MAX_HISTORY_TURNS = 10
    }

    private val _lastToolCallStatus = MutableStateFlow<ToolCallStatus>(ToolCallStatus.Idle)
    val lastToolCallStatus: StateFlow<ToolCallStatus> = _lastToolCallStatus.asStateFlow()

    private val _connectionState = MutableStateFlow<OpenClawConnectionState>(OpenClawConnectionState.NotConfigured)
    val connectionState: StateFlow<OpenClawConnectionState> = _connectionState.asStateFlow()

    private val _gatewayMode = MutableStateFlow(GatewayMode.NONE)
    val gatewayMode: StateFlow<GatewayMode> = _gatewayMode.asStateFlow()

    fun setToolCallStatus(status: ToolCallStatus) {
        _lastToolCallStatus.value = status
    }

    private val client = OkHttpClient.Builder()
        .readTimeout(120, TimeUnit.SECONDS)
        .connectTimeout(10, TimeUnit.SECONDS)
        .build()

    private val pingClient = OkHttpClient.Builder()
        .readTimeout(5, TimeUnit.SECONDS)
        .connectTimeout(5, TimeUnit.SECONDS)
        .build()

    private var sessionKey: String = "agent:main:glass"
    private val conversationHistory = mutableListOf<JSONObject>()

    /** Cached resolved base URL — set once during checkConnection(), reused by delegateTask() */
    var resolvedBaseURL: String? = null
        private set

    suspend fun checkConnection() = withContext(Dispatchers.IO) {
        if (!GeminiConfig.isOpenClawConfigured) {
            _connectionState.value = OpenClawConnectionState.NotConfigured
            _gatewayMode.value = GatewayMode.NONE
            resolvedBaseURL = null
            return@withContext
        }
        _connectionState.value = OpenClawConnectionState.Checking

        // Build candidates: remote first, then local
        data class Candidate(val url: String, val mode: GatewayMode)
        val candidates = mutableListOf<Candidate>()

        val remote = SettingsManager.openClawRemoteURL
        if (remote.isNotEmpty()) {
            candidates.add(Candidate(remote, GatewayMode.REMOTE))
        }

        val local = "${GeminiConfig.openClawHost}:${GeminiConfig.openClawPort}"
        candidates.add(Candidate(local, GatewayMode.LOCAL))

        for (candidate in candidates) {
            val result = probeGateway(candidate.url)
            when (result) {
                ProbeResult.REACHABLE -> {
                    resolvedBaseURL = candidate.url
                    _gatewayMode.value = candidate.mode
                    _connectionState.value = OpenClawConnectionState.Connected
                    Log.d(TAG, "Connected via ${candidate.mode} → ${candidate.url}")
                    return@withContext
                }
                is ProbeResult.AUTH_FAILED -> {
                    resolvedBaseURL = null
                    _gatewayMode.value = GatewayMode.NONE
                    _connectionState.value = OpenClawConnectionState.Unreachable(result.message)
                    return@withContext
                }
                ProbeResult.ENDPOINT_DISABLED -> {
                    resolvedBaseURL = null
                    _gatewayMode.value = GatewayMode.NONE
                    _connectionState.value = OpenClawConnectionState.Unreachable(
                        "chatCompletions endpoint disabled — enable it in openclaw.json"
                    )
                    return@withContext
                }
                ProbeResult.UNREACHABLE -> continue
            }
        }

        // All failed
        resolvedBaseURL = null
        _gatewayMode.value = GatewayMode.NONE
        val tried = candidates.joinToString { it.url }
        _connectionState.value = OpenClawConnectionState.Unreachable("No reachable gateway (tried: $tried)")
        Log.d(TAG, "All gateway endpoints unreachable")
    }

    fun resetSession() {
        conversationHistory.clear()
        Log.d(TAG, "Session reset (key retained: $sessionKey)")
    }

    suspend fun delegateTask(
        task: String,
        toolName: String = "execute"
    ): ToolResult = withContext(Dispatchers.IO) {
        _lastToolCallStatus.value = ToolCallStatus.Executing(toolName)

        val baseURL = resolvedBaseURL
        if (baseURL == null) {
            _lastToolCallStatus.value = ToolCallStatus.Failed(toolName, "No reachable gateway")
            return@withContext ToolResult.Failure("Gateway not connected. Check Settings → OpenClaw.")
        }

        val url = "$baseURL/v1/chat/completions"

        conversationHistory.add(JSONObject().apply {
            put("role", "user")
            put("content", task)
        })

        if (conversationHistory.size > MAX_HISTORY_TURNS * 2) {
            val trimmed = conversationHistory.takeLast(MAX_HISTORY_TURNS * 2)
            conversationHistory.clear()
            conversationHistory.addAll(trimmed)
        }

        Log.d(TAG, "Sending ${conversationHistory.size} messages via $baseURL")

        try {
            val messagesArray = JSONArray()
            for (msg in conversationHistory) {
                messagesArray.put(msg)
            }

            val body = JSONObject().apply {
                put("model", "openclaw")
                put("messages", messagesArray)
                put("stream", false)
            }

            val request = Request.Builder()
                .url(url)
                .post(body.toString().toRequestBody("application/json".toMediaType()))
                .addHeader("Authorization", "Bearer ${GeminiConfig.openClawGatewayToken}")
                .addHeader("Content-Type", "application/json")
                .addHeader("x-openclaw-session-key", sessionKey)
                .addHeader("x-openclaw-message-channel", "glass")
                .addHeader("x-openclaw-scopes", "operator.write")
                .build()

            val response = client.newCall(request).execute()
            val responseBody = response.body?.string() ?: ""
            val statusCode = response.code
            response.close()

            if (statusCode !in 200..299) {
                Log.d(TAG, "Chat failed: HTTP $statusCode - ${responseBody.take(200)}")
                if (statusCode == 0 || statusCode >= 500) resolvedBaseURL = null
                _lastToolCallStatus.value = ToolCallStatus.Failed(toolName, "HTTP $statusCode")
                return@withContext ToolResult.Failure("Agent returned HTTP $statusCode")
            }

            val json = JSONObject(responseBody)
            val choices = json.optJSONArray("choices")
            val content = choices?.optJSONObject(0)
                ?.optJSONObject("message")
                ?.optString("content", "")

            if (!content.isNullOrEmpty()) {
                conversationHistory.add(JSONObject().apply {
                    put("role", "assistant")
                    put("content", content)
                })
                Log.d(TAG, "Agent result: ${content.take(200)}")
                _lastToolCallStatus.value = ToolCallStatus.Completed(toolName)
                return@withContext ToolResult.Success(content)
            }

            conversationHistory.add(JSONObject().apply {
                put("role", "assistant")
                put("content", responseBody)
            })
            _lastToolCallStatus.value = ToolCallStatus.Completed(toolName)
            return@withContext ToolResult.Success(responseBody)
        } catch (e: Exception) {
            Log.e(TAG, "Agent error: ${e.message}")
            resolvedBaseURL = null
            _lastToolCallStatus.value = ToolCallStatus.Failed(toolName, e.message ?: "Unknown")
            return@withContext ToolResult.Failure("Agent error: ${e.message}")
        }
    }

    // Private

    private sealed class ProbeResult {
        data object REACHABLE : ProbeResult()
        data class AUTH_FAILED(val message: String) : ProbeResult()
        data object ENDPOINT_DISABLED : ProbeResult()
        data object UNREACHABLE : ProbeResult()
    }

    private fun probeGateway(baseURL: String): ProbeResult {
        // Step 1: Health check
        try {
            val healthReq = Request.Builder().url("$baseURL/health").get().build()
            val healthResp = pingClient.newCall(healthReq).execute()
            val healthCode = healthResp.code
            healthResp.close()
            if (healthCode !in 200..299) return ProbeResult.UNREACHABLE
        } catch (e: Exception) {
            return ProbeResult.UNREACHABLE
        }

        // Step 2: Verify chat completions endpoint
        try {
            val chatReq = Request.Builder()
                .url("$baseURL/v1/chat/completions")
                .get()
                .addHeader("Authorization", "Bearer ${GeminiConfig.openClawGatewayToken}")
                .addHeader("x-openclaw-message-channel", "glass")
                .build()
            val chatResp = pingClient.newCall(chatReq).execute()
            val code = chatResp.code
            chatResp.close()
            return when (code) {
                in 200..299, 405 -> ProbeResult.REACHABLE
                401, 403 -> ProbeResult.AUTH_FAILED("Authentication failed (HTTP $code) — check your gateway token")
                404 -> ProbeResult.ENDPOINT_DISABLED
                else -> ProbeResult.UNREACHABLE
            }
        } catch (e: Exception) {
            return ProbeResult.UNREACHABLE
        }
    }
}
