package com.meta.wearable.dat.externalsampleapps.cameraaccess.openclaw

import android.os.Handler
import android.os.Looper
import android.util.Log
import com.meta.wearable.dat.externalsampleapps.cameraaccess.gemini.GeminiConfig
import java.net.URI
import java.util.UUID
import java.util.concurrent.TimeUnit
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import org.json.JSONArray
import org.json.JSONObject

enum class OpenClawProgressKind(val displayText: String) {
    Memory("Searching memory"),
    Calendar("Checking calendar"),
    SlackLookup("Checking Slack recipient"),
    SlackSend("Sending Slack message"),
    Slack("Checking Slack"),
    Email("Checking email"),
    Browser("Using browser"),
    Web("Searching web"),
    File("Reading files"),
    Tool("Running tool")
}

data class OpenClawProgress(
    val kind: OpenClawProgressKind,
    val toolName: String,
    val phase: String,
    val detail: String,
    val speechHint: String,
    val stableKey: String
) {
    val displayText: String
        get() = speechHint.replaceFirstChar { it.uppercase() }
}

class OpenClawEventClient {
    companion object {
        private const val TAG = "OpenClawEventClient"
        private const val MAX_RECONNECT_DELAY_MS = 30_000L
    }

    var onNotification: ((String) -> Unit)? = null
    var onProgress: ((OpenClawProgress) -> Unit)? = null

    private var webSocket: WebSocket? = null
    private var isConnected = false
    private var shouldReconnect = false
    private var reconnectDelayMs = 2_000L
    private val handler = Handler(Looper.getMainLooper())
    private var lastProgressText: String? = null
    private var lastProgressAtMs: Long = 0

    // Pending RPC responses keyed by request ID
    private val pendingResponses = mutableMapOf<String, (JSONObject) -> Unit>()

    // Pending chat.send results keyed by runId — waits for the "chat" event with state="final"
    private val pendingChatResults = mutableMapOf<String, (String?) -> Unit>()

    private val client = OkHttpClient.Builder()
        .readTimeout(0, TimeUnit.MILLISECONDS)
        .pingInterval(10, TimeUnit.SECONDS)
        .build()

