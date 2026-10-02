package com.example.facedetectionapp

import android.app.*
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.Environment
import android.os.IBinder
import com.meta.wearable.dat.camera.StreamSession
import com.meta.wearable.dat.camera.startStreamSession
import com.meta.wearable.dat.camera.types.StreamConfiguration
import com.meta.wearable.dat.camera.types.StreamSessionState
import com.meta.wearable.dat.camera.types.VideoQuality
import com.meta.wearable.dat.core.Wearables
import com.meta.wearable.dat.core.selectors.AutoDeviceSelector
import io.livekit.android.LiveKit
import io.livekit.android.room.Room
import io.livekit.android.room.track.video.BitmapFrameCapturer
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import android.media.AudioManager
import okhttp3.*
import org.json.JSONObject
import java.io.File
import java.util.concurrent.TimeUnit

enum class StreamPhase { IDLE, CONNECTING, LIVE, ERROR }

class StreamingService : Service() {

    companion object {
        // ── 상태 ─────────────────────────────────────
        val phase         = MutableStateFlow(StreamPhase.IDLE)
        val viewerUrl     = MutableStateFlow("")
        val frameCount    = MutableStateFlow(0)
        val statusMsg     = MutableStateFlow("")
        val liveStartTime = MutableStateFlow(0L)
        val viewerCount   = MutableStateFlow(0)
        val isRecording   = MutableStateFlow(false)
        val recordingPath = MutableStateFlow("")

        // ── 액션 ─────────────────────────────────────
        private const val ACTION_RECORD_START = "record_start"
        private const val ACTION_RECORD_STOP  = "record_stop"

        fun start(context: Context) {
            val intent = Intent(context, StreamingService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
                context.startForegroundService(intent)
            else
                context.startService(intent)
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, StreamingService::class.java))
        }

        fun startRecording(context: Context) {
            context.startService(Intent(context, StreamingService::class.java).apply {
                action = ACTION_RECORD_START
            })
        }

