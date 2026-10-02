package com.example.facedetectionapp.data

import com.example.facedetectionapp.BuildConfig
import com.google.gson.annotations.SerializedName
import okhttp3.OkHttpClient
import okhttp3.logging.HttpLoggingInterceptor
import retrofit2.Retrofit
import retrofit2.converter.gson.GsonConverterFactory
import retrofit2.http.Body
import retrofit2.http.Headers
import retrofit2.http.POST
import java.util.concurrent.TimeUnit

// 1. 요청 데이터 구조
data class ChatRequest(
    val model: String = "gpt-4.1-mini", // 가성비 모델
    val messages: List<Message>,
    val temperature: Double = 0.7
)

data class Message(val role: String, val content: String)

// 2. 응답 데이터 구조
data class ChatResponse(val choices: List<Choice>)
data class Choice(val message: Message)

// 3. API 인터페이스
interface OpenAIApi {
    @Headers("Content-Type: application/json")
    @POST("v1/chat/completions")
    suspend fun getSummary(@Body request: ChatRequest): ChatResponse
}

// 4. 통신 관리자 (Singleton)
object OpenAIRepository {
    private val apiKey: String
        get() = BuildConfig.OPENAI_API_KEY

    private val client = OkHttpClient.Builder()
        .addInterceptor { chain ->
            if (apiKey.isBlank()) {
                error("OpenAI API key is not configured. Set openai_api_key in local.properties or OPENAI_API_KEY.")
            }
            val request = chain.request().newBuilder()
                .addHeader("Authorization", "Bearer $apiKey")
                .build()
            chain.proceed(request)
        }
        .connectTimeout(30, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .build()

    private val api = Retrofit.Builder()
        .baseUrl("https://api.openai.com/")
        .client(client)
        .addConverterFactory(GsonConverterFactory.create())
        .build()
        .create(OpenAIApi::class.java)

    // 이 함수를 호출하면 요약해줍니다.
    suspend fun summarizeText(rawText: String): String {
        try {
            val prompt = """
                [역할]
                너는 사용자의 인맥 관리를 돕는 비서야.
                입력된 텍스트를 읽고 **핵심 주제**와 **중요 내용**을 파악해서 한국어로 요약해줘.

                [제약 사항]
                1. 전체 내용을 아우르는 핵심 주제를 포함할 것.
                2. 약속 시간, 장소, 특이사항 등 중요한 정보는 누락하지 말 것.
                3. **반드시 2~3문장 이내**로 간결하게 줄글로 작성할 것.
                4. 말투는 "~함", "~기로 함" 처럼 명사형이나 간결한 문체로 끝낼 것.

                [입력 텍스트]
                $rawText
            """.trimIndent()

            val request = ChatRequest(messages = listOf(Message("user", prompt)))
            val response = api.getSummary(request)
            return response.choices.first().message.content
        } catch (e: Exception) {
            e.printStackTrace()
            return "오류 발생: ${e.message}"
        }
    }
}
