package com.meta.wearable.dat.externalsampleapps.cameraaccess.gemini

import android.app.Application
import android.graphics.Bitmap
import android.util.Log
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.meta.wearable.dat.externalsampleapps.cameraaccess.openclaw.OpenClawBridge
import com.meta.wearable.dat.externalsampleapps.cameraaccess.openclaw.OpenClawEventClient
import com.meta.wearable.dat.externalsampleapps.cameraaccess.settings.SettingsManager
import com.meta.wearable.dat.externalsampleapps.cameraaccess.openclaw.OpenClawConnectionState
import com.meta.wearable.dat.externalsampleapps.cameraaccess.openclaw.ToolCallRouter
import com.meta.wearable.dat.externalsampleapps.cameraaccess.openclaw.ToolCallStatus
import com.meta.wearable.dat.externalsampleapps.cameraaccess.stream.StreamingMode
import com.meta.wearable.dat.externalsampleapps.cameraaccess.voice.RealtimeVoiceService
import com.meta.wearable.dat.externalsampleapps.cameraaccess.voice.VoiceConnectionState
import com.meta.wearable.dat.externalsampleapps.cameraaccess.voice.VoiceProvider
import com.meta.wearable.dat.externalsampleapps.cameraaccess.voice.VoiceServiceFactory
import com.meta.wearable.dat.externalsampleapps.cameraaccess.voice.openai.OpenAIRealtimeConfig
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

data class GeminiUiState(
    val isGeminiActive: Boolean = false,
    val connectionState: VoiceConnectionState = VoiceConnectionState.Disconnected,
    val isModelSpeaking: Boolean = false,
    val errorMessage: String? = null,
    val userTranscript: String = "",
    val aiTranscript: String = "",
    val toolCallStatus: ToolCallStatus = ToolCallStatus.Idle,
    val openClawConnectionState: OpenClawConnectionState = OpenClawConnectionState.NotConfigured,
)

class GeminiSessionViewModel(application: Application) : AndroidViewModel(application) {
    companion object {
        private const val TAG = "GeminiSessionVM"
    }

    private val _uiState = MutableStateFlow(GeminiUiState())
    val uiState: StateFlow<GeminiUiState> = _uiState.asStateFlow()

    private val application: Application = application
    // Re-created on every startSession() so a provider switch in Settings
    // takes effect on the next session.
    private var voiceService: RealtimeVoiceService = VoiceServiceFactory.create(application)
    private val openClawBridge = OpenClawBridge()
    private var toolCallRouter: ToolCallRouter? = null
    private val audioManager = AudioManager()
    private val eventClient = OpenClawEventClient()
    private var lastVideoFrameTime: Long = 0
    private var stateObservationJob: Job? = null

    var streamingMode: StreamingMode = StreamingMode.GLASSES