        fun stopRecording(context: Context) {
            context.startService(Intent(context, StreamingService::class.java).apply {
                action = ACTION_RECORD_STOP
            })
        }
    }

    private val serviceScope     = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var lkRoom           : Room? = null
    private var datStreamSession : StreamSession? = null
    private var scoReceiver      : BroadcastReceiver? = null
    private val recorder         = VideoRecorder()
    private var currentRoomId    = ""

    private val httpClient = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(15, TimeUnit.SECONDS)
        .build()

    private val CHANNEL_ID = "streaming_live"
    private val NOTIF_ID   = 1001

    // ── 생명주기 ──────────────────────────────────────
    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        return when (intent?.action) {
            ACTION_RECORD_START -> {
                if (phase.value == StreamPhase.LIVE) beginRecording()
                START_NOT_STICKY
            }
            ACTION_RECORD_STOP -> {
                endRecording()
                START_NOT_STICKY
            }
            else -> {
                startForeground(NOTIF_ID, buildNotification("스트리밍 준비 중..."))
                serviceScope.launch { startStreaming() }
                START_NOT_STICKY
            }
        }
    }

    override fun onDestroy() {
        endRecording()
        stopAll()
        serviceScope.cancel()
        phase.value         = StreamPhase.IDLE
        viewerUrl.value     = ""
        frameCount.value    = 0
        statusMsg.value     = ""
        liveStartTime.value = 0L
        viewerCount.value   = 0
        isRecording.value   = false
        recordingPath.value = ""
    }

    override fun onBind(intent: Intent?): IBinder? = null

    // ── 스트리밍 메인 흐름 ─────────────────────────────
    private suspend fun startStreaming() {
        try {
            phase.value     = StreamPhase.CONNECTING
            statusMsg.value = "방 생성 중..."

            // 1. 서버에서 방 생성 + LiveKit 토큰 발급
            val roomJson = withContext(Dispatchers.IO) {
                val req = Request.Builder()
                    .url("$SERVER_URL/api/rooms/create?host=$SERVER_HOST&public_host=$PUBLIC_HOST")
                    .post(okhttp3.RequestBody.create(null, ByteArray(0)))
                    .header("X-Api-Key", TENANT_API_KEY)
                    .build()
                httpClient.newCall(req).execute().use { resp ->
                    if (!resp.isSuccessful) throw Exception("서버 오류 (${resp.code})")
                    JSONObject(resp.body!!.string())
                }
            }

            val livekitUrl     = roomJson.getString("livekit_url")
            val publisherToken = roomJson.getString("publisher_token")
            currentRoomId      = roomJson.getString("room_id")
            viewerUrl.value    = roomJson.getString("viewer_url")

            // 2. LiveKit Room 연결
            statusMsg.value = "LiveKit 연결 중..."
            val room = LiveKit.create(applicationContext)
            lkRoom = room
            room.connect(livekitUrl, publisherToken)

            // 3. 비디오 캡처러 준비
            val capturer   = BitmapFrameCapturer()
            val videoTrack = room.localParticipant.createVideoTrack("glasses-cam", capturer)
            room.localParticipant.publishVideoTrack(videoTrack)
            capturer.startCapture(1280, 720, 24)

            // 4. 글라스 세션 시작
            statusMsg.value = "글라스 연결 중..."
            val datSession = Wearables.startStreamSession(
                applicationContext as android.app.Application,
                AutoDeviceSelector(),
                StreamConfiguration(videoQuality = VideoQuality.MEDIUM, 24)
            )
            datStreamSession = datSession

            // 5. 상태 감시
            var streamStarted = false
            val stateJob = serviceScope.launch {
                datSession.state.collect { state ->
                    when (state) {
                        StreamSessionState.STREAMING -> {
                            if (!streamStarted) {
                                streamStarted       = true
                                phase.value         = StreamPhase.LIVE
                                liveStartTime.value = System.currentTimeMillis()
                                statusMsg.value     = "스트리밍 중"
                                updateNotification("🔴 LIVE 스트리밍 중")
                                startGlassesMic(room)
                                startViewerCountPolling()
                            }
                        }
                        StreamSessionState.STOPPED, StreamSessionState.CLOSED -> {
                            if (phase.value == StreamPhase.LIVE) {
                                phase.value     = StreamPhase.ERROR
                                statusMsg.value = "글라스 연결 끊김"
                                endRecording()
                                stopSelf()
                            }
                        }
                        else -> {}
                    }
                }
            }

            // 연결 타임아웃 15초
            serviceScope.launch {
                delay(15_000)
                if (phase.value == StreamPhase.CONNECTING) {
                    stateJob.cancel()
                    datSession.close()
                    room.disconnect()
                    phase.value     = StreamPhase.ERROR
                    statusMsg.value = "연결 시간 초과"
                    stopSelf()
                }
            }

            // 6. 프레임 수신 → LiveKit + 녹화
            datSession.videoStream.collect { videoFrame ->
                if (phase.value != StreamPhase.LIVE) return@collect
                val bitmap = withContext(Dispatchers.Default) {
                    YuvToBitmapConverter.convert(
                        videoFrame.buffer, videoFrame.width, videoFrame.height
                    )
                } ?: return@collect

                capturer.pushBitmap(bitmap, 0)

                if (isRecording.value) {
                    withContext(Dispatchers.IO) { recorder.feedBitmap(bitmap) }
                }

                bitmap.recycle()
                frameCount.value++
            }

        } catch (e: Exception) {
            phase.value     = StreamPhase.ERROR
            statusMsg.value = "오류: ${e.message}"
            stopSelf()
        }
    }

    // ── 녹화 ─────────────────────────────────────────
    private fun beginRecording() {
        if (recorder.isStarted) return
        val dir = getExternalFilesDir(Environment.DIRECTORY_MOVIES) ?: filesDir
        dir.mkdirs()
        val path = File(dir, "glasslink_${System.currentTimeMillis()}.mp4").absolutePath
        try {
            recorder.start(path)
            isRecording.value   = true
            recordingPath.value = path
            updateNotification("🔴 LIVE · ⏺ 녹화 중")
        } catch (_: Exception) {
            isRecording.value = false
        }
    }

    private fun endRecording() {
        if (!isRecording.value) return
        isRecording.value = false
        serviceScope.launch(Dispatchers.IO) { recorder.stop() }
    }

    // ── 시청자 수 폴링 ───────────────────────────────
    private fun startViewerCountPolling() {
        val roomId = currentRoomId
        serviceScope.launch {
            while (phase.value == StreamPhase.LIVE) {
                delay(5_000)
                try {
                    withContext(Dispatchers.IO) {
                        val req = Request.Builder()
                            .url("$SERVER_URL/api/rooms/$roomId/stats")
                            .build()
                        httpClient.newCall(req).execute().use { resp ->
                            if (resp.isSuccessful) {
                                val json = JSONObject(resp.body!!.string())
                                viewerCount.value = json.optInt("viewer_count", 0)
                            }
                        }
                    }
                } catch (_: Exception) {}
            }
            viewerCount.value = 0
        }
    }

    // ── 글라스 마이크 (Bluetooth SCO) ─────────────────
    private fun startGlassesMic(room: Room) {
        val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        scoReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                val state = intent.getIntExtra(AudioManager.EXTRA_SCO_AUDIO_STATE, -1)
                if (state == AudioManager.SCO_AUDIO_STATE_CONNECTED) {
                    serviceScope.launch {
                        room.localParticipant.setMicrophoneEnabled(true)
                    }
                    unregisterReceiver(this)
                    scoReceiver = null
                }
            }
        }
        registerReceiver(scoReceiver, IntentFilter(AudioManager.ACTION_SCO_AUDIO_STATE_CHANGED))
        audioManager.startBluetoothSco()
        audioManager.isBluetoothScoOn = true
    }

    // ── 정리 ─────────────────────────────────────────
    private fun stopAll() {
        scoReceiver?.let { try { unregisterReceiver(it) } catch (_: Exception) {} }
        scoReceiver = null

        val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        audioManager.stopBluetoothSco()
        audioManager.isBluetoothScoOn = false

        datStreamSession?.close()
        datStreamSession = null

        serviceScope.launch { lkRoom?.disconnect() }
        lkRoom = null
    }

    // ── 알림 ─────────────────────────────────────────
    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID, "글라스 라이브 스트리밍", NotificationManager.IMPORTANCE_LOW
            ).apply { description = "스트리밍 진행 중 알림" }
            getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        }
    }

    private fun buildNotification(text: String): Notification {
        val pendingIntent = PendingIntent.getActivity(
            this, 0,
            packageManager.getLaunchIntentForPackage(packageName),
            PendingIntent.FLAG_IMMUTABLE
        )
        return Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("글라스 라이브")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .build()
    }

    private fun updateNotification(text: String) {
        getSystemService(NotificationManager::class.java).notify(NOTIF_ID, buildNotification(text))
    }
}
