package com.example.facedetectionapp

import android.Manifest
import android.app.Activity
import android.app.Application
import android.graphics.Bitmap
import android.media.MediaRecorder
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.*
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.example.facedetectionapp.data.GeminiChatMessage
import com.example.facedetectionapp.data.GeminiService
import com.meta.wearable.dat.camera.StreamSession
import com.meta.wearable.dat.camera.startStreamSession
import com.meta.wearable.dat.camera.types.StreamConfiguration
import com.meta.wearable.dat.camera.types.StreamSessionState
import com.meta.wearable.dat.camera.types.VideoQuality
import com.meta.wearable.dat.core.Wearables
import com.meta.wearable.dat.core.selectors.AutoDeviceSelector
import com.meta.wearable.dat.core.types.Permission
import com.meta.wearable.dat.core.types.PermissionStatus
import com.meta.wearable.dat.core.types.RegistrationState
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.io.ByteArrayOutputStream
import java.io.File

private enum class CoachingPhase {
    IDLE,       // 초기 상태
    CONNECTING, // 글라스 연결 중
    READY,      // 연결됨 — 녹화 대기
    RECORDING,  // 녹화 중
    ANALYZING,  // Gemini 분석 중
    REPORT      // 분석 완료
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CoachingScreen(onNavigateBack: () -> Unit) {
    val context = LocalContext.current
    val activity = context as? Activity
    val application = context.applicationContext as Application
    val scope = rememberCoroutineScope()
    val snackbarHostState = remember { SnackbarHostState() }

    // ── 상태 ─────────────────────────────────────
    var phase by remember { mutableStateOf(CoachingPhase.IDLE) }
    var streamSession by remember { mutableStateOf<StreamSession?>(null) }
    var latestFrame by remember { mutableStateOf<Bitmap?>(null) }
    var isRegistered by remember { mutableStateOf(false) }
    var permissionsGranted by remember { mutableStateOf(false) }
    var statusText by remember { mutableStateOf("권한 요청 중...") }
    var isScreenActive by remember { mutableStateOf(true) }

    // ── 녹화 ─────────────────────────────────────
    val recordedFrames = remember { mutableListOf<Pair<Long, ByteArray>>() }
    var frameCount by remember { mutableIntStateOf(0) }
    var recordingStartTime by remember { mutableLongStateOf(0L) }
    var recordingElapsedSec by remember { mutableLongStateOf(0L) }
    var audioFile by remember { mutableStateOf<File?>(null) }
    var mediaRecorder by remember { mutableStateOf<MediaRecorder?>(null) }
    var contextInput by remember { mutableStateOf("") } // 상황 설명 (선택)

    // ── 분석 결과 / 채팅 ──────────────────────────
    var reportText by remember { mutableStateOf("") }
    val chatHistory = remember { mutableStateListOf<GeminiChatMessage>() }
    var chatInput by remember { mutableStateOf("") }
    var isChatLoading by remember { mutableStateOf(false) }
    val chatListState = rememberLazyListState()
    val reportScrollState = rememberScrollState()

    // ── Cleanup ───────────────────────────────────
    DisposableEffect(Unit) {
        onDispose {
            isScreenActive = false
            streamSession?.close()
            mediaRecorder?.runCatching { stop(); release() }
        }
    }

    // ── 녹화 타이머 ───────────────────────────────
    LaunchedEffect(phase) {
        if (phase != CoachingPhase.RECORDING) return@LaunchedEffect
        while (phase == CoachingPhase.RECORDING) {
            delay(1000)
            recordingElapsedSec = (System.currentTimeMillis() - recordingStartTime) / 1000
        }
    }

    // ── 프레임 샘플링 (2초마다, 최대 60프레임 = 2분) ──
    LaunchedEffect(phase) {
        if (phase != CoachingPhase.RECORDING) return@LaunchedEffect
        while (phase == CoachingPhase.RECORDING && recordedFrames.size < 60) {
            latestFrame?.let { bmp ->
                val elapsed = System.currentTimeMillis() - recordingStartTime
                val scaled = scaleBitmapForGemini(bmp)
                val out = ByteArrayOutputStream()
                scaled.compress(Bitmap.CompressFormat.JPEG, 65, out)
                recordedFrames.add(Pair(elapsed, out.toByteArray()))
                frameCount = recordedFrames.size
            }
            delay(2000)
        }
    }

    // ── 채팅 스크롤 ───────────────────────────────
    LaunchedEffect(chatHistory.size) {
        if (chatHistory.isNotEmpty()) chatListState.animateScrollToItem(chatHistory.size - 1)
    }

    // ── 권한 요청 ─────────────────────────────────
    val permLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) { perms ->
        permissionsGranted = perms.values.all { it }
        statusText = if (permissionsGranted) "Meta AI 등록 중..." else "권한이 필요합니다"
    }

