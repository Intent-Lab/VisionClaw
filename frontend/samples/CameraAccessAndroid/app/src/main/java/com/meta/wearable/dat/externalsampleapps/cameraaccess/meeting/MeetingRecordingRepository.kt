package com.meta.wearable.dat.externalsampleapps.cameraaccess.meeting

import com.meta.wearable.dat.externalsampleapps.cameraaccess.gemini.GeminiConfig
import java.io.File
import java.util.concurrent.TimeUnit
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.MultipartBody
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.asRequestBody
import org.json.JSONObject

class MeetingRecordingRepository {
    private val client = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .writeTimeout(120, TimeUnit.SECONDS)
        .readTimeout(180, TimeUnit.SECONDS)
        .build()

    fun upload(
        file: File,
        title: String,
        startedAt: String,
        endedAt: String,
    ): MeetingRecordingResult {
        val body = MultipartBody.Builder()
            .setType(MultipartBody.FORM)
            .addFormDataPart(
                "audio",
                file.name,
                file.asRequestBody("audio/mp4".toMediaType()),
            )
            .addFormDataPart("title", title)
            .addFormDataPart("started_at", startedAt)
            .addFormDataPart("ended_at", endedAt)
            .addFormDataPart("person_ids", "[]")
            .build()
        val request = Request.Builder()
            .url("${GeminiConfig.jarvisApiBase.trimEnd('/')}/meetings/recordings")
            .addHeader("X-API-Key", GeminiConfig.jarvisApiKey)
            .post(body)
            .build()

        client.newCall(request).execute().use { response ->
            val responseBody = response.body?.string().orEmpty()
            if (!response.isSuccessful) {
                throw IllegalStateException("HTTP ${response.code}: ${responseBody.take(300)}")
            }
            val json = JSONObject(responseBody)
            val summary = json.getJSONObject("summary")
            return MeetingRecordingResult(
                meetingId = json.getJSONObject("meeting").getString("id"),
                memoryId = json.getString("memory_id"),
                title = summary.optString("title", title),
                summary = summary.optString("summary"),
                decisions = summary.optJSONArray("decisions")?.toStringList().orEmpty(),
                actionItems = summary.optJSONArray("action_items")?.toStringList().orEmpty(),
            )
        }
    }

    private fun org.json.JSONArray.toStringList(): List<String> =
        (0 until length()).mapNotNull { index -> optString(index).takeIf { it.isNotBlank() } }
}

data class MeetingRecordingResult(
    val meetingId: String,
    val memoryId: String,
    val title: String,
    val summary: String,
    val decisions: List<String>,
    val actionItems: List<String>,
)
