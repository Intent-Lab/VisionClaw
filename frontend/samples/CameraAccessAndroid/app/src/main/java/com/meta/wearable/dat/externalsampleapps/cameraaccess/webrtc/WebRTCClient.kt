package com.meta.wearable.dat.externalsampleapps.cameraaccess.webrtc

import android.content.Context
import android.graphics.Bitmap
import android.util.Log
import org.webrtc.AudioSource
import org.webrtc.AudioTrack
import org.webrtc.DataChannel
import org.webrtc.DefaultVideoDecoderFactory
import org.webrtc.DefaultVideoEncoderFactory
import org.webrtc.EglBase
import org.webrtc.IceCandidate
import org.webrtc.MediaConstraints
import org.webrtc.MediaStream
import org.webrtc.PeerConnection
import org.webrtc.PeerConnectionFactory
import org.webrtc.RtpReceiver
import org.webrtc.SdpObserver
import org.webrtc.SessionDescription
import org.webrtc.VideoSource
import org.webrtc.VideoTrack

interface WebRTCClientDelegate {
    fun onConnectionStateChanged(state: PeerConnection.IceConnectionState)
    fun onIceCandidateGenerated(candidate: IceCandidate)
    fun onRemoteVideoTrackReceived(track: VideoTrack)
    fun onRemoteVideoTrackRemoved(track: VideoTrack)
}

class WebRTCClient(private val context: Context) {
    companion object {
        private const val TAG = "WebRTCClient"
    }

    var delegate: WebRTCClientDelegate? = null

    private var peerConnectionFactory: PeerConnectionFactory? = null
    private var peerConnection: PeerConnection? = null
    private var localVideoTrack: VideoTrack? = null
    private var localAudioTrack: AudioTrack? = null
    private var remoteVideoTrack: VideoTrack? = null
    private var videoSource: VideoSource? = null
    private var customCapturer: CustomVideoCapturer? = null

    val eglBase: EglBase = EglBase.create()

    fun setup(iceServers: List<PeerConnection.IceServer>?) {
        // Initialize PeerConnectionFactory
        PeerConnectionFactory.initialize(
            PeerConnectionFactory.InitializationOptions.builder(context)
                .setEnableInternalTracer(false)
                .createInitializationOptions()
        )

        val encoderFactory = DefaultVideoEncoderFactory(eglBase.eglBaseContext, true, true)
        val decoderFactory = DefaultVideoDecoderFactory(eglBase.eglBaseContext)

        peerConnectionFactory = PeerConnectionFactory.builder()
            .setVideoEncoderFactory(encoderFactory)
            .setVideoDecoderFactory(decoderFactory)
            .createPeerConnectionFactory()

        // Configure ICE servers
        val rtcConfig = PeerConnection.RTCConfiguration(
            iceServers ?: listOf(
                PeerConnection.IceServer.builder("stun:stun.l.google.com:19302").createIceServer()
            )
        )
        rtcConfig.sdpSemantics = PeerConnection.SdpSemantics.UNIFIED_PLAN
        rtcConfig.continualGatheringPolicy = PeerConnection.ContinualGatheringPolicy.GATHER_CONTINUALLY

        // Create peer connection
        peerConnection = peerConnectionFactory?.createPeerConnection(
            rtcConfig,
            object : PeerConnection.Observer {
                override fun onSignalingChange(state: PeerConnection.SignalingState?) {
                    Log.d(TAG, "Signaling state: $state")
                }

                override fun onIceConnectionChange(state: PeerConnection.IceConnectionState?) {
                    Log.d(TAG, "ICE connection state: $state")
                    state?.let { delegate?.onConnectionStateChanged(it) }
                }

                override fun onIceConnectionReceivingChange(receiving: Boolean) {}

                override fun onIceGatheringChange(state: PeerConnection.IceGatheringState?) {
                    Log.d(TAG, "ICE gathering state: $state")
                }

                override fun onIceCandidate(candidate: IceCandidate?) {
                    candidate?.let {
                        // Log candidate type for debugging
                        when {
                            it.sdp.contains("relay") -> Log.d(TAG, "ICE candidate: RELAY (TURN)")
                            it.sdp.contains("srflx") -> Log.d(TAG, "ICE candidate: SERVER REFLEXIVE (STUN)")
                            it.sdp.contains("host") -> Log.d(TAG, "ICE candidate: HOST (local)")
                        }
                        delegate?.onIceCandidateGenerated(it)
                    }
                }

                override fun onIceCandidatesRemoved(candidates: Array<out IceCandidate>?) {}

                override fun onAddStream(stream: MediaStream?) {
                    Log.d(TAG, "Remote stream added: ${stream?.videoTracks?.size} video, ${stream?.audioTracks?.size} audio")
                    stream?.videoTracks?.firstOrNull()?.let { track ->
                        remoteVideoTrack = track
                        delegate?.onRemoteVideoTrackReceived(track)
                    }
                }

                override fun onRemoveStream(stream: MediaStream?) {
                    Log.d(TAG, "Remote stream removed")
                    remoteVideoTrack?.let { track ->
                        remoteVideoTrack = null
                        delegate?.onRemoteVideoTrackRemoved(track)
                    }
                }

                override fun onDataChannel(channel: DataChannel?) {}
                override fun onRenegotiationNeeded() {
                    Log.d(TAG, "Negotiation needed")
                }
                override fun onAddTrack(receiver: RtpReceiver?, streams: Array<out MediaStream>?) {}
            }
        )

        // Create video source + track with custom capturer
        val factory = peerConnectionFactory ?: return
        videoSource = factory.createVideoSource(false) // false = not a screen cast
        customCapturer = CustomVideoCapturer().apply { initialize(videoSource!!) }
        localVideoTrack = factory.createVideoTrack("video0", videoSource).apply {
            setEnabled(true)
        }
        peerConnection?.addTrack(localVideoTrack, listOf("stream0"))

        // Create audio track
        val audioConstraints = MediaConstraints()
        val audioSource: AudioSource = factory.createAudioSource(audioConstraints)
        localAudioTrack = factory.createAudioTrack("audio0", audioSource).apply {
            setEnabled(true)
        }
        peerConnection?.addTrack(localAudioTrack, listOf("stream0"))
    }

