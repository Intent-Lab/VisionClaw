// app/src/main/java/com/meta/wearable/dat/externalsampleapps/cameraaccess/openclaw/OpenClawBridge.kt
package com.meta.wearable.dat.externalsampleapps.cameraaccess.openclaw

import android.util.Log
import com.meta.wearable.dat.externalsampleapps.cameraaccess.gemini.GeminiConfig
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.CancellableContinuation
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.withContext
import okhttp3.Call
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.MultipartBody
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.MediaType.Companion.toMediaTypeOrNull
import org.json.JSONArray
import org.json.JSONObject

class OpenClawBridge {
    companion object {
        private const val TAG = "OpenClawBridge"
        private const val MAX_HISTORY_TURNS = 10

        // OpenClaw media endpoints (split read/write)
        private const val MEDIA_READ_PORT = 18080
        private const val MEDIA_UPLOAD_PORT = 18081
        private const val MEDIA_UPLOAD_PATH = "/upload" // <-- 필요하면 여기만 수정
    }

    private val _lastToolCallStatus = MutableStateFlow<ToolCallStatus>(ToolCallStatus.Idle)
    val lastToolCallStatus: StateFlow<ToolCallStatus> = _lastToolCallStatus.asStateFlow()

    private val _connectionState =
        MutableStateFlow<OpenClawConnectionState>(OpenClawConnectionState.NotConfigured)
    val connectionState: StateFlow<OpenClawConnectionState> = _connectionState.asStateFlow()

    /** Set by GeminiSessionViewModel so we can send tasks via WebSocket chat.send */
    var eventClient: OpenClawEventClient? = null

    fun setToolCallStatus(status: ToolCallStatus) {
        _lastToolCallStatus.value = status
    }

    fun setToolCallProgress(progressText: String) {
        val current = _lastToolCallStatus.value
        if (current is ToolCallStatus.Executing) {
            _lastToolCallStatus.value = current.copy(progressText = progressText)
        }
    }

    private val client = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(300, TimeUnit.SECONDS)
        .callTimeout(330, TimeUnit.SECONDS)
        .writeTimeout(30, TimeUnit.SECONDS)
        .build()

    private val pingClient = OkHttpClient.Builder()
        .readTimeout(5, TimeUnit.SECONDS)
        .connectTimeout(5, TimeUnit.SECONDS)
        .build()

    private val inFlightCallRef = AtomicReference<Call?>(null)

    fun cancelInFlight(reason: String = "cancelled") {
        val call = inFlightCallRef.getAndSet(null)
        if (call != null && !call.isCanceled()) {
            Log.w(TAG, "Cancelling in-flight OpenClaw call: $reason")
            call.cancel()
        }
    }

    private var sessionKey: String = "agent:main:glass"
    private val conversationHistory = mutableListOf<JSONObject>()

    suspend fun checkConnection() = withContext(Dispatchers.IO) {
        if (!GeminiConfig.isOpenClawConfigured) {
            _connectionState.value = OpenClawConnectionState.NotConfigured
            return@withContext
        }
        _connectionState.value = OpenClawConnectionState.Checking
        Log.d("OpenClawBridge", "hookToken(prefix)=${GeminiConfig.openClawHookToken.take(6)}...${GeminiConfig.openClawHookToken.takeLast(4)}")
        val url = "${GeminiConfig.openClawHost}:${GeminiConfig.openClawPort}/v1/chat/completions"
        try {
            val request = Request.Builder()
                .url(url)
                .get()
                .addHeader("Authorization", "Bearer ${GeminiConfig.openClawGatewayToken}")
                .addHeader("x-openclaw-message-channel", "glass")
                .addHeader("x-openclaw-scopes", "operator.write")
                .build()

            val response = pingClient.newCall(request).execute()
            val code = response.code
            response.close()

            if (code in 200..499) {
                _connectionState.value = OpenClawConnectionState.Connected
                Log.d(TAG, "Gateway reachable (HTTP $code)")
            } else {
                _connectionState.value = OpenClawConnectionState.Unreachable("Unexpected response")
            }
        } catch (e: Exception) {
            _connectionState.value = OpenClawConnectionState.Unreachable(e.message ?: "Unknown error")
            Log.d(TAG, "Gateway unreachable: ${e::class.java.name}: ${e.message}")
        }
    }

    fun resetSession() {
        conversationHistory.clear()
        Log.d(TAG, "Session reset (key retained: $sessionKey)")
    }

