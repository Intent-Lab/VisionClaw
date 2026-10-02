# WebRTC Live Streaming

Real-time streaming from Meta Ray-Ban glasses (or iPhone camera) to a browser viewer with bidirectional audio and video.

## Architecture

```
iOS App (sender)                Signaling Server              Browser (viewer)
  |                                  |                              |
  | DAT SDK / iPhone camera          |                              |
  | frames -> CustomVideoCapturer    |                              |
  | -> RTCPeerConnection            |                              |
  |                                  |                              |
  |--- WebSocket (create/rejoin) -->|                              |
  |<-- room code (6 chars) ---------|                              |
  |                                  |<--- WebSocket (join) --------|
  |<-- peer_joined -----------------|                              |
  |--- SDP offer ------------------>|--- SDP offer --------------->|
  |<-- SDP answer ------------------|<-- SDP answer ---------------|
  |--- ICE candidates ------------->|--- ICE candidates ---------->|
  |<-- ICE candidates --------------|<-- ICE candidates -----------|
  |                                  |                              |
  |============= MEDIA FLOWING (P2P) =============|
  |  Video: glasses POV -> browser                                  |
  |  Video: browser camera -> iOS PiP                               |
  |  Audio: bidirectional                                           |
```

## iOS Files

| File | Purpose |
|------|---------|
| `WebRTCConfig.swift` | ICE servers, bitrate/framerate limits, TURN credential fetching |
| `WebRTCClient.swift` | `RTCPeerConnectionFactory` + `RTCPeerConnection` wrapper |
| `SignalingClient.swift` | WebSocket client for SDP/ICE signaling |
| `CustomVideoCapturer.swift` | Bridges UIImage frames into WebRTC video pipeline (UIImage -> CVPixelBuffer -> RTCVideoFrame) |
| `WebRTCSessionViewModel.swift` | Session state machine, room lifecycle, reconnection logic |
| `RTCVideoView.swift` | `UIViewRepresentable` wrapping `RTCMTLVideoView` (Metal renderer) |
| `PiPVideoView.swift` | Picture-in-picture layout -- main video + small overlay, tap to swap |
| `WebRTCOverlayView.swift` | Status bar with connection state, room code (copyable), mic indicator |

## Signaling Server

Located at `samples/CameraAccess/server/`.

- **Runtime**: Node.js
- **Dependencies**: `ws` (WebSocket library)
- **Ports**: HTTP + WebSocket on port 8080 (or `PORT` env var)
- **Serves**: `/index.html` (browser viewer) and `/api/turn` (TURN credentials)

### Signaling Protocol

| Message | Direction | Purpose |
|---------|-----------|---------|
| `create` | iOS -> Server | Request new room, returns 6-char room code |
| `rejoin` | iOS -> Server | Reconnect to existing room after backgrounding |
| `join` | Browser -> Server | Viewer joins room by code |
| `offer` | iOS -> Browser (via server) | SDP offer |
| `answer` | Browser -> iOS (via server) | SDP answer |
| `candidate` | Bidirectional | ICE candidates for NAT traversal |
| `peer_joined` | Server -> iOS | Viewer has connected |
| `peer_left` | Server -> Either | Peer disconnected |

### Room Lifecycle

- One-to-one only (one creator, one viewer per room)
- 60-second grace period when iOS app is backgrounded -- room stays alive for reconnection
- Creator sends `rejoin` with saved room code when app returns to foreground

### Running the Server

```bash
cd frontend/samples/CameraAccess/server
npm install
npm start
```

## Configuration

In `Secrets.swift`:

```swift
static let webrtcSignalingURL = "ws://YOUR_MAC_IP:8080"
```

The signaling URL must be set for the feature to appear in the app. Supports both `ws://` and `wss://`.

### ICE Servers

- **STUN**: Google's public servers (`stun.l.google.com:19302`)
- **TURN**: Fetched from the signaling server's `/api/turn` endpoint (uses ExpressTURN free tier)
- Falls back to STUN-only if TURN fetch fails

### Video Settings

- Max bitrate: 2.5 Mbps
- Max framerate: 24 fps
- Video frames come directly from DAT SDK (no throttling -- WebRTC handles bitrate adaptation)

## Browser Viewer

Served at `http://<server>:8080/` from `server/public/index.html`.

- Enter room code to join
- Main video shows glasses POV, PiP shows browser camera (tap to swap)
- Mic and camera toggles
- Graceful fallback: camera denied -> audio-only; both denied -> view-only
- ICE candidate type logging (RELAY/STUN/HOST) for debugging

## Constraints

- **Mutual exclusion with Gemini Live**: WebRTC and Gemini cannot run simultaneously due to audio device conflicts. The UI disables one when the other is active.
- **Single viewer**: Only one browser viewer per room.
- **Background reconnect**: Works within the 60-second grace window. After that, the room is destroyed and a new session is needed.
