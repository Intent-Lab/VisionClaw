package com.meta.wearable.dat.externalsampleapps.cameraaccess.webrtc

import android.util.Log
import com.meta.wearable.dat.externalsampleapps.cameraaccess.gemini.GeminiConfig
import com.meta.wearable.dat.externalsampleapps.cameraaccess.settings.SettingsManager
import java.net.URLEncoder
import java.nio.charset.StandardCharsets
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONObject
import org.webrtc.PeerConnection
import java.util.concurrent.TimeUnit

object WebRTCConfig {
    private const val TAG = "WebRTCConfig"

    // Video encoding
    const val VIDEO_BITRATE = 2_500_000 // 2.5 Mbps
    const val VIDEO_FRAMERATE = 24
    const val VIDEO_WIDTH = 1280
    const val VIDEO_HEIGHT = 720

    // STUN server
    private const val STUN_URL = "stun:stun.l.google.com:19302"

    // ExpressTURN credentials endpoint
    private const val TURN_CREDENTIALS_URL = "https://visionclaw-turn-creds.fly.dev/credentials"

    val signalingServerURL: String
        get() {
            val configured = SettingsManager.webrtcSignalingURL.trim()
            if (isUsableSignalingUrl(configured)) {
                return configured
            }
            return "${liveBaseUrl().replaceFirst("https://", "wss://").replaceFirst("http://", "ws://")}/ws"
        }

    val isConfigured: Boolean
        get() {
            val url = signalingServerURL
            return (url.startsWith("wss://") || url.startsWith("ws://")) &&
                !url.contains("YOUR_HOST") &&
                !url.contains("YOUR_SIGNALING_SERVER")
        }

    fun viewerUrl(roomCode: String): String {
        val encoded = URLEncoder.encode(roomCode, StandardCharsets.UTF_8.name())
        return "${liveBaseUrl().replaceFirst("ws://", "http://").replaceFirst("wss://", "https://")}/watch?room=$encoded"
    }

    private fun liveBaseUrl(): String = "${GeminiConfig.jarvisApiBase.trimEnd('/')}/live"

    private fun isUsableSignalingUrl(url: String): Boolean {
        if (url.isBlank()) return false
        if (url.contains("YOUR_SIGNALING_SERVER")) return false
        if (url.contains("YOUR_HOST")) return false
        return url.startsWith("wss://") || url.startsWith("ws://")
    }

    /**
     * Fetch TURN credentials from the credential server, falling back to STUN-only if unavailable.
     */
    suspend fun fetchIceServers(): List<PeerConnection.IceServer> {
        val servers = mutableListOf<PeerConnection.IceServer>()

        // Always include STUN
        servers.add(
            PeerConnection.IceServer.builder(STUN_URL).createIceServer()
        )

        // Fetch TURN credentials
        try {
            val turnServers = fetchTurnCredentials()
            servers.addAll(turnServers)
            Log.d(TAG, "Fetched ${turnServers.size} TURN servers")
        } catch (e: Exception) {
            Log.w(TAG, "Failed to fetch TURN credentials, using STUN only: ${e.message}")
        }

        return servers
    }

    private suspend fun fetchTurnCredentials(): List<PeerConnection.IceServer> =
        withContext(Dispatchers.IO) {
            val client = OkHttpClient.Builder()
                .connectTimeout(10, TimeUnit.SECONDS)
                .readTimeout(10, TimeUnit.SECONDS)
                .build()

            val request = Request.Builder()
                .url(TURN_CREDENTIALS_URL)
                .get()
                .build()

            val response = client.newCall(request).execute()
            if (!response.isSuccessful) {
                throw Exception("TURN credentials request failed: ${response.code}")
            }

            val body = response.body?.string() ?: throw Exception("Empty TURN response")
            val json = JSONObject(body)

            val servers = mutableListOf<PeerConnection.IceServer>()

            // Parse iceServers array
            val iceServers = json.optJSONArray("iceServers")
            if (iceServers != null) {
                for (i in 0 until iceServers.length()) {
                    val server = iceServers.getJSONObject(i)
                    val urls = server.optJSONArray("urls") ?: continue
                    val username = server.optString("username", "")
                    val credential = server.optString("credential", "")

                    val urlList = mutableListOf<String>()
                    for (j in 0 until urls.length()) {
                        urlList.add(urls.getString(j))
                    }

                    if (urlList.isNotEmpty()) {
                        val builder = PeerConnection.IceServer.builder(urlList)
                        if (username.isNotEmpty()) builder.setUsername(username)
                        if (credential.isNotEmpty()) builder.setPassword(credential)
                        servers.add(builder.createIceServer())
                    }
                }
            }

            servers
        }
}