    suspend fun sendSessionCommand(command: String): ToolResult = withContext(Dispatchers.IO) {
        val normalized = command.trim()
        if (normalized != "/new" && normalized != "/compact") {
            return@withContext ToolResult.Failure("Unsupported OpenClaw command: $normalized")
        }

        _lastToolCallStatus.value = ToolCallStatus.Executing("OpenClaw", "Sending $normalized")

        val ec = eventClient
        if (ec != null) {
            val wsResult = sendViaWebSocket(ec, normalized, imageBase64 = null, toolName = "OpenClaw")
            if (wsResult is ToolResult.Success) {
                if (normalized == "/new") resetSession()
                return@withContext wsResult
            }
            _lastToolCallStatus.value = ToolCallStatus.Executing("OpenClaw", "Sending $normalized")
        }

        if (!GeminiConfig.isOpenClawConfigured) {
            _lastToolCallStatus.value = ToolCallStatus.Failed("OpenClaw", "Not configured")
            return@withContext ToolResult.Failure("OpenClaw is not configured")
        }

        val url = "${GeminiConfig.openClawHost}:${GeminiConfig.openClawPort}/v1/chat/completions"
        val messagesArray = JSONArray().put(JSONObject().apply {
            put("role", "user")
            put("content", normalized)
        })
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

        val call = client.newCall(request)
        inFlightCallRef.set(call)
        try {
            val response = call.execute()
            val responseBody = response.body?.string() ?: ""
            val statusCode = response.code
            response.close()

            if (statusCode !in 200..299) {
                _lastToolCallStatus.value = ToolCallStatus.Failed("OpenClaw", "HTTP $statusCode")
                return@withContext ToolResult.Failure("OpenClaw command returned HTTP $statusCode")
            }

            if (normalized == "/new") resetSession()

            val content = try {
                JSONObject(responseBody).optJSONArray("choices")
                    ?.optJSONObject(0)
                    ?.optJSONObject("message")
                    ?.optString("content", "")
                    ?.takeIf { it.isNotBlank() }
            } catch (_: Exception) {
                responseBody.takeIf { it.isNotBlank() }
            }

            _lastToolCallStatus.value = ToolCallStatus.Completed("OpenClaw")
            ToolResult.Success(content ?: "OpenClaw command completed.")
        } catch (e: Exception) {
            Log.e(TAG, "OpenClaw command error: ${e::class.java.name}: ${e.message}")
            _lastToolCallStatus.value = ToolCallStatus.Failed("OpenClaw", e.message ?: "Unknown")
            ToolResult.Failure("OpenClaw command failed: ${e.message}")
        } finally {
            inFlightCallRef.compareAndSet(call, null)
        }
    }

    /**
     * Upload JPEG bytes to OpenClaw media upload API (write-only port 18081).
     * Returns a read-only URL on port 18080.
     */
    suspend fun uploadToolCallImage(jpegBytes: ByteArray): String? = withContext(Dispatchers.IO) {
        if (!GeminiConfig.isOpenClawConfigured) return@withContext null

        val host = GeminiConfig.openClawHost.trimEnd('/')
        val uploadUrl = "${host}:${MEDIA_UPLOAD_PORT}${MEDIA_UPLOAD_PATH}"

        val filename = "tool_${System.currentTimeMillis()}.jpg"

        val body = MultipartBody.Builder()
            .setType(MultipartBody.FORM)
            .addFormDataPart(
                name = "file", // <-- 서버 스펙이 "image"면 여기만 바꾸면 됨
                filename = filename,
                body = jpegBytes.toRequestBody("image/jpeg".toMediaTypeOrNull())
            )
            .build()

        val request = Request.Builder()
            .url(uploadUrl)
            .post(body)
            .addHeader("Authorization", "Bearer ${GeminiConfig.openClawHookToken}")
            .build()

        try {
            Log.d("OpenClawBridge", "Uploading to $uploadUrl bytes=${jpegBytes.size}")
            val response = client.newCall(request).execute()
            val respBody = response.body?.string() ?: ""
            val code = response.code
            response.close()
            Log.w("OpenClawBridge", "Upload HTTP $code body=${respBody.take(300)}")
            if (code !in 200..299) {
                Log.w(TAG, "Media upload failed: HTTP $code - ${respBody.take(200)}")
                return@withContext null
            }

            // tolerant parse: JSON {url/readUrl/filename/file/path} or plain string
            val inferred: String? = try {
                val j = JSONObject(respBody)
                j.optString("url", null)
                    ?: j.optString("readUrl", null)
                    ?: j.optString("filename", null)
                    ?: j.optString("file", null)
                    ?: j.optString("path", null)
            } catch (_: Exception) {
                respBody.trim().ifEmpty { null }
            }

            if (inferred.isNullOrEmpty()) return@withContext null

            if (inferred.startsWith("http://") || inferred.startsWith("https://")) {
                return@withContext inferred
            }

            val cleaned = inferred.trimStart('/')
            val readUrl = "${host}:${MEDIA_READ_PORT}/${cleaned}"
            return@withContext readUrl
        } catch (e: Exception) {
            Log.w(TAG, "Media upload exception: ${e::class.java.simpleName}: ${e.message}")
            return@withContext null
        }
    }

