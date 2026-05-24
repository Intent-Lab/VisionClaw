package com.meta.wearable.dat.externalsampleapps.cameraaccess.openclaw

import android.os.Handler
import android.os.Looper
import android.util.Log
import com.meta.wearable.dat.externalsampleapps.cameraaccess.gemini.GeminiConfig
import java.util.UUID
import java.util.concurrent.TimeUnit
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import org.json.JSONArray
import org.json.JSONObject

class OpenClawEventClient {
    companion object {
        private const val TAG = "OpenClawEventClient"
        private const val MAX_RECONNECT_DELAY_MS = 30_000L
    }

    var onNotification: ((String) -> Unit)? = null

    private var webSocket: WebSocket? = null
    private var isConnected = false
    private var shouldReconnect = false
    private var reconnectDelayMs = 2_000L
    private val handler = Handler(Looper.getMainLooper())

    // Pending RPC responses keyed by request ID
    private val pendingResponses = mutableMapOf<String, (JSONObject) -> Unit>()

    // Pending chat.send results keyed by runId — waits for the "chat" event with state="final"
    private val pendingChatResults = mutableMapOf<String, (String?) -> Unit>()

    private val client = OkHttpClient.Builder()
        .readTimeout(0, TimeUnit.MILLISECONDS)
        .pingInterval(10, TimeUnit.SECONDS)
        .build()

    fun connect() {
        if (!GeminiConfig.isOpenClawConfigured) {
            Log.d(TAG, "Not configured, skipping")
            return
        }
        shouldReconnect = true
        reconnectDelayMs = 2_000L
        establishConnection()
    }

    fun disconnect() {
        shouldReconnect = false
        isConnected = false
        handler.removeCallbacksAndMessages(null)
        // Cancel all pending callbacks so they don't fire after session stops
        pendingResponses.clear()
        pendingChatResults.clear()
        webSocket?.close(1000, null)
        webSocket = null
        Log.d(TAG, "Disconnected")
    }

