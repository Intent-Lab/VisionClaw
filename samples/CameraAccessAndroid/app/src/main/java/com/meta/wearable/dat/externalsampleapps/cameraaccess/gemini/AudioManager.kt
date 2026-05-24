package com.meta.wearable.dat.externalsampleapps.cameraaccess.gemini

import android.annotation.SuppressLint
import android.content.Context
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.MediaRecorder
import android.media.audiofx.AcousticEchoCanceler
import android.media.audiofx.AutomaticGainControl
import android.media.audiofx.NoiseSuppressor
import android.os.Build
import android.util.Log
import com.meta.wearable.dat.externalsampleapps.cameraaccess.settings.SettingsManager
import java.io.ByteArrayOutputStream

class AudioManager(private val appContext: Context) {
    companion object {
        private const val TAG = "AudioManager"
        private const val MIN_SEND_BYTES = 3200 // 100ms at 16kHz mono Int16 = 1600 frames * 2 bytes
    }

    var onAudioCaptured: ((ByteArray) -> Unit)? = null

    private var audioRecord: AudioRecord? = null
    private var audioTrack: AudioTrack? = null
    private var echoCanceler: AcousticEchoCanceler? = null
    private var noiseSuppressor: NoiseSuppressor? = null
    private var automaticGainControl: AutomaticGainControl? = null
    private var captureThread: Thread? = null

    @Volatile
    private var isCapturing = false

    @Volatile
    private var micEnabled = true

    private val accumulatedData = ByteArrayOutputStream()
    private val accumulateLock = Any()

    private var commDeviceSet = false
    private var scoStarted = false
    private var preferredBtDevice: AudioDeviceInfo? = null

    /**
     * "Mic mute" without tearing down the whole Gemini session.
     *
     * - enabled=false: we still keep AudioRecord running (so routing stays stable),
     *   but we DO NOT forward audio chunks to Gemini.
     * - when toggling, we clear any buffered audio to avoid "catch-up" sending.
     */
    fun setMicEnabled(enabled: Boolean) {
        micEnabled = enabled
        synchronized(accumulateLock) {
            accumulatedData.reset()
        }
        Log.d(TAG, "Mic enabled = $micEnabled")
    }

    fun isMicEnabled(): Boolean = micEnabled

