package com.meta.wearable.dat.externalsampleapps.cameraaccess.gemini

import android.util.Log
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.util.concurrent.TimeUnit
import org.json.JSONObject

class SopRelayClient {
    companion object {
        private const val TAG = "SopRelayClient"
        private const val JSON_MEDIA_TYPE = "application/json; charset=utf-8"
        private const val MAX_RETRIES = 3
    }

    private val client = OkHttpClient.Builder()
        .connectTimeout(5, TimeUnit.SECONDS)
        .readTimeout(10, TimeUnit.SECONDS)
        .writeTimeout(10, TimeUnit.SECONDS)
        .build()

    fun postSopLog(
        tailscaleIp: String,
        sessionId: String,
        stepName: String,
        timestampIso8601: String,
        imageBase64: String
    ) {
        if (tailscaleIp.isBlank()) {
            Log.w(TAG, "OPENCLAW_TAILSCALE_IP is empty, skipping SOP log relay")
            return
        }

        val payload = JSONObject().apply {
            put("session_id", sessionId)
            put("step_name", stepName)
            put("timestamp", timestampIso8601)
            put("image_base64", stripDataUriPrefix(imageBase64))
        }

        postJson("http://$tailscaleIp:8000/api/v1/sop-log", payload)
    }

    fun postHeartbeat(
        tailscaleIp: String,
        sessionId: String,
        status: String
    ) {
        if (tailscaleIp.isBlank()) {
            Log.w(TAG, "OPENCLAW_TAILSCALE_IP is empty, skipping heartbeat relay")
            return
        }

        val payload = JSONObject().apply {
            put("session_id", sessionId)
            put("status", status)
        }

        postJson("http://$tailscaleIp:8000/api/v1/heartbeat", payload)
    }

    fun postHeartbeatForReceipt(
        tailscaleIp: String,
        sessionId: String,
        status: String
    ): String? {
        if (tailscaleIp.isBlank()) {
            Log.w(TAG, "OPENCLAW_TAILSCALE_IP is empty, skipping heartbeat relay")
            return null
        }

        val payload = JSONObject().apply {
            put("session_id", sessionId)
            put("status", status)
        }

        val rawBody = postJsonWithResponse("http://$tailscaleIp:8000/api/v1/heartbeat", payload) ?: return null

        return try {
            JSONObject(rawBody).optString("message").ifBlank { rawBody }
        } catch (_: Exception) {
            rawBody
        }
    }

    private fun postJson(url: String, payload: JSONObject) {
        postJsonWithResponse(url, payload)
    }

    private fun postJsonWithResponse(url: String, payload: JSONObject): String? {
        var attempt = 0
        var backoffMs = 500L

        while (attempt < MAX_RETRIES) {
            attempt += 1

            try {
                val requestBody = payload.toString().toRequestBody(JSON_MEDIA_TYPE.toMediaType())
                val request = Request.Builder()
                    .url(url)
                    .post(requestBody)
                    .build()

                client.newCall(request).execute().use { response ->
                    val responseBody = response.body?.string()

                    if (response.isSuccessful) {
                        return responseBody
                    }

                    if (response.code in 500..599 && attempt < MAX_RETRIES) {
                        Thread.sleep(backoffMs)
                        backoffMs *= 2
                        continue
                    }

                    Log.w(TAG, "POST $url failed with HTTP ${response.code}")
                    return responseBody
                }
            } catch (e: Exception) {
                if (attempt < MAX_RETRIES) {
                    Thread.sleep(backoffMs)
                    backoffMs *= 2
                    continue
                }

                Log.e(TAG, "POST failed for $url after $attempt attempts: ${e.message}")
                return null
            }
        }

        return null
    }

    private fun stripDataUriPrefix(value: String): String {
        return if (value.startsWith("data:image/jpeg;base64,")) {
            value.removePrefix("data:image/jpeg;base64,")
        } else {
            value
        }
    }
}
