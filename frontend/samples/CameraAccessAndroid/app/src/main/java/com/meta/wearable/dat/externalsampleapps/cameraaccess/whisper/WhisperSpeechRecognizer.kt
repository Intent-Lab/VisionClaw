package com.meta.wearable.dat.externalsampleapps.cameraaccess.whisper

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.util.Log
import androidx.core.content.ContextCompat
import com.meta.wearable.dat.externalsampleapps.cameraaccess.gemini.KoreanSpeechRecognizer
import com.meta.wearable.dat.externalsampleapps.cameraaccess.gemini.SpeechInputController
import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class WhisperSpeechRecognizer(
    context: Context,
    private val onPartialText: (String) -> Unit,
    private val onFinalText: (String) -> Unit,
    private val onErrorText: (String) -> Unit,
) : SpeechInputController {
    companion object {
        private const val TAG = "WhisperSpeechRecognizer"
        private const val SAMPLE_RATE = 16_000
        private const val MODEL_ASSET = "whisper/ggml-tiny.bin"
        private const val MODEL_FILE = "ggml-tiny.bin"
        private const val MIN_MODEL_BYTES = 20_000_000L
        private const val SILENCE_RMS = 0.010
        private const val SPEECH_RMS = 0.018
        private const val END_SILENCE_MS = 1_100L
        private const val MIN_UTTERANCE_MS = 500L
        private const val MAX_UTTERANCE_MS = 12_000L
    }

    private val appContext = context.applicationContext
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var job: Job? = null
    private var whisperContext: WhisperContext? = null
    private var warmupRecognizer: SpeechInputController? = null

    @Volatile
    private var running = false

    @Volatile
    private var suspended = false

    override fun start() {
        if (running) return
        if (
            ContextCompat.checkSelfPermission(appContext, Manifest.permission.RECORD_AUDIO) !=
                PackageManager.PERMISSION_GRANTED
        ) {
            onErrorText("마이크 권한이 없습니다.")
            return
        }
        running = true
        warmupRecognizer = KoreanSpeechRecognizer(
            context = appContext,
            onPartialText = onPartialText,
            onFinalText = onFinalText,
            onErrorText = { message -> Log.w(TAG, "Warmup Android STT error: $message") },
        ).also {
            onPartialText("Whisper 준비 중... 우선 Android STT로 듣습니다.")
            it.start()
        }
        job = scope.launch {
            runCatching {
                val model = ensureModel()
                if (!running) return@launch
                whisperContext = whisperContext ?: WhisperContext.create(model.absolutePath)
                if (!running) return@launch
                withContext(Dispatchers.Main) {
                    if (!running) return@withContext
                    warmupRecognizer?.stop()
                    warmupRecognizer = null
                    onPartialText("Whisper STT 준비 완료")
                }
                if (!running) return@launch
                captureLoop()
            }.onFailure {
                running = false
                if (it is CancellationException) {
                    Log.d(TAG, "Whisper STT cancelled")
                    return@onFailure
                }
                Log.e(TAG, "Whisper STT failed; keeping Android STT warmup active", it)
                if (warmupRecognizer == null) {
                    warmupRecognizer = KoreanSpeechRecognizer(
                        context = appContext,
                        onPartialText = onPartialText,
                        onFinalText = onFinalText,
                        onErrorText = onErrorText,
                    ).also { recognizer -> recognizer.start() }
                }
                onErrorText("Whisper STT 오류: ${it.message ?: it.javaClass.simpleName}. Android STT로 계속 듣습니다.")
            }
        }
    }

    override fun setSuspended(value: Boolean) {
        suspended = value
        warmupRecognizer?.setSuspended(value)
    }

    override fun stop() {
        running = false
        suspended = false
        job?.cancel()
        job = null
        warmupRecognizer?.stop()
        warmupRecognizer = null
        whisperContext?.release()
        whisperContext = null
    }

    private fun ensureModel(): File {
        val dir = File(appContext.filesDir, "whisper").apply { mkdirs() }
        val model = File(dir, MODEL_FILE)
        if (model.exists() && model.length() > MIN_MODEL_BYTES) return model

        onPartialText("Whisper 모델 준비 중...")
        val tmp = File(dir, "$MODEL_FILE.tmp")
        appContext.assets.open(MODEL_ASSET).use { input ->
            tmp.outputStream().use { output ->
                input.copyTo(output)
            }
        }
        if (tmp.length() < MIN_MODEL_BYTES) {
            tmp.delete()
            error("Whisper model download incomplete")
        }
        if (model.exists()) model.delete()
        check(tmp.renameTo(model)) { "Whisper model save failed" }
        return model
    }

    @SuppressLint("MissingPermission")
    private suspend fun captureLoop() {
        val minBuffer = AudioRecord.getMinBufferSize(
            SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
        )
        val bufferSize = minBuffer.coerceAtLeast(SAMPLE_RATE / 10 * 2)
        val audioRecord = AudioRecord(
            MediaRecorder.AudioSource.VOICE_RECOGNITION,
            SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
            bufferSize,
        )

        try {
            audioRecord.startRecording()
            val chunk = ByteArray(bufferSize)
            while (running) {
                if (suspended) {
                    Thread.sleep(120)
                    continue
                }
                val utterance = readUtterance(audioRecord, chunk) ?: continue
                val floats = pcm16ToFloatArray(utterance)
                onPartialText("Whisper 인식 중...")
                val text = whisperContext?.transcribe(floats, "ko").orEmpty()
                if (text.isNotBlank()) {
                    withContext(Dispatchers.Main) {
                        onFinalText(text)
                    }
                }
            }
        } finally {
            runCatching { audioRecord.stop() }
            audioRecord.release()
        }
    }

    private fun readUtterance(audioRecord: AudioRecord, chunk: ByteArray): ByteArray? {
        val output = ByteArrayOutputStream()
        var speechStarted = false
        var speechStartAt = 0L
        var lastSpeechAt = 0L

        while (running && !suspended) {
            val read = audioRecord.read(chunk, 0, chunk.size)
            if (read <= 0) continue

            val rms = rms(chunk, read)
            val now = System.currentTimeMillis()
            if (!speechStarted && rms >= SPEECH_RMS) {
                speechStarted = true
                speechStartAt = now
                lastSpeechAt = now
                output.reset()
            }

            if (!speechStarted) continue

            output.write(chunk, 0, read)
            if (rms >= SILENCE_RMS) {
                lastSpeechAt = now
            }

            val duration = now - speechStartAt
            val silentFor = now - lastSpeechAt
            if (
                (duration >= MIN_UTTERANCE_MS && silentFor >= END_SILENCE_MS) ||
                duration >= MAX_UTTERANCE_MS
            ) {
                return output.toByteArray()
            }
        }
        return null
    }

    private fun rms(data: ByteArray, length: Int): Double {
        val shorts = length / 2
        if (shorts == 0) return 0.0
        val buffer = ByteBuffer.wrap(data, 0, length).order(ByteOrder.LITTLE_ENDIAN)
        var sum = 0.0
        repeat(shorts) {
            val sample = buffer.short.toDouble() / Short.MAX_VALUE
            sum += sample * sample
        }
        return kotlin.math.sqrt(sum / shorts)
    }

    private fun pcm16ToFloatArray(data: ByteArray): FloatArray {
        val buffer = ByteBuffer.wrap(data).order(ByteOrder.LITTLE_ENDIAN)
        val result = FloatArray(data.size / 2)
        for (i in result.indices) {
            result[i] = buffer.short / 32768.0f
        }
        return result
    }
}
