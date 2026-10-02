import java.util.Properties

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.ksp)
    alias(libs.plugins.google.services)
}

val localProperties = Properties().apply {
    val file = rootProject.file("local.properties")
    if (file.exists()) {
        file.inputStream().use { load(it) }
    }
}

android {
    namespace = "com.example.facedetectionapp"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.example.facedetectionapp"
        minSdk = 29
        targetSdk = 36
        versionCode = 2
        versionName = "1.1.1"

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        buildConfigField(
            "String",
            "OPENAI_API_KEY",
            "\"${System.getenv("OPENAI_API_KEY") ?: localProperties.getProperty("openai_api_key") ?: ""}\""
        )
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }
    kotlinOptions {
        jvmTarget = "11"
        freeCompilerArgs += listOf("-opt-in=androidx.compose.material3.ExperimentalMaterial3Api")
    }
    buildFeatures {
        compose = true
        buildConfig = true
    }
}

dependencies {

    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.lifecycle.runtime.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.compose.ui)
    implementation(libs.androidx.compose.ui.graphics)
    implementation(libs.androidx.compose.ui.tooling.preview)
    implementation(libs.androidx.compose.material3)
    testImplementation(libs.junit)
    androidTestImplementation(libs.androidx.junit)
    androidTestImplementation(libs.androidx.espresso.core)
    androidTestImplementation(platform(libs.androidx.compose.bom))
    androidTestImplementation(libs.androidx.compose.ui.test.junit4)
    debugImplementation(libs.androidx.compose.ui.tooling)
    debugImplementation(libs.androidx.compose.ui.test.manifest)

    // --- 1. 카메라 (CameraX) ---
    implementation(libs.androidx.camera.core)
    implementation(libs.androidx.camera.camera2)
    implementation(libs.androidx.camera.lifecycle)
    implementation(libs.androidx.camera.view)

    // --- 2. 아이콘 (Extended Icons) ---
    implementation(libs.androidx.compose.material.icons.extended)

    // --- 3. 얼굴 탐지 (ML Kit) ---
    implementation(libs.mlkit.face.detection)

    // --- 4. 얼굴 식별 (TensorFlow Lite) ---
    implementation(libs.tensorflow.lite) // gpu-delegate-plugin에 포함되어 있음
    implementation(libs.tensorflow.lite.gpu) // <-- 이 줄을 삭제하세요.
    implementation(libs.tensorflow.lite.gpu.delegate.plugin)
    implementation(libs.kotlinx.coroutines.play.services)

    // --- 5. 로컬 DB (Room) ---
    implementation(libs.androidx.room.runtime)
    implementation(libs.androidx.room.ktx) // Kotlin Extensions
    ksp(libs.androidx.room.compiler) // Annotation Processor

    // --- 6. 데이터 변환 (Gson) ---
    // 설명: 안면 인식 데이터(FloatArray 리스트)를 DB에 문자열로 저장하기 위해 필수
    implementation(libs.gson)

    // --- 7. 화면 이동 (Navigation Compose) ---
    // 설명: [홈(리스트)] <-> [카메라(등록)] 화면을 왔다 갔다 하기 위해 필수
    implementation(libs.androidx.navigation.compose)

    implementation(platform(libs.firebase.bom))
    implementation(libs.firebase.analytics)

    // --- 8. API 통신용 (Retrofit & Gson) ---
    implementation(libs.retrofit)
    implementation(libs.retrofit.converter.gson)
    implementation(libs.okhttp.logging.interceptor)

    implementation(libs.androidx.lifecycle.runtime.compose)

    // ★ Meta Wearables DAT SDK
    implementation(libs.meta.wearables.core)
    implementation(libs.meta.wearables.camera)

    // ★ LiveKit WebRTC SDK
    implementation(libs.livekit.android)

    // WebSocket (OkHttp에 포함됨 — 별도 추가 불필요)
}
