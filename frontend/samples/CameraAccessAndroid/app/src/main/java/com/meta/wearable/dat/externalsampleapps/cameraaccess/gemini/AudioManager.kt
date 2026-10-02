package com.meta.wearable.dat.externalsampleapps.cameraaccess.gemini

import android.annotation.SuppressLint
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.MediaRecorder
import android.media.audiofx.AcousticEchoCanceler
import android.media.audiofx.NoiseSuppressor
import android.util.Log

class AudioManager {
    companion object {
        private const val TAG = "AudioManager"
        private const val CAPTURE_BYTES = 1280 // 40ms, 16kHz mono PCM16
    }

    @Volatile var onAudioCaptured: ((ByteArray) -> Unit)? = null
    @Volatile var onError: ((String) -> Unit)? = null

    @Volatile private var audioRecord: AudioRecord? = null
    private var audioTrack: AudioTrack? = null
    private var echoCanceler: AcousticEchoCanceler? = null
    private var noiseSuppressor: NoiseSuppressor? = null
    private var captureThread: Thread? = null
    private var playbackThread: Thread? = null
    @Volatile private var isCapturing = false
    @Volatile private var isPlaying = false
    private val playbackLock = Any()
    private val playbackQueue = PcmPlaybackQueue()
    private var writtenFrames = 0L

    val hasPendingPlayback: Boolean
        get() = synchronized(playbackLock) {
            val track = audioTrack
            playbackQueue.hasPendingAudio || (track != null &&
                (track.playbackHeadPosition.toLong() and 0xffffffffL) < writtenFrames)
        }

    @SuppressLint("MissingPermission")
    fun startCapture() {
        if (isCapturing) return
        val minimum = AudioRecord.getMinBufferSize(
            GeminiConfig.INPUT_AUDIO_SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
        )
        check(minimum > 0) { "16kHz microphone input is unavailable" }
        val bufferSize = maxOf(minimum, CAPTURE_BYTES * 4)
        try {
            val recorder = createRecorder(bufferSize)
            audioRecord = recorder
            // Full duplex needs echo cancellation; muting capture would disable barge-in.
            if (AcousticEchoCanceler.isAvailable()) {
                runCatching {
                    echoCanceler = AcousticEchoCanceler.create(recorder.audioSessionId)
                    echoCanceler?.enabled = true
                }.onFailure { Log.w(TAG, "Echo cancellation unavailable", it) }
            }
            if (NoiseSuppressor.isAvailable()) {
                runCatching {
                    noiseSuppressor = NoiseSuppressor.create(recorder.audioSessionId)
                    noiseSuppressor?.enabled = true
                }.onFailure { Log.w(TAG, "Noise suppression unavailable", it) }
            }
            startPlayback()
            recorder.startRecording()
            check(recorder.recordingState == AudioRecord.RECORDSTATE_RECORDING)
            isCapturing = true
            captureThread = Thread({
                android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_AUDIO)
                val buffer = ByteArray(CAPTURE_BYTES)
                try {
                    while (isCapturing && audioRecord === recorder) {
                        val read = recorder.read(buffer, 0, buffer.size, AudioRecord.READ_BLOCKING)
                        if (!isCapturing || audioRecord !== recorder) break
                        check(read >= 0) { "Microphone read failed ($read)" }
                        if (read > 0) onAudioCaptured?.invoke(buffer.copyOf(read))
                    }
                } catch (error: Exception) {
                    if (isCapturing && audioRecord === recorder) onError?.invoke("마이크 입력 오류: ${error.message}")
                }
            }, "live-audio-capture").also { it.start() }
        } catch (error: Exception) {
            stopCapture()
            throw error
        }
    }

    @SuppressLint("MissingPermission")
    private fun createRecorder(bufferSize: Int): AudioRecord {
        for (source in listOf(MediaRecorder.AudioSource.VOICE_COMMUNICATION, MediaRecorder.AudioSource.MIC)) {
            val recorder = AudioRecord(
                source, GeminiConfig.INPUT_AUDIO_SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, bufferSize,
            )
            if (recorder.state == AudioRecord.STATE_INITIALIZED) return recorder
            recorder.release()
        }
        error("Microphone initialization failed")
    }

    fun startPlayback() {
        synchronized(playbackLock) {
            if (audioTrack != null) return
            val minimum = AudioTrack.getMinBufferSize(
                GeminiConfig.OUTPUT_AUDIO_SAMPLE_RATE,
                AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT,
            )
            check(minimum > 0) { "24kHz audio output is unavailable" }
            val track = AudioTrack.Builder()
                .setAudioAttributes(AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
                .setAudioFormat(AudioFormat.Builder()
                    .setSampleRate(GeminiConfig.OUTPUT_AUDIO_SAMPLE_RATE)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT).build())
                .setTransferMode(AudioTrack.MODE_STREAM)
                .setBufferSizeInBytes(minimum * 2)
                .build()
            audioTrack = track
            writtenFrames = 0
            check(track.state == AudioTrack.STATE_INITIALIZED)
            track.play()
            isPlaying = true
        }
        playbackThread = Thread({
            android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_AUDIO)
            try {
                while (isPlaying) {
                    // Non-blocking writes let interruption flush both queues immediately.
                    val written = synchronized(playbackLock) {
                        val track = audioTrack
                        if (track == null) 0 else playbackQueue.writeNext { bytes, offset, size ->
                            track.write(bytes, offset, size, AudioTrack.WRITE_NON_BLOCKING).also {
                                if (it > 0) writtenFrames += it / 2
                            }
                        }
                    }
                    check(written >= 0) { "Audio output failed ($written)" }
                    if (written == 0) Thread.sleep(5)
                }
            } catch (_: InterruptedException) {
                // Session stopped.
            } catch (error: Exception) {
                if (isPlaying) onError?.invoke("음성 재생 오류: ${error.message}")
            }
        }, "live-audio-playback").also { it.start() }
    }

    fun playAudio(data: ByteArray) {
        if (data.isEmpty()) return
        val accepted = synchronized(playbackLock) {
            if (!isPlaying) return
            playbackQueue.offer(data)
        }
        if (!accepted) onError?.invoke("음성 재생이 지연되고 있습니다. 대화를 다시 시작해주세요.")
    }

    fun stopPlayback() {
        synchronized(playbackLock) {
            playbackQueue.clear()
            writtenFrames = 0
            audioTrack?.apply {
                pause()
                flush()
                play()
            }
        }
    }

    fun stopCapture() {
        isCapturing = false
        // Stop before joining: AudioRecord.read may be blocked waiting for microphone data.
        runCatching { audioRecord?.stop() }
        captureThread?.join(1000)
        captureThread = null
        echoCanceler?.release()
        echoCanceler = null
        noiseSuppressor?.release()
        noiseSuppressor = null
        audioRecord?.release()
        audioRecord = null

        isPlaying = false
        playbackThread?.interrupt()
        playbackThread?.join(1000)
        playbackThread = null
        synchronized(playbackLock) {
            playbackQueue.clear()
            writtenFrames = 0
            runCatching { audioTrack?.stop() }
            audioTrack?.release()
            audioTrack = null
        }
    }
}