    val datPermLauncher = rememberLauncherForActivityResult(
        Wearables.RequestPermissionContract()
    ) { result ->
        if (result.getOrDefault(PermissionStatus.Denied) == PermissionStatus.Granted) {
            statusText = "글라스를 켜주세요..."
        } else {
            statusText = "글라스 카메라 권한 거부됨"
        }
    }

    LaunchedEffect(Unit) {
        val perms = buildList {
            add(Manifest.permission.CAMERA)
            add(Manifest.permission.RECORD_AUDIO)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                add(Manifest.permission.BLUETOOTH_SCAN)
                add(Manifest.permission.BLUETOOTH_CONNECT)
            }
        }
        permLauncher.launch(perms.toTypedArray())
    }

    // ── Meta AI 등록 ──────────────────────────────
    LaunchedEffect(permissionsGranted) {
        if (!permissionsGranted || activity == null) return@LaunchedEffect
        phase = CoachingPhase.CONNECTING
        Wearables.startRegistration(activity)
        Wearables.registrationState.collect { state ->
            if (!isScreenActive) return@collect
            when (state) {
                is RegistrationState.Registered -> {
                    if (!isRegistered) {
                        isRegistered = true
                        statusText = "카메라 권한 확인 중..."
                        val check = Wearables.checkPermissionStatus(Permission.CAMERA)
                        if (check.getOrNull() == PermissionStatus.Granted) {
                            statusText = "글라스를 켜주세요..."
                        } else {
                            datPermLauncher.launch(Permission.CAMERA)
                        }
                    }
                }
                is RegistrationState.Available -> statusText = "Meta AI 앱에서 승인해주세요"
                is RegistrationState.Registering -> statusText = "Meta AI 등록 중..."
                is RegistrationState.Unavailable -> {
                    statusText = "Meta AI 앱을 설치해주세요"
                    phase = CoachingPhase.IDLE
                }
                is RegistrationState.Unregistering -> {}
            }
        }
    }

    // ── 글라스 감지 → 자동 연결 ───────────────────
    LaunchedEffect(isRegistered) {
        if (!isRegistered) return@LaunchedEffect
        Wearables.devices.collect { devices ->
            if (!isScreenActive) return@collect
            if (devices.isNotEmpty() && phase == CoachingPhase.CONNECTING) {
                statusText = "글라스 스트리밍 연결 중..."
                try {
                    val session = Wearables.startStreamSession(
                        application, AutoDeviceSelector(),
                        StreamConfiguration(videoQuality = VideoQuality.MEDIUM, 24)
                    )
                    streamSession = session

                    var streamingReached = false
                    val stateJob = scope.launch {
                        session.state.collect { state ->
                            if (!isScreenActive) return@collect
                            when (state) {
                                StreamSessionState.STREAMING -> {
                                    streamingReached = true
                                    phase = CoachingPhase.READY
                                    statusText = "연결됨"
                                }
                                StreamSessionState.STOPPED, StreamSessionState.CLOSED -> {
                                    if (phase == CoachingPhase.READY || phase == CoachingPhase.RECORDING) {
                                        phase = CoachingPhase.CONNECTING
                                        statusText = "연결 끊김"
                                    }
                                }
                                else -> {}
                            }
                        }
                    }

                    // 15초 타임아웃
                    scope.launch {
                        delay(15_000)
                        if (!streamingReached) {
                            stateJob.cancel()
                            session.close()
                            statusText = "연결 시간 초과"
                            scope.launch { snackbarHostState.showSnackbar("글라스가 응답하지 않습니다. 상태를 확인해주세요.") }
                        }
                    }

                    // 프레임 수신
                    session.videoStream.collect { videoFrame ->
                        if (!isScreenActive) return@collect
                        val bitmap = YuvToBitmapConverter.convert(
                            videoFrame.buffer, videoFrame.width, videoFrame.height
                        )
                        if (bitmap != null) latestFrame = bitmap
                    }
                } catch (e: Exception) {
                    statusText = "연결 실패: ${e.message}"
                    phase = CoachingPhase.CONNECTING
                }
            }
        }
    }

    // ── 녹화 시작/종료 함수 ───────────────────────
    fun startRecording() {
        recordedFrames.clear()
        frameCount = 0
        recordingElapsedSec = 0
        recordingStartTime = System.currentTimeMillis()

        val file = File(context.cacheDir, "coaching_${System.currentTimeMillis()}.aac")
        audioFile = file

        @Suppress("DEPRECATION")
        val recorder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S)
            MediaRecorder(context) else MediaRecorder()
        recorder.apply {
            setAudioSource(MediaRecorder.AudioSource.MIC)
            setOutputFormat(MediaRecorder.OutputFormat.AAC_ADTS)
            setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
            setAudioSamplingRate(44100)
            setAudioEncodingBitRate(96000)
            setOutputFile(file.absolutePath)
            runCatching { prepare(); start() }
        }
        mediaRecorder = recorder
        phase = CoachingPhase.RECORDING
    }

    fun stopAndAnalyze() {
        val durationSec = recordingElapsedSec
        val frames = recordedFrames.toList()

        mediaRecorder?.runCatching { stop(); release() }
        mediaRecorder = null

        val audioBytes = audioFile?.takeIf { it.exists() && it.length() > 0 }?.readBytes()
        val ctx = contextInput.trim()

        phase = CoachingPhase.ANALYZING
        chatHistory.clear()

        scope.launch {
            try {
                val report = GeminiService.analyzeSession(frames, audioBytes, durationSec, ctx)
                reportText = report
                phase = CoachingPhase.REPORT
            } catch (e: Exception) {
                snackbarHostState.showSnackbar("분석 실패: ${e.message}")
                phase = CoachingPhase.READY
            }
        }
    }

    fun sendChat() {
        val question = chatInput.trim()
        if (question.isBlank() || isChatLoading) return
        chatInput = ""
        chatHistory.add(GeminiChatMessage("user", question))
        isChatLoading = true

        val historyForApi = chatHistory.dropLast(1)

        scope.launch {
            try {
                val answer = GeminiService.askQuestion(question, reportText, historyForApi)
                chatHistory.add(GeminiChatMessage("model", answer))
            } catch (e: Exception) {
                chatHistory.add(GeminiChatMessage("model", "오류: ${e.message}"))
            }
            isChatLoading = false
        }
    }

    // ── UI ────────────────────────────────────────
    Scaffold(
        containerColor = Color(0xFF0F0F0F),
        snackbarHost = { SnackbarHost(snackbarHostState) },
        topBar = {
            TopAppBar(
                title = { Text("AI 코칭 세션", fontWeight = FontWeight.Bold, color = Color.White) },
                navigationIcon = {
                    IconButton(onClick = onNavigateBack) {
                        Icon(Icons.Filled.ArrowBack, contentDescription = "뒤로가기", tint = Color.White)
                    }
                },
                actions = {
                    // 연결 상태 표시
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier.padding(end = 12.dp)
                    ) {
                        Box(
                            modifier = Modifier
                                .size(8.dp)
                                .background(
                                    color = when (phase) {
                                        CoachingPhase.READY, CoachingPhase.RECORDING -> Color(0xFF00E676)
                                        CoachingPhase.CONNECTING -> Color(0xFFFFC107)
                                        else -> Color(0xFF616161)
                                    },
                                    shape = CircleShape
                                )
                        )
                        Spacer(Modifier.width(6.dp))
                        Text(
                            text = when (phase) {
                                CoachingPhase.READY -> "연결됨"
                                CoachingPhase.RECORDING -> "녹화 중"
                                CoachingPhase.CONNECTING -> "연결 중"
                                CoachingPhase.ANALYZING -> "분석 중"
                                CoachingPhase.REPORT -> "완료"
                                CoachingPhase.IDLE -> "대기"
                            },
                            color = Color.Gray,
                            fontSize = 12.sp
                        )
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = Color(0xFF1A1A1A))
            )
        }
    ) { innerPadding ->
        Box(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding)
        ) {
            when (phase) {
                // ── 연결 중 ──────────────────────────────────
                CoachingPhase.IDLE, CoachingPhase.CONNECTING -> {
                    Column(
                        modifier = Modifier.fillMaxSize(),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.Center
                    ) {
                        CircularProgressIndicator(color = Color(0xFF7B2FBE), modifier = Modifier.size(56.dp))
                        Spacer(Modifier.height(24.dp))
                        Text(statusText, color = Color.White, fontSize = 16.sp)
                        Spacer(Modifier.height(8.dp))
                        Text("Meta AI 앱과 글라스가 연결되어 있어야 합니다", color = Color.Gray, fontSize = 13.sp, textAlign = TextAlign.Center, modifier = Modifier.padding(horizontal = 32.dp))
                    }
                }

                // ── 녹화 대기 ────────────────────────────────
                CoachingPhase.READY -> {
                    Column(
                        modifier = Modifier
                            .fillMaxSize()
                            .padding(24.dp),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.Center
                    ) {
                        Icon(
                            Icons.Filled.Videocam,
                            contentDescription = null,
                            tint = Color(0xFF7B2FBE),
                            modifier = Modifier.size(72.dp)
                        )
                        Spacer(Modifier.height(20.dp))
                        Text("녹화 준비 완료", color = Color.White, fontSize = 22.sp, fontWeight = FontWeight.Bold)
                        Spacer(Modifier.height(8.dp))
                        Text(
                            "글라스 카메라 + 폰 마이크로\n영상과 음성을 함께 녹화합니다",
                            color = Color.Gray,
                            fontSize = 14.sp,
                            textAlign = TextAlign.Center,
                            lineHeight = 22.sp
                        )
                        Spacer(Modifier.height(24.dp))
                        OutlinedTextField(
                            value = contextInput,
                            onValueChange = { contextInput = it },
                            placeholder = { Text("상황 설명 (선택) — 예: 영업 미팅, 발표 연습", color = Color.Gray) },
                            modifier = Modifier.fillMaxWidth(),
                            colors = OutlinedTextFieldDefaults.colors(
                                focusedBorderColor = Color(0xFF7B2FBE),
                                unfocusedBorderColor = Color(0xFF444444),
                                focusedTextColor = Color.White,
                                unfocusedTextColor = Color.White
                            ),
                            singleLine = true,
                            shape = RoundedCornerShape(12.dp)
                        )
                        Spacer(Modifier.height(32.dp))
                        Button(
                            onClick = { startRecording() },
                            modifier = Modifier.fillMaxWidth().height(56.dp),
                            shape = RoundedCornerShape(16.dp),
                            colors = ButtonDefaults.buttonColors(containerColor = Color(0xFFE53935))
                        ) {
                            Icon(Icons.Filled.FiberManualRecord, contentDescription = null, modifier = Modifier.size(20.dp))
                            Spacer(Modifier.width(8.dp))
                            Text("녹화 시작", fontWeight = FontWeight.Bold, fontSize = 16.sp)
                        }
                    }
                }

                // ── 녹화 중 ──────────────────────────────────
                CoachingPhase.RECORDING -> {
                    Column(
                        modifier = Modifier
                            .fillMaxSize()
                            .padding(24.dp),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.Center
                    ) {
                        // 녹화 인디케이터
                        Surface(
                            shape = CircleShape,
                            color = Color(0xFFE53935).copy(alpha = 0.15f),
                            modifier = Modifier.size(120.dp)
                        ) {
                            Box(contentAlignment = Alignment.Center) {
                                Icon(Icons.Filled.FiberManualRecord, contentDescription = null, tint = Color(0xFFE53935), modifier = Modifier.size(48.dp))
                            }
                        }
                        Spacer(Modifier.height(24.dp))
                        val min = recordingElapsedSec / 60
                        val sec = recordingElapsedSec % 60
                        Text(
                            "%02d:%02d".format(min, sec),
                            color = Color.White,
                            fontSize = 48.sp,
                            fontWeight = FontWeight.Bold
                        )
                        Spacer(Modifier.height(8.dp))
                        Text("캡처된 프레임: ${frameCount}장 / 60장", color = Color.Gray, fontSize = 14.sp)
                        Spacer(Modifier.height(4.dp))
                        LinearProgressIndicator(
                            progress = { frameCount / 60f },
                            modifier = Modifier.fillMaxWidth().padding(horizontal = 32.dp),
                            color = Color(0xFFE53935),
                            trackColor = Color(0xFF333333)
                        )
                        Spacer(Modifier.height(40.dp))
                        Button(
                            onClick = { stopAndAnalyze() },
                            modifier = Modifier.fillMaxWidth().height(56.dp),
                            shape = RoundedCornerShape(16.dp),
                            colors = ButtonDefaults.buttonColors(containerColor = Color(0xFF7B2FBE))
                        ) {
                            Icon(Icons.Filled.Stop, contentDescription = null, modifier = Modifier.size(20.dp))
                            Spacer(Modifier.width(8.dp))
                            Text("녹화 종료 & AI 분석", fontWeight = FontWeight.Bold, fontSize = 16.sp)
                        }
                    }
                }

                // ── 분석 중 ──────────────────────────────────
                CoachingPhase.ANALYZING -> {
                    Column(
                        modifier = Modifier.fillMaxSize(),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.Center
                    ) {
                        CircularProgressIndicator(color = Color(0xFF7B2FBE), modifier = Modifier.size(64.dp), strokeWidth = 5.dp)
                        Spacer(Modifier.height(24.dp))
                        Text("Gemini가 분석 중...", color = Color.White, fontSize = 18.sp, fontWeight = FontWeight.Medium)
                        Spacer(Modifier.height(8.dp))
                        Text("영상 ${frameCount}프레임 + 음성 분석 중입니다", color = Color.Gray, fontSize = 13.sp)
                        Spacer(Modifier.height(4.dp))
                        Text("잠시 기다려주세요 (30초~1분 소요)", color = Color.Gray, fontSize = 12.sp)
                    }
                }

                // ── 분석 완료 — 리포트 + 채팅 ────────────────
                CoachingPhase.REPORT -> {
                    Column(modifier = Modifier.fillMaxSize()) {
                        // 리포트 영역
                        Column(
                            modifier = Modifier
                                .weight(1f)
                                .verticalScroll(reportScrollState)
                                .padding(16.dp)
                        ) {
                            // 리포트 카드
                            Surface(
                                shape = RoundedCornerShape(16.dp),
                                color = Color(0xFF1E1E1E),
                                modifier = Modifier.fillMaxWidth()
                            ) {
                                Column(modifier = Modifier.padding(16.dp)) {
                                    Row(verticalAlignment = Alignment.CenterVertically) {
                                        Icon(Icons.Filled.Assessment, contentDescription = null, tint = Color(0xFF7B2FBE), modifier = Modifier.size(20.dp))
                                        Spacer(Modifier.width(8.dp))
                                        Text("AI 분석 리포트", color = Color.White, fontWeight = FontWeight.Bold, fontSize = 16.sp)
                                        Spacer(Modifier.weight(1f))
                                        val min = recordingElapsedSec / 60
                                        val sec = recordingElapsedSec % 60
                                        Text("%02d:%02d".format(min, sec), color = Color.Gray, fontSize = 12.sp)
                                    }
                                    HorizontalDivider(modifier = Modifier.padding(vertical = 12.dp), color = Color(0xFF333333))
                                    Text(reportText, color = Color(0xFFE0E0E0), fontSize = 14.sp, lineHeight = 22.sp)
                                }
                            }

                            Spacer(Modifier.height(16.dp))

                            // 채팅 기록
                            if (chatHistory.isNotEmpty()) {
                                Text("Q&A", color = Color.Gray, fontSize = 12.sp, fontWeight = FontWeight.Medium)
                                Spacer(Modifier.height(8.dp))
                                chatHistory.forEach { msg ->
                                    ChatBubble(msg)
                                    Spacer(Modifier.height(8.dp))
                                }
                            }

                            if (isChatLoading) {
                                Box(modifier = Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                                    CircularProgressIndicator(color = Color(0xFF7B2FBE), modifier = Modifier.size(24.dp), strokeWidth = 2.dp)
                                }
                            }
                        }

                        // 채팅 입력
                        Surface(color = Color(0xFF1A1A1A)) {
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .navigationBarsPadding()
                                    .padding(horizontal = 12.dp, vertical = 8.dp),
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                OutlinedTextField(
                                    value = chatInput,
                                    onValueChange = { chatInput = it },
                                    placeholder = { Text("무엇이든 물어보세요...", color = Color.Gray) },
                                    modifier = Modifier.weight(1f),
                                    colors = OutlinedTextFieldDefaults.colors(
                                        focusedBorderColor = Color(0xFF7B2FBE),
                                        unfocusedBorderColor = Color(0xFF444444),
                                        focusedTextColor = Color.White,
                                        unfocusedTextColor = Color.White
                                    ),
                                    singleLine = true,
                                    shape = RoundedCornerShape(12.dp)
                                )
                                Spacer(Modifier.width(8.dp))
                                IconButton(
                                    onClick = { sendChat() },
                                    enabled = chatInput.isNotBlank() && !isChatLoading
                                ) {
                                    Icon(
                                        Icons.Filled.Send,
                                        contentDescription = "전송",
                                        tint = if (chatInput.isNotBlank() && !isChatLoading) Color(0xFF7B2FBE) else Color.Gray
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun ChatBubble(msg: GeminiChatMessage) {
    val isUser = msg.role == "user"
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = if (isUser) Arrangement.End else Arrangement.Start
    ) {
        if (!isUser) {
            Box(
                modifier = Modifier
                    .size(28.dp)
                    .background(Color(0xFF7B2FBE), CircleShape),
                contentAlignment = Alignment.Center
            ) {
                Text("AI", color = Color.White, fontSize = 10.sp, fontWeight = FontWeight.Bold)
            }
            Spacer(Modifier.width(8.dp))
        }
        Surface(
            shape = RoundedCornerShape(
                topStart = if (isUser) 12.dp else 4.dp,
                topEnd = if (isUser) 4.dp else 12.dp,
                bottomStart = 12.dp,
                bottomEnd = 12.dp
            ),
            color = if (isUser) Color(0xFF7B2FBE) else Color(0xFF2A2A2A),
            modifier = Modifier.widthIn(max = 280.dp)
        ) {
            Text(
                text = msg.text,
                color = Color.White,
                fontSize = 14.sp,
                lineHeight = 20.sp,
                modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp)
            )
        }
    }
}

private fun scaleBitmapForGemini(bitmap: Bitmap, maxWidth: Int = 768): Bitmap {
    if (bitmap.width <= maxWidth) return bitmap
    val ratio = maxWidth.toFloat() / bitmap.width
    val newHeight = (bitmap.height * ratio).toInt()
    return Bitmap.createScaledBitmap(bitmap, maxWidth, newHeight, true)
}
