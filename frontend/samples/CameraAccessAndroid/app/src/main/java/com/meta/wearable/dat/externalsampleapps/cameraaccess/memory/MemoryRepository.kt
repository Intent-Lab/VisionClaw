package com.meta.wearable.dat.externalsampleapps.cameraaccess.memory

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import com.meta.wearable.dat.externalsampleapps.cameraaccess.gemini.GeminiConfig
import java.time.Instant
import java.time.ZoneId
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import java.util.concurrent.TimeUnit
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Request
import org.json.JSONObject

class MemoryRepository {
    private val client = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .build()
    private val jsonMediaType = "application/json".toMediaType()
    private val kstZone = ZoneId.of("Asia/Seoul")
    private val displayFormatter = DateTimeFormatter.ofPattern("MM-dd HH:mm")

    fun recent(limit: Int = 30): List<MemoryItem> {
        val body = JSONObject()
            .put("limit", limit)
            .put("memory_type", "life_scene")
        return postMemories("/memory/recent", body)
    }

    fun search(query: String, topK: Int = 20): List<MemoryItem> {
        val body = JSONObject()
            .put("query", query)
            .put("top_k", topK)
        val response = postRaw("/memory/search", body)
        val items = mutableListOf<MemoryItem>()
        for (i in 0 until response.length()) {
            val wrapper = response.getJSONObject(i)
            items.add(parseMemory(wrapper.getJSONObject("memory")))
        }
        return items
    }

    fun get(memoryId: String): MemoryItem {
        val request = Request.Builder()
            .url("${GeminiConfig.jarvisApiBase.trimEnd('/')}/memory/$memoryId")
            .get()
            .addHeader("X-API-Key", GeminiConfig.jarvisApiKey)
            .build()
        client.newCall(request).execute().use { response ->
            val responseBody = response.body?.string().orEmpty()
            if (!response.isSuccessful) {
                throw IllegalStateException("HTTP ${response.code}: ${responseBody.take(160)}")
            }
            return parseMemory(JSONObject(responseBody))
        }
    }

    fun update(memory: MemoryItem): MemoryItem {
        val body = JSONObject()
            .put("captured_at", memory.capturedAt)
            .put("user_note", memory.userNote ?: JSONObject.NULL)
            .put("ai_interpretation", memory.aiInterpretation ?: JSONObject.NULL)
            .put("people_text", memory.peopleText ?: JSONObject.NULL)
        val request = Request.Builder()
            .url("${GeminiConfig.jarvisApiBase.trimEnd('/')}/memory/${memory.id}")
            .put(body.toString().toRequestBody(jsonMediaType))
            .addHeader("X-API-Key", GeminiConfig.jarvisApiKey)
            .addHeader("Content-Type", "application/json")
            .build()
        client.newCall(request).execute().use { response ->
            val responseBody = response.body?.string().orEmpty()
            if (!response.isSuccessful) {
                throw IllegalStateException("HTTP ${response.code}: ${responseBody.take(160)}")
            }
            return parseMemory(JSONObject(responseBody))
        }
    }

    fun delete(memoryId: String) {
        val request = Request.Builder()
            .url("${GeminiConfig.jarvisApiBase.trimEnd('/')}/memory/$memoryId")
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

    private fun postMemories(path: String, body: JSONObject): List<MemoryItem> {
        val response = postRaw(path, body)
        val items = mutableListOf<MemoryItem>()
        for (i in 0 until response.length()) {
            items.add(parseMemory(response.getJSONObject(i)))
        }
        return items
    }

    private fun postRaw(path: String, body: JSONObject): org.json.JSONArray {
        val request = Request.Builder()
            .url("${GeminiConfig.jarvisApiBase.trimEnd('/')}$path")
            .post(body.toString().toRequestBody(jsonMediaType))
            .addHeader("X-API-Key", GeminiConfig.jarvisApiKey)
            .addHeader("Content-Type", "application/json")
            .build()
        client.newCall(request).execute().use { response ->
            val responseBody = response.body?.string().orEmpty()
            if (!response.isSuccessful) {
                throw IllegalStateException("HTTP ${response.code}: ${responseBody.take(160)}")
            }
            return org.json.JSONArray(responseBody)
        }
    }

    private fun parseMemory(json: JSONObject): MemoryItem {
        val metadata = json.optJSONObject("metadata") ?: JSONObject()
        val capturedAt = json.optString("captured_at")
        return MemoryItem(
            id = json.optString("id"),
            capturedAt = capturedAt,
            capturedAtDisplay = formatKst(capturedAt, metadata.optString("captured_at_kst")),
            text = json.optString("text"),
            source = json.optString("source"),
            userNote = metadata.optString("user_note").ifBlank { null },
            aiInterpretation = metadata.optString("ai_interpretation").ifBlank { null },
            peopleText = metadata.optString("people_text").ifBlank { null },
            imageFilename = metadata.optString("image_filename").ifBlank { null },
            labels = metadata.optJSONArray("labels").toStringList(),
        )
    }

    fun loadImage(filename: String): Bitmap? {
        val request = Request.Builder()
            .url("${GeminiConfig.jarvisApiBase.trimEnd('/')}/memory/images/$filename")
            .get()
            .addHeader("X-API-Key", GeminiConfig.jarvisApiKey)
            .build()
        client.newCall(request).execute().use { response ->
            if (!response.isSuccessful) return null
            val bytes = response.body?.bytes() ?: return null
            return BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
        }
    }

    private fun org.json.JSONArray?.toStringList(): List<String> =
        if (this == null) {
            emptyList()
        } else {
            (0 until length()).mapNotNull { index -> optString(index).takeIf { it.isNotBlank() } }
        }

    private fun formatKst(capturedAt: String, capturedAtKst: String): String {
        val source = capturedAtKst.ifBlank { capturedAt }
        return try {
            ZonedDateTime.parse(source).withZoneSameInstant(kstZone).format(displayFormatter)
        } catch (_: Exception) {
            try {
                Instant.parse(capturedAt).atZone(kstZone).format(displayFormatter)
            } catch (_: Exception) {
                capturedAt.take(16)
            }
        }
    }
}
