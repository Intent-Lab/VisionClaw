package com.meta.wearable.dat.externalsampleapps.cameraaccess.settings

import android.content.Context
import android.content.SharedPreferences
import com.meta.wearable.dat.externalsampleapps.cameraaccess.Secrets
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Which realtime model answers. The choice travels to the agent worker as
 * room-token metadata; the phone never talks to either provider directly.
 */
enum class IntelligenceEngine(val value: String, val label: String) {
    GEMINI("gemini", "Gemini"),
    OPENAI("openai", "OpenAI");

    companion object {
        fun fromValue(value: String?): IntelligenceEngine =
            entries.firstOrNull { it.value == value } ?: GEMINI
    }
}

/**
 * Where video comes from. The app is a vision assistant first -- it opens
 * looking at the world through the phone -- and glasses are one capture
 * source, selected in Settings, rather than a mode the user must decide about
 * at launch. Exposed as a flow so the root scaffold swaps the capture
 * pipeline live when the setting changes.
 */
enum class CaptureSource(val value: String, val label: String) {
    PHONE("phone", "Phone Camera"),
    GLASSES("glasses", "Glasses");

    companion object {
        fun fromValue(value: String?): CaptureSource =
            entries.firstOrNull { it.value == value } ?: PHONE
    }
}

object SettingsManager {
    private const val PREFS_NAME = "visionclaw_settings"
    private const val DEFAULT_SIGNALING_URL = "wss://YOUR_SIGNALING_SERVER"

    private lateinit var prefs: SharedPreferences

    private val _captureSourceFlow = MutableStateFlow(CaptureSource.PHONE)
    val captureSourceFlow: StateFlow<CaptureSource> = _captureSourceFlow.asStateFlow()

    fun init(context: Context) {
        prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        _captureSourceFlow.value = CaptureSource.fromValue(prefs.getString("captureSource", null))
    }

    var captureSource: CaptureSource
        get() = _captureSourceFlow.value
        set(value) {
            prefs.edit().putString("captureSource", value.value).apply()
            _captureSourceFlow.value = value
        }

    /** Full base URL of the hosted gateway, scheme included (e.g. "https://gw.example.com"). */
    var gatewayBaseUrl: String
        get() = prefs.getString("gatewayBaseUrl", null) ?: Secrets.gatewayBaseUrl
        set(value) = prefs.edit().putString("gatewayBaseUrl", value).apply()

    var gatewayToken: String
        get() = prefs.getString("gatewayToken", null) ?: Secrets.gatewayToken
        set(value) = prefs.edit().putString("gatewayToken", value).apply()

    // An unfilled Secrets.kt.example placeholder is not empty, so without this
    // a fresh clone reports "configured" and then fails with a 401 that looks
    // like a server problem rather than a missing token.
    val isGatewayConfigured: Boolean
        get() = gatewayBaseUrl.startsWith("http") &&
            gatewayToken.isNotEmpty() &&
            !gatewayToken.startsWith("YOUR_")

    var intelligenceEngine: IntelligenceEngine
        get() = IntelligenceEngine.fromValue(prefs.getString("intelligenceEngine", null))
        set(value) = prefs.edit().putString("intelligenceEngine", value.value).apply()

    var webrtcSignalingURL: String
        get() = prefs.getString("webrtcSignalingURL", null) ?: DEFAULT_SIGNALING_URL
        set(value) = prefs.edit().putString("webrtcSignalingURL", value).apply()

    fun resetAll() {
        prefs.edit().clear().apply()
        _captureSourceFlow.value = CaptureSource.PHONE
    }
}
