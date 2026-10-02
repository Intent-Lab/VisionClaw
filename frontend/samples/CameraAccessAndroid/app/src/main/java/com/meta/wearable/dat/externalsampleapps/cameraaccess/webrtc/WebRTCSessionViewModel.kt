package com.meta.wearable.dat.externalsampleapps.cameraaccess.webrtc

import android.app.Application
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.graphics.Bitmap
import android.util.Log
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.ProcessLifecycleOwner
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import org.webrtc.IceCandidate
import org.webrtc.PeerConnection
import org.webrtc.VideoTrack

sealed class WebRTCConnectionState {
    object Disconnected : WebRTCConnectionState()
    object Connecting : WebRTCConnectionState()
    object WaitingForPeer : WebRTCConnectionState()
    object Connected : WebRTCConnectionState()
    object Backgrounded : WebRTCConnectionState()
    data class Error(val message: String) : WebRTCConnectionState()
}

data class WebRTCUiState(
    val isActive: Boolean = false,
    val connectionState: WebRTCConnectionState = WebRTCConnectionState.Disconnected,
    val roomCode: String = "",
    val viewerUrl: String = "",
    val isMuted: Boolean = false,
    val errorMessage: String? = null,
    val remoteVideoTrack: VideoTrack? = null,
    val hasRemoteVideo: Boolean = false,
)

class WebRTCSessionViewModel(application: Application) : AndroidViewModel(application) {
    companion object {
        private const val TAG = "WebRTCSessionVM"
    }

    private val _uiState = MutableStateFlow(WebRTCUiState())
    val uiState: StateFlow<WebRTCUiState> = _uiState.asStateFlow()

    private var webRTCClient: WebRTCClient? = null
    private var signalingClient: SignalingClient? = null
    private var savedRoomCode: String? = null
    private var signalingTimeoutJob: Job? = null

    private val lifecycleObserver = object : DefaultLifecycleObserver {
        override fun onStart(owner: LifecycleOwner) {
            // App came to foreground
            handleReturnToForeground()
        }
    }

    fun startSession() {
        if (_uiState.value.isActive) return

        if (!WebRTCConfig.isConfigured) {
            _uiState.value = _uiState.value.copy(
                errorMessage = "WebRTC signaling URL not configured."
            )
            return
        }

        _uiState.value = _uiState.value.copy(
            isActive = true,
            connectionState = WebRTCConnectionState.Connecting,
        )
        savedRoomCode = null

        viewModelScope.launch {
            val iceServers = WebRTCConfig.fetchIceServers()
            setupWebRTCClient(iceServers)
            connectSignaling(rejoinCode = null)
            observeForeground()
        }
    }

    fun stopSession() {
        removeForegroundObserver()
        signalingTimeoutJob?.cancel()
        signalingTimeoutJob = null
        webRTCClient?.close()
        webRTCClient = null
        signalingClient?.disconnect()
        signalingClient = null
        savedRoomCode = null
        _uiState.value = WebRTCUiState()
    }

    fun toggleMute() {
        val newMuted = !_uiState.value.isMuted
        _uiState.value = _uiState.value.copy(isMuted = newMuted)
        webRTCClient?.muteAudio(newMuted)
    }

    fun copyRoomCode() {
        val code = _uiState.value.roomCode
        if (code.isNotEmpty()) {
            val clipboard = getApplication<Application>()
                .getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            clipboard.setPrimaryClip(ClipData.newPlainText("Room Code", code))
        }
    }

    fun pushVideoFrame(bitmap: Bitmap) {
        if (!_uiState.value.isActive) return
        if (_uiState.value.connectionState != WebRTCConnectionState.Connected) return
        webRTCClient?.pushVideoFrame(bitmap)
    }

    fun clearError() {
        _uiState.value = _uiState.value.copy(errorMessage = null)
    }

    // -- Private --

    private fun setupWebRTCClient(iceServers: List<PeerConnection.IceServer>) {
        webRTCClient?.close()
        val client = WebRTCClient(getApplication())
        client.delegate = object : WebRTCClientDelegate {
            override fun onConnectionStateChanged(state: PeerConnection.IceConnectionState) {
                viewModelScope.launch { handleConnectionStateChange(state) }
            }
            override fun onIceCandidateGenerated(candidate: IceCandidate) {
                signalingClient?.sendCandidate(candidate)
            }
            override fun onRemoteVideoTrackReceived(track: VideoTrack) {
                viewModelScope.launch {
                    _uiState.value = _uiState.value.copy(
                        remoteVideoTrack = track,
                        hasRemoteVideo = true,
                    )
                    Log.d(TAG, "Remote video track received")
                }
            }
            override fun onRemoteVideoTrackRemoved(track: VideoTrack) {
                viewModelScope.launch {
                    _uiState.value = _uiState.value.copy(
                        remoteVideoTrack = null,
                        hasRemoteVideo = false,
                    )
                    Log.d(TAG, "Remote video track removed")
                }
            }
        }
        client.setup(iceServers)
        webRTCClient = client
    }

