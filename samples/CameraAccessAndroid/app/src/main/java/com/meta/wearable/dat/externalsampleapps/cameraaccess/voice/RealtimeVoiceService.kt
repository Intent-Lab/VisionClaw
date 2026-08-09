package com.meta.wearable.dat.externalsampleapps.cameraaccess.voice

import android.content.Context
import android.graphics.Bitmap
import com.meta.wearable.dat.externalsampleapps.cameraaccess.gemini.GeminiLiveService
import com.meta.wearable.dat.externalsampleapps.cameraaccess.openclaw.GeminiToolCall
import com.meta.wearable.dat.externalsampleapps.cameraaccess.openclaw.GeminiToolCallCancellation
import com.meta.wearable.dat.externalsampleapps.cameraaccess.openclaw.ToolResult
import com.meta.wearable.dat.externalsampleapps.cameraaccess.settings.SettingsManager
import com.meta.wearable.dat.externalsampleapps.cameraaccess.voice.openai.OpenAIRealtimeService
import kotlinx.coroutines.flow.StateFlow

// Extracted from GeminiLiveService's public surface so alternate realtime voice
// backends (e.g. WebRTC-based providers) can plug into GeminiSessionViewModel.
// Tool-call types keep their Gemini names for now; they act as the app's neutral
// internal representation and other providers map into them.
interface RealtimeVoiceService {
    val connectionState: StateFlow<VoiceConnectionState>
    val isModelSpeaking: StateFlow<Boolean>

    // true when the provider owns mic capture and speaker playback end to end
    // (WebRTC). false when the caller must pump PCM through sendAudio() and
    // play back audio delivered via onAudioReceived.
    val managesOwnAudio: Boolean

    var onAudioReceived: ((ByteArray) -> Unit)?
    var onTurnComplete: (() -> Unit)?
    var onInterrupted: (() -> Unit)?
    var onDisconnected: ((String?) -> Unit)?
    var onInputTranscription: ((String) -> Unit)?
    var onOutputTranscription: ((String) -> Unit)?
    var onToolCall: ((GeminiToolCall) -> Unit)?
    var onToolCallCancellation: ((GeminiToolCallCancellation) -> Unit)?

    fun connect(callback: (Boolean) -> Unit)
    fun disconnect()
    fun sendAudio(data: ByteArray)
    fun sendVideoFrame(bitmap: Bitmap)
    fun sendToolResponse(callId: String, name: String, result: ToolResult)
    fun sendTextMessage(text: String)
}

enum class VoiceProvider(val id: String) {
    GEMINI("gemini"),
    OPENAI_REALTIME("openai");

    companion object {
        fun fromId(id: String): VoiceProvider =
            entries.firstOrNull { it.id == id } ?: GEMINI
    }
}

object VoiceServiceFactory {
    fun current(): VoiceProvider = VoiceProvider.fromId(SettingsManager.voiceProvider)

    fun create(context: Context): RealtimeVoiceService = when (current()) {
        VoiceProvider.GEMINI -> GeminiLiveService()
        VoiceProvider.OPENAI_REALTIME -> OpenAIRealtimeService(context.applicationContext)
    }
}
