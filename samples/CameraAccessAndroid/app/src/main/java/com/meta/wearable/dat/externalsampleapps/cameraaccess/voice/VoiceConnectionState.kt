package com.meta.wearable.dat.externalsampleapps.cameraaccess.voice

// Provider-neutral connection state for realtime voice sessions.
// (Moved from gemini/GeminiLiveService.kt.)
sealed class VoiceConnectionState {
    data object Disconnected : VoiceConnectionState()
    data object Connecting : VoiceConnectionState()
    data object SettingUp : VoiceConnectionState()
    data object Ready : VoiceConnectionState()
    data class Error(val message: String) : VoiceConnectionState()
}
