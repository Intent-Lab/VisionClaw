package com.meta.wearable.dat.externalsampleapps.cameraaccess.gemini

import android.graphics.Bitmap
import android.util.Base64
import android.util.Log
import com.meta.wearable.dat.externalsampleapps.cameraaccess.openclaw.GeminiToolCall
import com.meta.wearable.dat.externalsampleapps.cameraaccess.openclaw.GeminiToolCallCancellation
import com.meta.wearable.dat.externalsampleapps.cameraaccess.openclaw.ToolDeclarations
import java.io.ByteArrayOutputStream
import java.util.Timer
import java.util.TimerTask
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import org.json.JSONArray
import org.json.JSONObject

sealed class GeminiConnectionState {
    data object Disconnected : GeminiConnectionState()
    data object Connecting : GeminiConnectionState()
    data object SettingUp : GeminiConnectionState()
    data object Ready : GeminiConnectionState()
    data class Error(val message: String) : GeminiConnectionState()
}

class GeminiLiveService {
    companion object {
        private const val TAG = "GeminiLiveService"
    }

    private val _connectionState = MutableStateFlow<GeminiConnectionState>(GeminiConnectionState.Disconnected)
    val connectionState: StateFlow<GeminiConnectionState> = _connectionState.asStateFlow()

    private val _isModelSpeaking = MutableStateFlow(false)
    val isModelSpeaking: StateFlow<Boolean> = _isModelSpeaking.asStateFlow()

    var onAudioReceived: ((ByteArray) -> Unit)? = null
    var onTurnComplete: (() -> Unit)? = null
    var onInterrupted: (() -> Unit)? = null
    var onDisconnected: ((String?) -> Unit)? = null
    var onInputTranscription: ((String) -> Unit)? = null
    var onOutputTranscription: ((String) -> Unit)? = null
    var onToolCall: ((GeminiToolCall) -> Unit)? = null
    var onToolCallCancellation: ((GeminiToolCallCancellation) -> Unit)? = null

    // Latency tracking
    private var lastUserSpeechEnd: Long = 0
    private var responseLatencyLogged = false

    private var webSocket: WebSocket? = null
    private val sendExecutor = Executors.newSingleThreadExecutor()
    private var connectCallback: ((Boolean) -> Unit)? = null
    private var timeoutTimer: Timer? = null

    private val client = OkHttpClient.Builder()
        .readTimeout(0, TimeUnit.MILLISECONDS)
        .pingInterval(10, TimeUnit.SECONDS)
        .build()

    fun connect(callback: (Boolean) -> Unit) {
        val url = GeminiConfig.websocketURL()
        if (url == null) {
            _connectionState.value = GeminiConnectionState.Error("No API key configured")
            callback(false)
            return
        }

        _connectionState.value = GeminiConnectionState.Connecting
        connectCallback = callback

        val request = Request.Builder().url(url).build()
        webSocket = client.newWebSocket(request, object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                Log.d(TAG, "WebSocket opened")
                _connectionState.value = GeminiConnectionState.SettingUp
                sendSetupMessage()
            }

            override fun onMessage(webSocket: WebSocket, text: String) {
                handleMessage(text)
            }

            override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
                handleMessage(bytes.utf8())
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                val msg = t.message ?: "Unknown error"
                Log.e(TAG, "WebSocket failure: $msg")
                _connectionState.value = GeminiConnectionState.Error(msg)
                _isModelSpeaking.value = false
                resolveConnect(false)
                onDisconnected?.invoke(msg)
            }

