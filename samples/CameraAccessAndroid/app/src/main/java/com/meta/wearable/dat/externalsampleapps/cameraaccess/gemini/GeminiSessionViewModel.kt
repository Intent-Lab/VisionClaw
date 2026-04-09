package com.meta.wearable.dat.externalsampleapps.cameraaccess.gemini

import android.graphics.Bitmap
import android.util.Log
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.meta.wearable.dat.externalsampleapps.cameraaccess.conference.ConferenceExtraction
import com.meta.wearable.dat.externalsampleapps.cameraaccess.conference.ConferenceExtractionHandlingResult
import com.meta.wearable.dat.externalsampleapps.cameraaccess.conference.ConferenceExtractionProcessor
import com.meta.wearable.dat.externalsampleapps.cameraaccess.conference.ConferenceModeConfig
import com.meta.wearable.dat.externalsampleapps.cameraaccess.openclaw.OpenClawBridge
import com.meta.wearable.dat.externalsampleapps.cameraaccess.openclaw.OpenClawEventClient
import com.meta.wearable.dat.externalsampleapps.cameraaccess.openclaw.OpenClawConnectionState
import com.meta.wearable.dat.externalsampleapps.cameraaccess.openclaw.ToolDeclarations
import com.meta.wearable.dat.externalsampleapps.cameraaccess.openclaw.ToolCallRouter
import com.meta.wearable.dat.externalsampleapps.cameraaccess.openclaw.ToolCallStatus
import com.meta.wearable.dat.externalsampleapps.cameraaccess.openclaw.ToolResult
import com.meta.wearable.dat.externalsampleapps.cameraaccess.settings.SettingsManager
import com.meta.wearable.dat.externalsampleapps.cameraaccess.stream.StreamingMode
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import org.json.JSONObject

data class GeminiUiState(
    val isGeminiActive: Boolean = false,
    val connectionState: GeminiConnectionState = GeminiConnectionState.Disconnected,
    val isModelSpeaking: Boolean = false,
    val errorMessage: String? = null,
    val userTranscript: String = "",
    val aiTranscript: String = "",
    val toolCallStatus: ToolCallStatus = ToolCallStatus.Idle,
    val openClawConnectionState: OpenClawConnectionState = OpenClawConnectionState.NotConfigured,
    val conferenceModeEnabled: Boolean = false,
    val lastConferenceExtraction: ConferenceExtraction? = null,
)

class GeminiSessionViewModel : ViewModel() {
    companion object {
        private const val TAG = "GeminiSessionVM"
    }

    private val _uiState = MutableStateFlow(GeminiUiState())
    val uiState: StateFlow<GeminiUiState> = _uiState.asStateFlow()

    private val geminiService = GeminiLiveService()
    private val openClawBridge = OpenClawBridge()
    private var toolCallRouter: ToolCallRouter? = null
    private val audioManager = AudioManager()
    private val eventClient = OpenClawEventClient()
    private var lastVideoFrameTime: Long = 0
    private var stateObservationJob: Job? = null
    private var conferenceProcessor = ConferenceExtractionProcessor(ConferenceModeConfig(enabled = false))

    var streamingMode: StreamingMode = StreamingMode.GLASSES

    fun startSession() {
        if (_uiState.value.isGeminiActive) return

        if (!GeminiConfig.isConfigured) {
            _uiState.value = _uiState.value.copy(
                errorMessage = "Gemini API key not configured. Open Settings and add your key from https://aistudio.google.com/apikey"
            )
            return
        }

        conferenceProcessor = ConferenceExtractionProcessor(ConferenceModeConfig.current())
        _uiState.value = _uiState.value.copy(
            isGeminiActive = true,
            conferenceModeEnabled = SettingsManager.conferenceModeEnabled,
            lastConferenceExtraction = null,
        )

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
            if (_uiState.value.isGeminiActive) {
                stopSession()
                _uiState.value = _uiState.value.copy(
                    errorMessage = "Connection lost: ${reason ?: "Unknown error"}"
                )
            }
        }

