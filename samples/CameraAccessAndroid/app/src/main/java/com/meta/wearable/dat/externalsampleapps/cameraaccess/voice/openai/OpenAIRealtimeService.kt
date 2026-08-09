package com.meta.wearable.dat.externalsampleapps.cameraaccess.voice.openai

import android.content.Context
import android.graphics.Bitmap
import android.util.Base64
import android.util.Log
import com.meta.wearable.dat.externalsampleapps.cameraaccess.openclaw.GeminiFunctionCall
import com.meta.wearable.dat.externalsampleapps.cameraaccess.openclaw.GeminiToolCall
import com.meta.wearable.dat.externalsampleapps.cameraaccess.openclaw.GeminiToolCallCancellation
import com.meta.wearable.dat.externalsampleapps.cameraaccess.openclaw.ToolDeclarations
import com.meta.wearable.dat.externalsampleapps.cameraaccess.openclaw.ToolResult
import com.meta.wearable.dat.externalsampleapps.cameraaccess.voice.RealtimeVoiceService
import com.meta.wearable.dat.externalsampleapps.cameraaccess.voice.VoiceConnectionState
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.charset.StandardCharsets
import java.util.Timer
import java.util.TimerTask
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import org.webrtc.DataChannel
import org.webrtc.IceCandidate
import org.webrtc.MediaConstraints
import org.webrtc.MediaStream
import org.webrtc.PeerConnection
import org.webrtc.PeerConnectionFactory
import org.webrtc.RtpReceiver
import org.webrtc.SdpObserver
import org.webrtc.SessionDescription
import org.webrtc.audio.JavaAudioDeviceModule

// Realtime voice over WebRTC against the OpenAI Realtime API.
//
// Unlike the Gemini Live path, WebRTC owns the microphone and speaker: capture,
// playback, echo cancellation, jitter buffering, and Opus encoding all happen
// inside the peer connection (managesOwnAudio = true), so AudioManager's PCM
// pump stays off. Model/tool events flow over the "oai-events" data channel.
//
// Vision: continuous 1fps frame push (the Gemini approach) would flood the
// conversation context, so the latest camera frame is cached and attached as an
// image item once per user turn, when the server reports speech start.
class OpenAIRealtimeService(private val context: Context) : RealtimeVoiceService {
    companion object {
        private const val TAG = "OpenAIRealtimeService"
        private const val ICE_GATHERING_TIMEOUT_MS = 2000L
        private const val CONNECT_TIMEOUT_MS = 20000L
        private const val DATA_CHANNEL_LABEL = "oai-events"
    }

    private val _connectionState =
        MutableStateFlow<VoiceConnectionState>(VoiceConnectionState.Disconnected)
    override val connectionState: StateFlow<VoiceConnectionState> = _connectionState.asStateFlow()

    private val _isModelSpeaking = MutableStateFlow(false)
    override val isModelSpeaking: StateFlow<Boolean> = _isModelSpeaking.asStateFlow()

    override val managesOwnAudio: Boolean = true

    override var onAudioReceived: ((ByteArray) -> Unit)? = null // unused: WebRTC plays audio itself
    override var onTurnComplete: (() -> Unit)? = null
    override var onInterrupted: (() -> Unit)? = null
    override var onDisconnected: ((String?) -> Unit)? = null
    override var onInputTranscription: ((String) -> Unit)? = null
    override var onOutputTranscription: ((String) -> Unit)? = null
    override var onToolCall: ((GeminiToolCall) -> Unit)? = null
    override var onToolCallCancellation: ((GeminiToolCallCancellation) -> Unit)? = null

    private var peerConnectionFactory: PeerConnectionFactory? = null
    private var peerConnection: PeerConnection? = null
    private var audioDeviceModule: JavaAudioDeviceModule? = null
    private var dataChannel: DataChannel? = null

    private val httpClient = OkHttpClient()
    private val sendExecutor = Executors.newSingleThreadExecutor()
    private var connectCallback: ((Boolean) -> Unit)? = null
    private var timeoutTimer: Timer? = null
    private val offerPosted = AtomicBoolean(false)
    private var ephemeralKey: String? = null

    @Volatile
    private var pendingFrameBase64: String? = null

    override fun connect(callback: (Boolean) -> Unit) {
        if (!OpenAIRealtimeConfig.isConfigured) {
            _connectionState.value = VoiceConnectionState.Error("No OpenAI API key configured")
            callback(false)
            return
        }

        _connectionState.value = VoiceConnectionState.Connecting
        connectCallback = callback
        offerPosted.set(false)

        timeoutTimer = Timer().apply {
            schedule(object : TimerTask() {
                override fun run() {
                    if (_connectionState.value == VoiceConnectionState.Connecting
                        || _connectionState.value == VoiceConnectionState.SettingUp) {
                        Log.e(TAG, "Connection timed out")
                        failConnect("Connection timed out")
                    }
                }
            }, CONNECT_TIMEOUT_MS)
        }

        Thread({
            try {
                ephemeralKey = mintClientSecret()
                setupPeerConnection()
            } catch (e: Exception) {
                Log.e(TAG, "Connect failed: ${e.message}")
                failConnect(e.message ?: "Connect failed")
            }
        }, "openai-connect").start()
    }

