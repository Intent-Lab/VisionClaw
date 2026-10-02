package com.meta.wearable.dat.externalsampleapps.cameraaccess.meeting

import com.meta.wearable.dat.externalsampleapps.cameraaccess.gemini.GeminiConfig
import java.time.Instant
import java.time.Duration
import java.time.ZoneId
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import java.util.concurrent.TimeUnit
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.MediaType.Companion.toMediaType
import org.json.JSONArray
import org.json.JSONObject

class MeetingHistoryRepository {
    private val client = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .build()
    private val jsonMediaType = "application/json".toMediaType()
    private val kstZone = ZoneId.of("Asia/Seoul")
    private val displayFormatter = DateTimeFormatter.ofPattern("MM-dd HH:mm")

    fun recent(limit: Int = 30): List<MeetingHistoryItem> {
        val request = Request.Builder()
            .url("${GeminiConfig.jarvisApiBase.trimEnd('/')}/meetings?limit=$limit")
            .get()
            .addHeader("X-API-Key", GeminiConfig.jarvisApiKey)
            .build()
        client.newCall(request).execute().use { response ->
            val responseBody = response.body?.string().orEmpty()
            if (!response.isSuccessful) {
                throw IllegalStateException("HTTP ${response.code}: ${responseBody.take(160)}")
            }
            val json = JSONArray(responseBody)
            return (0 until json.length()).map { index ->
                parseMeeting(json.getJSONObject(index))
            }
        }
    }

    fun buildShareText(item: MeetingHistoryItem): String {
        item.markdownSummary?.takeIf { it.isNotBlank() }?.let { return it.trim() }
        return buildString {
            appendLine(item.title)
            appendLine("시간: ${item.timeDisplay}")
            item.durationDisplay?.let { appendLine("소요 시간: $it") }
            item.summary?.takeIf { it.isNotBlank() }?.let {
                appendLine()
                appendLine("요약")
                appendLine(it)
            }
            if (item.decisions.isNotEmpty()) {
                appendLine()
                appendLine("결정사항")
                item.decisions.forEach { appendLine("- $it") }
            }
            if (item.actionItems.isNotEmpty()) {
                appendLine()
                appendLine("후속 작업")
                item.actionItems.forEach { appendLine("- $it") }
            }
            item.transcript?.takeIf { it.isNotBlank() }?.let {
                appendLine()
                appendLine("원문")
                appendLine(it)
            }
        }.trim()
    }

    fun get(meetingId: String): MeetingHistoryItem {
        val request = Request.Builder()
            .url("${GeminiConfig.jarvisApiBase.trimEnd('/')}/meetings/$meetingId")
            .get()
            .addHeader("X-API-Key", GeminiConfig.jarvisApiKey)
            .build()
        client.newCall(request).execute().use { response ->
            val responseBody = response.body?.string().orEmpty()
            if (!response.isSuccessful) {
                throw IllegalStateException("HTTP ${response.code}: ${responseBody.take(160)}")
            }
            return parseMeeting(JSONObject(responseBody))
        }
    }

    fun update(meeting: MeetingHistoryItem): MeetingHistoryItem {
        val body = JSONObject()
            .put("title", meeting.title)
            .put("summary", meeting.summary ?: JSONObject.NULL)
            .put("raw_transcript", meeting.transcript ?: JSONObject.NULL)
            .put(
                "metadata",
                JSONObject().put("markdown_summary", meeting.markdownSummary ?: JSONObject.NULL),
            )
        val request = Request.Builder()
            .url("${GeminiConfig.jarvisApiBase.trimEnd('/')}/meetings/${meeting.id}")
            .put(body.toString().toRequestBody(jsonMediaType))
            .addHeader("X-API-Key", GeminiConfig.jarvisApiKey)
            .addHeader("Content-Type", "application/json")
            .build()
        client.newCall(request).execute().use { response ->
            val responseBody = response.body?.string().orEmpty()
            if (!response.isSuccessful) {
                throw IllegalStateException("HTTP ${response.code}: ${responseBody.take(160)}")
            }
            return parseMeeting(JSONObject(responseBody))
        }
    }

    fun delete(meetingId: String) {
        val request = Request.Builder()
            .url("${GeminiConfig.jarvisApiBase.trimEnd('/')}/meetings/$meetingId")
            .delete()
            .addHeader("X-API-Key", GeminiConfig.jarvisApiKey)
            .build()
        client.newCall(request).execute().use { response ->
            if (!response.isSuccessful) {
                val responseBody = response.body?.string().orEmpty()
                throw IllegalStateException("HTTP ${response.code}: ${responseBody.take(160)}")
            }
        }
    }

    private fun parseMeeting(json: JSONObject): MeetingHistoryItem {
        val metadata = json.optJSONObject("metadata") ?: JSONObject()
        val startedAt = json.optString("started_at")
        val endedAt = json.optString("ended_at").ifBlank { null }
        return MeetingHistoryItem(
            id = json.optString("id"),
            title = json.optString("title").ifBlank { "회의 기록" },
            startedAt = startedAt,
            timeDisplay = buildTimeDisplay(startedAt, endedAt),
            durationDisplay = buildDurationDisplay(startedAt, endedAt),
            summary = json.optString("summary").ifBlank { null },
            markdownSummary = metadata.optString("markdown_summary").ifBlank { null },
            transcript = json.optString("raw_transcript").ifBlank { null },
            decisions = metadata.optJSONArray("decisions").toStringList(),
            actionItems = metadata.optJSONArray("action_items").toStringList(),
            keywords = metadata.optJSONArray("keywords").toStringList(),
        )
    }

    private fun JSONArray?.toStringList(): List<String> =
        if (this == null) {
            emptyList()
        } else {
            (0 until length()).mapNotNull { index -> optString(index).takeIf { it.isNotBlank() } }
        }

    private fun formatKst(value: String): String {
        return try {
            ZonedDateTime.parse(value).withZoneSameInstant(kstZone).format(displayFormatter)
        } catch (_: Exception) {
            try {
                Instant.parse(value).atZone(kstZone).format(displayFormatter)
            } catch (_: Exception) {
                value.take(16)
            }
        }
    }

    private fun buildTimeDisplay(startedAt: String, endedAt: String?): String {
        val start = formatKst(startedAt)
        val end = endedAt?.let(::formatKst)
        return if (end != null) "$start - $end" else start
    }

    private fun buildDurationDisplay(startedAt: String, endedAt: String?): String? {
        if (endedAt == null) return null
        return try {
            val duration = Duration.between(ZonedDateTime.parse(startedAt), ZonedDateTime.parse(endedAt))
            val minutes = duration.toMinutes().coerceAtLeast(0)
            when {
                minutes >= 60 -> "${minutes / 60}시간 ${minutes % 60}분"
                else -> "${minutes}분"
            }
        } catch (_: Exception) {
            null
        }
    }
}
