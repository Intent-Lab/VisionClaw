// app/src/main/java/com/meta/wearable/dat/externalsampleapps/cameraaccess/gemini/GeminiSessionViewModel.kt
package com.meta.wearable.dat.externalsampleapps.cameraaccess.gemini

import android.app.Application
import android.graphics.Bitmap
import android.util.Log
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.meta.wearable.dat.externalsampleapps.cameraaccess.chat.ChatMessage
import com.meta.wearable.dat.externalsampleapps.cameraaccess.chat.ChatMessageRole
import com.meta.wearable.dat.externalsampleapps.cameraaccess.chat.ChatMessageStatus
import com.meta.wearable.dat.externalsampleapps.cameraaccess.net.NetworkType
import com.meta.wearable.dat.externalsampleapps.cameraaccess.net.NetworkTypeMonitor
import com.meta.wearable.dat.externalsampleapps.cameraaccess.openclaw.OpenClawBridge
import com.meta.wearable.dat.externalsampleapps.cameraaccess.openclaw.OpenClawConnectionState
import com.meta.wearable.dat.externalsampleapps.cameraaccess.openclaw.OpenClawEventClient
import com.meta.wearable.dat.externalsampleapps.cameraaccess.openclaw.OpenClawProgress
import com.meta.wearable.dat.externalsampleapps.cameraaccess.openclaw.OpenClawProgressKind
import com.meta.wearable.dat.externalsampleapps.cameraaccess.openclaw.ToolCallRouter
import com.meta.wearable.dat.externalsampleapps.cameraaccess.openclaw.ToolCallStatus
import com.meta.wearable.dat.externalsampleapps.cameraaccess.openclaw.ToolResult
import com.meta.wearable.dat.externalsampleapps.cameraaccess.chat.ChatHistoryStore
import com.meta.wearable.dat.externalsampleapps.cameraaccess.gallery.CapturedPhoto
import com.meta.wearable.dat.externalsampleapps.cameraaccess.gallery.PhotoCaptureStore
import com.meta.wearable.dat.externalsampleapps.cameraaccess.settings.SettingsManager
import com.meta.wearable.dat.externalsampleapps.cameraaccess.stream.StreamingMode
import com.meta.wearable.dat.externalsampleapps.cameraaccess.stream.StreamingService
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

data class GeminiUiState(
    val isGeminiActive: Boolean = false,
    val connectionState: GeminiConnectionState = GeminiConnectionState.Disconnected,
    val isModelSpeaking: Boolean = false,
    val isMicEnabled: Boolean = true,
    val errorMessage: String? = null,
    val userTranscript: String = "",
    val aiTranscript: String = "",
    val messages: List<ChatMessage> = emptyList(),
    val toolCallStatus: ToolCallStatus = ToolCallStatus.Idle,
    val openClawConnectionState: OpenClawConnectionState = OpenClawConnectionState.NotConfigured,
    val networkType: NetworkType = NetworkType.NONE,
)

class GeminiSessionViewModel(app: Application) : AndroidViewModel(app) {

    private val _uiState = MutableStateFlow(GeminiUiState(
        messages = ChatHistoryStore.load(app)
    ))
    val uiState: StateFlow<GeminiUiState> = _uiState.asStateFlow()

    private val _captureEvent = MutableStateFlow<CapturedPhoto?>(null)
    val captureEvent: StateFlow<CapturedPhoto?> = _captureEvent.asStateFlow()

    private val geminiService = GeminiLiveService()
    private val progressSpeechService = GeminiProgressSpeechService()
    private val openClawBridge = OpenClawBridge()
    private val eventClient = OpenClawEventClient()
    private var toolCallRouter: ToolCallRouter? = null
    private val audioManager = AudioManager(getApplication<Application>().applicationContext)
    private var lastVideoFrameTime: Long = 0

    @Volatile private var latestFrameForToolCall: Bitmap? = null
    @Volatile private var lastUserOriginalInstruction: String? = null

    private var stateObservationJob: Job? = null

    private var userStopped = false
    private var reconnectJob: Job? = null
    private var reconnectAttempts = 0
    private val maxReconnectAttempts = 6

    var streamingMode: StreamingMode = StreamingMode.GLASSES

    private val netMonitor = NetworkTypeMonitor(app)
    private var netMonitorJob: Job? = null