    override fun disconnect() {
        timeoutTimer?.cancel()
        timeoutTimer = null
        onToolCall = null
        onToolCallCancellation = null
        teardown()
        _connectionState.value = VoiceConnectionState.Disconnected
        _isModelSpeaking.value = false
        resolveConnect(false)
    }

    // WebRTC captures the microphone itself; PCM pushed by the caller is ignored.
    override fun sendAudio(data: ByteArray) {}

    override fun sendVideoFrame(bitmap: Bitmap) {
        if (_connectionState.value != VoiceConnectionState.Ready) return
        val baos = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.JPEG, OpenAIRealtimeConfig.VIDEO_JPEG_QUALITY, baos)
        pendingFrameBase64 = Base64.encodeToString(baos.toByteArray(), Base64.NO_WRAP)
    }

    override fun sendToolResponse(callId: String, name: String, result: ToolResult) {
        sendEvent(JSONObject().apply {
            put("type", "conversation.item.create")
            put("item", JSONObject().apply {
                put("type", "function_call_output")
                put("call_id", callId)
                put("output", result.toJSON().toString())
            })
        })
        sendEvent(JSONObject().put("type", "response.create"))
    }

    override fun sendTextMessage(text: String) {
        if (_connectionState.value != VoiceConnectionState.Ready) return
        sendEvent(JSONObject().apply {
            put("type", "conversation.item.create")
            put("item", JSONObject().apply {
                put("type", "message")
                put("role", "user")
                put("content", JSONArray().put(JSONObject().apply {
                    put("type", "input_text")
                    put("text", text)
                }))
            })
        })
        sendEvent(JSONObject().put("type", "response.create"))
    }

    // Connection setup

    private fun mintClientSecret(): String {
        val session = JSONObject().apply {
            put("session", JSONObject().apply {
                put("type", "realtime")
                put("model", OpenAIRealtimeConfig.MODEL)
                put("instructions", OpenAIRealtimeConfig.systemInstruction)
                put("audio", JSONObject().apply {
                    put("input", JSONObject().apply {
                        put("transcription", JSONObject().apply {
                            put("model", OpenAIRealtimeConfig.TRANSCRIPTION_MODEL)
                        })
                    })
                    put("output", JSONObject().apply {
                        put("voice", OpenAIRealtimeConfig.VOICE)
                    })
                })
                put("tools", ToolDeclarations.openAIDeclarationsJSON())
            })
        }

        val request = Request.Builder()
            .url(OpenAIRealtimeConfig.CLIENT_SECRETS_URL)
            .header("Authorization", "Bearer ${OpenAIRealtimeConfig.apiKey}")
            .post(session.toString().toRequestBody("application/json".toMediaType()))
            .build()

        httpClient.newCall(request).execute().use { response ->
            val body = response.body?.string() ?: ""
            if (!response.isSuccessful) {
                throw IllegalStateException("client_secrets HTTP ${response.code}: ${body.take(200)}")
            }
            val value = JSONObject(body).optString("value", "")
            if (value.isEmpty()) throw IllegalStateException("client_secrets response missing value")
            return value
        }
    }

    private fun setupPeerConnection() {
        PeerConnectionFactory.initialize(
            PeerConnectionFactory.InitializationOptions.builder(context)
                .setEnableInternalTracer(false)
                .createInitializationOptions()
        )

        val adm = JavaAudioDeviceModule.builder(context)
            .setUseHardwareAcousticEchoCanceler(true)
            .setUseHardwareNoiseSuppressor(true)
            .createAudioDeviceModule()
        audioDeviceModule = adm

        val factory = PeerConnectionFactory.builder()
            .setAudioDeviceModule(adm)
            .createPeerConnectionFactory()
        peerConnectionFactory = factory

        val rtcConfig = PeerConnection.RTCConfiguration(
            listOf(PeerConnection.IceServer.builder("stun:stun.l.google.com:19302").createIceServer())
        )
        rtcConfig.sdpSemantics = PeerConnection.SdpSemantics.UNIFIED_PLAN

        val pc = factory.createPeerConnection(rtcConfig, object : PeerConnection.Observer {
            override fun onSignalingChange(state: PeerConnection.SignalingState?) {}

            override fun onIceConnectionChange(state: PeerConnection.IceConnectionState?) {
                Log.d(TAG, "ICE connection state: $state")
                if (state == PeerConnection.IceConnectionState.FAILED) {
                    handleDropped("ICE connection failed")
                }
            }

            override fun onIceConnectionReceivingChange(receiving: Boolean) {}

            override fun onIceGatheringChange(state: PeerConnection.IceGatheringState?) {
                Log.d(TAG, "ICE gathering state: $state")
                if (state == PeerConnection.IceGatheringState.COMPLETE) {
                    postOfferOnce()
                }
            }

            override fun onIceCandidate(candidate: IceCandidate?) {}
            override fun onIceCandidatesRemoved(candidates: Array<out IceCandidate>?) {}
            override fun onAddStream(stream: MediaStream?) {}
            override fun onRemoveStream(stream: MediaStream?) {}
            override fun onDataChannel(channel: DataChannel?) {}
            override fun onRenegotiationNeeded() {}
            override fun onAddTrack(receiver: RtpReceiver?, streams: Array<out MediaStream>?) {}
        }) ?: throw IllegalStateException("Failed to create peer connection")
        peerConnection = pc

        val audioSource = factory.createAudioSource(MediaConstraints())
        val audioTrack = factory.createAudioTrack("mic0", audioSource).apply { setEnabled(true) }
        pc.addTrack(audioTrack, listOf("mic"))

        dataChannel = pc.createDataChannel(DATA_CHANNEL_LABEL, DataChannel.Init())
        dataChannel?.registerObserver(object : DataChannel.Observer {
            override fun onBufferedAmountChange(previousAmount: Long) {}

            override fun onStateChange() {
                val state = dataChannel?.state()
                Log.d(TAG, "Data channel state: $state")
                when (state) {
                    DataChannel.State.OPEN -> {
                        _connectionState.value = VoiceConnectionState.Ready
                        resolveConnect(true)
                    }
                    DataChannel.State.CLOSED -> handleDropped("Data channel closed")
                    else -> {}
                }
            }

            override fun onMessage(buffer: DataChannel.Buffer?) {
                buffer ?: return
                val bytes = ByteArray(buffer.data.remaining())
                buffer.data.get(bytes)
                handleEvent(String(bytes, StandardCharsets.UTF_8))
            }
        })

        val constraints = MediaConstraints().apply {
            mandatory.add(MediaConstraints.KeyValuePair("OfferToReceiveAudio", "true"))
        }
        pc.createOffer(object : SdpObserver {
            override fun onCreateSuccess(sdp: SessionDescription?) {
                sdp ?: return failConnect("Empty SDP offer")
                pc.setLocalDescription(object : SdpObserver {
                    override fun onSetSuccess() {
                        // Post after ICE gathering completes, or after a short
                        // timeout with whatever candidates are already in the SDP.
                        Timer().schedule(object : TimerTask() {
                            override fun run() { postOfferOnce() }
                        }, ICE_GATHERING_TIMEOUT_MS)
                    }
                    override fun onSetFailure(error: String?) {
                        failConnect("setLocalDescription failed: $error")
                    }
                    override fun onCreateSuccess(p0: SessionDescription?) {}
                    override fun onCreateFailure(p0: String?) {}
                }, sdp)
            }
            override fun onCreateFailure(error: String?) {
                failConnect("createOffer failed: $error")
            }
            override fun onSetSuccess() {}
            override fun onSetFailure(p0: String?) {}
        }, constraints)
    }

    private fun postOfferOnce() {
        if (offerPosted.getAndSet(true)) return
        val offerSdp = peerConnection?.localDescription?.description
            ?: return failConnect("No local SDP")

        Thread({
            try {
                val request = Request.Builder()
                    .url(OpenAIRealtimeConfig.CALLS_URL)
                    .header("Authorization", "Bearer ${ephemeralKey ?: ""}")
                    .post(offerSdp.toRequestBody("application/sdp".toMediaType()))
                    .build()

                val answerSdp = httpClient.newCall(request).execute().use { response ->
                    val body = response.body?.string() ?: ""
                    if (!response.isSuccessful) {
                        throw IllegalStateException("calls HTTP ${response.code}: ${body.take(200)}")
                    }
                    body
                }

                _connectionState.value = VoiceConnectionState.SettingUp
                peerConnection?.setRemoteDescription(object : SdpObserver {
                    override fun onSetSuccess() {
                        Log.d(TAG, "Remote description set; waiting for data channel")
                    }
                    override fun onSetFailure(error: String?) {
                        failConnect("setRemoteDescription failed: $error")
                    }
                    override fun onCreateSuccess(p0: SessionDescription?) {}
                    override fun onCreateFailure(p0: String?) {}
                }, SessionDescription(SessionDescription.Type.ANSWER, answerSdp))
            } catch (e: Exception) {
                Log.e(TAG, "SDP exchange failed: ${e.message}")
                failConnect(e.message ?: "SDP exchange failed")
            }
        }, "openai-sdp").start()
    }

    // Event handling

    private fun handleEvent(text: String) {
        try {
            val json = JSONObject(text)
            when (val type = json.optString("type", "")) {
                "session.created", "session.updated" -> {
                    Log.d(TAG, type)
                }

                "input_audio_buffer.speech_started" -> {
                    // Barge-in: the server clears the output buffer; mirror state.
                    _isModelSpeaking.value = false
                    onInterrupted?.invoke()
                    sendPendingFrame()
                }

                "conversation.item.input_audio_transcription.completed" -> {
                    val transcript = json.optString("transcript", "")
                    if (transcript.isNotEmpty()) {
                        Log.d(TAG, "You: $transcript")
                        onInputTranscription?.invoke(transcript)
                    }
                }

                // Event renamed between Realtime API versions; accept both.
                "response.output_audio_transcript.delta", "response.audio_transcript.delta" -> {
                    val delta = json.optString("delta", "")
                    if (delta.isNotEmpty()) onOutputTranscription?.invoke(delta)
                }

                "output_audio_buffer.started" -> _isModelSpeaking.value = true

                "output_audio_buffer.stopped", "output_audio_buffer.cleared" -> {
                    _isModelSpeaking.value = false
                }

                "response.function_call_arguments.done" -> {
                    val callId = json.optString("call_id", "")
                    val name = json.optString("name", "")
                    if (callId.isNotEmpty() && name.isNotEmpty()) {
                        val args = mutableMapOf<String, Any?>()
                        try {
                            val argsObj = JSONObject(json.optString("arguments", "{}"))
                            for (key in argsObj.keys()) args[key] = argsObj.opt(key)
                        } catch (e: Exception) {
                            Log.e(TAG, "Bad tool args: ${e.message}")
                        }
                        Log.d(TAG, "Tool call: $name (id: $callId)")
                        onToolCall?.invoke(
                            GeminiToolCall(listOf(GeminiFunctionCall(callId, name, args)))
                        )
                    }
                }

                "response.done" -> {
                    onTurnComplete?.invoke()
                }

                "error" -> {
                    val message = json.optJSONObject("error")?.optString("message") ?: text.take(200)
                    Log.e(TAG, "Server error: $message")
                    if (_connectionState.value != VoiceConnectionState.Ready) {
                        failConnect(message)
                    }
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error parsing event: ${e.message}")
        }
    }

    private fun sendPendingFrame() {
        val base64 = pendingFrameBase64 ?: return
        pendingFrameBase64 = null
        sendEvent(JSONObject().apply {
            put("type", "conversation.item.create")
            put("item", JSONObject().apply {
                put("type", "message")
                put("role", "user")
                put("content", JSONArray().put(JSONObject().apply {
                    put("type", "input_image")
                    put("image_url", "data:image/jpeg;base64,$base64")
                }))
            })
        })
    }

    private fun sendEvent(json: JSONObject) {
        sendExecutor.execute {
            val channel = dataChannel ?: return@execute
            if (channel.state() != DataChannel.State.OPEN) return@execute
            val bytes = json.toString().toByteArray(StandardCharsets.UTF_8)
            channel.send(DataChannel.Buffer(ByteBuffer.wrap(bytes), false))
        }
    }

    // Lifecycle helpers

    private fun resolveConnect(success: Boolean) {
        val cb = connectCallback
        connectCallback = null // null out BEFORE invoking to prevent re-entrancy
        timeoutTimer?.cancel()
        timeoutTimer = null
        cb?.invoke(success)
    }

    private fun failConnect(message: String) {
        _connectionState.value = VoiceConnectionState.Error(message)
        _isModelSpeaking.value = false
        // failConnect can fire from WebRTC observer callbacks, and
        // PeerConnection.close() blocks until callbacks return -- tear down on
        // a separate thread to avoid deadlocking libwebrtc's signaling thread.
        Thread({ teardown() }, "openai-teardown").start()
        resolveConnect(false)
    }

    private fun handleDropped(reason: String) {
        if (_connectionState.value == VoiceConnectionState.Disconnected) return
        val wasReady = _connectionState.value == VoiceConnectionState.Ready
        _connectionState.value = VoiceConnectionState.Disconnected
        _isModelSpeaking.value = false
        resolveConnect(false)
        if (wasReady) onDisconnected?.invoke(reason)
    }

    private fun teardown() {
        pendingFrameBase64 = null
        ephemeralKey = null
        dataChannel?.unregisterObserver()
        dataChannel?.close()
        dataChannel = null
        peerConnection?.close()
        peerConnection = null
        peerConnectionFactory?.dispose()
        peerConnectionFactory = null
        audioDeviceModule?.release()
        audioDeviceModule = null
    }
}
