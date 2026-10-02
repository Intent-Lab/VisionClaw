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

        val request = Request.Builder().url(url).build()
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
        }
    }

    private fun sendConnectHandshake() {
        val connectMsg = JSONObject().apply {
            put("type", "req")
            put("id", UUID.randomUUID().toString())
            put("method", "connect")
            put("params", JSONObject().apply {
                put("minProtocol", 3)
                put("maxProtocol", 3)
                put("client", JSONObject().apply {
                    put("id", "android-node")
                    put("displayName", "VisionClaw Glass")
                    put("version", "1.0")
                    put("platform", "android")
                    put("mode", "node")
                })
                put("role", "node")
                put("scopes", JSONArray())
                put("caps", JSONArray().apply {
                    put("camera")
                    put("voice")
                })
                put("commands", JSONArray())
                put("permissions", JSONObject())
                put("auth", JSONObject().apply {
                    put("token", GeminiConfig.openClawGatewayToken)
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