    private val videoIntervalWifiMs = 1000L
    private val videoIntervalCellularMs = 4000L
    private val videoIntervalOtherMs = 2000L

    // Chat message tracking
    private var activeUserBubbleId: String? = null
    private var activeAIBubbleId: String? = null
    private var lastUserText: String = ""
    private var lastAIText: String = ""
    private var lastSpokenProgressKind: OpenClawProgressKind? = null
    private var lastSpokenProgressAtMs: Long = 0

    // execute 시작 시 mic 상태를 저장해뒀다가 끝나면 복원
    private var micStateBeforeExecution: Boolean? = null
    private var micAutoMutedForExecution = false

    private fun isToolExecuting(status: ToolCallStatus): Boolean {
        return status is ToolCallStatus.Executing
    }

    private fun syncMicWithToolExecution(status: ToolCallStatus) {
        // With NON_BLOCKING execute, keep mic on so user can keep talking
        return

        val executing = isToolExecuting(status)

        if (executing) {
            if (!micAutoMutedForExecution) {
                micStateBeforeExecution = _uiState.value.isMicEnabled

                if (_uiState.value.isMicEnabled) {
                    _uiState.value = _uiState.value.copy(isMicEnabled = false)
                    audioManager.setMicEnabled(false)
                }

                micAutoMutedForExecution = true
            }
            return
        }

        if (micAutoMutedForExecution) {
            val restoreMic = micStateBeforeExecution ?: true
            _uiState.value = _uiState.value.copy(isMicEnabled = restoreMic)
            audioManager.setMicEnabled(restoreMic)

            micStateBeforeExecution = null
            micAutoMutedForExecution = false
        }
    }

    fun toggleMic() {
        if (!_uiState.value.isGeminiActive) return

        val newEnabled = !_uiState.value.isMicEnabled
        _uiState.value = _uiState.value.copy(isMicEnabled = newEnabled)
        audioManager.setMicEnabled(newEnabled)
    }

    fun setMicEnabled(enabled: Boolean) {
        if (!_uiState.value.isGeminiActive) return

        _uiState.value = _uiState.value.copy(isMicEnabled = enabled)
        audioManager.setMicEnabled(enabled)
    }

