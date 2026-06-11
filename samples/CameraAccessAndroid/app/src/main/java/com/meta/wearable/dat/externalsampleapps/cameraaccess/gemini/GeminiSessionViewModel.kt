package com.meta.wearable.dat.externalsampleapps.cameraaccess.gemini

import android.graphics.Bitmap
import android.util.Log
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.meta.wearable.dat.externalsampleapps.cameraaccess.openclaw.OpenClawBridge
import com.meta.wearable.dat.externalsampleapps.cameraaccess.openclaw.OpenClawEventClient
import com.meta.wearable.dat.externalsampleapps.cameraaccess.settings.SettingsManager
import com.meta.wearable.dat.externalsampleapps.cameraaccess.openclaw.OpenClawConnectionState
import com.meta.wearable.dat.externalsampleapps.cameraaccess.openclaw.ToolCallRouter
import com.meta.wearable.dat.externalsampleapps.cameraaccess.openclaw.ToolCallStatus
import com.meta.wearable.dat.externalsampleapps.cameraaccess.stream.StreamingMode
import kotlinx.coroutines.Job
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant
import java.util.UUID

data class GeminiUiState(
    val isGeminiActive: Boolean = false,
    val connectionState: GeminiConnectionState = GeminiConnectionState.Disconnected,
    val isModelSpeaking: Boolean = false,
    val errorMessage: String? = null,
    val userTranscript: String = "",
    val aiTranscript: String = "",
    val toolCallStatus: ToolCallStatus = ToolCallStatus.Idle,
    val openClawConnectionState: OpenClawConnectionState = OpenClawConnectionState.NotConfigured,
)

class GeminiSessionViewModel : ViewModel() {
    companion object {
        private const val TAG = "GeminiSessionVM"
    }

    private val _uiState = MutableStateFlow(GeminiUiState())
    val uiState: StateFlow<GeminiUiState> = _uiState.asStateFlow()

    private val geminiService = GeminiLiveService()
    private val sopRelayClient = SopRelayClient()
    private val openClawBridge = OpenClawBridge()
    private var toolCallRouter: ToolCallRouter? = null
    private val audioManager = AudioManager()
    private val eventClient = OpenClawEventClient()
    private var lastVideoFrameTime: Long = 0
    private var stateObservationJob: Job? = null
    private var heartbeatJob: Job? = null
    private var heartbeatTimeoutJob: Job? = null
    private var currentSopSessionId: String? = null
    private var isSopSessionTerminated = true
    private var isFinalizingSession = false

    var streamingMode: StreamingMode = StreamingMode.GLASSES

