package com.example.facedetectionapp.data

import android.util.Base64
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.TimeUnit

data class GeminiChatMessage(val role: String, val text: String) // role: "user" | "model"

object GeminiService {

    // ★ Gemini API 키 입력 (https://aistudio.google.com/apikey)
    private const val API_KEY = "YOUR_GEMINI_API_KEY"

    // 최신 모델로 교체 가능 (gemini-2.5-pro 등)
    private const val MODEL = "gemini-2.0-flash"
    private const val BASE_URL = "https://generativelanguage.googleapis.com/v1beta/models/$MODEL:generateContent"

    private val client = OkHttpClient.Builder()
        .connectTimeout(60, TimeUnit.SECONDS)
        .readTimeout(180, TimeUnit.SECONDS)
        .writeTimeout(120, TimeUnit.SECONDS)
        .build()

    /**
     * 녹화 세션 전체 분석 — 프레임(이미지) + 오디오 → 피드백 리포트
     */
    suspend fun analyzeSession(
        frames: List<Pair<Long, ByteArray>>, // (경과ms, JPEG bytes)
        audioBytes: ByteArray?,
        durationSec: Long,
        context: String = ""                 // 추가 컨텍스트 (장소, 상황 설명 등)
    ): String = withContext(Dispatchers.IO) {
        val parts = JSONArray()

        val durationStr = "%02d:%02d".format(durationSec / 60, durationSec % 60)
        val intervalSec = if (frames.size > 1) durationSec / frames.size else 2

        val prompt = buildString {
            appendLine("다음은 ${durationStr} 동안 1인칭 시점(스마트 글라스)으로 촬영된 영상입니다.")
            appendLine("프레임은 약 ${intervalSec}초 간격으로 캡처되었고, 총 ${frames.size}장입니다.")
            if (context.isNotBlank()) appendLine("상황 컨텍스트: $context")
            appendLine()
            appendLine("아래 형식으로 한국어 분석 리포트를 작성해주세요:")
            appendLine()
            appendLine("## 📋 상황 요약")
            appendLine("어떤 상황이었는지 2~3문장으로 요약")
            appendLine()
            appendLine("## ✅ 잘한 점 (최대 3가지)")
            appendLine("각각 구체적인 타임스탬프(예: 00:30)와 함께")
            appendLine()
            appendLine("## ⚠️ 개선할 점 (최대 3가지)")
            appendLine("각각 구체적인 타임스탬프와 함께, 개선 방법도 포함")
            appendLine()
            appendLine("## 💡 놓친 기회 / 주목할 순간")
            appendLine("더 활용했으면 좋았을 순간이나 중요한 장면")
            appendLine()
            appendLine("## 🎯 다음번 실행 조언")
            appendLine("비슷한 상황에서 즉시 적용할 수 있는 구체적인 행동 3가지")
        }

        parts.put(JSONObject().put("text", prompt))

        // 프레임 추가 (타임스탬프 레이블 + 이미지)
        frames.forEach { (elapsedMs, jpeg) ->
            val sec = elapsedMs / 1000
            val label = "%02d:%02d".format(sec / 60, sec % 60)
            parts.put(JSONObject().put("text", "▶ $label"))
            parts.put(
                JSONObject().put(
                    "inline_data", JSONObject()
                        .put("mime_type", "image/jpeg")
                        .put("data", Base64.encodeToString(jpeg, Base64.NO_WRAP))
                )
            )
        }

        // 오디오 추가 (폰 마이크 녹음)
        if (audioBytes != null && audioBytes.isNotEmpty()) {
            parts.put(JSONObject().put("text", "\n[음성 녹음 파일]"))
            parts.put(
                JSONObject().put(
                    "inline_data", JSONObject()
                        .put("mime_type", "audio/aac")
                        .put("data", Base64.encodeToString(audioBytes, Base64.NO_WRAP))
                )
            )
        }

        val body = JSONObject()
            .put("contents", JSONArray().put(JSONObject().put("parts", parts)))
            .put("generationConfig", JSONObject()
                .put("maxOutputTokens", 2048)
                .put("temperature", 0.7))

        callGemini(body)
    }

    /**
     * 리포트 기반 자유 질의응답 — 프레임 재전송 없이 리포트 텍스트를 컨텍스트로 사용
     */
    suspend fun askQuestion(
        question: String,
        reportContext: String,
        history: List<GeminiChatMessage>
    ): String = withContext(Dispatchers.IO) {
        val contents = JSONArray()

        // 대화 기록 복원
        history.forEach { msg ->
            contents.put(
                JSONObject()
                    .put("role", msg.role)
                    .put("parts", JSONArray().put(JSONObject().put("text", msg.text)))
            )
        }

        // 현재 질문
        contents.put(
            JSONObject()
                .put("role", "user")
                .put("parts", JSONArray().put(JSONObject().put("text", question)))
        )

        val body = JSONObject()
            .put("system_instruction", JSONObject().put(
                "parts", JSONArray().put(JSONObject().put(
                    "text",
                    "당신은 사용자의 행동을 분석하는 AI 코치입니다.\n" +
                    "아래는 방금 세션의 분석 리포트입니다. 이를 기반으로 사용자 질문에 한국어로 친절하고 구체적으로 답변하세요.\n\n" +
                    "=== 세션 분석 리포트 ===\n$reportContext"
                ))
            ))
            .put("contents", contents)
            .put("generationConfig", JSONObject()
                .put("maxOutputTokens", 1024)
                .put("temperature", 0.7))

        callGemini(body)
    }

    private fun callGemini(body: JSONObject): String {
        val request = Request.Builder()
            .url("$BASE_URL?key=$API_KEY")
            .post(body.toString().toRequestBody("application/json".toMediaType()))
            .build()

        val response = client.newCall(request).execute()
        val responseBody = response.body?.string() ?: throw Exception("빈 응답")

        if (!response.isSuccessful) {
            val errMsg = runCatching {
                JSONObject(responseBody).getJSONObject("error").getString("message")
            }.getOrDefault(responseBody)
            throw Exception("Gemini 오류 (${response.code}): $errMsg")
        }

        return JSONObject(responseBody)
            .getJSONArray("candidates")
            .getJSONObject(0)
            .getJSONObject("content")
            .getJSONArray("parts")
            .getJSONObject(0)
            .getString("text")
    }
}