    fun startSession() {
        if (_uiState.value.isGeminiActive) return

        if (!GeminiConfig.isConfigured) {
            _uiState.value = _uiState.value.copy(
                errorMessage = "Gemini API key not configured. Open Settings and add your key."
            )
            return
        }

        userStopped = false
        reconnectAttempts = 0
        reconnectJob?.cancel()
        reconnectJob = null
        micStateBeforeExecution = null
        micAutoMutedForExecution = false
        lastSpokenProgressKind = null
        lastSpokenProgressAtMs = 0

        // Insert session divider if there are previous messages
        val currentMessages = _uiState.value.messages.toMutableList()
        if (currentMessages.isNotEmpty()) {
            currentMessages.add(ChatMessage(role = ChatMessageRole.SessionDivider, text = ""))
        }

        // Start foreground service to keep alive when screen is locked
        StreamingService.start(getApplication())

        // Start with mic enabled by default
        _uiState.value = _uiState.value.copy(isGeminiActive = true, isMicEnabled = true, messages = currentMessages)
        audioManager.setMicEnabled(true)
        RemoteLogger.log("session:start")

        netMonitor.start()
        netMonitorJob?.cancel()
        netMonitorJob = viewModelScope.launch {
            netMonitor.networkType.collect { t ->
                _uiState.value = _uiState.value.copy(networkType = t)
            }
        }

        audioManager.onAudioCaptured = lambda@{ data ->
            // NON_BLOCKING: keep sending audio during tool execution

            // streamingMode == PHONE 일때 모델이 말하는동안에는 입력을 막음(기존 로직)
            if (streamingMode == StreamingMode.PHONE && geminiService.isModelSpeaking.value) return@lambda

            geminiService.sendAudio(data)
        }

        geminiService.onAudioReceived = { data ->
            audioManager.playAudio(data)
        }
        progressSpeechService.onAudioReceived = { data ->
            audioManager.playAudio(data)
        }

        geminiService.onInterrupted = {
            audioManager.stopPlayback()
        }

        geminiService.onTurnComplete = {
            // Log finalized transcripts before clearing
            if (lastUserText.isNotEmpty()) {
                RemoteLogger.log("voice:user", mapOf("text" to lastUserText))
            }
            if (lastAIText.isNotEmpty()) {
                RemoteLogger.log("voice:ai", mapOf("text" to lastAIText))
            }
            finalizeCurrentBubbles()
            _uiState.value = _uiState.value.copy(userTranscript = "")
            persistMessages()
        }

        geminiService.onInputTranscription = input@{ text ->
            // NON_BLOCKING: keep accepting input during tool execution

            val newTranscript = _uiState.value.userTranscript + text
            lastUserOriginalInstruction = newTranscript

            _uiState.value = _uiState.value.copy(
                userTranscript = newTranscript,
                aiTranscript = ""
            )
            updateUserBubble(newTranscript)
        }

        geminiService.onOutputTranscription = output@{ text ->
            val newAI = _uiState.value.aiTranscript + text
            _uiState.value = _uiState.value.copy(aiTranscript = newAI)
            updateAIBubble(newAI)
        }

        geminiService.onDisconnected = { reason ->
            if (_uiState.value.isGeminiActive && !userStopped) {
                _uiState.value = _uiState.value.copy(
                    errorMessage = "Disconnected: ${reason ?: "Unknown"}\nReconnecting..."
                )
                scheduleReconnect(reason)
            }
        }
        progressSpeechService.connect()

        viewModelScope.launch {
            openClawBridge.checkConnection()
            openClawBridge.resetSession()
            openClawBridge.eventClient = eventClient

            // Connect event client early — needed for image sending via chat.send
            syncProactiveNotifications()

            toolCallRouter = ToolCallRouter(
                bridge = openClawBridge,
                scope = viewModelScope,
                latestFrameProvider = { latestFrameForToolCall },
                originalInstructionProvider = { lastUserOriginalInstruction }
            )

            // Local capture_photo handler
            toolCallRouter?.onCapturePhoto = { description, completion ->
                val frame = latestFrameForToolCall
                if (frame != null) {
                    val photo = PhotoCaptureStore.saveFrame(getApplication(), frame, description)
                    if (photo != null) {
                        _captureEvent.value = photo
                        // Also upload to Mac so agent can access the file
                        viewModelScope.launch(kotlinx.coroutines.Dispatchers.IO) {
                            val macPath = try {
                                val baos = java.io.ByteArrayOutputStream()
                                frame.compress(android.graphics.Bitmap.CompressFormat.JPEG, 90, baos)
                                val base64 = android.util.Base64.encodeToString(baos.toByteArray(), android.util.Base64.NO_WRAP)
                                openClawBridge.uploadImageFilePublic(base64)
                            } catch (e: Exception) { null }
                            if (macPath != null) {
                                completion(ToolResult.Success("Photo captured and saved: ${photo.filename}\nAlso saved on Mac at: $macPath"))
                            } else {
                                completion(ToolResult.Success("Photo captured and saved: ${photo.filename}"))
                            }
                        }
                    } else {
                        completion(ToolResult.Failure("Failed to save photo"))
                    }
                } else {
                    completion(ToolResult.Failure("No camera frame available to capture"))
                }
            }

            // Auto-save to gallery when image is attached to execute call
            toolCallRouter?.onAutoSaveFrame = { bitmap, description ->
                PhotoCaptureStore.saveFrame(getApplication(), bitmap, description)
                _captureEvent.value = PhotoCaptureStore.photos.value.firstOrNull()
            }

            // Load gallery
            PhotoCaptureStore.loadPhotos(getApplication())

            geminiService.onToolCall = { toolCall ->
                for (call in toolCall.functionCalls) {
                    val taskDesc = (call.args["task"] as? String) ?: ""
                    RemoteLogger.log("voice:tool_call", mapOf("tool" to call.name, "task" to taskDesc))
                    if (call.name == "execute") {
                        lastSpokenProgressKind = null
                        lastSpokenProgressAtMs = 0
                        eventClient.resetProgressState()
                    }

                    finalizeCurrentBubbles()
                    val toolMsg = ChatMessage(
                        role = ChatMessageRole.ToolCall(call.name),
                        text = "Executing...",
                        status = ChatMessageStatus.Streaming,
                    )
                    val msgs = _uiState.value.messages.toMutableList()
                    msgs.add(toolMsg)
                    _uiState.value = _uiState.value.copy(messages = msgs)

                    toolCallRouter?.handleToolCall(call) { response ->
                        RemoteLogger.log("voice:tool_result", mapOf("tool" to call.name, "result" to response.toString().take(500)))
                        val updated = _uiState.value.messages.map {
                            if (it.id == toolMsg.id) it.copy(text = "Done", status = ChatMessageStatus.Complete) else it
                        }
                        _uiState.value = _uiState.value.copy(messages = updated)
                        // Reset active bubbles so post-tool AI text goes into a new bubble
                        finalizeCurrentBubbles()
                        geminiService.sendToolResponse(response)
                    }
                }
            }

            geminiService.onToolCallCancellation = { cancellation ->
                toolCallRouter?.cancelToolCalls(cancellation.ids)
            }

            stateObservationJob = viewModelScope.launch {
                while (isActive) {
                    delay(100)

                    val latestToolStatus = openClawBridge.lastToolCallStatus.value
                    syncMicWithToolExecution(latestToolStatus)

                    _uiState.value = _uiState.value.copy(
                        connectionState = geminiService.connectionState.value,
                        isModelSpeaking = geminiService.isModelSpeaking.value,
                        toolCallStatus = latestToolStatus,
                        openClawConnectionState = openClawBridge.connectionState.value,
                    )
                }
            }

            geminiService.connect { setupOk ->
                if (!setupOk) {
                    val msg = when (val state = geminiService.connectionState.value) {
                        is GeminiConnectionState.Error -> state.message
                        else -> geminiService.lastDisconnectInfo.value ?: "Failed to connect to Gemini"
                    }
                    _uiState.value = _uiState.value.copy(errorMessage = msg)
                    geminiService.disconnect()
                    stateObservationJob?.cancel()
                    _uiState.value = _uiState.value.copy(
                        isGeminiActive = false,
                        connectionState = GeminiConnectionState.Disconnected
                    )
                    return@connect
                }

                try {
                    audioManager.startCapture()
                    audioManager.setMicEnabled(_uiState.value.isMicEnabled)
                    _uiState.value = _uiState.value.copy(errorMessage = null)
                } catch (e: Exception) {
                    _uiState.value = _uiState.value.copy(
                        errorMessage = "Mic capture failed: ${e.message}"
                    )
                    geminiService.disconnect()
                    stateObservationJob?.cancel()
                    _uiState.value = _uiState.value.copy(
                        isGeminiActive = false,
                        connectionState = GeminiConnectionState.Disconnected
                    )
                }
            }
        }
    }