    fun startSession() {
        if (_uiState.value.isGeminiActive) return

        if (!GeminiConfig.isConfigured) {
            _uiState.value = _uiState.value.copy(
                errorMessage = "Gemini API key not configured. Open Settings and add your key from https://aistudio.google.com/apikey"
            )
            return
        }

        _uiState.value = _uiState.value.copy(isGeminiActive = true)

        // Wire audio callbacks
        audioManager.onAudioCaptured = lambda@{ data ->
            // Phone mode: mute mic while model speaks to prevent echo
            if (streamingMode == StreamingMode.PHONE && geminiService.isModelSpeaking.value) return@lambda
            geminiService.sendAudio(data)
        }

        geminiService.onAudioReceived = { data ->
            audioManager.playAudio(data)
        }

        geminiService.onInterrupted = {
            audioManager.stopPlayback()
        }

        geminiService.onTurnComplete = {
            _uiState.value = _uiState.value.copy(userTranscript = "")
        }

        geminiService.onInputTranscription = { text ->
            _uiState.value = _uiState.value.copy(
                userTranscript = _uiState.value.userTranscript + text,
                aiTranscript = ""
            )
        }

        geminiService.onOutputTranscription = { text ->
            _uiState.value = _uiState.value.copy(
                aiTranscript = _uiState.value.aiTranscript + text
            )
        }

        geminiService.onDisconnected = { reason ->
            if (_uiState.value.isGeminiActive && !isFinalizingSession) {
                resetToIdle("Connection lost: ${reason ?: "Unknown error"}")
                _uiState.value = _uiState.value.copy(
                    errorMessage = "Connection lost: ${reason ?: "Unknown error"}"
                )
            }
        }

        geminiService.onSocketOpened = {
            startSopHeartbeatSession()
        }

        geminiService.onSocketClosed = {
            if (!_uiState.value.isGeminiActive || isFinalizingSession) return@onSocketClosed
            finalizeSessionWithReceipt(status = "terminated")
        }

        // Check OpenClaw and start session
        viewModelScope.launch {
            openClawBridge.checkConnection()
            openClawBridge.resetSession()

            // Wire tool call handling
            toolCallRouter = ToolCallRouter(openClawBridge, viewModelScope)

            geminiService.onToolCall = { toolCall ->
                for (call in toolCall.functionCalls) {
                    if (call.name == "log_sop_step") {
                        handleSopLogToolCall(call)
                        continue
                    }

                    toolCallRouter?.handleToolCall(call) { response ->
                        geminiService.sendToolResponse(response)
                    }
                }
            }

            geminiService.onToolCallCancellation = { cancellation ->
                toolCallRouter?.cancelToolCalls(cancellation.ids)
            }

            // Observe service state
            stateObservationJob = viewModelScope.launch {
                while (isActive) {
                    delay(100)
                    _uiState.value = _uiState.value.copy(
                        connectionState = geminiService.connectionState.value,
                        isModelSpeaking = geminiService.isModelSpeaking.value,
                        toolCallStatus = openClawBridge.lastToolCallStatus.value,
                        openClawConnectionState = openClawBridge.connectionState.value,
                    )
                }
            }

            // Connect to Gemini
            geminiService.connect { setupOk ->
                if (!setupOk) {
                    val msg = when (val state = geminiService.connectionState.value) {
                        is GeminiConnectionState.Error -> state.message
                        else -> "Failed to connect to Gemini"
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

                // Start mic capture
                try {
                    audioManager.startCapture()
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

                // Connect to OpenClaw event stream for proactive notifications
                if (SettingsManager.proactiveNotificationsEnabled) {
                    eventClient.onNotification = { text ->
                        val state = _uiState.value
                        if (state.isGeminiActive && state.connectionState == GeminiConnectionState.Ready) {
                            geminiService.sendTextMessage(text)
                        }
                    }
                    eventClient.connect()
                }
            }
        }
    }

    fun stopSession() {
        eventClient.disconnect()
        finalizeSessionWithReceipt(status = "terminated")
    }

    fun sendVideoFrameIfThrottled(bitmap: Bitmap) {
        if (!SettingsManager.videoStreamingEnabled) return
        if (!_uiState.value.isGeminiActive) return
        if (_uiState.value.connectionState != GeminiConnectionState.Ready) return
        val now = System.currentTimeMillis()
        if (now - lastVideoFrameTime < GeminiConfig.VIDEO_FRAME_INTERVAL_MS) return
        lastVideoFrameTime = now
        geminiService.sendVideoFrame(bitmap)
    }

    fun clearError() {
        _uiState.value = _uiState.value.copy(errorMessage = null)
    }

    override fun onCleared() {
        super.onCleared()
        stopSession()
    }

    private fun handleSopLogToolCall(call: com.meta.wearable.dat.externalsampleapps.cameraaccess.openclaw.GeminiFunctionCall) {
        val stepName = call.args["step_name"]?.toString()?.trim().orEmpty()
        if (stepName.isEmpty()) {
            geminiService.sendToolResponse(buildToolResponse(
                callId = call.id,
                name = call.name,
                result = com.meta.wearable.dat.externalsampleapps.cameraaccess.openclaw.ToolResult.Failure("Missing required argument: step_name")
            ))
            return
        }

        val sessionId = currentSopSessionId ?: UUID.randomUUID().toString().also {
            currentSopSessionId = it
            isSopSessionTerminated = false
        }

        val imageBase64 = call.args["frame_data"]?.toString()?.takeIf { it.isNotBlank() }
            ?: call.args["image_base64"]?.toString()?.takeIf { it.isNotBlank() }
            ?: geminiService.lastVideoFrameBase64.orEmpty()

        viewModelScope.launch(Dispatchers.IO) {
            sopRelayClient.postSopLog(
                tailscaleIp = GeminiConfig.openClawTailscaleIP,
                sessionId = sessionId,
                stepName = stepName,
                timestampIso8601 = Instant.now().toString(),
                imageBase64 = imageBase64
            )
        }

        geminiService.sendToolResponse(buildToolResponse(
            callId = call.id,
            name = call.name,
            result = com.meta.wearable.dat.externalsampleapps.cameraaccess.openclaw.ToolResult.Success("SOP step forwarded")
        ))
    }

    private fun startSopHeartbeatSession() {
        if (currentSopSessionId != null && !isSopSessionTerminated) return

        val sessionId = UUID.randomUUID().toString()
        currentSopSessionId = sessionId
        isSopSessionTerminated = false

        heartbeatJob?.cancel()
        heartbeatTimeoutJob?.cancel()

        heartbeatJob = viewModelScope.launch(Dispatchers.IO) {
            sopRelayClient.postHeartbeat(
                tailscaleIp = GeminiConfig.openClawTailscaleIP,
                sessionId = sessionId,
                status = "active"
            )

            while (isActive && !isSopSessionTerminated) {
                sopRelayClient.postHeartbeat(
                    tailscaleIp = GeminiConfig.openClawTailscaleIP,
                    sessionId = sessionId,
                    status = "active"
                )
                delay(3_000)
            }
        }

        heartbeatTimeoutJob = viewModelScope.launch {
            delay(60_000)
            finalizeSessionWithReceipt(status = "terminated")
        }
    }

    private fun finalizeSessionWithReceipt(status: String) {
        if (isFinalizingSession) return

        val sessionId = currentSopSessionId
        if (sessionId == null) {
            resetToIdle(null)
            return
        }
        if (isSopSessionTerminated) {
            resetToIdle(null)
            return
        }

        isFinalizingSession = true
        isSopSessionTerminated = true
        heartbeatJob?.cancel()
        heartbeatJob = null
        heartbeatTimeoutJob?.cancel()
        heartbeatTimeoutJob = null

        viewModelScope.launch(Dispatchers.IO) {
            val receiptMessage = sopRelayClient.postHeartbeatForReceipt(
                tailscaleIp = GeminiConfig.openClawTailscaleIP,
                sessionId = sessionId,
                status = status
            )

            withContext(Dispatchers.Main) {
                resetToIdle(receiptMessage)
            }
        }
    }

    private fun resetToIdle(receiptMessage: String?) {
        eventClient.disconnect()
        geminiService.onDisconnected = null
        geminiService.onSocketClosed = null
        geminiService.onSocketOpened = null

        toolCallRouter?.cancelAll()
        toolCallRouter = null
        audioManager.stopCapture()
        geminiService.disconnect()
        stateObservationJob?.cancel()
        stateObservationJob = null

        _uiState.value = GeminiUiState(errorMessage = receiptMessage)
        isFinalizingSession = false
        currentSopSessionId = null
    }

    private fun buildToolResponse(
        callId: String,
        name: String,
        result: com.meta.wearable.dat.externalsampleapps.cameraaccess.openclaw.ToolResult
    ): JSONObject {
        return JSONObject().apply {
            put("toolResponse", JSONObject().apply {
                put("functionResponses", JSONArray().put(JSONObject().apply {
                    put("id", callId)
                    put("name", name)
                    put("response", result.toJSON())
                }))
            })
        }
    }
}
