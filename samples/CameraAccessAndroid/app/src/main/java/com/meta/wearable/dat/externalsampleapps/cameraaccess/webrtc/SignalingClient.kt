package com.meta.wearable.dat.externalsampleapps.cameraaccess.webrtc

import android.util.Log
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import org.json.JSONObject
import org.webrtc.IceCandidate
import org.webrtc.SessionDescription
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

sealed class SignalingMessage {
    data class RoomCreated(val room: String) : SignalingMessage()
    data class RoomRejoined(val room: String) : SignalingMessage()
    object RoomJoined : SignalingMessage()
    object PeerJoined : SignalingMessage()
    object PeerLeft : SignalingMessage()
    data class Offer(val sdp: SessionDescription) : SignalingMessage()
    data class Answer(val sdp: SessionDescription) : SignalingMessage()
    data class Candidate(val candidate: IceCandidate) : SignalingMessage()
    data class Error(val message: String) : SignalingMessage()
}

class SignalingClient {
    companion object {
        private const val TAG = "SignalingClient"
    }

    var onMessageReceived: ((SignalingMessage) -> Unit)? = null
    var onConnected: (() -> Unit)? = null
    var onDisconnected: ((String?) -> Unit)? = null

    private var webSocket: WebSocket? = null
    private val sendExecutor = Executors.newSingleThreadExecutor()
    private val client = OkHttpClient.Builder()
        .readTimeout(0, TimeUnit.MILLISECONDS) // No read timeout for WebSocket
        .connectTimeout(30, TimeUnit.SECONDS)
        .build()

    fun connect(url: String) {
        disconnect()

        val request = Request.Builder()
            .url(url)
            .build()

        webSocket = client.newWebSocket(request, object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                Log.d(TAG, "Connected to $url")
                onConnected?.invoke()
            }

            override fun onMessage(webSocket: WebSocket, text: String) {
                handleMessage(text)
            }

            override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
                Log.d(TAG, "Closing: $reason")
                webSocket.close(1000, null)
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                Log.d(TAG, "Closed: $reason")
                onDisconnected?.invoke(reason.ifEmpty { null })
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                Log.e(TAG, "Failure: ${t.message}")
                onDisconnected?.invoke(t.message)
            }
        })
    }

    fun createRoom() {
        sendJSON(JSONObject().put("type", "create"))
    }

    fun joinRoom(code: String) {
        sendJSON(JSONObject().put("type", "join").put("room", code).put("room_code", code))
    }

    fun rejoinRoom(code: String) {
        sendJSON(JSONObject().put("type", "rejoin").put("room", code).put("room_code", code))
    }

    fun sendSdp(sdp: SessionDescription) {
        val type = if (sdp.type == SessionDescription.Type.OFFER) "offer" else "answer"
        sendJSON(JSONObject().put("type", type).put("sdp", sdp.description))
    }

    fun sendCandidate(candidate: IceCandidate) {
        sendJSON(
            JSONObject()
                .put("type", "candidate")
                .put("candidate", candidate.sdp)
                .put("sdpMid", candidate.sdpMid ?: "")
                .put("sdpMLineIndex", candidate.sdpMLineIndex)
        )
    }

    fun disconnect() {
        webSocket?.close(1000, "Going away")
        webSocket = null
    }

    private fun sendJSON(json: JSONObject) {
        sendExecutor.execute {
            val ws = webSocket ?: return@execute
            ws.send(json.toString())
        }
    }

    private fun handleMessage(text: String) {
        try {
            val json = JSONObject(text)
            val type = json.optString("type", "")

            when (type) {
                "room_created" -> {
                    val room = readRoomCode(json)
                    if (room.isNotEmpty()) {
                        onMessageReceived?.invoke(SignalingMessage.RoomCreated(room))
                    }
                }
                "room_joined" -> {
                    onMessageReceived?.invoke(SignalingMessage.RoomJoined)
                }
                "room_rejoined" -> {
                    val room = readRoomCode(json)
                    if (room.isNotEmpty()) {
                        onMessageReceived?.invoke(SignalingMessage.RoomRejoined(room))
                    }
                }
                "peer_joined", "viewer_joined" -> {
                    onMessageReceived?.invoke(SignalingMessage.PeerJoined)
                }
                "peer_left", "viewer_left" -> {
                    onMessageReceived?.invoke(SignalingMessage.PeerLeft)
                }
                "offer" -> {
                    val sdp = json.optString("sdp", "")
                    if (sdp.isNotEmpty()) {
                        onMessageReceived?.invoke(
                            SignalingMessage.Offer(
                                SessionDescription(SessionDescription.Type.OFFER, sdp)
                            )
                        )
                    }
                }
                "answer" -> {
                    val sdp = json.optString("sdp", "")
                    if (sdp.isNotEmpty()) {
                        onMessageReceived?.invoke(
                            SignalingMessage.Answer(
                                SessionDescription(SessionDescription.Type.ANSWER, sdp)
                            )
                        )
                    }
                }
                "candidate" -> {
                    val candidate = json.optString("candidate", "")
                    val sdpMid = json.optString("sdpMid", "")
                    val sdpMLineIndex = json.optInt("sdpMLineIndex", 0)
                    if (candidate.isNotEmpty()) {
                        onMessageReceived?.invoke(
                            SignalingMessage.Candidate(
                                IceCandidate(sdpMid, sdpMLineIndex, candidate)
                            )
                        )
                    }
                }
                "error" -> {
                    val msg = json.optString("message", "Unknown signaling error")
                    onMessageReceived?.invoke(SignalingMessage.Error(msg))
                }
                else -> {
                    Log.w(TAG, "Unknown message type: $type")
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to parse signaling message: ${e.message}")
        }
    }

    private fun readRoomCode(json: JSONObject): String {
        return json.optString("room", json.optString("room_code", ""))
    }
}