    fun resetProgressState() {
        lastProgressText = null
        lastProgressAtMs = 0
    }

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
                            subscribeSessionEvents()
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
            "agent", "session.tool" -> handleAgentProgressEvent(event, payload)
        }
    }

    private fun handleAgentProgressEvent(event: String, payload: JSONObject) {
        val data = payload.optJSONObject("data") ?: payload
        val stream = payload.optString("stream", if (event == "session.tool") "tool" else "")
        val phase = data.optString("phase", data.optString("status", ""))

        if (phase != "start" && phase != "update") {
            Log.d(TAG, "Progress skip: phase=$phase event=$event")
            return
        }

        val name = data.optString("name", data.optString("title", ""))
        val argsText = data.opt("args")?.toString()
            ?: data.opt("arguments")?.toString()
            ?: ""
        if (stream == "item" && argsText.isBlank() && looksLikeToolItem(name)) {
            Log.d(TAG, "Progress skip: waiting for richer tool event name=$name")
            return
        }
        if (isNoisyInternalBashRead(name, argsText)) {
            Log.d(TAG, "Progress skip: internal bash read name=$name args=${argsText.take(160)}")
            return
        }
        val detail = buildString {
            append(name)
            append(" ")
            append(data.optString("progressText", ""))
            append(" ")
            append(data.optString("partialResult", ""))
            append(" ")
            append(argsText)
        }

        val progress = progressFor(name = name, detail = detail, argsText = argsText, stream = stream, phase = phase)
        if (progress == null) {
            Log.d(TAG, "Progress skip: unclassified event=$event stream=$stream phase=$phase name=$name detail=${detail.take(220)}")
            return
        }
        emitProgress(progress)
    }

    private fun looksLikeToolItem(name: String): Boolean {
        val text = name.lowercase()
        return text == "bash" ||
            text == "browser" ||
            text.contains("_") ||
            text.contains("memory") ||
            text.contains("search") ||
            text.contains("mail") ||
            text.contains("slack") ||
            text.contains("calendar")
    }

    private fun progressFor(
        name: String,
        detail: String,
        argsText: String,
        stream: String,
        phase: String
    ): OpenClawProgress? {
        val text = "$name $detail".lowercase()

        // These fire constantly and are too noisy for glasses.
        if (text.contains("reasoning")
            || text.contains("codex_app_server")
            || stream == "lifecycle") {
            return null
        }

        val kind = when {
            text.contains("memory") -> OpenClawProgressKind.Memory
            text.contains("calendar") -> OpenClawProgressKind.Calendar
            text.contains("slack") && (text.contains("lookup") || text.contains("user")) -> OpenClawProgressKind.SlackLookup
            text.contains("slack") && (text.contains("send") || text.contains("message")) -> OpenClawProgressKind.SlackSend
            text.contains("slack") -> OpenClawProgressKind.Slack
            text.contains("mail") || text.contains("email") || text.contains("gmail") -> OpenClawProgressKind.Email
            text.contains("browser") -> OpenClawProgressKind.Browser
            text.contains("web") || text.contains("search") -> OpenClawProgressKind.Web
            text.contains("file") || text.contains("read") -> OpenClawProgressKind.File
            else -> OpenClawProgressKind.Tool
        }

        // Raw bash can be very noisy, but many OpenClaw skills currently arrive
        // as bash with the real service encoded in the command/cwd.
        if (name == "bash" && kind == OpenClawProgressKind.Tool) {
            return null
        }

        val target = progressTarget(kind, name, argsText, detail)
        val speechHint = progressSpeechHint(kind, target)
        val stableKey = listOf(kind.name.lowercase(), target.lowercase())
            .filter { it.isNotBlank() }
            .joinToString(":")

        return OpenClawProgress(
            kind = kind,
            toolName = name.ifBlank { stream.ifBlank { "tool" } },
            phase = phase,
            detail = detail.trim(),
            speechHint = speechHint,
            stableKey = stableKey
        )
    }

    private fun progressSpeechHint(kind: OpenClawProgressKind, target: String): String {
        return when (kind) {
            OpenClawProgressKind.Memory -> listOf("searching memory", target).joinNonBlank(" for ")
            OpenClawProgressKind.Calendar -> listOf("checking calendar", target).joinNonBlank(" for ")
            OpenClawProgressKind.SlackLookup -> listOf("checking Slack recipient", target).joinNonBlank(" for ")
            OpenClawProgressKind.SlackSend -> listOf("sending Slack message", target).joinNonBlank(" to ")
            OpenClawProgressKind.Slack -> listOf("checking Slack", target).joinNonBlank(" for ")
            OpenClawProgressKind.Email -> listOf("checking email", target).joinNonBlank(" for ")
            OpenClawProgressKind.Browser -> if (target.isBlank()) "using browser" else "opening $target"
            OpenClawProgressKind.Web -> listOf("searching web", target).joinNonBlank(" for ")
            OpenClawProgressKind.File -> listOf("reading files", target).joinNonBlank(" for ")
            OpenClawProgressKind.Tool -> listOf("running tool", target).joinNonBlank(" for ")
        }
    }

    private fun List<String>.joinNonBlank(separator: String): String {
        return filter { it.isNotBlank() }.joinToString(separator)
    }

    private fun progressTarget(
        kind: OpenClawProgressKind,
        name: String,
        argsText: String,
        detail: String
    ): String {
        val args = parseJsonObject(argsText)
        val query = args?.optString("query", "")?.takeIf { it.isNotBlank() }
        val url = args?.optString("url", "")?.takeIf { it.isNotBlank() }
        val path = args?.optString("path", "")?.takeIf { it.isNotBlank() }
        val command = args?.optString("command", "")?.takeIf { it.isNotBlank() }
        val action = args?.optString("action", "")?.takeIf { it.isNotBlank() }

        return when (kind) {
            OpenClawProgressKind.Memory -> query ?: path?.substringAfterLast("/") ?: commandSearchTarget(command) ?: ""
            OpenClawProgressKind.Calendar -> commandSearchTarget(command) ?: query ?: ""
            OpenClawProgressKind.SlackLookup,
            OpenClawProgressKind.SlackSend,
            OpenClawProgressKind.Slack -> commandSearchTarget(command) ?: query ?: ""
            OpenClawProgressKind.Email -> commandSearchTarget(command) ?: query ?: ""
            OpenClawProgressKind.Browser -> domainFromUrl(url) ?: browserActionTarget(action, detail)
            OpenClawProgressKind.Web -> domainFromUrl(url) ?: query ?: commandSearchTarget(command) ?: ""
            OpenClawProgressKind.File -> path?.substringAfterLast("/") ?: commandSearchTarget(command) ?: ""
            OpenClawProgressKind.Tool -> query ?: commandSearchTarget(command) ?: name
        }.sanitizeTarget()
    }

    private fun parseJsonObject(text: String): JSONObject? {
        if (text.isBlank()) return null
        return try {
            JSONObject(text)
        } catch (_: Exception) {
            null
        }
    }

    private fun domainFromUrl(url: String?): String? {
        if (url.isNullOrBlank()) return null
        return try {
            URI(url).host?.removePrefix("www.")
        } catch (_: Exception) {
            null
        }
    }

    private fun browserActionTarget(action: String?, detail: String): String {
        if (!action.isNullOrBlank() && action != "act") return action
        return when {
            detail.contains("amazon", ignoreCase = true) -> "Amazon"
            detail.contains("apple.com", ignoreCase = true) -> "apple.com"
            else -> ""
        }
    }

    private fun commandSearchTarget(command: String?): String? {
        if (command.isNullOrBlank()) return null
        val quoted = Regex("\"([^\"]{2,80})\"|'([^']{2,80})'").findAll(command)
            .mapNotNull { it.groups[1]?.value ?: it.groups[2]?.value }
            .firstOrNull { candidate -> isUsefulCommandCandidate(candidate) }
        return quoted
    }

    private fun isNoisyInternalBashRead(name: String, argsText: String): Boolean {
        if (name != "bash") return false
        val command = parseJsonObject(argsText)
            ?.optString("command", "")
            ?.takeIf { it.isNotBlank() }
            ?: return false

        val lower = command.lowercase()
        val looksReadOnly = listOf("sed ", "sed -n", "cat ", "head ", "tail ", "grep ", "rg ", "find ", "ls ", "for ")
            .any { lower.contains(it) }
        if (!looksReadOnly) return false

        return lower.contains("/skills/") ||
            lower.contains("skill.md") ||
            lower.contains("agents.md") ||
            lower.contains(".openclaw/workspace/memory") ||
            lower.contains("memory/2026") ||
            lower.contains("memory/2025")
    }

    private fun isUsefulCommandCandidate(candidate: String): Boolean {
        val text = candidate.trim()
        if (text.isBlank()) return false
        if (!text.any { it.isLetterOrDigit() || it.code > 127 }) return false
        if (text.contains("/") || text.contains("--")) return false
        if (text.startsWith("###")) return false
        if (Regex("^\\d+,\\d+p$").matches(text)) return false
        if (Regex("^\\d+,\\${'$'}p${'$'}").matches(text)) return false
        if (text.startsWith("memory/", ignoreCase = true)) return false
        if (text.endsWith(".md", ignoreCase = true)) return false
        return true
    }

    private fun String.sanitizeTarget(): String {
        return trim()
            .replace(Regex("\\s+"), " ")
            .replace(Regex("[\\r\\n]"), " ")
            .take(80)
    }

    private fun emitProgress(progress: OpenClawProgress) {
        val now = System.currentTimeMillis()
        if (progress.stableKey == lastProgressText && now - lastProgressAtMs < 12_000) {
            Log.d(TAG, "Progress skip: duplicate key=${progress.stableKey} tool=${progress.toolName}")
            return
        }
        if (lastProgressText != null && now - lastProgressAtMs < 2_000) {
            Log.d(TAG, "Progress skip: throttle display=${progress.displayText} tool=${progress.toolName}")
            return
        }

        lastProgressText = progress.stableKey
        lastProgressAtMs = now
        Log.d(TAG, "Progress: ${progress.speechHint} (${progress.toolName}) detail=${progress.detail.take(220)}")
        handler.post {
            onProgress?.invoke(progress)
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

    private fun subscribeSessionEvents() {
        val reqId = UUID.randomUUID().toString()
        pendingResponses[reqId] = { response ->
            val ok = response.optBoolean("ok", false)
            if (ok) {
                val subscribed = response.optJSONObject("result")?.optBoolean("subscribed", false) ?: false
                Log.d(TAG, "sessions.subscribe ok subscribed=$subscribed")
            } else {
                val error = response.optJSONObject("error")
                val msg = error?.optString("message", "unknown") ?: "unknown"
                Log.w(TAG, "sessions.subscribe failed: $msg")
            }
        }
        val request = JSONObject().apply {
            put("type", "req")
            put("id", reqId)
            put("method", "sessions.subscribe")
            put("params", JSONObject())
        }
        val sent = webSocket?.send(request.toString()) ?: false
        if (!sent) {
            pendingResponses.remove(reqId)
            Log.w(TAG, "sessions.subscribe send failed")
        }
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