            override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
                Log.d(TAG, "WebSocket closing: $code $reason")
                _connectionState.value = GeminiConnectionState.Disconnected
                _isModelSpeaking.value = false
                resolveConnect(false)
                onDisconnected?.invoke("Connection closed (code $code: $reason)")
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                Log.d(TAG, "WebSocket closed: $code $reason")
                _connectionState.value = GeminiConnectionState.Disconnected
                _isModelSpeaking.value = false
            }
        })

        // Timeout after 15 seconds (use Timer so we don't block sendExecutor)
        timeoutTimer = Timer().apply {
            schedule(object : TimerTask() {
                override fun run() {
                    if (_connectionState.value == GeminiConnectionState.Connecting
                        || _connectionState.value == GeminiConnectionState.SettingUp) {
                        Log.e(TAG, "Connection timed out")
                        _connectionState.value = GeminiConnectionState.Error("Connection timed out")
                        resolveConnect(false)
                    }
                }
            }, 15000)
        }
    }

    fun disconnect() {
        timeoutTimer?.cancel()
        timeoutTimer = null
        webSocket?.close(1000, null)
        webSocket = null
        onToolCall = null
        onToolCallCancellation = null
        _connectionState.value = GeminiConnectionState.Disconnected
        _isModelSpeaking.value = false
        resolveConnect(false)
    }

    fun sendAudio(data: ByteArray) {
        if (_connectionState.value != GeminiConnectionState.Ready) return
        sendExecutor.execute {
            val base64 = Base64.encodeToString(data, Base64.NO_WRAP)
            val json = JSONObject().apply {
                put("realtimeInput", JSONObject().apply {
                    put("audio", JSONObject().apply {
                        put("mimeType", "audio/pcm;rate=16000")
                        put("data", base64)
                    })
                })
            }
            webSocket?.send(json.toString())
        }
    }

    fun sendVideoFrame(bitmap: Bitmap) {
        if (_connectionState.value != GeminiConnectionState.Ready) return
        sendExecutor.execute {
            val baos = ByteArrayOutputStream()
            bitmap.compress(Bitmap.CompressFormat.JPEG, GeminiConfig.VIDEO_JPEG_QUALITY, baos)
            val base64 = Base64.encodeToString(baos.toByteArray(), Base64.NO_WRAP)
            val json = JSONObject().apply {
                put("realtimeInput", JSONObject().apply {
                    put("video", JSONObject().apply {
                        put("mimeType", "image/jpeg")
                        put("data", base64)
                    })
                })
            }
            webSocket?.send(json.toString())
        }
    }

    fun sendToolResponse(response: JSONObject) {
        sendExecutor.execute {
            webSocket?.send(response.toString())
        }
    }

    // Private

    private fun resolveConnect(success: Boolean) {
        val cb = connectCallback
        connectCallback = null  // null out BEFORE invoking to prevent re-entrancy
        timeoutTimer?.cancel()
        timeoutTimer = null
        cb?.invoke(success)
    }

    private fun sendSetupMessage() {
        val setup = JSONObject().apply {
            put("setup", JSONObject().apply {
                put("model", GeminiConfig.MODEL)
                put("generationConfig", JSONObject().apply {
                    put("responseModalities", JSONArray().put("AUDIO"))
                    put("thinkingConfig", JSONObject().apply {
                        put("thinkingBudget", 0)
                    })
                })
                put("systemInstruction", JSONObject().apply {
                    put("parts", JSONArray().put(JSONObject().apply {
                        put("text", GeminiConfig.systemInstruction)
                    }))
                })
                if (GeminiConfig.isOpenClawConfigured) {
                    put("tools", JSONArray().put(JSONObject().apply {
                        put("functionDeclarations", ToolDeclarations.allDeclarationsJSON())
                    }))
                }
                put("realtimeInputConfig", JSONObject().apply {
                    put("automaticActivityDetection", JSONObject().apply {
                        put("disabled", false)
                        put("startOfSpeechSensitivity", "START_SENSITIVITY_HIGH")
                        put("endOfSpeechSensitivity", "END_SENSITIVITY_LOW")
                        put("silenceDurationMs", 500)
                        put("prefixPaddingMs", 40)
                    })
                    put("activityHandling", "START_OF_ACTIVITY_INTERRUPTS")
                    put("turnCoverage", "TURN_INCLUDES_ALL_INPUT")
                })
                put("inputAudioTranscription", JSONObject())
                put("outputAudioTranscription", JSONObject())
            })
        }
        // Send directly (not via sendExecutor) to ensure it's the first message
        webSocket?.send(setup.toString())
    }

    private fun handleMessage(text: String) {
        try {
            val json = JSONObject(text)

            // Setup complete
            if (json.has("setupComplete")) {
                _connectionState.value = GeminiConnectionState.Ready
                resolveConnect(true)
                return
            }

            // GoAway
            if (json.has("goAway")) {
                val goAway = json.getJSONObject("goAway")
                val seconds = goAway.optJSONObject("timeLeft")?.optInt("seconds", 0) ?: 0
                _connectionState.value = GeminiConnectionState.Disconnected
                _isModelSpeaking.value = false
                onDisconnected?.invoke("Server closing (time left: ${seconds}s)")
                return
            }

            // Tool call
            val toolCall = GeminiToolCall.fromJSON(json)
            if (toolCall != null) {
                Log.d(TAG, "Tool call received: ${toolCall.functionCalls.size} function(s)")
                onToolCall?.invoke(toolCall)
                return
            }

            // Tool call cancellation
            val cancellation = GeminiToolCallCancellation.fromJSON(json)
            if (cancellation != null) {
                Log.d(TAG, "Tool call cancellation: ${cancellation.ids.joinToString()}")
                onToolCallCancellation?.invoke(cancellation)
                return
            }

            // Server content
            if (json.has("serverContent")) {
                val serverContent = json.getJSONObject("serverContent")

                if (serverContent.optBoolean("interrupted", false)) {
                    _isModelSpeaking.value = false
                    onInterrupted?.invoke()
                    return
                }

                if (serverContent.has("modelTurn")) {
                    val modelTurn = serverContent.getJSONObject("modelTurn")
                    if (modelTurn.has("parts")) {
                        val parts = modelTurn.getJSONArray("parts")
                        for (i in 0 until parts.length()) {
                            val part = parts.getJSONObject(i)
                            if (part.has("inlineData")) {
                                val inlineData = part.getJSONObject("inlineData")
                                val mimeType = inlineData.optString("mimeType", "")
                                if (mimeType.startsWith("audio/pcm")) {
                                    val base64Data = inlineData.optString("data", "")
                                    if (base64Data.isNotEmpty()) {
                                        val audioData = Base64.decode(base64Data, Base64.DEFAULT)
                                        if (!_isModelSpeaking.value) {
                                            _isModelSpeaking.value = true
                                            if (lastUserSpeechEnd > 0 && !responseLatencyLogged) {
                                                val latency = System.currentTimeMillis() - lastUserSpeechEnd
                                                Log.d(TAG, "[Latency] ${latency}ms (user speech end -> first audio)")
                                                responseLatencyLogged = true
                                            }
                                        }
                                        onAudioReceived?.invoke(audioData)
                                    }
                                }
                            } else if (part.has("text")) {
                                Log.d(TAG, part.getString("text"))
                            }
                        }
                    }
                }

                if (serverContent.optBoolean("turnComplete", false)) {
                    _isModelSpeaking.value = false
                    responseLatencyLogged = false
                    onTurnComplete?.invoke()
                }

                if (serverContent.has("inputTranscription")) {
                    val transcription = serverContent.getJSONObject("inputTranscription")
                    val transcriptText = transcription.optString("text", "")
                    if (transcriptText.isNotEmpty()) {
                        Log.d(TAG, "You: $transcriptText")
                        lastUserSpeechEnd = System.currentTimeMillis()
                        responseLatencyLogged = false
                        onInputTranscription?.invoke(transcriptText)
                    }
                }

                if (serverContent.has("outputTranscription")) {
                    val transcription = serverContent.getJSONObject("outputTranscription")
                    val transcriptText = transcription.optString("text", "")
                    if (transcriptText.isNotEmpty()) {
                        Log.d(TAG, "AI: $transcriptText")
                        onOutputTranscription?.invoke(transcriptText)
                    }
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error parsing message: ${e.message}")
        }
    }
}