        // Check OpenClaw and start session
        viewModelScope.launch {
            openClawBridge.checkConnection()
            openClawBridge.resetSession()

            // Wire tool call handling
            toolCallRouter = ToolCallRouter(openClawBridge, viewModelScope)

            geminiService.onToolCall = { toolCall ->
                for (call in toolCall.functionCalls) {
                    if (call.name == ToolDeclarations.EXTRACT_ENTITY_NAME) {
                        val response = handleConferenceToolCall(call)
                        geminiService.sendToolResponse(response)
                    } else {
                        toolCallRouter?.handleToolCall(call) { response ->
                            geminiService.sendToolResponse(response)
                        }
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
                        conferenceModeEnabled = SettingsManager.conferenceModeEnabled,
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
        toolCallRouter?.cancelAll()
        toolCallRouter = null
        audioManager.stopCapture()
        geminiService.disconnect()
        stateObservationJob?.cancel()
        stateObservationJob = null
        _uiState.value = GeminiUiState(conferenceModeEnabled = SettingsManager.conferenceModeEnabled)
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

    private fun handleConferenceToolCall(
        call: com.meta.wearable.dat.externalsampleapps.cameraaccess.openclaw.GeminiFunctionCall,
    ): JSONObject {
        if (!SettingsManager.conferenceModeEnabled) {
            return buildLocalToolResponse(
                callId = call.id,
                name = call.name,
                result = ToolResult.Failure("Conference mode is disabled"),
            )
        }

        return when (val result = conferenceProcessor.handle(call.args)) {
            is ConferenceExtractionHandlingResult.Accepted -> {
                _uiState.value = _uiState.value.copy(lastConferenceExtraction = result.extraction)
                logConferenceExtraction(result.extraction, "accepted")
                buildLocalToolResponse(
                    callId = call.id,
                    name = call.name,
                    result = ToolResult.Success("Accepted conference extraction for ${result.extraction.name}"),
                )
            }
            is ConferenceExtractionHandlingResult.Review -> {
                _uiState.value = _uiState.value.copy(lastConferenceExtraction = result.extraction)
                logConferenceExtraction(result.extraction, "review")
                buildLocalToolResponse(
                    callId = call.id,
                    name = call.name,
                    result = ToolResult.Success("Queued conference extraction for review for ${result.extraction.name}"),
                )
            }
            is ConferenceExtractionHandlingResult.IgnoredLowConfidence -> {
                Log.d(TAG, "[Conference] Ignored low-confidence extraction (${result.confidence}): ${call.args}")
                buildLocalToolResponse(
                    callId = call.id,
                    name = call.name,
                    result = ToolResult.Success("Ignored low-confidence conference extraction"),
                )
            }
            ConferenceExtractionHandlingResult.IgnoredDuplicate -> {
                Log.d(TAG, "[Conference] Ignored duplicate extraction: ${call.args}")
                buildLocalToolResponse(
                    callId = call.id,
                    name = call.name,
                    result = ToolResult.Success("Ignored duplicate conference extraction"),
                )
            }
            is ConferenceExtractionHandlingResult.Invalid -> {
                Log.d(TAG, "[Conference] Invalid extraction payload: ${result.message} ${call.args}")
                buildLocalToolResponse(
                    callId = call.id,
                    name = call.name,
                    result = ToolResult.Failure(result.message),
                )
            }
        }
    }

    private fun logConferenceExtraction(extraction: ConferenceExtraction, event: String) {
        Log.d(
            TAG,
            "[Conference] $event name=${extraction.name} company=${extraction.company.orEmpty()} role=${extraction.role.orEmpty()} source=${extraction.sourceType.wireValue} confidence=${extraction.confidence} observed_text=${extraction.observedText.orEmpty()}",
        )
    }

    private fun buildLocalToolResponse(
        callId: String,
        name: String,
        result: ToolResult,
    ): JSONObject {
        return JSONObject().apply {
            put("toolResponse", JSONObject().apply {
                put("functionResponses", org.json.JSONArray().put(JSONObject().apply {
                    put("id", callId)
                    put("name", name)
                    put("response", result.toJSON())
                }))
            })
        }
    }

    override fun onCleared() {
        super.onCleared()
        stopSession()
    }
}
