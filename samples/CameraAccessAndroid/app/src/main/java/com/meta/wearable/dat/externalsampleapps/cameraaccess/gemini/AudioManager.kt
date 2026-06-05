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
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException

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
    private val playbackExecutor = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "audio-playback").apply { isDaemon = true }
    }
    private val playbackLock = Any()

    @Volatile
    private var isCapturing = false

    @Volatile
    private var playbackGeneration = 0

    @Volatile
    private var micEnabled = true

    private val accumulatedData = ByteArrayOutputStream()
    private val accumulateLock = Any()

    private var commDeviceSet = false
    private var scoStarted = false
    private var preferredBtDevice: AudioDeviceInfo? = null
    private var preferredBtInputDevice: AudioDeviceInfo? = null
    private var preferredBtOutputDevice: AudioDeviceInfo? = null
    private var lastInputLevelLogMs = 0L
    private var lastPlaybackLevelLogMs = 0L
    private var silentInputLevelLogs = 0
    private var fellBackToBuiltInMic = false

    private data class BluetoothAudioRoute(
        val communicationDevice: AudioDeviceInfo?,
        val inputDevice: AudioDeviceInfo?,
        val outputDevice: AudioDeviceInfo?,
    )

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
        var useBluetoothMediaOutputOnly = false

        if (demoSpeakerMode) {
            sysAm.mode = android.media.AudioManager.MODE_IN_COMMUNICATION
            commDeviceSet = false
            scoStarted = false
            preferredBtDevice = null
            preferredBtInputDevice = null
            preferredBtOutputDevice = null
            Log.d(TAG, "Demo speaker mode enabled -> use phone-style communication input without BT SCO")
        } else {
            val bluetoothRoute = findBluetoothAudioRoute(sysAm)
            preferredBtDevice = bluetoothRoute.communicationDevice
            preferredBtInputDevice = bluetoothRoute.inputDevice
            preferredBtOutputDevice = bluetoothRoute.outputDevice

            if (bluetoothRoute.outputDevice != null && isBluetoothMediaOutput(bluetoothRoute.outputDevice)) {
                useBluetoothMediaOutputOnly = true
                preferredBtInputDevice = null
                commDeviceSet = false
                scoStarted = false
                try {
                    sysAm.mode = android.media.AudioManager.MODE_NORMAL
                } catch (t: Throwable) {
                    Log.w(TAG, "MODE_NORMAL for Bluetooth media output failed: ${t.message}")
                }
                Log.d(
                    TAG,
                    "Bluetooth media output detected -> use built-in mic with media output, " +
                        "output=${describeDevice(bluetoothRoute.outputDevice)}"
                )
            } else if (bluetoothRoute.communicationDevice != null || bluetoothRoute.inputDevice != null) {
                sysAm.mode = android.media.AudioManager.MODE_IN_COMMUNICATION

                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && bluetoothRoute.communicationDevice != null) {
                    try {
                        commDeviceSet = sysAm.setCommunicationDevice(bluetoothRoute.communicationDevice)
                        Log.d(TAG, "setCommunicationDevice(BT) = $commDeviceSet, dev=${describeDevice(bluetoothRoute.communicationDevice)}")
                    } catch (t: Throwable) {
                        commDeviceSet = false
                        Log.w(TAG, "setCommunicationDevice failed: ${t.message}")
                    }
                }

                try {
                    sysAm.startBluetoothSco()
                    sysAm.isBluetoothScoOn = true
                    scoStarted = true
                    waitForBluetoothSco(sysAm)
                    Log.d(TAG, "Bluetooth SCO started")
                } catch (t: Throwable) {
                    scoStarted = false
                    Log.w(TAG, "startBluetoothSco failed: ${t.message}")
                }
            } else {
                commDeviceSet = false
                scoStarted = false
                Log.d(TAG, "No BT mic -> fallback to phone mic")
            }
            logBluetoothRoute("selected", bluetoothRoute)
        }

        val bufferSize = AudioRecord.getMinBufferSize(
            GeminiConfig.INPUT_AUDIO_SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT
        )

        val preferredInputDevice =
            if (demoSpeakerMode || useBluetoothMediaOutputOnly) findBuiltInMicOrNull() else preferredBtInputDevice
        audioRecord = buildAudioRecord(preferredInputDevice, bufferSize)

        val routed = audioRecord?.routedDevice
        Log.d(TAG, "AudioRecord routedDevice: type=${routed?.type} name=${routed?.productName}")

        if (demoSpeakerMode) {
            enableVoiceProcessing(audioRecord?.audioSessionId ?: 0)
        }

        val newAudioTrack = buildAudioTrack(
            useMediaOutput = demoSpeakerMode || useBluetoothMediaOutputOnly,
            preferredOutputDevice = if (demoSpeakerMode) null else preferredBtOutputDevice,
        )

        audioRecord?.startRecording()
        synchronized(playbackLock) {
            playbackGeneration++
            audioTrack = newAudioTrack
            try {
                newAudioTrack.play()
            } catch (t: Throwable) {
                Log.w(TAG, "AudioTrack.play failed: ${t.message}")
            }
        }
        isCapturing = true

        synchronized(accumulateLock) {
            accumulatedData.reset()
        }
        silentInputLevelLogs = 0
        fellBackToBuiltInMic = false

        captureThread = Thread(
            {
                val buffer = ByteArray(bufferSize)
                var tapCount = 0
                while (isCapturing) {
                    val read = audioRecord?.read(buffer, 0, buffer.size) ?: break
                    if (read > 0) {
                        logInputLevelIfNeeded(buffer, read)

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

        Log.d(
            TAG,
            "Audio capture started (16kHz mono PCM16, demoSpeakerMode=$demoSpeakerMode, " +
                "useBluetoothMediaOutputOnly=$useBluetoothMediaOutputOnly)"
        )
    }

    private fun logInputLevelIfNeeded(buffer: ByteArray, byteCount: Int) {
        val now = System.currentTimeMillis()
        if (now - lastInputLevelLogMs < 1000) return
        lastInputLevelLogMs = now

        var sumSquares = 0.0
        var peak = 0
        var i = 0
        while (i + 1 < byteCount) {
            val sample = ((buffer[i + 1].toInt() shl 8) or (buffer[i].toInt() and 0xff)).toShort().toInt()
            val abs = kotlin.math.abs(sample)
            if (abs > peak) peak = abs
            sumSquares += sample.toDouble() * sample.toDouble()
            i += 2
        }
        val samples = byteCount / 2
        if (samples == 0) return

        val rms = kotlin.math.sqrt(sumSquares / samples)
        Log.d(
            TAG,
            "Input level rms=${rms.toInt()} peak=$peak device=${describeDevice(audioRecord?.routedDevice)}"
        )

        if (preferredBtInputDevice != null && !fellBackToBuiltInMic && rms < 1.0 && peak == 0) {
            silentInputLevelLogs++
            if (silentInputLevelLogs >= 3) {
                switchToBuiltInMicAfterSilentBluetooth()
            }
        } else {
            silentInputLevelLogs = 0
        }
    }

    private fun switchToBuiltInMicAfterSilentBluetooth() {
        val builtInMic = findBuiltInMicOrNull()
        if (builtInMic == null) {
            Log.w(TAG, "Bluetooth input is silent, but no built-in mic fallback was found")
            return
        }

        try {
            leaveBluetoothCommunicationRoute()
            val ok = rebuildAudioRecord(builtInMic)
            fellBackToBuiltInMic = true
            silentInputLevelLogs = 0
            Log.w(
                TAG,
                "Bluetooth input stayed silent; rebuilt capture for built-in mic " +
                    "preferredOk=$ok dev=${describeDevice(builtInMic)} routed=${describeDevice(audioRecord?.routedDevice)}"
            )
            if (ok) {
                switchPlaybackToMediaBluetoothAfterMicFallback()
            }
        } catch (t: Throwable) {
            Log.w(TAG, "Built-in mic fallback failed: ${t.message}")
        }
    }

    private fun switchPlaybackToMediaBluetoothAfterMicFallback() {
        leaveBluetoothCommunicationRoute()

        try {
            Thread.sleep(150)
            val mediaOutput = findBluetoothMediaOutputDeviceOrNull()
            preferredBtOutputDevice = mediaOutput ?: preferredBtOutputDevice

            val newTrack = buildAudioTrack(
                useMediaOutput = true,
                preferredOutputDevice = preferredBtOutputDevice,
            )

            synchronized(playbackLock) {
                playbackGeneration++
                val oldTrack = audioTrack
                audioTrack = newTrack
                try {
                    newTrack.play()
                } catch (t: Throwable) {
                    Log.w(TAG, "Fallback AudioTrack.play failed: ${t.message}")
                }
                try {
                    oldTrack?.stop()
                } catch (_: Throwable) {
                }
                try {
                    oldTrack?.release()
                } catch (_: Throwable) {
                }
            }
            Log.w(TAG, "Switched playback to media Bluetooth output dev=${describeDevice(preferredBtOutputDevice)}")
        } catch (t: Throwable) {
            Log.w(TAG, "Media Bluetooth playback fallback failed: ${t.message}")
        }
    }

    private fun leaveBluetoothCommunicationRoute() {
        val sysAm = appContext.getSystemService(Context.AUDIO_SERVICE) as android.media.AudioManager

        try {
            if (scoStarted) {
                sysAm.stopBluetoothSco()
                sysAm.isBluetoothScoOn = false
                scoStarted = false
            }
        } catch (t: Throwable) {
            Log.w(TAG, "stopBluetoothSco during fallback failed: ${t.message}")
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && commDeviceSet) {
            try {
                sysAm.clearCommunicationDevice()
                commDeviceSet = false
            } catch (t: Throwable) {
                Log.w(TAG, "clearCommunicationDevice during fallback failed: ${t.message}")
            }
        }

        try {
            sysAm.mode = android.media.AudioManager.MODE_NORMAL
        } catch (t: Throwable) {
            Log.w(TAG, "MODE_NORMAL during fallback failed: ${t.message}")
        }
    }

    private fun buildAudioRecord(
        preferredInputDevice: AudioDeviceInfo?,
        bufferSize: Int,
    ): AudioRecord {
        val record = AudioRecord(
            MediaRecorder.AudioSource.VOICE_COMMUNICATION,
            GeminiConfig.INPUT_AUDIO_SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
            bufferSize
        )

        preferredInputDevice?.let { dev ->
            try {
                val ok = record.setPreferredDevice(dev)
                Log.d(TAG, "AudioRecord.setPreferredDevice ok=$ok dev=${describeDevice(dev)}")
            } catch (t: Throwable) {
                Log.w(TAG, "setPreferredDevice failed: ${t.message}")
            }
        }

        return record
    }

    private fun rebuildAudioRecord(preferredInputDevice: AudioDeviceInfo): Boolean {
        val bufferSize = AudioRecord.getMinBufferSize(
            GeminiConfig.INPUT_AUDIO_SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT
        )

        val oldRecord = audioRecord
        audioRecord = null
        try {
            oldRecord?.stop()
        } catch (_: Throwable) {
        }
        try {
            oldRecord?.release()
        } catch (_: Throwable) {
        }

        val newRecord = buildAudioRecord(preferredInputDevice, bufferSize)
        audioRecord = newRecord
        newRecord.startRecording()

        synchronized(accumulateLock) {
            accumulatedData.reset()
        }

        return newRecord.preferredDevice?.id == preferredInputDevice.id
    }

    private fun buildAudioTrack(
        useMediaOutput: Boolean,
        preferredOutputDevice: AudioDeviceInfo?,
    ): AudioTrack {
        val track = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(
                        if (useMediaOutput) {
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

        preferredOutputDevice?.let { dev ->
            try {
                val ok = track.setPreferredDevice(dev)
                Log.d(TAG, "AudioTrack.setPreferredDevice ok=$ok dev=${describeDevice(dev)} media=$useMediaOutput")
            } catch (t: Throwable) {
                Log.w(TAG, "AudioTrack.setPreferredDevice failed: ${t.message}")
            }
        }

        return track
    }

    private fun waitForBluetoothSco(sysAm: android.media.AudioManager) {
        repeat(12) {
            if (sysAm.isBluetoothScoOn) return
            Thread.sleep(100)
        }
    }

    private fun findBluetoothAudioRoute(sysAm: android.media.AudioManager): BluetoothAudioRoute {
        val inputs = sysAm.getDevices(android.media.AudioManager.GET_DEVICES_INPUTS)
        val outputs = sysAm.getDevices(android.media.AudioManager.GET_DEVICES_OUTPUTS)

        val communicationDevice =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                sysAm.availableCommunicationDevices.firstOrNull { isBluetoothDevice(it) }
            } else {
                null
            }
        val inputDevice =
            inputs.firstOrNull { it.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO }
                ?: inputs.firstOrNull { isBluetoothDevice(it) }
                ?: communicationDevice?.takeIf { it.isSource }
        val outputDevice =
            outputs.firstOrNull { it.type == AudioDeviceInfo.TYPE_BLUETOOTH_A2DP }
                ?: outputs.firstOrNull {
                    Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
                        (it.type == AudioDeviceInfo.TYPE_BLE_HEADSET ||
                            it.type == AudioDeviceInfo.TYPE_BLE_SPEAKER)
                }
                ?: outputs.firstOrNull { it.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO }
                ?: communicationDevice?.takeIf { it.isSink }

        logAudioDevices(sysAm, inputs, outputs)

        return BluetoothAudioRoute(
            communicationDevice = communicationDevice,
            inputDevice = inputDevice,
            outputDevice = outputDevice,
        )
    }

    private fun isBluetoothDevice(device: AudioDeviceInfo): Boolean {
        return when (device.type) {
            AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
            AudioDeviceInfo.TYPE_BLUETOOTH_A2DP -> true
            else ->
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
                    (device.type == AudioDeviceInfo.TYPE_BLE_HEADSET ||
                        device.type == AudioDeviceInfo.TYPE_BLE_SPEAKER)
        }
    }

    private fun isBluetoothMediaOutput(device: AudioDeviceInfo): Boolean {
        return when (device.type) {
            AudioDeviceInfo.TYPE_BLUETOOTH_A2DP -> true
            else ->
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
                    (device.type == AudioDeviceInfo.TYPE_BLE_HEADSET ||
                        device.type == AudioDeviceInfo.TYPE_BLE_SPEAKER)
        }
    }

    private fun logAudioDevices(
        sysAm: android.media.AudioManager,
        inputs: Array<AudioDeviceInfo>,
        outputs: Array<AudioDeviceInfo>,
    ) {
        Log.d(TAG, "Audio inputs: ${inputs.joinToString { describeDevice(it) }}")
        Log.d(TAG, "Audio outputs: ${outputs.joinToString { describeDevice(it) }}")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            Log.d(
                TAG,
                "Communication devices: ${sysAm.availableCommunicationDevices.joinToString { describeDevice(it) }}"
            )
        }
    }

    private fun logBluetoothRoute(label: String, route: BluetoothAudioRoute) {
        Log.d(
            TAG,
            "Bluetooth route $label: communication=${describeDevice(route.communicationDevice)}, " +
                "input=${describeDevice(route.inputDevice)}, output=${describeDevice(route.outputDevice)}"
        )
    }

    private fun describeDevice(device: AudioDeviceInfo?): String {
        return device?.let {
            "type=${it.type}, name=${it.productName}, source=${it.isSource}, sink=${it.isSink}"
        } ?: "none"
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

    private fun findBluetoothMediaOutputDeviceOrNull(): AudioDeviceInfo? {
        val sysAm = appContext.getSystemService(Context.AUDIO_SERVICE) as android.media.AudioManager
        val outputs = sysAm.getDevices(android.media.AudioManager.GET_DEVICES_OUTPUTS)
        return outputs.firstOrNull { it.type == AudioDeviceInfo.TYPE_BLUETOOTH_A2DP }
            ?: outputs.firstOrNull {
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
                    (it.type == AudioDeviceInfo.TYPE_BLE_HEADSET ||
                        it.type == AudioDeviceInfo.TYPE_BLE_SPEAKER)
            }
            ?: outputs.firstOrNull { it.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO }
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
        val generation = playbackGeneration
        val chunk = data.copyOf()
        try {
            playbackExecutor.execute {
                if (!isCapturing || generation != playbackGeneration) return@execute
                synchronized(playbackLock) {
                    if (!isCapturing || generation != playbackGeneration) return@synchronized
                    val track = audioTrack ?: return@synchronized
                    try {
                        ensurePreferredPlaybackDevice(track)
                        val written = track.write(chunk, 0, chunk.size)
                        if (written < 0) {
                            Log.w(TAG, "AudioTrack.write failed: $written")
                        } else {
                            logPlaybackLevelIfNeeded(track, chunk, written)
                        }
                    } catch (t: Throwable) {
                        Log.w(TAG, "AudioTrack.write threw: ${t.message}")
                    }
                }
            }
        } catch (t: RejectedExecutionException) {
            Log.w(TAG, "Playback executor rejected audio: ${t.message}")
        }
    }

    private fun ensurePreferredPlaybackDevice(track: AudioTrack) {
        val routed = track.routedDevice
        if (routed != null && isBluetoothMediaOutput(routed)) return

        val mediaOutput = findBluetoothMediaOutputDeviceOrNull() ?: preferredBtOutputDevice ?: return
        preferredBtOutputDevice = mediaOutput

        try {
            val ok = track.setPreferredDevice(mediaOutput)
            Log.w(
                TAG,
                "Reassert playback Bluetooth output ok=$ok dev=${describeDevice(mediaOutput)} " +
                    "previous=${describeDevice(routed)}"
            )
        } catch (t: Throwable) {
            Log.w(TAG, "Reassert playback Bluetooth output threw: ${t.message}")
        }
    }

    private fun logPlaybackLevelIfNeeded(track: AudioTrack, buffer: ByteArray, byteCount: Int) {
        val now = System.currentTimeMillis()
        if (now - lastPlaybackLevelLogMs < 1000) return
        lastPlaybackLevelLogMs = now

        val level = computePcmLevel(buffer, byteCount)
        Log.d(
            TAG,
            "Playback write bytes=$byteCount rms=${level.first} peak=${level.second} device=${describeDevice(track.routedDevice)}"
        )
    }

    private fun computePcmLevel(buffer: ByteArray, byteCount: Int): Pair<Int, Int> {
        var sumSquares = 0.0
        var peak = 0
        var i = 0
        while (i + 1 < byteCount) {
            val sample = ((buffer[i + 1].toInt() shl 8) or (buffer[i].toInt() and 0xff)).toShort().toInt()
            val abs = kotlin.math.abs(sample)
            if (abs > peak) peak = abs
            sumSquares += sample.toDouble() * sample.toDouble()
            i += 2
        }
        val samples = byteCount / 2
        if (samples == 0) return 0 to 0
        return kotlin.math.sqrt(sumSquares / samples).toInt() to peak
    }

    fun stopPlayback() {
        val generation = playbackGeneration
        try {
            playbackExecutor.execute {
                synchronized(playbackLock) {
                    if (generation != playbackGeneration) return@synchronized
                    val track = audioTrack ?: return@synchronized
                    try {
                        track.pause()
                        track.flush()
                        track.play()
                    } catch (t: Throwable) {
                        Log.w(TAG, "stopPlayback failed: ${t.message}")
                    }
                }
            }
        } catch (t: RejectedExecutionException) {
            Log.w(TAG, "Playback executor rejected stopPlayback: ${t.message}")
        }
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

        synchronized(playbackLock) {
            playbackGeneration++
            val track = audioTrack
            audioTrack = null
            try {
                track?.stop()
            } catch (t: Throwable) {
                Log.w(TAG, "AudioTrack.stop failed: ${t.message}")
            }
            try {
                track?.release()
            } catch (t: Throwable) {
                Log.w(TAG, "AudioTrack.release failed: ${t.message}")
            }
        }

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
        preferredBtInputDevice = null
        preferredBtOutputDevice = null

        sysAm.mode = android.media.AudioManager.MODE_NORMAL

        Log.d(TAG, "Audio capture stopped")
    }
}