    private fun scheduleReconnect(reason: String?) {
        if (reconnectJob?.isActive == true) return
        if (userStopped) return

        reconnectJob = viewModelScope.launch {
            toolCallRouter?.cancelAll()
            openClawBridge.cancelInFlight("gemini disconnected: ${reason ?: "unknown"}")

            audioManager.stopCapture()
            geminiService.disconnect()

            reconnectAttempts = 0

            while (isActive && !userStopped && reconnectAttempts < maxReconnectAttempts) {
                val backoffSec = listOf(1L, 2L, 4L, 8L, 16L, 30L).getOrElse(reconnectAttempts) { 30L }
                reconnectAttempts++

                _uiState.value = _uiState.value.copy(
                    errorMessage = "Reconnecting... (attempt $reconnectAttempts/$maxReconnectAttempts, wait ${backoffSec}s)\nLast: ${reason ?: "Unknown"}"
                )

                delay(backoffSec * 1000)

                var cbOk = false
                geminiService.connect { ok -> cbOk = ok }

                val startWait = System.currentTimeMillis()
                var ready = false
                var errored = false

                while (isActive && !userStopped && System.currentTimeMillis() - startWait < 20_000) {
                    when (geminiService.connectionState.value) {
                        is GeminiConnectionState.Ready -> { ready = true; break }
                        is GeminiConnectionState.Error -> { errored = true; break }
                        else -> delay(100)
                    }
                }

                if ((cbOk || ready) && geminiService.connectionState.value == GeminiConnectionState.Ready) {
                    try {
                        audioManager.startCapture()
                        audioManager.setMicEnabled(_uiState.value.isMicEnabled)
                        _uiState.value = _uiState.value.copy(errorMessage = null)
                        reconnectAttempts = 0
                        return@launch
                    } catch (e: Exception) {
                        _uiState.value = _uiState.value.copy(
                            errorMessage = "Reconnected but mic capture failed: ${e.message}"
                        )
                    }
                } else {
                    val last = (geminiService.connectionState.value as? GeminiConnectionState.Error)?.message
                        ?: geminiService.lastDisconnectInfo.value
                        ?: "unknown"
                    _uiState.value = _uiState.value.copy(
                        errorMessage = "Reconnect failed (attempt $reconnectAttempts): $last"
                    )

                    if (errored) {
                        geminiService.disconnect()
                        audioManager.stopCapture()
                    }
                }
            }

            _uiState.value = _uiState.value.copy(
                errorMessage = "Reconnect failed after $maxReconnectAttempts attempts.\nLast: ${reason ?: "Unknown"}"
            )
        }
    }