    private fun establishConnection() {
        val host = GeminiConfig.openClawHost
            .replace("http://", "")
            .replace("https://", "")
        val port = GeminiConfig.openClawPort
        val url = "ws://$host:$port"

        Log.d(TAG, "Connecting to $url")

        val request = Request.Builder()
            .url(url)
            .header("Host", "localhost:${GeminiConfig.openClawPort}")
            .build()
        webSocket = client.newWebSocket(request, object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                Log.d(TAG, "WebSocket opened")
            }

            override fun onMessage(webSocket: WebSocket, text: String) {
                handleMessage(text)
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                Log.e(TAG, "WebSocket failure: ${t.message}")
                isConnected = false
                scheduleReconnect()
            }

            override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
                Log.d(TAG, "WebSocket closing: $code $reason")
                isConnected = false
                scheduleReconnect()
            }
        })
    }

    private fun handleMessage(text: String) {
        try {
            val json = JSONObject(text)
            val type = json.optString("type", "")

            when (type) {
                "event" -> handleEvent(json)
                "res" -> {
                    val id = json.optString("id", "")
                    val callback = pendingResponses.remove(id)
                    if (callback != null) {
                        callback(json)
                    } else {
                        // Connect handshake response
                        val ok = json.optBoolean("ok", false)
                        if (ok) {
                            Log.d(TAG, "Connected and authenticated")
                            isConnected = true
                            reconnectDelayMs = 2_000L
                        } else {
                            val error = json.optJSONObject("error")
                            val msg = error?.optString("message", "unknown") ?: "unknown"
                            Log.e(TAG, "Connect failed: $msg")
                        }
                    }
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Parse error: ${e.message}")
        }
    }

    private fun handleEvent(json: JSONObject) {
        val event = json.optString("event", "")
        val payload = json.optJSONObject("payload") ?: JSONObject()

        when (event) {
            "connect.challenge" -> sendConnectHandshake()
            "heartbeat" -> handleHeartbeatEvent(payload)
            "cron" -> handleCronEvent(payload)
            "chat" -> handleChatEvent(payload)
        }
    }

    private fun handleChatEvent(payload: JSONObject) {
        val state = payload.optString("state", "")
        val runId = payload.optString("runId", "")

        if (state == "final" && runId.isNotEmpty()) {
            val callback = pendingChatResults.remove(runId)
            if (callback != null) {
                // Extract reply text from message.content
                val message = payload.optJSONObject("message")
                val content = message?.opt("content")
                val replyText = when {
                    content is String -> content
                    content is JSONArray -> {
                        val parts = mutableListOf<String>()
                        for (i in 0 until content.length()) {
                            val part = content.optJSONObject(i)
                            if (part?.optString("type") == "text") {
                                parts.add(part.optString("text", ""))
                            }
                        }
                        parts.joinToString("\n").ifEmpty { null }
                    }
                    else -> null
                }
                Log.d(TAG, "chat final for $runId: ${replyText?.take(200)}")
                callback(replyText ?: "Agent completed but returned no text.")
            }
        } else if (state == "error" && runId.isNotEmpty()) {
            val callback = pendingChatResults.remove(runId)
            if (callback != null) {
                val errorMsg = payload.optString("errorMessage", "Agent error")
                Log.e(TAG, "chat error for $runId: $errorMsg")
                callback(null)
            }
        }
    }

    private fun sendConnectHandshake() {
        val connectMsg = JSONObject().apply {
            put("type", "req")
            put("id", UUID.randomUUID().toString())
            put("method", "connect")
            put("params", JSONObject().apply {
                put("minProtocol", 4)
                put("maxProtocol", 4)
                put("client", JSONObject().apply {
                    put("id", "gateway-client")
                    put("displayName", "VisionClaw Glass")
                    put("version", "1.0")
                    put("platform", "android")
                    put("mode", "backend")
                })
                put("auth", JSONObject().apply {
                    put("token", GeminiConfig.openClawGatewayToken)
                })
                put("scopes", JSONArray().apply {
                    put("operator.admin")
                })
            })
        }
        webSocket?.send(connectMsg.toString())
    }

    private fun handleHeartbeatEvent(payload: JSONObject) {
        val status = payload.optString("status", "")
        if (status != "sent") return

        val preview = payload.optString("preview", "")
        if (preview.isEmpty()) return

        val silent = payload.optBoolean("silent", false)
        if (silent) return

        Log.d(TAG, "Heartbeat notification: ${preview.take(100)}")
        onNotification?.invoke("[Notification from your assistant] $preview")
    }

    private fun handleCronEvent(payload: JSONObject) {
        val action = payload.optString("action", "")
        if (action != "finished") return

        val summary = payload.optString("summary", "").ifEmpty {
            payload.optString("result", "")
        }
        if (summary.isEmpty()) return

        Log.d(TAG, "Cron notification: ${summary.take(100)}")
        onNotification?.invoke("[Scheduled update] $summary")
    }

    /**
     * Send a chat message with optional image attachment via WebSocket chat.send RPC.
     * This is the only way to reliably pass images to the OpenClaw agent.
     * Returns the agent's reply text, or null on failure.
     */
    fun sendChatMessage(
        sessionKey: String,
        message: String,
        imageBase64: String? = null,
        imageMimeType: String = "image/jpeg",
        onResult: (String?) -> Unit
    ) {
        if (!isConnected || webSocket == null) {
            Log.e(TAG, "Cannot send chat.send: not connected")
            onResult(null)
            return
        }

        val reqId = UUID.randomUUID().toString()

        val params = JSONObject().apply {
            put("sessionKey", sessionKey)
            put("message", message)
            put("idempotencyKey", reqId)
            if (imageBase64 != null) {
                put("attachments", JSONArray().put(JSONObject().apply {
                    put("mimeType", imageMimeType)
                    put("fileName", "camera_frame.jpg")
                    put("content", imageBase64)
                }))
            }
        }

        val request = JSONObject().apply {
            put("type", "req")
            put("id", reqId)
            put("method", "chat.send")
            put("params", params)
        }

        // Register callback for RPC ack — then wait for the actual chat event
        pendingResponses[reqId] = { response ->
            val ok = response.optBoolean("ok", false)
            if (ok) {
                // RPC accepted — now wait for the "chat" event with state="final"
                Log.d(TAG, "chat.send accepted, waiting for agent reply (runId=$reqId)")
                pendingChatResults[reqId] = onResult
            } else {
                val error = response.optJSONObject("error")
                val msg = error?.optString("message", "unknown") ?: "unknown"
                Log.e(TAG, "chat.send rejected: $msg")
                onResult(null)
            }
        }

        val sent = webSocket?.send(request.toString()) ?: false
        if (!sent) {
            pendingResponses.remove(reqId)
            Log.e(TAG, "Failed to send chat.send WebSocket message")
            onResult(null)
        } else {
            Log.d(TAG, "chat.send sent (id=$reqId, hasImage=${imageBase64 != null})")
        }
    }

    private fun scheduleReconnect() {
        if (!shouldReconnect) return
        Log.d(TAG, "Reconnecting in ${reconnectDelayMs}ms")
        handler.postDelayed({
            if (shouldReconnect) {
                reconnectDelayMs = (reconnectDelayMs * 2).coerceAtMost(MAX_RECONNECT_DELAY_MS)
                establishConnection()
            }
        }, reconnectDelayMs)
    }
}
