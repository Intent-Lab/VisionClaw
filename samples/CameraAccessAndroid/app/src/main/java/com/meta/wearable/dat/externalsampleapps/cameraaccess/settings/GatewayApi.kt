package com.meta.wearable.dat.externalsampleapps.cameraaccess.settings

import java.io.IOException
import java.time.Instant
import java.time.OffsetDateTime
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONException
import org.json.JSONObject

/**
 * Reachability of the hosted gateway, resolved by an actual authenticated
 * request. "Configured" and "working" are different things -- a wrong token
 * looks identical to a correct one until something calls the server.
 */
sealed class GatewayStatus {
    data object Checking : GatewayStatus()
    data object Ready : GatewayStatus()
    data object NotConfigured : GatewayStatus()
    data object Unauthorized : GatewayStatus()
    data class Unreachable(val detail: String) : GatewayStatus()
}

/** Read-only gateway calls backing the Settings screens. */
object GatewayApi {
    private val client = OkHttpClient.Builder()
        .callTimeout(15, TimeUnit.SECONDS)
        .build()

    data class ConnectableApp(
        val id: String,
        val displayName: String,
        val connected: Boolean,
        val available: Boolean,
        /** Connected, but the stored credential no longer works; only reconnecting fixes it. */
        val needsReconnect: Boolean,
    )

    data class TaskEntry(
        val id: String,
        val timestampMs: Long?,
        val prompt: String,
        val result: String,
    )

    private fun request(path: String): Request = Request.Builder()
        .url("${SettingsManager.gatewayBaseUrl.trimEnd('/')}$path")
        .header("Authorization", "Bearer ${SettingsManager.gatewayToken}")
        .build()

    /**
     * /apps is the cheapest route that needs a valid token, and distinguishing
     * 401 from a transport failure is the whole point -- they need opposite
     * fixes.
     */
    suspend fun checkStatus(): GatewayStatus = withContext(Dispatchers.IO) {
        if (!SettingsManager.isGatewayConfigured) return@withContext GatewayStatus.NotConfigured
        try {
            client.newCall(request("/apps")).execute().use { response ->
                when (response.code) {
                    200 -> GatewayStatus.Ready
                    401, 403 -> GatewayStatus.Unauthorized
                    else -> GatewayStatus.Unreachable("Server error ${response.code}")
                }
            }
        } catch (e: IOException) {
            GatewayStatus.Unreachable("Unreachable")
        }
    }

    suspend fun fetchApps(): Result<List<ConnectableApp>> = withContext(Dispatchers.IO) {
        if (!SettingsManager.isGatewayConfigured) {
            return@withContext Result.failure(IOException("Gateway not configured"))
        }
        try {
            client.newCall(request("/apps")).execute().use { response ->
                val text = response.body?.string().orEmpty()
                if (response.code != 200) {
                    return@use Result.failure(IOException(errorMessage(text) ?: "Server error"))
                }
                val items = JSONObject(text).optJSONArray("apps")
                    ?: return@use Result.failure(IOException("Unexpected response"))
                val apps = (0 until items.length()).mapNotNull { index ->
                    val item = items.optJSONObject(index) ?: return@mapNotNull null
                    val id = item.optString("id").takeIf { it.isNotEmpty() } ?: return@mapNotNull null
                    ConnectableApp(
                        id = id,
                        displayName = item.optString("displayName", id),
                        connected = item.optBoolean("connected", false),
                        available = item.optBoolean("available", false),
                        needsReconnect = item.optBoolean("needs_reconnect", false),
                    )
                }
                Result.success(apps)
            }
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun fetchTasks(): Result<List<TaskEntry>> = withContext(Dispatchers.IO) {
        if (!SettingsManager.isGatewayConfigured) {
            return@withContext Result.failure(IOException("Gateway not configured"))
        }
        try {
            client.newCall(request("/tasks?limit=20")).execute().use { response ->
                val text = response.body?.string().orEmpty()
                if (response.code != 200) {
                    return@use Result.failure(IOException(errorMessage(text) ?: "Server error"))
                }
                val items = JSONObject(text).optJSONArray("tasks")
                    ?: return@use Result.failure(IOException("Unexpected response"))
                val tasks = (0 until items.length()).mapNotNull { index ->
                    val item = items.optJSONObject(index) ?: return@mapNotNull null
                    TaskEntry(
                        id = item.optString("id", index.toString()),
                        timestampMs = parseTimestamp(item.optString("ts")),
                        prompt = item.optString("prompt"),
                        result = item.optString("result"),
                    )
                }
                Result.success(tasks)
            }
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    /**
     * Browser URL for the gateway's OAuth connect route. No callback scheme is
     * passed, so the gateway finishes on its own "you can close this window"
     * page instead of bouncing to an app link.
     */
    fun connectUrl(appId: String): String {
        val base = SettingsManager.gatewayBaseUrl.trimEnd('/')
        return "$base/connect/$appId?token=${SettingsManager.gatewayToken}"
    }

    /** Parses the gateway's {"error": {"message": ...}} / {"error": "..."} shapes. */
    fun errorMessage(body: String): String? {
        return try {
            when (val error = JSONObject(body).opt("error")) {
                is JSONObject -> error.optString("message").takeIf { it.isNotEmpty() }
                is String -> error
                else -> null
            }
        } catch (e: JSONException) {
            null
        }
    }

    private fun parseTimestamp(raw: String?): Long? {
        if (raw.isNullOrEmpty()) return null
        return try {
            OffsetDateTime.parse(raw).toInstant().toEpochMilli()
        } catch (e: Exception) {
            try {
                Instant.parse(raw).toEpochMilli()
            } catch (e: Exception) {
                null
            }
        }
    }
}