    @SuppressLint("MissingPermission")
    fun startCapture() {
        if (isCapturing) return

        val sysAm = appContext.getSystemService(Context.AUDIO_SERVICE) as android.media.AudioManager
        val demoSpeakerMode = SettingsManager.demoSpeakerModeEnabled

        if (demoSpeakerMode) {
            sysAm.mode = android.media.AudioManager.MODE_IN_COMMUNICATION
            commDeviceSet = false
            scoStarted = false
            preferredBtDevice = null
            Log.d(TAG, "Demo speaker mode enabled -> use phone-style communication input without BT SCO")
        } else {
            // ✅ BT 마이크가 있으면 그걸 우선 사용, 없으면 폰 마이크로 폴백
            preferredBtDevice = findBluetoothInputDeviceOrNull()

            if (preferredBtDevice != null) {
                // 통화 모드로 전환 (SCO 입력 안정화에 도움)
                sysAm.mode = android.media.AudioManager.MODE_IN_COMMUNICATION

                // Android 12+ : communication device 선택 시도 (실패해도 폴백 가능)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    try {
                        commDeviceSet = sysAm.setCommunicationDevice(preferredBtDevice!!)
                        Log.d(TAG, "setCommunicationDevice(BT) = $commDeviceSet, dev=${preferredBtDevice?.productName}")
                    } catch (t: Throwable) {
                        commDeviceSet = false
                        Log.w(TAG, "setCommunicationDevice failed: ${t.message}")
                    }
                }

                // 구형/일부 기기 fallback: SCO 시작 (BT 없으면 시작하지 않음)
                try {
                    sysAm.startBluetoothSco()
                    sysAm.isBluetoothScoOn = true
                    scoStarted = true
                    Log.d(TAG, "Bluetooth SCO started")
                } catch (t: Throwable) {
                    scoStarted = false
                    Log.w(TAG, "startBluetoothSco failed: ${t.message}")
                }
            } else {
                // ✅ BT가 없으면 강제 라우팅/모드 변경 안 함 (그냥 폰 마이크)
                commDeviceSet = false
                scoStarted = false
                Log.d(TAG, "No BT mic -> fallback to phone mic")
            }
        }

        val bufferSize = AudioRecord.getMinBufferSize(
            GeminiConfig.INPUT_AUDIO_SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT
        )

        audioRecord = AudioRecord(
            MediaRecorder.AudioSource.VOICE_COMMUNICATION,
            GeminiConfig.INPUT_AUDIO_SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
            bufferSize
        )

        val preferredInputDevice = if (demoSpeakerMode) findBuiltInMicOrNull() else preferredBtDevice
        preferredInputDevice?.let { dev ->
            try {
                val ok = audioRecord?.setPreferredDevice(dev) == true
                Log.d(TAG, "AudioRecord.setPreferredDevice ok=$ok dev=${dev.productName}")
            } catch (t: Throwable) {
                Log.w(TAG, "setPreferredDevice failed: ${t.message}")
            }
        }

        val routed = audioRecord?.routedDevice
        Log.d(TAG, "AudioRecord routedDevice: type=${routed?.type} name=${routed?.productName}")

        if (demoSpeakerMode) {
            enableVoiceProcessing(audioRecord?.audioSessionId ?: 0)
        }

        audioTrack = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(
                        if (demoSpeakerMode) {
                            AudioAttributes.USAGE_MEDIA
                        } else {
                            AudioAttributes.USAGE_VOICE_COMMUNICATION
                        }
                    )
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build()
            )
            .setAudioFormat(
                AudioFormat.Builder()
                    .setSampleRate(GeminiConfig.OUTPUT_AUDIO_SAMPLE_RATE)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .build()
            )
            .setTransferMode(AudioTrack.MODE_STREAM)
            .setBufferSizeInBytes(
                AudioTrack.getMinBufferSize(
                    GeminiConfig.OUTPUT_AUDIO_SAMPLE_RATE,
                    AudioFormat.CHANNEL_OUT_MONO,
                    AudioFormat.ENCODING_PCM_16BIT
                ) * 2
            )
            .build()

        audioRecord?.startRecording()
        audioTrack?.play()
        isCapturing = true

        synchronized(accumulateLock) {
            accumulatedData.reset()
        }

        captureThread = Thread(
            {
                val buffer = ByteArray(bufferSize)
                var tapCount = 0
                while (isCapturing) {
                    val read = audioRecord?.read(buffer, 0, buffer.size) ?: break
                    if (read > 0) {
                        if (!micEnabled) {
                            // Mic muted: discard data and clear any partial buffer.
                            synchronized(accumulateLock) {
                                accumulatedData.reset()
                            }
                            continue
                        }

                        tapCount++
                        synchronized(accumulateLock) {
                            accumulatedData.write(buffer, 0, read)
                            if (accumulatedData.size() >= MIN_SEND_BYTES) {
                                val chunk = accumulatedData.toByteArray()
                                accumulatedData.reset()
                                if (tapCount <= 3) {
                                    Log.d(TAG, "Sending chunk: ${chunk.size} bytes (~${chunk.size / 32}ms)")
                                }
                                onAudioCaptured?.invoke(chunk)
                            }
                        }
                    }
                }
            },
            "audio-capture"
        ).also { it.start() }

        Log.d(TAG, "Audio capture started (16kHz mono PCM16, demoSpeakerMode=$demoSpeakerMode)")
    }

    private fun findBluetoothInputDeviceOrNull(): AudioDeviceInfo? {
        val sysAm = appContext.getSystemService(Context.AUDIO_SERVICE) as android.media.AudioManager

        // 입력 디바이스 목록에서 BT 계열 우선 탐색
        val inputs = sysAm.getDevices(android.media.AudioManager.GET_DEVICES_INPUTS)

        // 1순위: SCO (통화용)
        inputs.firstOrNull { it.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO }?.let { return it }

        // 2순위: BLE Headset (기기/OS에 따라 여기로 잡히는 경우가 있음)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            inputs.firstOrNull { it.type == AudioDeviceInfo.TYPE_BLE_HEADSET }?.let { return it }
        }

        return null
    }

    private fun findBuiltInMicOrNull(): AudioDeviceInfo? {
        val sysAm = appContext.getSystemService(Context.AUDIO_SERVICE) as android.media.AudioManager
        val inputs = sysAm.getDevices(android.media.AudioManager.GET_DEVICES_INPUTS)
        return inputs.firstOrNull { it.type == AudioDeviceInfo.TYPE_BUILTIN_MIC }
    }

    private fun findBuiltInSpeakerOrNull(): AudioDeviceInfo? {
        val sysAm = appContext.getSystemService(Context.AUDIO_SERVICE) as android.media.AudioManager
        val outputs = sysAm.getDevices(android.media.AudioManager.GET_DEVICES_OUTPUTS)
        return outputs.firstOrNull { it.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER }
    }

    private fun enableVoiceProcessing(audioSessionId: Int) {
        if (audioSessionId == 0) return

        if (AcousticEchoCanceler.isAvailable()) {
            try {
                echoCanceler = AcousticEchoCanceler.create(audioSessionId)?.apply { enabled = true }
                Log.d(TAG, "AcousticEchoCanceler enabled=${echoCanceler?.enabled}")
            } catch (t: Throwable) {
                Log.w(TAG, "AcousticEchoCanceler failed: ${t.message}")
            }
        }

        if (NoiseSuppressor.isAvailable()) {
            try {
                noiseSuppressor = NoiseSuppressor.create(audioSessionId)?.apply { enabled = true }
                Log.d(TAG, "NoiseSuppressor enabled=${noiseSuppressor?.enabled}")
            } catch (t: Throwable) {
                Log.w(TAG, "NoiseSuppressor failed: ${t.message}")
            }
        }

        if (AutomaticGainControl.isAvailable()) {
            try {
                automaticGainControl = AutomaticGainControl.create(audioSessionId)?.apply { enabled = true }
                Log.d(TAG, "AutomaticGainControl enabled=${automaticGainControl?.enabled}")
            } catch (t: Throwable) {
                Log.w(TAG, "AutomaticGainControl failed: ${t.message}")
            }
        }
    }

    private fun releaseVoiceProcessing() {
        echoCanceler?.release()
        echoCanceler = null
        noiseSuppressor?.release()
        noiseSuppressor = null
        automaticGainControl?.release()
        automaticGainControl = null
    }

    fun playAudio(data: ByteArray) {
        if (!isCapturing || data.isEmpty()) return
        audioTrack?.write(data, 0, data.size)
    }

    fun stopPlayback() {
        audioTrack?.pause()
        audioTrack?.flush()
        audioTrack?.play()
    }

    fun stopCapture() {
        if (!isCapturing) return
        isCapturing = false

        captureThread?.join(1000)
        captureThread = null

        // Flush remaining accumulated audio
        synchronized(accumulateLock) {
            if (micEnabled && accumulatedData.size() > 0) {
                val chunk = accumulatedData.toByteArray()
                accumulatedData.reset()
                onAudioCaptured?.invoke(chunk)
            } else {
                accumulatedData.reset()
            }
        }

        audioRecord?.stop()
        releaseVoiceProcessing()
        audioRecord?.release()
        audioRecord = null

        audioTrack?.stop()
        audioTrack?.release()
        audioTrack = null

        val sysAm = appContext.getSystemService(Context.AUDIO_SERVICE) as android.media.AudioManager

        if (scoStarted) {
            try {
                sysAm.stopBluetoothSco()
                sysAm.isBluetoothScoOn = false
            } catch (_: Throwable) {
            }
            scoStarted = false
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && commDeviceSet) {
            try {
                sysAm.clearCommunicationDevice()
            } catch (_: Throwable) {
            }
            commDeviceSet = false
        }

        preferredBtDevice = null

        // 필요하면 모드 원복 (기기 따라 유지해도 되지만 안전하게 NORMAL 추천)
        sysAm.mode = android.media.AudioManager.MODE_NORMAL

        Log.d(TAG, "Audio capture stopped")
    }
}