    suspend fun delegateTask(
        task: String,
        toolName: String = "execute",
        imageBase64: String? = null
    ): ToolResult = withContext(Dispatchers.IO) {
        _lastToolCallStatus.value = ToolCallStatus.Executing(toolName, "OpenClaw is working")

        val ec = eventClient
        if (ec != null) {
            val imageSize = imageBase64?.let { "${it.length / 1024} KB" } ?: "none"
            Log.d(TAG, "Sending task via WebSocket chat.send (image=$imageSize)")
            val wsResult = sendViaWebSocket(ec, task, imageBase64, toolName)
            if (wsResult is ToolResult.Success || imageBase64 != null) {
                return@withContext wsResult
            }
            Log.w(TAG, "WebSocket chat.send failed for text task; falling back to HTTP")
            _lastToolCallStatus.value = ToolCallStatus.Executing(toolName, "OpenClaw is working")
        } else if (imageBase64 != null) {
            Log.w(TAG, "Image task but no event client, falling back to text-only HTTP")
        }

        val url = "${GeminiConfig.openClawHost}:${GeminiConfig.openClawPort}/v1/chat/completions"

        val userMessage = JSONObject().apply {
            put("role", "user")
            put("content", task)
        }

        conversationHistory.add(userMessage)

        if (conversationHistory.size > MAX_HISTORY_TURNS * 2) {
            val trimmed = conversationHistory.takeLast(MAX_HISTORY_TURNS * 2)
            conversationHistory.clear()
            conversationHistory.addAll(trimmed)
        }

        val messagesArray = JSONArray()
        for (msg in conversationHistory) messagesArray.put(msg)

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

        val call = client.newCall(request)
        inFlightCallRef.set(call)

        try {
            val response = call.execute()
            val responseBody = response.body?.string() ?: ""
            val statusCode = response.code
            response.close()

            if (statusCode !in 200..299) {
                Log.d(TAG, "Chat failed: HTTP $statusCode - ${responseBody.take(200)}")
                _lastToolCallStatus.value = ToolCallStatus.Failed(toolName, "HTTP $statusCode")
                return@withContext ToolResult.Failure("Agent returned HTTP $statusCode")
            }

            val json = JSONObject(responseBody)
            val content = json.optJSONArray("choices")
                ?.optJSONObject(0)
                ?.optJSONObject("message")
                ?.optString("content", "")

            if (!content.isNullOrEmpty()) {
                conversationHistory.add(JSONObject().apply {
                    put("role", "assistant")
                    put("content", content)
                })
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
            Log.e(TAG, "Agent error: ${e::class.java.name}: ${e.message}")
            _lastToolCallStatus.value = ToolCallStatus.Failed(toolName, e.message ?: "Unknown")
            return@withContext ToolResult.Failure("Agent error: ${e.message}")
        } finally {
            inFlightCallRef.compareAndSet(call, null)
        }
    }

    /**
     * Upload JPEG to the upload server so the agent can access the file on disk.
     * Returns the saved file path, or null if upload fails.
     */
    fun uploadImageFilePublic(imageBase64: String): String? = uploadImageFile(imageBase64)

    private fun uploadImageFile(imageBase64: String): String? {
        val uploadPort = GeminiConfig.openClawPort + 6 // upload server runs on gateway port + 6
        val host = GeminiConfig.openClawHost.trimEnd('/')
        val url = "$host:$uploadPort/upload"
        return try {
            val jpegBytes = android.util.Base64.decode(imageBase64, android.util.Base64.NO_WRAP)
            val request = Request.Builder()
                .url(url)
                .post(jpegBytes.toRequestBody("image/jpeg".toMediaType()))
                .build()
            val response = pingClient.newCall(request).execute()
            val body = response.body?.string() ?: ""
            response.close()
            if (response.code in 200..299) {
                val json = JSONObject(body)
                val path = json.optString("path", "")
                if (path.isNotEmpty()) {
                    Log.d(TAG, "Image uploaded to: $path")
                    path
                } else null
            } else {
                Log.w(TAG, "Image upload HTTP ${response.code}")
                null
            }
        } catch (e: Exception) {
            Log.w(TAG, "Image upload failed: ${e.message}")
            null
        }
    }

    /**
     * Send a task via WebSocket chat.send RPC.
     * Also uploads the image file to disk when present so the agent can access it.
     */
    private suspend fun sendViaWebSocket(
        eventClient: OpenClawEventClient,
        task: String,
        imageBase64: String?,
        toolName: String
    ): ToolResult = suspendCancellableCoroutine { continuation ->
        val taskWithPath = if (imageBase64 != null) {
            val filePath = uploadImageFile(imageBase64)
            if (filePath != null) {
                "$task\n\n[image_file_path]\n$filePath"
            } else {
                task
            }
        } else {
            task
        }

        eventClient.sendChatMessage(
            sessionKey = sessionKey,
            message = taskWithPath,
            imageBase64 = imageBase64
        ) { reply ->
            if (reply != null) {
                conversationHistory.add(JSONObject().apply {
                    put("role", "user")
                    put("content", task)
                })
                conversationHistory.add(JSONObject().apply {
                    put("role", "assistant")
                    put("content", reply)
                })
                Log.d(TAG, "WebSocket chat.send result: ${reply.take(200)}")
                _lastToolCallStatus.value = ToolCallStatus.Completed(toolName)
                continuation.resume(ToolResult.Success(reply)) {}
            } else {
                _lastToolCallStatus.value = ToolCallStatus.Failed(toolName, "WebSocket chat.send failed")
                continuation.resume(ToolResult.Failure("Failed to send image via WebSocket")) {}
            }
        }
    }
}
