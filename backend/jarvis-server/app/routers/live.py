import json
import secrets
from typing import Any, Optional

from fastapi import APIRouter, WebSocket, WebSocketDisconnect
from fastapi.responses import HTMLResponse

router = APIRouter(prefix="/live", tags=["live"])

_rooms: dict[str, dict[str, Optional[WebSocket]]] = {}


def _new_room_id() -> str:
    return secrets.token_hex(3)


async def _send(ws: Optional[WebSocket], payload: dict[str, Any]) -> None:
    if ws is not None:
        await ws.send_text(json.dumps(payload))


def _room(room_id: str) -> dict[str, Optional[WebSocket]]:
    return _rooms.setdefault(room_id, {"streamer": None, "viewer": None})


async def _leave(ws: WebSocket) -> None:
    empty_rooms = []
    for room_id, room in _rooms.items():
        if room.get("streamer") is ws:
            room["streamer"] = None
            await _send(room.get("viewer"), {"type": "peer_left"})
        if room.get("viewer") is ws:
            room["viewer"] = None
            await _send(room.get("streamer"), {"type": "peer_left"})
        if room.get("streamer") is None and room.get("viewer") is None:
            empty_rooms.append(room_id)
    for room_id in empty_rooms:
        _rooms.pop(room_id, None)


@router.websocket("/ws")
async def live_ws(websocket: WebSocket):
    await websocket.accept()
    current_room_id: Optional[str] = None
    role: Optional[str] = None
    try:
        while True:
            raw = await websocket.receive_text()
            message = json.loads(raw)
            msg_type = message.get("type")

            if msg_type == "create":
                current_room_id = _new_room_id()
                role = "streamer"
                room = _room(current_room_id)
                room["streamer"] = websocket
                await _send(websocket, {"type": "room_created", "room": current_room_id})
                continue

            if msg_type in {"join", "rejoin"}:
                current_room_id = str(message.get("room") or "")
                if not current_room_id or current_room_id not in _rooms:
                    await _send(websocket, {"type": "error", "message": "Room not found"})
                    continue

                role = "viewer"
                room = _room(current_room_id)
                room["viewer"] = websocket
                await _send(websocket, {"type": "room_joined", "room": current_room_id})
                await _send(room.get("streamer"), {"type": "peer_joined"})
                continue

            if current_room_id is None or current_room_id not in _rooms:
                await _send(websocket, {"type": "error", "message": "Room not found"})
                continue

            room = _room(current_room_id)
            target = room.get("viewer") if role == "streamer" else room.get("streamer")
            if msg_type in {"offer", "answer", "candidate"}:
                await _send(target, message)
            else:
                await _send(websocket, {"type": "error", "message": f"Unknown type: {msg_type}"})
    except WebSocketDisconnect:
        await _leave(websocket)
    except Exception:
        await _leave(websocket)
        raise


@router.get("/watch")
def watch() -> HTMLResponse:
    return HTMLResponse(_WATCH_HTML)


@router.get("/health")
def live_health():
    return {"status": "ok", "rooms": len(_rooms)}


_WATCH_HTML = """<!doctype html>
<html lang="ko">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Jarvis Live View</title>
  <style>
    html, body { margin: 0; height: 100%; background: #080808; color: #f4f4f4; font-family: system-ui, -apple-system, BlinkMacSystemFont, sans-serif; }
    main { min-height: 100%; display: grid; grid-template-rows: auto 1fr auto; }
    header { padding: 12px 16px; display: flex; justify-content: space-between; align-items: center; background: rgba(0,0,0,.72); }
    h1 { margin: 0; font-size: 16px; font-weight: 650; }
    #status { font-size: 13px; color: #bdbdbd; }
    #stage { display: grid; place-items: center; min-height: 0; }
    video { width: 100%; height: 100%; max-height: calc(100vh - 92px); object-fit: contain; background: #000; }
    footer { padding: 10px 16px; color: #aaa; font-size: 12px; background: rgba(0,0,0,.72); }
    .error { color: #ff7b7b; }
  </style>
</head>
<body>
<main>
  <header>
    <h1>Jarvis Live View</h1>
    <div id="status">connecting</div>
  </header>
  <section id="stage">
    <video id="video" autoplay playsinline controls muted></video>
  </section>
  <footer>공유자가 Live를 끄면 연결이 종료됩니다.</footer>
</main>
<script>
const statusEl = document.getElementById('status');
const videoEl = document.getElementById('video');
const params = new URLSearchParams(location.search);
const roomId = params.get('room');
let pc;
let ws;

function setStatus(text, error=false) {
  statusEl.textContent = text;
  statusEl.className = error ? 'error' : '';
}

function wsUrl() {
  const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
  return `${proto}//${location.host}/live/ws`;
}

async function start() {
  if (!roomId) {
    setStatus('room 파라미터가 없습니다', true);
    return;
  }
  pc = new RTCPeerConnection({
    iceServers: [{ urls: 'stun:stun.l.google.com:19302' }]
  });
  pc.ontrack = (event) => {
    const [stream] = event.streams;
    if (stream) videoEl.srcObject = stream;
    setStatus('live');
  };
  pc.onicecandidate = (event) => {
    if (event.candidate && ws?.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({
        type: 'candidate',
        candidate: event.candidate.candidate,
        sdpMid: event.candidate.sdpMid || '',
        sdpMLineIndex: event.candidate.sdpMLineIndex || 0
      }));
    }
  };
  pc.onconnectionstatechange = () => setStatus(pc.connectionState);

  ws = new WebSocket(wsUrl());
  ws.onopen = () => {
    setStatus('waiting');
    ws.send(JSON.stringify({ type: 'join', room: roomId }));
  };
  ws.onmessage = async (event) => {
    const msg = JSON.parse(event.data);
    if (msg.type === 'offer') {
      await pc.setRemoteDescription({ type: 'offer', sdp: msg.sdp });
      const answer = await pc.createAnswer();
      await pc.setLocalDescription(answer);
      ws.send(JSON.stringify({ type: 'answer', sdp: answer.sdp }));
    } else if (msg.type === 'candidate') {
      await pc.addIceCandidate({
        candidate: msg.candidate,
        sdpMid: msg.sdpMid || '',
        sdpMLineIndex: msg.sdpMLineIndex || 0
      });
    } else if (msg.type === 'peer_left') {
      setStatus('stream ended');
    } else if (msg.type === 'error') {
      setStatus(msg.message || 'error', true);
    }
  };
  ws.onerror = () => setStatus('signaling error', true);
  ws.onclose = () => setStatus('disconnected');
}

start();
</script>
</body>
</html>"""