    fun stopSession() {
        RemoteLogger.log("session:end")
        StreamingService.stop(getApplication())
        userStopped = true
        reconnectJob?.cancel()
        reconnectJob = null

        eventClient.disconnect()
        toolCallRouter?.cancelAll()
        toolCallRouter = null

        openClawBridge.cancelInFlight("user stopSession")

        audioManager.stopCapture()
        progressSpeechService.disconnect()
        geminiService.disconnect()

        stateObservationJob?.cancel()
        stateObservationJob = null

        netMonitorJob?.cancel()
        netMonitorJob = null
        netMonitor.stop()

        // Keep message history, just reset session state
        _uiState.value = GeminiUiState(messages = _uiState.value.messages)
        persistMessages()
        lastUserOriginalInstruction = null
        latestFrameForToolCall = null
        micStateBeforeExecution = null
        micAutoMutedForExecution = false
    }

    private fun syncProactiveNotifications() {
        // Always connect event client — needed for image sending via chat.send
        eventClient.onProgress = { progress ->
            openClawBridge.setToolCallProgress(progress.displayText)
            maybeSpeakProgress(progress)
        }
        if (SettingsManager.proactiveNotificationsEnabled) {
            eventClient.onNotification = { text ->
                val state = _uiState.value
                if (state.isGeminiActive && state.connectionState == GeminiConnectionState.Ready) {
                    geminiService.sendTextMessage(text)
                }
            }
        } else {
            eventClient.onNotification = null
        }
        eventClient.connect()
    }

    private fun maybeSpeakProgress(progress: OpenClawProgress) {
        val status = openClawBridge.lastToolCallStatus.value
        if (status !is ToolCallStatus.Executing) {
            Log.d("GeminiProgress", "Skip speech: not executing kind=${progress.kind} tool=${progress.toolName}")
            return
        }

        val now = System.currentTimeMillis()
        if (lastSpokenProgressAtMs != 0L && now - lastSpokenProgressAtMs < 8_000) {
            Log.d("GeminiProgress", "Skip speech: throttle kind=${progress.kind} tool=${progress.toolName}")
            return
        }

        lastSpokenProgressKind = progress.kind
        lastSpokenProgressAtMs = now
        val languageName = progressLanguageName()
        Log.d("GeminiProgress", "Send speech hint: ${progress.speechHint} language=$languageName kind=${progress.kind} tool=${progress.toolName}")
        progressSpeechService.speakProgress(progress.speechHint, languageName)
    }

    private fun progressLanguageName(): String {
        return if (containsJapanese(lastUserOriginalInstruction.orEmpty())) "Japanese" else "English"
    }

    private fun containsJapanese(text: String): Boolean {
        return text.any { ch ->
            (ch in '\u3040'..'\u30ff') || (ch in '\u3400'..'\u9fff')
        }
    }

    fun sendVideoFrameIfThrottled(bitmap: Bitmap) {
        if (!SettingsManager.videoStreamingEnabled) return
        if (!_uiState.value.isGeminiActive) return
        if (_uiState.value.connectionState != GeminiConnectionState.Ready) return

        val intervalMs = when (_uiState.value.networkType) {
            NetworkType.WIFI -> videoIntervalWifiMs
            NetworkType.CELLULAR -> videoIntervalCellularMs
            NetworkType.OTHER -> videoIntervalOtherMs
            NetworkType.NONE -> return
        }

        val now = System.currentTimeMillis()
        if (now - lastVideoFrameTime < intervalMs) return
        lastVideoFrameTime = now

        // ✅ tool-call 시점에 업로드할 "원본 bitmap"을 그대로 보관
        latestFrameForToolCall = bitmap

        // Gemini 입력은 기존 로직대로 (GeminiLiveService 내부에서 resize/base64 처리)
        geminiService.sendVideoFrame(bitmap)
    }