    fun startSession() {
        if (_uiState.value.isGeminiActive) return

        when (VoiceServiceFactory.current()) {
            VoiceProvider.GEMINI -> if (!GeminiConfig.isConfigured) {
                _uiState.value = _uiState.value.copy(
                    errorMessage = "Gemini API key not configured. Open Settings and add your key from https://aistudio.google.com/apikey"
                )
                return
            }
            VoiceProvider.OPENAI_REALTIME -> if (!OpenAIRealtimeConfig.isConfigured) {
                _uiState.value = _uiState.value.copy(
                    errorMessage = "OpenAI API key not configured. Open Settings and add your key from https://platform.openai.com/api-keys"
                )
                return
            }
        }

        _uiState.value = _uiState.value.copy(isGeminiActive = true)
        voiceService = VoiceServiceFactory.create(application)

        // Wire audio callbacks. A provider that manages its own audio (WebRTC)
        // captures the mic and plays audio inside the peer connection, so the
        // PCM pump stays idle for it.
        if (!voiceService.managesOwnAudio) {
            audioManager.onAudioCaptured = lambda@{ data ->
                // Phone mode: mute mic while model speaks to prevent echo
                if (streamingMode == StreamingMode.PHONE && voiceService.isModelSpeaking.value) return@lambda
                voiceService.sendAudio(data)
            }

            voiceService.onAudioReceived = { data ->
                audioManager.playAudio(data)
            }
        }

        voiceService.onInterrupted = {
            audioManager.stopPlayback()
        }

        voiceService.onTurnComplete = {
            _uiState.value = _uiState.value.copy(userTranscript = "")
        }

        voiceService.onInputTranscription = { text ->
            _uiState.value = _uiState.value.copy(
                userTranscript = _uiState.value.userTranscript + text,
                aiTranscript = ""
            )
        }

        voiceService.onOutputTranscription = { text ->
            _uiState.value = _uiState.value.copy(
                aiTranscript = _uiState.value.aiTranscript + text
            )
        }

        voiceService.onDisconnected = { reason ->
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

            voiceService.onToolCall = { toolCall ->
                for (call in toolCall.functionCalls) {
                    toolCallRouter?.handleToolCall(call) { callId, name, result ->
                        voiceService.sendToolResponse(callId, name, result)
                    }
                }
            }

            voiceService.onToolCallCancellation = { cancellation ->
                toolCallRouter?.cancelToolCalls(cancellation.ids)
            }

            // Observe service state
            stateObservationJob = viewModelScope.launch {
                while (isActive) {
                    delay(100)
                    _uiState.value = _uiState.value.copy(
                        connectionState = voiceService.connectionState.value,
                        isModelSpeaking = voiceService.isModelSpeaking.value,
                        toolCallStatus = openClawBridge.lastToolCallStatus.value,
                        openClawConnectionState = openClawBridge.connectionState.value,
                    )
                }
            }

            // Connect to Gemini
            voiceService.connect { setupOk ->
                if (!setupOk) {
                    val msg = when (val state = voiceService.connectionState.value) {
                        is VoiceConnectionState.Error -> state.message
                        else -> "Failed to connect to Gemini"
                    }
                    _uiState.value = _uiState.value.copy(errorMessage = msg)
                    voiceService.disconnect()
                    stateObservationJob?.cancel()
                    _uiState.value = _uiState.value.copy(
                        isGeminiActive = false,
                        connectionState = VoiceConnectionState.Disconnected
                    )
                    return@connect
                }

                // Start mic capture (WebRTC providers capture inside the peer connection)
                try {
                    if (!voiceService.managesOwnAudio) {
                        audioManager.startCapture()
                    }
                } catch (e: Exception) {
                    _uiState.value = _uiState.value.copy(
                        errorMessage = "Mic capture failed: ${e.message}"
                    )
                    voiceService.disconnect()
                    stateObservationJob?.cancel()
                    _uiState.value = _uiState.value.copy(
                        isGeminiActive = false,
                        connectionState = VoiceConnectionState.Disconnected
                    )
                }

                // Connect to OpenClaw event stream for proactive notifications
                if (SettingsManager.proactiveNotificationsEnabled) {
                    eventClient.onNotification = { text ->
                        val state = _uiState.value
                        if (state.isGeminiActive && state.connectionState == VoiceConnectionState.Ready) {
                            voiceService.sendTextMessage(text)
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
        voiceService.disconnect()
        stateObservationJob?.cancel()
        stateObservationJob = null
        _uiState.value = GeminiUiState()
    }

    fun sendVideoFrameIfThrottled(bitmap: Bitmap) {
        if (!SettingsManager.videoStreamingEnabled) return
        if (!_uiState.value.isGeminiActive) return
        if (_uiState.value.connectionState != VoiceConnectionState.Ready) return
        val now = System.currentTimeMillis()
        if (now - lastVideoFrameTime < GeminiConfig.VIDEO_FRAME_INTERVAL_MS) return
        lastVideoFrameTime = now
        voiceService.sendVideoFrame(bitmap)
    }

    fun clearError() {
        _uiState.value = _uiState.value.copy(errorMessage = null)
    }

    override fun onCleared() {
        super.onCleared()
        stopSession()
    }
}
