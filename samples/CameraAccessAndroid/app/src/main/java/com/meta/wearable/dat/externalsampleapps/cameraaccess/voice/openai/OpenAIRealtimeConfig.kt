package com.meta.wearable.dat.externalsampleapps.cameraaccess.voice.openai

import com.meta.wearable.dat.externalsampleapps.cameraaccess.settings.SettingsManager

object OpenAIRealtimeConfig {
    // Ephemeral-token flow: mint a client secret server-side style with the API
    // key, then POST the SDP offer with the ephemeral key.
    // https://developers.openai.com/api/docs/guides/realtime-webrtc
    const val CLIENT_SECRETS_URL = "https://api.openai.com/v1/realtime/client_secrets"
    const val CALLS_URL = "https://api.openai.com/v1/realtime/calls"

    const val MODEL = "gpt-realtime-2.1"
    const val VOICE = "marin"
    const val TRANSCRIPTION_MODEL = "gpt-4o-mini-transcribe"

    const val VIDEO_JPEG_QUALITY = 50

    val apiKey: String
        get() = SettingsManager.openaiAPIKey

    // The system prompt is provider-neutral; reuse the existing setting.
    val systemInstruction: String
        get() = SettingsManager.geminiSystemPrompt

    val isConfigured: Boolean
        get() = apiKey.isNotEmpty() && !apiKey.startsWith("YOUR_")
}
