package com.example.facedetectionapp

import android.Manifest
import android.app.Activity
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.os.Build
import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
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
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.activity.compose.BackHandler
import com.meta.wearable.dat.core.Wearables
import com.meta.wearable.dat.core.types.Permission
import com.meta.wearable.dat.core.types.PermissionStatus
import com.meta.wearable.dat.core.types.RegistrationState
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

// ★ 백엔드 서버 주소 — PC IP
internal const val SERVER_HOST      = "127.0.0.1:8000"
internal const val SERVER_URL       = "http://$SERVER_HOST"
internal const val PUBLIC_HOST      = ""  // cloudflare 쓸 때만 설정
internal const val TENANT_API_KEY   = ""  // 서버에서 발급받은 API 키

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun StreamingScreen(onNavigateBack: () -> Unit) {
    val context  = LocalContext.current
    val activity = context as? Activity
    val scope    = rememberCoroutineScope()
    val snackbar = remember { SnackbarHostState() }

    var showExitDialog by remember { mutableStateOf(false) }

    // ── 서비스 StateFlow 구독 ─────────────────────────
    val phase         by StreamingService.phase.collectAsState()
    val viewerUrl     by StreamingService.viewerUrl.collectAsState()
    val frameCount    by StreamingService.frameCount.collectAsState()
    val statusMsg     by StreamingService.statusMsg.collectAsState()
    val liveStartTime by StreamingService.liveStartTime.collectAsState()
    val viewerCount   by StreamingService.viewerCount.collectAsState()
    val isRecording   by StreamingService.isRecording.collectAsState()
    val recordingPath by StreamingService.recordingPath.collectAsState()

    // 경과 시간 (LIVE일 때만 갱신)
    var liveDurationSec by remember { mutableLongStateOf(0L) }
    LaunchedEffect(phase) {
        if (phase != StreamPhase.LIVE) { liveDurationSec = 0L; return@LaunchedEffect }
        while (phase == StreamPhase.LIVE) {
            liveDurationSec = (System.currentTimeMillis() - liveStartTime) / 1000
            delay(1_000)
        }
    }

    // 녹화 완료 스낵바
    LaunchedEffect(isRecording) {
        if (!isRecording && recordingPath.isNotEmpty()) {
            snackbar.showSnackbar("녹화 저장됨: ${recordingPath.substringAfterLast('/')}")
        }
    }

    // LIVE 중 뒤로가기 → 종료 확인
    BackHandler(enabled = phase == StreamPhase.LIVE || phase == StreamPhase.CONNECTING) {
        showExitDialog = true
    }

    // ── DAT 등록 / 권한 ──────────────────────────────
    var isRegistered       by remember { mutableStateOf(false) }
    var permissionsGranted by remember { mutableStateOf(false) }

    val datPermLauncher = rememberLauncherForActivityResult(
        Wearables.RequestPermissionContract()
    ) { result ->
        if (result.getOrDefault(PermissionStatus.Denied) != PermissionStatus.Granted) {
            scope.launch { snackbar.showSnackbar("글라스 카메라 권한이 필요합니다") }
        }
    }

    val permLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) { perms -> permissionsGranted = perms.values.all { it } }

    LaunchedEffect(Unit) {
        val perms = buildList {
            add(Manifest.permission.CAMERA)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                add(Manifest.permission.BLUETOOTH_SCAN)
                add(Manifest.permission.BLUETOOTH_CONNECT)
            }
        }
        permLauncher.launch(perms.toTypedArray())
    }

    LaunchedEffect(permissionsGranted) {
        if (!permissionsGranted || activity == null) return@LaunchedEffect
        Wearables.startRegistration(activity)
        Wearables.registrationState.collect { state ->
            when (state) {
                is RegistrationState.Registered -> {
                    if (!isRegistered) {
                        isRegistered = true
                        val check = Wearables.checkPermissionStatus(Permission.CAMERA)
                        if (check.getOrNull() != PermissionStatus.Granted) {
                            datPermLauncher.launch(Permission.CAMERA)
                        }
                    }
                }
                is RegistrationState.Unavailable ->
                    scope.launch { snackbar.showSnackbar("Meta AI 앱을 설치해주세요") }
                else -> {}
            }
        }
    }

    // ── 종료 확인 다이얼로그 ──────────────────────────
    if (showExitDialog) {
        AlertDialog(
            onDismissRequest = { showExitDialog = false },
            containerColor   = Color(0xFF1E1E1E),
            title = { Text("라이브 종료", color = Color.White, fontWeight = FontWeight.Bold) },
            text  = { Text("라이브 모드를 종료하겠습니까?\n시청자와의 연결이 끊깁니다.", color = Color.LightGray) },
            confirmButton = {
                TextButton(onClick = {
                    showExitDialog = false
                    StreamingService.stop(context)
                    onNavigateBack()
                }) { Text("종료", color = Color(0xFFE53935), fontWeight = FontWeight.Bold) }
            },
            dismissButton = {
                TextButton(onClick = { showExitDialog = false }) {
                    Text("계속하기", color = Color.Gray)
                }
            }
        )
    }

    // ── UI ────────────────────────────────────────────
    Scaffold(
        containerColor = Color(0xFF0A0A0A),
        snackbarHost   = { SnackbarHost(snackbar) },
        topBar = {
            TopAppBar(
                title = { Text("글라스 라이브", fontWeight = FontWeight.Bold, color = Color.White) },
                navigationIcon = {
                    IconButton(onClick = onNavigateBack) {
                        Icon(Icons.Filled.ArrowBack, contentDescription = "뒤로가기", tint = Color.White)
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = Color(0xFF111111))
            )
        }
    ) { inner ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(inner)
                .padding(24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(20.dp)
        ) {
            Spacer(Modifier.weight(1f))

            when (phase) {
                StreamPhase.IDLE -> {
                    Icon(Icons.Filled.Videocam, null, tint = Color(0xFFE53935), modifier = Modifier.size(80.dp))
                    Text(
                        "글라스 시점을\n링크 하나로 공유",
                        color = Color.White, fontSize = 22.sp,
                        fontWeight = FontWeight.Bold, textAlign = TextAlign.Center, lineHeight = 30.sp
                    )
                    Text("앱 설치 없이 링크 클릭 → 바로 시청", color = Color.Gray, fontSize = 14.sp)
                }

                StreamPhase.CONNECTING -> {
                    CircularProgressIndicator(color = Color(0xFFE53935), modifier = Modifier.size(64.dp), strokeWidth = 4.dp)
                    Text(statusMsg, color = Color.White, fontSize = 16.sp)
                }

                StreamPhase.LIVE -> {
                    // LIVE 배지 + 시청자 수
                    Row(
                        horizontalArrangement = Arrangement.spacedBy(10.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Surface(shape = RoundedCornerShape(6.dp), color = Color(0xFFE53935)) {
                            Row(
                                modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(6.dp)
                            ) {
                                Box(Modifier.size(8.dp).background(Color.White, CircleShape))
                                Text("LIVE", color = Color.White, fontWeight = FontWeight.Bold, fontSize = 13.sp)
                            }
                        }
                        Surface(shape = RoundedCornerShape(6.dp), color = Color(0xFF2A2A2A)) {
                            Row(
                                modifier = Modifier.padding(horizontal = 10.dp, vertical = 6.dp),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(5.dp)
                            ) {
                                Icon(Icons.Filled.Person, null, tint = Color.Gray, modifier = Modifier.size(14.dp))
                                Text("$viewerCount", color = Color.White, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
                            }
                        }
                        // 녹화 중 배지
                        if (isRecording) {
                            Surface(shape = RoundedCornerShape(6.dp), color = Color(0xFF7B1FA2)) {
                                Row(
                                    modifier = Modifier.padding(horizontal = 10.dp, vertical = 6.dp),
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.spacedBy(5.dp)
                                ) {
                                    Box(Modifier.size(7.dp).background(Color.White, CircleShape))
                                    Text("REC", color = Color.White, fontSize = 12.sp, fontWeight = FontWeight.Bold)
                                }
                            }
                        }
                    }

                    // 타이머
                    val h = liveDurationSec / 3600
                    val m = (liveDurationSec % 3600) / 60
                    val s = liveDurationSec % 60
                    Text("%02d:%02d:%02d".format(h, m, s), color = Color.White, fontSize = 40.sp, fontWeight = FontWeight.Bold)
                    Text("${frameCount}프레임 전송됨", color = Color.Gray, fontSize = 13.sp)

                    // 시청자 링크 카드
                    Surface(shape = RoundedCornerShape(12.dp), color = Color(0xFF1E1E1E), modifier = Modifier.fillMaxWidth()) {
                        Column(modifier = Modifier.padding(16.dp)) {
                            Text("시청자 링크", color = Color.Gray, fontSize = 12.sp)
                            Spacer(Modifier.height(6.dp))
                            Text(viewerUrl, color = Color.White, fontSize = 12.sp, maxLines = 2, overflow = TextOverflow.Ellipsis)
                            Spacer(Modifier.height(12.dp))
                            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                OutlinedButton(
                                    onClick = {
                                        val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                                        cm.setPrimaryClip(ClipData.newPlainText("viewer_url", viewerUrl))
                                        Toast.makeText(context, "링크 복사됨", Toast.LENGTH_SHORT).show()
                                    },
                                    modifier = Modifier.weight(1f),
                                    border = androidx.compose.foundation.BorderStroke(1.dp, Color(0xFF444444))
                                ) {
                                    Icon(Icons.Filled.ContentCopy, null, tint = Color.White, modifier = Modifier.size(16.dp))
                                    Spacer(Modifier.width(6.dp))
                                    Text("복사", color = Color.White)
                                }
                                OutlinedButton(
                                    onClick = {
                                        val shareIntent = android.content.Intent(android.content.Intent.ACTION_SEND).apply {
                                            type = "text/plain"
                                            putExtra(android.content.Intent.EXTRA_TEXT, "👓 글라스 시점 라이브 보기: $viewerUrl")
                                        }
                                        context.startActivity(android.content.Intent.createChooser(shareIntent, "링크 공유"))
                                    },
                                    modifier = Modifier.weight(1f),
                                    border = androidx.compose.foundation.BorderStroke(1.dp, Color(0xFF444444))
                                ) {
                                    Icon(Icons.Filled.Share, null, tint = Color.White, modifier = Modifier.size(16.dp))
                                    Spacer(Modifier.width(6.dp))
                                    Text("공유", color = Color.White)
                                }
                            }
                        }
                    }

                    // 녹화 버튼
                    if (!isRecording) {
                        OutlinedButton(
                            onClick = { StreamingService.startRecording(context) },
                            modifier = Modifier.fillMaxWidth(),
                            border = androidx.compose.foundation.BorderStroke(1.dp, Color(0xFF7B1FA2)),
                            shape = RoundedCornerShape(12.dp)
                        ) {
                            Icon(Icons.Filled.FiberManualRecord, null, tint = Color(0xFFCE93D8), modifier = Modifier.size(16.dp))
                            Spacer(Modifier.width(8.dp))
                            Text("녹화 시작", color = Color(0xFFCE93D8))
                        }
                    } else {
                        OutlinedButton(
                            onClick = { StreamingService.stopRecording(context) },
                            modifier = Modifier.fillMaxWidth(),
                            border = androidx.compose.foundation.BorderStroke(1.dp, Color(0xFF7B1FA2)),
                            shape = RoundedCornerShape(12.dp),
                            colors = ButtonDefaults.outlinedButtonColors(containerColor = Color(0xFF1A0A1E))
                        ) {
                            Icon(Icons.Filled.Stop, null, tint = Color(0xFFCE93D8), modifier = Modifier.size(16.dp))
                            Spacer(Modifier.width(8.dp))
                            Text("녹화 중지", color = Color(0xFFCE93D8))
                        }
                    }
                }

                StreamPhase.ERROR -> {
                    Icon(Icons.Filled.ErrorOutline, null, tint = Color(0xFFE53935), modifier = Modifier.size(56.dp))
                    Text(statusMsg, color = Color.White, fontSize = 15.sp, textAlign = TextAlign.Center)
                }
            }

            Spacer(Modifier.weight(1f))

            // ── 액션 버튼 ──────────────────────────────────
            when (phase) {
                StreamPhase.IDLE, StreamPhase.ERROR -> {
                    Button(
                        onClick = {
                            if (!isRegistered) {
                                scope.launch { snackbar.showSnackbar("Meta AI 앱과 연동이 필요합니다") }
                            } else {
                                StreamingService.start(context)
                            }
                        },
                        modifier = Modifier.fillMaxWidth().height(56.dp),
                        shape = RoundedCornerShape(16.dp),
                        colors = ButtonDefaults.buttonColors(containerColor = Color(0xFFE53935))
                    ) {
                        Icon(Icons.Filled.FiberManualRecord, null)
                        Spacer(Modifier.width(8.dp))
                        Text(
                            if (phase == StreamPhase.ERROR) "다시 시작" else "스트리밍 시작",
                            fontWeight = FontWeight.Bold, fontSize = 16.sp
                        )
                    }
                }
                StreamPhase.CONNECTING -> {
                    OutlinedButton(
                        onClick = { StreamingService.stop(context) },
                        modifier = Modifier.fillMaxWidth().height(56.dp),
                        shape = RoundedCornerShape(16.dp),
                        border = androidx.compose.foundation.BorderStroke(1.dp, Color(0xFF444444))
                    ) {
                        Text("취소", color = Color.Gray, fontSize = 16.sp)
                    }
                }
                StreamPhase.LIVE -> {
                    Button(
                        onClick = { showExitDialog = true },
                        modifier = Modifier.fillMaxWidth().height(56.dp),
                        shape = RoundedCornerShape(16.dp),
                        colors = ButtonDefaults.buttonColors(containerColor = Color(0xFF333333))
                    ) {
                        Icon(Icons.Filled.Stop, null)
                        Spacer(Modifier.width(8.dp))
                        Text("스트리밍 종료", fontWeight = FontWeight.Bold, fontSize = 16.sp)
                    }
                }
            }

            Spacer(Modifier.height(8.dp))
        }
    }
}