    fun pushVideoFrame(bitmap: Bitmap) {
        customCapturer?.pushFrame(bitmap)
    }

    fun createOffer(onSuccess: (SessionDescription) -> Unit) {
        val constraints = MediaConstraints().apply {
            mandatory.add(MediaConstraints.KeyValuePair("OfferToReceiveAudio", "true"))
            mandatory.add(MediaConstraints.KeyValuePair("OfferToReceiveVideo", "true"))
        }

        peerConnection?.createOffer(object : SdpObserver {
            override fun onCreateSuccess(sdp: SessionDescription?) {
                sdp?.let { offer ->
                    peerConnection?.setLocalDescription(object : SdpObserver {
                        override fun onSetSuccess() {
                            onSuccess(offer)
                        }
                        override fun onSetFailure(error: String?) {
                            Log.e(TAG, "Failed to set local description: $error")
                        }
                        override fun onCreateSuccess(p0: SessionDescription?) {}
                        override fun onCreateFailure(p0: String?) {}
                    }, offer)
                }
            }
            override fun onCreateFailure(error: String?) {
                Log.e(TAG, "Failed to create offer: $error")
            }
            override fun onSetSuccess() {}
            override fun onSetFailure(p0: String?) {}
        }, constraints)
    }

    fun setRemoteSdp(sdp: SessionDescription, onComplete: (String?) -> Unit) {
        peerConnection?.setRemoteDescription(object : SdpObserver {
            override fun onSetSuccess() {
                onComplete(null)
            }
            override fun onSetFailure(error: String?) {
                onComplete(error)
            }
            override fun onCreateSuccess(p0: SessionDescription?) {}
            override fun onCreateFailure(p0: String?) {}
        }, sdp)
    }

    fun addRemoteCandidate(candidate: IceCandidate, onComplete: (String?) -> Unit) {
        val success = peerConnection?.addIceCandidate(candidate) ?: false
        onComplete(if (success) null else "Failed to add ICE candidate")
    }

    fun muteAudio(mute: Boolean) {
        localAudioTrack?.setEnabled(!mute)
    }

    fun close() {
        localVideoTrack?.setEnabled(false)
        localAudioTrack?.setEnabled(false)
        remoteVideoTrack = null
        customCapturer?.dispose()
        customCapturer = null
        peerConnection?.close()
        peerConnection = null
        peerConnectionFactory?.dispose()
        peerConnectionFactory = null
        Log.d(TAG, "Peer connection closed")
    }
}
