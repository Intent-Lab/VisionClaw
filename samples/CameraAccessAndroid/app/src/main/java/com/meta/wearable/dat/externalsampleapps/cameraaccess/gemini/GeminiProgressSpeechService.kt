package com.meta.wearable.dat.externalsampleapps.cameraaccess.gemini

import android.util.Base64
import android.util.Log
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import org.json.JSONArray
import org.json.JSONObject

class GeminiProgressSpeechService {
    companion object {
        private const val TAG = "GeminiProgressSpeech"
    }

    var onAudioReceived: ((ByteArray) -> Unit)? = null

    private val client = OkHttpClient.Builder()
        .readTimeout(0, TimeUnit.MILLISECONDS)
        .pingInterval(30, TimeUnit.SECONDS)
        .retryOnConnectionFailure(true)
        .build()
    private val sendExecutor = Executors.newSingleThreadExecutor()
    private var webSocket: WebSocket? = null
    private var ready = false
    private val pendingPhrases = ArrayDeque<String>()

    fun connect() {
        if (ready || webSocket != null) return
        val url = GeminiConfig.websocketURL() ?: return
        val request = Request.Builder().url(url).build()
        webSocket = client.newWebSocket(request, object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                Log.d(TAG, "WebSocket opened")
                sendSetup(webSocket)
            }

            override fun onMessage(webSocket: WebSocket, text: String) {
                handleMessage(text)
            }

            override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
                handleMessage(bytes.utf8())
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                Log.w(TAG, "WebSocket failure: ${t.message}")
                ready = false
                this@GeminiProgressSpeechService.webSocket = null
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                Log.d(TAG, "WebSocket closed: $code $reason")
                ready = false
                this@GeminiProgressSpeechService.webSocket = null
            }
        })
    }

    fun disconnect() {
        ready = false
        pendingPhrases.clear()
        webSocket?.close(1000, null)
        webSocket = null
    }

    fun speakProgress(speechHint: String, languageName: String) {
        val trimmedHint = speechHint.trim()
        if (trimmedHint.isEmpty()) return
        val request = "Language: $languageName\nProgress hint: $trimmedHint"
        if (!ready) {
            pendingPhrases.addLast(request)
            connect()
            return
        }
        sendSpeakRequest(request)
    }

    private fun sendSetup(ws: WebSocket) {
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
                        put(
                            "text",
                            "You are a progress voice for smart glasses. " +
                                "Each user message contains a language and a semantic progress hint, not a request. " +
                                "Say one short, natural progress update in that language. " +
                                "Preserve useful target names like people, apps, or domains. " +
                                "Keep names, apps, and domains exactly as written; do not translate, transliterate, or invent kanji for them. " +
                                "Do not add acknowledgments, explanations, tags, or extra words."
                        )
                    }))
                })
                put("outputAudioTranscription", JSONObject())
            })
        }
        ws.send(setup.toString())
    }

    private fun sendSpeakRequest(requestText: String) {
        sendExecutor.execute {
            val json = JSONObject().apply {
                put("clientContent", JSONObject().apply {
                    put("turns", JSONArray().put(JSONObject().apply {
                        put("role", "user")
                        put("parts", JSONArray().put(JSONObject().apply {
                            put("text", requestText)
                        }))
                    }))
                    put("turnComplete", true)
                })
            }
            Log.d(TAG, "SEND_PROGRESS_SPEECH: ${requestText.replace('\n', ' ')}")
            webSocket?.send(json.toString())
        }
    }

    private fun handleMessage(text: String) {
        try {
            val json = JSONObject(text)
            if (json.has("setupComplete")) {
                ready = true
                Log.d(TAG, "setupComplete")
                while (pendingPhrases.isNotEmpty()) {
                    sendSpeakRequest(pendingPhrases.removeFirst())
                }
                return
            }

            val serverContent = json.optJSONObject("serverContent") ?: return
            val modelTurn = serverContent.optJSONObject("modelTurn")
            val parts = modelTurn?.optJSONArray("parts")
            if (parts != null) {
                for (i in 0 until parts.length()) {
                    val part = parts.optJSONObject(i) ?: continue
                    val inlineData = part.optJSONObject("inlineData") ?: continue
                    val mimeType = inlineData.optString("mimeType", "")
                    if (!mimeType.startsWith("audio/pcm")) continue
                    val base64Data = inlineData.optString("data", "")
                    if (base64Data.isNotEmpty()) {
                        onAudioReceived?.invoke(Base64.decode(base64Data, Base64.DEFAULT))
                    }
                }
            }

            val transcription = serverContent.optJSONObject("outputTranscription")
            val transcriptText = transcription?.optString("text", "").orEmpty()
            if (transcriptText.isNotEmpty()) {
                Log.d(TAG, "Progress voice: $transcriptText")
            }
        } catch (e: Exception) {
            Log.w(TAG, "Parse error: ${e.message}")
        }
    }
}