    private fun connectSignaling(rejoinCode: String?) {
        signalingClient?.disconnect()
        signalingTimeoutJob?.cancel()

        val signaling = SignalingClient()
        signalingClient = signaling
        val signalingUrl = WebRTCConfig.signalingServerURL

        signaling.onConnected = {
            viewModelScope.launch {
                if (rejoinCode != null) {
                    Log.d(TAG, "Reconnected, rejoining room: $rejoinCode")
                    signalingClient?.rejoinRoom(rejoinCode)
                } else {
                    signalingClient?.createRoom()
                }
            }
        }

        signaling.onMessageReceived = { message ->
            viewModelScope.launch { handleSignalingMessage(message) }
        }

        signaling.onDisconnected = { reason ->
            viewModelScope.launch {
                if (!_uiState.value.isActive) return@launch
                if (savedRoomCode != null) {
                    _uiState.value = _uiState.value.copy(
                        connectionState = WebRTCConnectionState.Backgrounded
                    )
                    Log.d(TAG, "Signaling disconnected (backgrounded), will rejoin: $reason")
                } else {
                    stopSession()
                    _uiState.value = _uiState.value.copy(
                        errorMessage = reason ?: "Live signaling disconnected."
                    )
                }
            }
        }

        signaling.connect(signalingUrl)
        signalingTimeoutJob = viewModelScope.launch {
            delay(10_000)
            val state = _uiState.value.connectionState
            if (_uiState.value.isActive && state is WebRTCConnectionState.Connecting) {
                stopSession()
                _uiState.value = _uiState.value.copy(
                    errorMessage = "Live server timeout. Check phone Wi-Fi and Mac server: $signalingUrl"
                )
            }
        }
    }

    private fun handleSignalingMessage(message: SignalingMessage) {
        when (message) {
            is SignalingMessage.RoomCreated -> {
                signalingTimeoutJob?.cancel()
                _uiState.value = _uiState.value.copy(
                    roomCode = message.room,
                    viewerUrl = WebRTCConfig.viewerUrl(message.room),
                    connectionState = WebRTCConnectionState.WaitingForPeer,
                )
                savedRoomCode = message.room
                Log.d(TAG, "Room created: ${message.room}")
            }
            is SignalingMessage.RoomRejoined -> {
                signalingTimeoutJob?.cancel()
                _uiState.value = _uiState.value.copy(
                    roomCode = message.room,
                    viewerUrl = WebRTCConfig.viewerUrl(message.room),
                    connectionState = WebRTCConnectionState.WaitingForPeer,
                )
                savedRoomCode = message.room
                Log.d(TAG, "Room rejoined: ${message.room}")
            }
            is SignalingMessage.PeerJoined -> {
                Log.d(TAG, "Peer joined, creating offer")
                webRTCClient?.createOffer { sdp ->
                    signalingClient?.sendSdp(sdp)
                }
            }
            is SignalingMessage.Answer -> {
                webRTCClient?.setRemoteSdp(message.sdp) { error ->
                    error?.let { Log.e(TAG, "Error setting remote SDP: $it") }
                }
            }
            is SignalingMessage.Candidate -> {
                webRTCClient?.addRemoteCandidate(message.candidate) { error ->
                    error?.let { Log.e(TAG, "Error adding ICE candidate: $it") }
                }
            }
            is SignalingMessage.PeerLeft -> {
                Log.d(TAG, "Peer left")
                _uiState.value = _uiState.value.copy(
                    connectionState = WebRTCConnectionState.WaitingForPeer,
                )
            }
            is SignalingMessage.Error -> {
                // If rejoin fails (room expired), create a new room
                if (savedRoomCode != null && message.message == "Room not found") {
                    Log.d(TAG, "Rejoin failed (room expired), creating new room")
                    savedRoomCode = null
                    signalingClient?.createRoom()
                } else {
                    _uiState.value = _uiState.value.copy(errorMessage = message.message)
                }
            }
            is SignalingMessage.RoomJoined, is SignalingMessage.Offer -> {
                // Not handled by streamer side
            }
        }
    }

    private fun handleConnectionStateChange(state: PeerConnection.IceConnectionState) {
        when (state) {
            PeerConnection.IceConnectionState.CONNECTED,
            PeerConnection.IceConnectionState.COMPLETED -> {
                _uiState.value = _uiState.value.copy(
                    connectionState = WebRTCConnectionState.Connected
                )
                Log.d(TAG, "Peer connected")
            }
            PeerConnection.IceConnectionState.DISCONNECTED -> {
                _uiState.value = _uiState.value.copy(
                    connectionState = WebRTCConnectionState.WaitingForPeer
                )
            }
            PeerConnection.IceConnectionState.FAILED -> {
                _uiState.value = _uiState.value.copy(
                    connectionState = WebRTCConnectionState.Error("Connection failed")
                )
            }
            PeerConnection.IceConnectionState.CLOSED -> {
                _uiState.value = _uiState.value.copy(
                    connectionState = WebRTCConnectionState.Disconnected
                )
            }
            else -> {}
        }
    }

    private fun handleReturnToForeground() {
        val code = savedRoomCode ?: return
        if (!_uiState.value.isActive) return

        Log.d(TAG, "App returned to foreground, reconnecting to room: $code")
        _uiState.value = _uiState.value.copy(
            connectionState = WebRTCConnectionState.Connecting,
            remoteVideoTrack = null,
            hasRemoteVideo = false,
        )

        webRTCClient?.close()

        viewModelScope.launch {
            val iceServers = WebRTCConfig.fetchIceServers()
            setupWebRTCClient(iceServers)
            connectSignaling(rejoinCode = code)
        }
    }

    private fun observeForeground() {
        ProcessLifecycleOwner.get().lifecycle.addObserver(lifecycleObserver)
    }

    private fun removeForegroundObserver() {
        ProcessLifecycleOwner.get().lifecycle.removeObserver(lifecycleObserver)
    }

    override fun onCleared() {
        super.onCleared()
        stopSession()
    }
}