    fun clearCachedVideoFrame() {
        latestFrameForToolCall = null
        lastVideoFrameTime = 0
    }

    suspend fun runOpenClawDeveloperCommand(command: String): String {
        val result = openClawBridge.sendSessionCommand(command)
        return when (result) {
            is ToolResult.Success -> {
                if (command.trim() == "/new") {
                    finalizeCurrentBubbles()
                    val msgs = _uiState.value.messages.toMutableList()
                    if (msgs.isNotEmpty()) {
                        msgs.add(ChatMessage(role = ChatMessageRole.SessionDivider, text = ""))
                    }
                    _uiState.value = _uiState.value.copy(
                        userTranscript = "",
                        aiTranscript = "",
                        messages = msgs,
                    )
                    persistMessages()
                    lastUserOriginalInstruction = null
                    lastSpokenProgressKind = null
                    lastSpokenProgressAtMs = 0
                }
                result.result.ifBlank { "OpenClaw command completed." }
            }
            is ToolResult.Failure -> {
                val message = result.error
                _uiState.value = _uiState.value.copy(errorMessage = message)
                message
            }
        }
    }

    fun clearError() {
        _uiState.value = _uiState.value.copy(errorMessage = null)
    }

    private fun persistMessages() {
        ChatHistoryStore.save(getApplication(), _uiState.value.messages)
    }

    // Chat message helpers

    private fun updateUserBubble(text: String) {
        if (text.isEmpty()) return
        val msgs = _uiState.value.messages.toMutableList()
        val existingIdx = activeUserBubbleId?.let { id -> msgs.indexOfFirst { it.id == id } }?.takeIf { it >= 0 }

        if (existingIdx != null) {
            msgs[existingIdx] = msgs[existingIdx].copy(text = text)
        } else {
            // Finalize previous AI bubble
            activeAIBubbleId?.let { aiId ->
                val aiIdx = msgs.indexOfFirst { it.id == aiId }
                if (aiIdx >= 0) msgs[aiIdx] = msgs[aiIdx].copy(status = ChatMessageStatus.Complete)
                activeAIBubbleId = null
            }
            val msg = ChatMessage(role = ChatMessageRole.User, text = text, status = ChatMessageStatus.Streaming)
            msgs.add(msg)
            activeUserBubbleId = msg.id
        }
        lastUserText = text
        _uiState.value = _uiState.value.copy(messages = msgs)
    }

    private fun updateAIBubble(text: String) {
        if (text.isEmpty()) return
        val msgs = _uiState.value.messages.toMutableList()

        // Finalize user bubble
        activeUserBubbleId?.let { userId ->
            val idx = msgs.indexOfFirst { it.id == userId }
            if (idx >= 0) msgs[idx] = msgs[idx].copy(status = ChatMessageStatus.Complete)
        }

        val existingIdx = activeAIBubbleId?.let { id -> msgs.indexOfFirst { it.id == id } }?.takeIf { it >= 0 }
        if (existingIdx != null) {
            msgs[existingIdx] = msgs[existingIdx].copy(text = text)
        } else {
            val msg = ChatMessage(role = ChatMessageRole.Assistant, text = text, status = ChatMessageStatus.Streaming)
            msgs.add(msg)
            activeAIBubbleId = msg.id
        }
        lastAIText = text
        _uiState.value = _uiState.value.copy(messages = msgs)
    }

    private fun finalizeCurrentBubbles() {
        val msgs = _uiState.value.messages.toMutableList()
        activeUserBubbleId?.let { id ->
            val idx = msgs.indexOfFirst { it.id == id }
            if (idx >= 0) msgs[idx] = msgs[idx].copy(status = ChatMessageStatus.Complete)
        }
        activeAIBubbleId?.let { id ->
            val idx = msgs.indexOfFirst { it.id == id }
            if (idx >= 0) msgs[idx] = msgs[idx].copy(status = ChatMessageStatus.Complete)
        }
        activeUserBubbleId = null
        activeAIBubbleId = null
        lastUserText = ""
        lastAIText = ""
        _uiState.value = _uiState.value.copy(messages = msgs)
    }

    override fun onCleared() {
        super.onCleared()
        stopSession()
    }
}
