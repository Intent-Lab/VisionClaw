package com.example.facedetectionapp

import android.Manifest
import android.app.Activity
import android.app.Application
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.graphics.Bitmap
import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.speech.tts.TextToSpeech
import android.util.Log
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.*
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.app.NotificationCompat
import androidx.lifecycle.viewmodel.compose.viewModel
import com.example.facedetectionapp.data.PersonViewModel
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.face.FaceDetection
import com.google.mlkit.vision.face.FaceDetectorOptions
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

import com.meta.wearable.dat.core.Wearables
import com.meta.wearable.dat.core.selectors.AutoDeviceSelector
import com.meta.wearable.dat.camera.startStreamSession
import com.meta.wearable.dat.camera.types.StreamConfiguration
import com.meta.wearable.dat.camera.types.VideoQuality
import com.meta.wearable.dat.camera.types.StreamSessionState
import com.meta.wearable.dat.camera.StreamSession
import com.meta.wearable.dat.core.types.Permission
import com.meta.wearable.dat.core.types.PermissionStatus
import com.meta.wearable.dat.core.types.RegistrationState
import androidx.compose.material3.TabRowDefaults.tabIndicatorOffset

private enum class GlassesMode { RECOGNIZE, REGISTER }

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun GlassesAssistantScreen(
    viewModel: PersonViewModel = viewModel()
) {
    val context = LocalContext.current
    val activity = context as? Activity
    val application = context.applicationContext as Application
    val registeredPeople by viewModel.allPeople.collectAsState()
    val scope = rememberCoroutineScope()
    val snackbarHostState = remember { SnackbarHostState() }

    // --- 상태 ---
    var glassesMode by remember { mutableStateOf(GlassesMode.RECOGNIZE) }
    var isGlassesStreaming by remember { mutableStateOf(false) }
    var isConnecting by remember { mutableStateOf(false) }
    var isDatCameraGranted by remember { mutableStateOf(false) }
    var permissionsGranted by remember { mutableStateOf(false) }
    var isRegistered by remember { mutableStateOf(false) }
    var availableDevices by remember { mutableIntStateOf(0) }

    var streamSession by remember { mutableStateOf<StreamSession?>(null) }
    var latestFrame by remember { mutableStateOf<Bitmap?>(null) }
    var frameCount by remember { mutableIntStateOf(0) }

    // 화면 활성 상태 (dispose 후 콜백 차단용)
    var isScreenActive by remember { mutableStateOf(true) }

    // 인물별 마지막 알림 시각 (20초 쿨다운)
    val notificationCooldowns = remember { mutableMapOf<String, Long>() }
    // 인식 팝업 상태 (name, info)
    var recognitionPopup by remember { mutableStateOf<Pair<String, String>?>(null) }

    // 등록 모드 상태
    var showRegisterDialog by remember { mutableStateOf(false) }
    var capturedFaceBitmap by remember { mutableStateOf<Bitmap?>(null) }
    var pendingEmbedding by remember { mutableStateOf<FloatArray?>(null) }
    var registerName by remember { mutableStateOf("") }
    var registerInfo by remember { mutableStateOf("") }
    var registerError by remember { mutableStateOf("") }
    var isCapturing by remember { mutableStateOf(false) }
    var isSaving by remember { mutableStateOf(false) }

    // 디버그 로그
    var debugLog by remember { mutableStateOf("") }
    val scrollState = rememberScrollState()

    fun appendLog(msg: String) {
        val time = SimpleDateFormat("HH:mm:ss", Locale.getDefault()).format(Date())
        debugLog += "[$time] $msg\n"
        Log.d("GLASSES_DEBUG", msg)
    }

    // 로그 추가 시 자동 스크롤
    LaunchedEffect(debugLog) {
        scrollState.animateScrollTo(scrollState.maxValue)
    }

    val classifier = remember { FaceClassifier(context) }
    val detector = remember {
        FaceDetection.getClient(
            FaceDetectorOptions.Builder()
                .setPerformanceMode(FaceDetectorOptions.PERFORMANCE_MODE_FAST)
                .build()
        )
    }

    var tts by remember { mutableStateOf<TextToSpeech?>(null) }
    DisposableEffect(context) {
        val t = TextToSpeech(context) { status ->
            if (status == TextToSpeech.SUCCESS) tts?.language = Locale.KOREAN
        }
        tts = t
        onDispose { t.shutdown() }
    }

    // 진동 헬퍼
    val vibrator = remember {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            (context.getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as VibratorManager).defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            context.getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
        }
    }
    fun vibratePhone() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            vibrator.vibrate(VibrationEffect.createWaveform(longArrayOf(0, 150, 80, 150), -1))
        } else {
            @Suppress("DEPRECATION")
            vibrator.vibrate(longArrayOf(0, 150, 80, 150), -1)
        }
    }

    // 시스템 알림 채널 초기화
    LaunchedEffect(Unit) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                "face_recognition", "얼굴 인식 알림", NotificationManager.IMPORTANCE_HIGH
            ).apply { description = "글라스로 인식된 인물 정보" }
            (context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
                .createNotificationChannel(channel)
        }
    }

    fun showSystemNotification(name: String, info: String) {
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val notification = NotificationCompat.Builder(context, "face_recognition")
            .setSmallIcon(android.R.drawable.ic_menu_view)
            .setContentTitle("👤 $name 님 인식됨")
            .setContentText(info.ifBlank { "글라스 카메라에서 인식되었습니다" })
            .setStyle(NotificationCompat.BigTextStyle().bigText(info.ifBlank { "글라스 카메라에서 인식되었습니다" }))
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setAutoCancel(true)
            .build()
        nm.notify(name.hashCode(), notification)
    }

    // 팝업 자동 닫기 (5초)
    LaunchedEffect(recognitionPopup) {
        if (recognitionPopup != null) {
            delay(5_000)
            recognitionPopup = null
        }
    }

    // 통합 알림 함수 — 인물별 20초 쿨다운
    fun notifyRecognition(name: String, info: String) {
        if (!isScreenActive) return
        val now = System.currentTimeMillis()
        val lastTime = notificationCooldowns[name] ?: 0L
        if (now - lastTime < 20_000) return   // 해당 인물 20초 내 중복 무시

        notificationCooldowns[name] = now
        appendLog("🎉 인식: $name")

        // 1. 폰 진동
        vibratePhone()
        // 2. 앱 내 팝업
        recognitionPopup = Pair(name, info)
        // 3. 시스템 알림
        showSystemNotification(name, info)
        // 4. TTS (글라스 스피커)
        tts?.speak("$name 님입니다. $info", TextToSpeech.QUEUE_FLUSH, null, "briefing")
    }

    fun processImageFromGlasses(bitmap: Bitmap) {
        if (!isScreenActive || glassesMode != GlassesMode.RECOGNIZE) return
        val inputImage = InputImage.fromBitmap(bitmap, 0)
        detector.process(inputImage).addOnSuccessListener { faces ->
            if (!isScreenActive) return@addOnSuccessListener
            if (faces.isEmpty()) {
                if (frameCount % 60 == 0) appendLog("👀 얼굴 없음...")
                return@addOnSuccessListener
            }
            val face = faces[0]
            val rect = face.boundingBox
            val x = rect.left.coerceAtLeast(0)
            val y = rect.top.coerceAtLeast(0)
            val w = rect.width().coerceAtMost(bitmap.width - x)
            val h = rect.height().coerceAtMost(bitmap.height - y)
            if (w > 0 && h > 0) {
                val cropped = Bitmap.createBitmap(bitmap, x, y, w, h)
                val embedding = classifier.getFaceEmbedding(cropped)
                var bestName = "Unknown"; var bestInfo = ""; var bestDist = Float.MAX_VALUE
                for (person in registeredPeople) {
                    val minDist = person.embeddings.minOfOrNull { v -> classifier.calculateDistance(embedding, v) } ?: Float.MAX_VALUE
                    if (minDist < bestDist) { bestDist = minDist; bestName = person.name; bestInfo = person.info }
                }
                if (bestDist < 0.85f) {
                    notifyRecognition(bestName, bestInfo)
                }
            }
        }
    }

    fun captureForRegistration() {
        val frame = latestFrame ?: run {
            scope.launch { snackbarHostState.showSnackbar("스트리밍이 시작되지 않았습니다. 먼저 글라스를 연결해주세요.") }
            return
        }
        isCapturing = true
        val inputImage = InputImage.fromBitmap(frame, 0)
        detector.process(inputImage)
            .addOnSuccessListener { faces ->
                isCapturing = false
                if (faces.isEmpty()) {
                    scope.launch { snackbarHostState.showSnackbar("얼굴이 감지되지 않았습니다. 카메라 정면을 바라봐 주세요.") }
                    appendLog("❌ 얼굴 감지 실패")
                    return@addOnSuccessListener
                }
                val rect = faces[0].boundingBox
                val x = rect.left.coerceAtLeast(0)
                val y = rect.top.coerceAtLeast(0)
                val w = rect.width().coerceAtMost(frame.width - x)
                val h = rect.height().coerceAtMost(frame.height - y)
                if (w > 0 && h > 0) {
                    val cropped = Bitmap.createBitmap(frame, x, y, w, h)
                    capturedFaceBitmap = cropped
                    pendingEmbedding = classifier.getFaceEmbedding(cropped)
                    registerName = ""; registerInfo = ""; registerError = ""
                    showRegisterDialog = true
                    appendLog("✅ 얼굴 캡처 완료")
                }
            }
            .addOnFailureListener {
                isCapturing = false
                scope.launch { snackbarHostState.showSnackbar("얼굴 감지 중 오류가 발생했습니다. 다시 시도해주세요.") }
                appendLog("❌ 오류: ${it.message}")
            }
    }

    fun disconnectGlasses() {
        streamSession?.close()
        streamSession = null
        isGlassesStreaming = false
        isConnecting = false
        frameCount = 0
        appendLog("⏹️ 연결을 종료했습니다")
    }

    // 등록 다이얼로그
    if (showRegisterDialog) {
        AlertDialog(
            onDismissRequest = { if (!isSaving) showRegisterDialog = false },
            title = { Text("새 인물 등록", fontWeight = FontWeight.Bold) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    capturedFaceBitmap?.let { bmp ->
                        Image(
                            bitmap = bmp.asImageBitmap(),
                            contentDescription = "캡처된 얼굴",
                            modifier = Modifier
                                .size(120.dp)
                                .align(Alignment.CenterHorizontally)
                        )
                    }
                    OutlinedTextField(
                        value = registerName,
                        onValueChange = { registerName = it; registerError = "" },
                        label = { Text("이름 *") },
                        singleLine = true,
                        isError = registerError.isNotBlank(),
                        supportingText = if (registerError.isNotBlank()) {{ Text(registerError, color = MaterialTheme.colorScheme.error) }} else null,
                        modifier = Modifier.fillMaxWidth(),
                        enabled = !isSaving
                    )
                    OutlinedTextField(
                        value = registerInfo,
                        onValueChange = { registerInfo = it },
                        label = { Text("메모 (회사, 관계 등)") },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth(),
                        enabled = !isSaving
                    )
                }
            },
            confirmButton = {
                Button(
                    onClick = {
                        if (registerName.isBlank()) { registerError = "이름을 입력해주세요"; return@Button }
                        val emb = pendingEmbedding ?: return@Button
                        isSaving = true
                        val thumbnail = capturedFaceBitmap?.let { bmp ->
                            val scaled = Bitmap.createScaledBitmap(bmp, 96, 96, true)
                            val out = java.io.ByteArrayOutputStream()
                            scaled.compress(Bitmap.CompressFormat.JPEG, 70, out)
                            out.toByteArray()
                        }
                        viewModel.addPerson(registerName.trim(), registerInfo.trim(), listOf(emb), thumbnails = if (thumbnail != null) listOf(thumbnail) else emptyList())
                        val savedName = registerName.trim()
                        isSaving = false
                        showRegisterDialog = false
                        appendLog("✅ $savedName 님 등록 완료!")
                        scope.launch { snackbarHostState.showSnackbar("✅ $savedName 님이 등록되었습니다.") }
                    },
                    enabled = !isSaving
                ) {
                    if (isSaving) {
                        CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp, color = Color.White)
                    } else {
                        Text("등록")
                    }
                }
            },
            dismissButton = {
                TextButton(onClick = { showRegisterDialog = false }, enabled = !isSaving) { Text("취소") }
            }
        )
    }

    // 권한 요청
    val datPermissionLauncher = rememberLauncherForActivityResult(Wearables.RequestPermissionContract()) { result ->
        val status = result.getOrDefault(PermissionStatus.Denied)
        appendLog("메타 권한 결과: $status")
        if (status == PermissionStatus.Granted) {
            isDatCameraGranted = true
        } else {
            scope.launch { snackbarHostState.showSnackbar("글라스 카메라 권한이 거부되었습니다. Meta AI 앱에서 권한을 허용해주세요.") }
        }
    }
    val permissionLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { perms ->
        permissionsGranted = perms.values.all { it }
        if (!permissionsGranted) {
            scope.launch { snackbarHostState.showSnackbar("일부 권한이 거부되었습니다. 설정에서 권한을 허용해주세요.") }
        }
        appendLog("안드로이드 권한: $permissionsGranted")
    }

    LaunchedEffect(Unit) {
        val req = mutableListOf(Manifest.permission.CAMERA, Manifest.permission.RECORD_AUDIO)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S)
            req.addAll(listOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT))
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU)
            req.add(Manifest.permission.POST_NOTIFICATIONS)
        permissionLauncher.launch(req.toTypedArray())
    }

    LaunchedEffect(permissionsGranted) {
        if (permissionsGranted && activity != null) {
            appendLog("🔄 Meta AI 등록 시작...")
            Wearables.startRegistration(activity)
            Wearables.registrationState.collect { state ->
                when (state) {
                    is RegistrationState.Registered -> {
                        if (!isRegistered) {
                            isRegistered = true
                            appendLog("✅ Meta AI 등록 완료!")
                            val checkResult = Wearables.checkPermissionStatus(Permission.CAMERA)
                            if (checkResult.getOrNull() == PermissionStatus.Granted) {
                                isDatCameraGranted = true
                                appendLog("✅ 카메라 권한 확인됨")
                            } else {
                                appendLog("📋 카메라 권한 요청 중...")
                                datPermissionLauncher.launch(Permission.CAMERA)
                            }
                        }
                    }
                    is RegistrationState.Available -> {
                        isRegistered = false
                        appendLog("⚠️ 미등록 - Meta AI 앱에서 승인해주세요")
                    }
                    is RegistrationState.Registering -> appendLog("🔄 등록 진행 중...")
                    is RegistrationState.Unregistering -> { isRegistered = false; appendLog("🔄 등록 해제 중...") }
                    is RegistrationState.Unavailable -> {
                        scope.launch { snackbarHostState.showSnackbar("Meta AI 앱을 찾을 수 없습니다. 앱이 설치되어 있는지 확인해주세요.") }
                        appendLog("❌ 등록 불가 (Meta AI 앱 확인 필요)")
                    }
                }
            }
        }
    }

    // 연결된 글라스 수 모니터링
    LaunchedEffect(isRegistered) {
        if (isRegistered) {
            Wearables.devices.collect { devices ->
                availableDevices = devices.size
                if (devices.isEmpty()) appendLog("📡 연결 가능한 글라스 없음 - 글라스가 켜져 있는지 확인해주세요")
                else appendLog("🕶️ 글라스 감지됨 (${devices.size}대)")
            }
        }
    }

    DisposableEffect(Unit) {
        onDispose {
            isScreenActive = false
            streamSession?.close()
            try { if (activity != null) Wearables.startUnregistration(activity) } catch (_: Exception) {}
        }
    }

    // ============================
    // UI
    // ============================
    Scaffold(
        containerColor = Color(0xFF0F0F0F),
        snackbarHost = {
            SnackbarHost(snackbarHostState) { data ->
                Snackbar(
                    snackbarData = data,
                    containerColor = Color(0xFF323232),
                    contentColor = Color.White
                )
            }
        },
        topBar = {
            Column {
                // 상태 바
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .background(Color(0xFF1A1A1A))
                        .padding(horizontal = 16.dp, vertical = 10.dp),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    // 스트리밍 상태
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Box(
                            modifier = Modifier
                                .size(10.dp)
                                .background(
                                    when {
                                        isConnecting -> Color(0xFFFFC107)
                                        isGlassesStreaming -> Color(0xFF00E676)
                                        else -> Color(0xFF616161)
                                    },
                                    shape = RoundedCornerShape(50)
                                )
                        )
                        Spacer(Modifier.width(6.dp))
                        Text(
                            text = when {
                                isConnecting -> "연결 중..."
                                isGlassesStreaming -> "스트리밍 중 ($frameCount 프레임)"
                                else -> "대기 중"
                            },
                            color = when {
                                isConnecting -> Color(0xFFFFC107)
                                isGlassesStreaming -> Color(0xFF00E676)
                                else -> Color(0xFF9E9E9E)
                            },
                            fontSize = 13.sp
                        )
                    }
                    // 등록 상태 + 글라스 수
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(
                            if (isRegistered && availableDevices > 0) Icons.Filled.CheckCircle
                            else if (isRegistered) Icons.Filled.Warning
                            else Icons.Filled.RadioButtonUnchecked,
                            contentDescription = null,
                            tint = when {
                                isRegistered && availableDevices > 0 -> Color(0xFF69F0AE)
                                isRegistered -> Color(0xFFFFC107)
                                else -> Color(0xFF9E9E9E)
                            },
                            modifier = Modifier.size(14.dp)
                        )
                        Spacer(Modifier.width(4.dp))
                        Text(
                            text = when {
                                isRegistered && availableDevices > 0 -> "글라스 ${availableDevices}대 연결됨"
                                isRegistered -> "글라스 미감지"
                                else -> "Meta AI 미연결"
                            },
                            color = when {
                                isRegistered && availableDevices > 0 -> Color(0xFF69F0AE)
                                isRegistered -> Color(0xFFFFC107)
                                else -> Color(0xFF9E9E9E)
                            },
                            fontSize = 13.sp
                        )
                    }
                }

                // 모드 탭
                TabRow(
                    selectedTabIndex = glassesMode.ordinal,
                    containerColor = Color(0xFF1A1A1A),
                    contentColor = Color.White,
                    indicator = { tabPositions ->
                        TabRowDefaults.SecondaryIndicator(
                            modifier = Modifier.tabIndicatorOffset(tabPositions[glassesMode.ordinal]),
                            color = MaterialTheme.colorScheme.primary
                        )
                    }
                ) {
                    Tab(
                        selected = glassesMode == GlassesMode.RECOGNIZE,
                        onClick = { glassesMode = GlassesMode.RECOGNIZE },
                        text = {
                            Text(
                                "인식 모드",
                                color = if (glassesMode == GlassesMode.RECOGNIZE) Color.White else Color(0xFF9E9E9E),
                                fontWeight = if (glassesMode == GlassesMode.RECOGNIZE) FontWeight.Bold else FontWeight.Normal
                            )
                        },
                        icon = {
                            Icon(Icons.Filled.Visibility, contentDescription = null,
                                tint = if (glassesMode == GlassesMode.RECOGNIZE) MaterialTheme.colorScheme.primary else Color(0xFF9E9E9E))
                        }
                    )
                    Tab(
                        selected = glassesMode == GlassesMode.REGISTER,
                        onClick = { glassesMode = GlassesMode.REGISTER },
                        text = {
                            Text(
                                "등록 모드",
                                color = if (glassesMode == GlassesMode.REGISTER) Color.White else Color(0xFF9E9E9E),
                                fontWeight = if (glassesMode == GlassesMode.REGISTER) FontWeight.Bold else FontWeight.Normal
                            )
                        },
                        icon = {
                            Icon(Icons.Filled.PersonAdd, contentDescription = null,
                                tint = if (glassesMode == GlassesMode.REGISTER) MaterialTheme.colorScheme.primary else Color(0xFF9E9E9E))
                        }
                    )
                }
            }
        }
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            // 연결 / 연결 끊기 버튼
            if (!isGlassesStreaming && !isConnecting) {
                Button(
                    onClick = {
                        if (!isRegistered) {
                            scope.launch { snackbarHostState.showSnackbar("Meta AI 앱 등록이 필요합니다. 잠시 기다려주세요.") }
                            return@Button
                        }
                        if (!isDatCameraGranted) {
                            scope.launch { snackbarHostState.showSnackbar("글라스 카메라 권한이 없습니다. Meta AI 앱에서 권한을 허용해주세요.") }
                            return@Button
                        }
                        if (availableDevices == 0) {
                            scope.launch { snackbarHostState.showSnackbar("연결된 글라스가 없습니다. 글라스가 켜져 있고 블루투스가 연결되어 있는지 확인해주세요.") }
                            return@Button
                        }
                        isConnecting = true
                        scope.launch {
                            try {
                                appendLog("🚀 세션 생성 요청 중...")
                                val session = Wearables.startStreamSession(
                                    application, AutoDeviceSelector(),
                                    StreamConfiguration(videoQuality = VideoQuality.MEDIUM, 24)
                                )
                                streamSession = session
                                appendLog("🔄 세션 생성됨 — 글라스 응답 대기 중...")

                                // STREAMING 상태 도달 여부 추적 (실제 연결 확인)
                                var streamingReached = false

                                val stateJob = launch {
                                    session.state.collect { state ->
                                        appendLog("📶 세션 상태: $state")
                                        when (state) {
                                            StreamSessionState.STREAMING -> {
                                                streamingReached = true
                                                isConnecting = false
                                                isGlassesStreaming = true
                                                appendLog("✅ 스트리밍 시작!")
                                            }
                                            StreamSessionState.STOPPED, StreamSessionState.CLOSED -> {
                                                isConnecting = false
                                                isGlassesStreaming = false
                                                frameCount = 0
                                                if (!streamingReached) {
                                                    appendLog("❌ 연결 실패: 글라스가 응답하지 않습니다")
                                                    snackbarHostState.showSnackbar("글라스가 응답하지 않습니다. 글라스 상태를 확인해주세요.")
                                                } else {
                                                    appendLog("🔌 연결이 끊어졌습니다")
                                                    snackbarHostState.showSnackbar("글라스 연결이 끊어졌습니다.")
                                                }
                                            }
                                            StreamSessionState.STOPPING -> appendLog("⏸️ 세션 종료 중...")
                                            else -> {}
                                        }
                                    }
                                }

                                // 15초 타임아웃 — STREAMING 미도달 시 연결 실패 처리
                                launch {
                                    kotlinx.coroutines.delay(15_000)
                                    if (isConnecting && !isGlassesStreaming) {
                                        stateJob.cancel()
                                        session.close()
                                        isConnecting = false
                                        appendLog("❌ 연결 시간 초과 (15초)")
                                        snackbarHostState.showSnackbar("연결 시간이 초과되었습니다. 글라스 상태를 확인해주세요.")
                                    }
                                }

                                session.videoStream.collect { videoFrame ->
                                    frameCount++
                                    val bitmap = YuvToBitmapConverter.convert(
                                        videoFrame.buffer, videoFrame.width, videoFrame.height
                                    )
                                    if (bitmap != null) {
                                        latestFrame = bitmap
                                        processImageFromGlasses(bitmap)
                                    }
                                }
                            } catch (e: Exception) {
                                isConnecting = false
                                isGlassesStreaming = false
                                appendLog("❌ 연결 실패: ${e.message}")
                                snackbarHostState.showSnackbar("글라스에 연결할 수 없습니다. 글라스 상태를 확인해주세요.")
                            }
                        }
                    },
                    colors = ButtonDefaults.buttonColors(containerColor = Color(0xFFFF4081)),
                    modifier = Modifier.fillMaxWidth().height(56.dp),
                    shape = RoundedCornerShape(12.dp)
                ) {
                    Icon(Icons.Filled.BluetoothConnected, contentDescription = null)
                    Spacer(Modifier.width(8.dp))
                    Text("글라스 연결하기", fontSize = 16.sp, fontWeight = FontWeight.Bold)
                }
            } else if (isConnecting) {
                // 연결 중 상태 - 취소 가능
                OutlinedButton(
                    onClick = {
                        disconnectGlasses()
                        scope.launch { snackbarHostState.showSnackbar("연결을 취소했습니다.") }
                    },
                    modifier = Modifier.fillMaxWidth().height(56.dp),
                    shape = RoundedCornerShape(12.dp),
                    colors = ButtonDefaults.outlinedButtonColors(contentColor = Color(0xFFFFC107)),
                    border = androidx.compose.foundation.BorderStroke(1.dp, Color(0xFFFFC107))
                ) {
                    CircularProgressIndicator(modifier = Modifier.size(20.dp), strokeWidth = 2.dp, color = Color(0xFFFFC107))
                    Spacer(Modifier.width(10.dp))
                    Text("연결 중... (탭하여 취소)", fontSize = 15.sp, color = Color(0xFFFFC107))
                }
            } else {
                // 스트리밍 중 - 연결 끊기 버튼
                OutlinedButton(
                    onClick = {
                        disconnectGlasses()
                        scope.launch { snackbarHostState.showSnackbar("연결을 종료했습니다.") }
                    },
                    modifier = Modifier.fillMaxWidth().height(56.dp),
                    shape = RoundedCornerShape(12.dp),
                    colors = ButtonDefaults.outlinedButtonColors(contentColor = Color(0xFFFF5252)),
                    border = androidx.compose.foundation.BorderStroke(1.dp, Color(0xFFFF5252))
                ) {
                    Icon(Icons.Filled.BluetoothDisabled, contentDescription = null, tint = Color(0xFFFF5252))
                    Spacer(Modifier.width(8.dp))
                    Text("연결 끊기", fontSize = 16.sp, color = Color(0xFFFF5252), fontWeight = FontWeight.Bold)
                }
            }

            // 인식 결과 팝업 카드
            AnimatedVisibility(
                visible = recognitionPopup != null,
                enter = slideInVertically { -it } + fadeIn(),
                exit = slideOutVertically { -it } + fadeOut()
            ) {
                recognitionPopup?.let { (name, info) ->
                    Card(
                        modifier = Modifier.fillMaxWidth(),
                        shape = RoundedCornerShape(16.dp),
                        colors = CardDefaults.cardColors(containerColor = Color(0xFF0D3320)),
                        border = androidx.compose.foundation.BorderStroke(1.dp, Color(0xFF00E676))
                    ) {
                        Row(
                            modifier = Modifier.padding(16.dp),
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                                Text("✅ 인식됨", color = Color(0xFF69F0AE), fontSize = 12.sp, fontWeight = FontWeight.Bold)
                                Text(name, color = Color.White, fontSize = 22.sp, fontWeight = FontWeight.Bold)
                                if (info.isNotBlank()) {
                                    Text(info, color = Color(0xFFB0BEC5), fontSize = 13.sp, maxLines = 2)
                                }
                            }
                            IconButton(onClick = { recognitionPopup = null }) {
                                Icon(Icons.Filled.Close, contentDescription = "닫기", tint = Color(0xFF9E9E9E))
                            }
                        }
                    }
                }
            }

            // 등록 모드 전용 UI
            if (glassesMode == GlassesMode.REGISTER) {
                Card(
                    colors = CardDefaults.cardColors(containerColor = Color(0xFF1E1E1E)),
                    shape = RoundedCornerShape(12.dp),
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Column(
                        modifier = Modifier.padding(16.dp),
                        verticalArrangement = Arrangement.spacedBy(12.dp),
                        horizontalAlignment = Alignment.CenterHorizontally
                    ) {
                        Text(
                            "글라스 카메라로 얼굴을 촬영해 새 인물을 등록합니다",
                            color = Color(0xFF9E9E9E), fontSize = 13.sp
                        )
                        latestFrame?.let { bmp ->
                            Image(
                                bitmap = bmp.asImageBitmap(),
                                contentDescription = "현재 프레임",
                                modifier = Modifier.fillMaxWidth().height(180.dp)
                            )
                        } ?: Box(
                            modifier = Modifier
                                .fillMaxWidth()
                                .height(120.dp)
                                .background(Color(0xFF2A2A2A), RoundedCornerShape(8.dp)),
                            contentAlignment = Alignment.Center
                        ) {
                            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                                Icon(Icons.Filled.Videocam, null, tint = Color(0xFF424242), modifier = Modifier.size(36.dp))
                                Spacer(Modifier.height(8.dp))
                                Text("먼저 글라스를 연결해주세요", color = Color(0xFF616161), fontSize = 13.sp)
                            }
                        }

                        Button(
                            onClick = { captureForRegistration() },
                            enabled = isGlassesStreaming && !isCapturing,
                            modifier = Modifier.fillMaxWidth().height(52.dp),
                            shape = RoundedCornerShape(12.dp),
                            colors = ButtonDefaults.buttonColors(containerColor = Color(0xFF4CAF50))
                        ) {
                            if (isCapturing) {
                                CircularProgressIndicator(modifier = Modifier.size(20.dp), strokeWidth = 2.dp, color = Color.White)
                                Spacer(Modifier.width(8.dp))
                                Text("얼굴 감지 중...", fontWeight = FontWeight.Bold, fontSize = 15.sp)
                            } else {
                                Icon(Icons.Filled.CameraAlt, contentDescription = null)
                                Spacer(Modifier.width(8.dp))
                                Text(
                                    if (isGlassesStreaming) "지금 얼굴 촬영하기" else "글라스 연결 후 사용 가능",
                                    fontWeight = FontWeight.Bold, fontSize = 15.sp
                                )
                            }
                        }
                    }
                }
            }

            // 인식 모드 - 등록된 인물 없음 경고
            if (glassesMode == GlassesMode.RECOGNIZE && registeredPeople.isEmpty()) {
                Card(
                    colors = CardDefaults.cardColors(containerColor = Color(0xFF2A1A00)),
                    shape = RoundedCornerShape(12.dp),
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Row(
                        modifier = Modifier.padding(14.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Icon(Icons.Filled.Warning, null, tint = Color(0xFFFFC107), modifier = Modifier.size(20.dp))
                        Spacer(Modifier.width(10.dp))
                        Text(
                            "등록된 인물이 없습니다. 등록 모드에서 먼저 얼굴을 등록해주세요.",
                            color = Color(0xFFFFC107), fontSize = 13.sp
                        )
                    }
                }
            }

            // 로그 패널
            Card(
                colors = CardDefaults.cardColors(containerColor = Color(0xFF0A0A0A)),
                shape = RoundedCornerShape(12.dp),
                modifier = Modifier.fillMaxWidth().weight(1f)
            ) {
                if (debugLog.isBlank()) {
                    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                        Text("연결 로그가 여기에 표시됩니다", color = Color(0xFF424242), fontSize = 13.sp)
                    }
                } else {
                    Text(
                        text = debugLog,
                        color = Color(0xFF00E676),
                        fontSize = 12.sp,
                        lineHeight = 18.sp,
                        modifier = Modifier
                            .padding(12.dp)
                            .verticalScroll(scrollState)
                    )
                }
            }
        }
    }
}
