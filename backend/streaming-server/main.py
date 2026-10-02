"""
GlassLink 스트리밍 서버 — LiveKit WebRTC + 멀티테넌트

아키텍처:
  Android 앱 ─── LiveKit SDK (WebRTC) ──→ LiveKit Cloud ←── 브라우저 LiveKit JS
  이 서버: 테넌트 인증 + 토큰 발급 + 뷰어 페이지 + 시청자 통계

환경변수:
  LIVEKIT_URL        = wss://your-project.livekit.cloud
  LIVEKIT_API_KEY    = your_api_key
  LIVEKIT_API_SECRET = your_api_secret

실행:
  uvicorn main:app --host 0.0.0.0 --port 8000
"""

import json
import os
import sqlite3
import time
import uuid
from contextlib import contextmanager
from typing import Optional

import httpx
import jwt
from fastapi import FastAPI, HTTPException, Header, Depends
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import HTMLResponse
from fastapi.staticfiles import StaticFiles
from passlib.hash import bcrypt
from pydantic import BaseModel

app = FastAPI(title="GlassLink Stream Server")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

app.mount("/static", StaticFiles(directory="static"), name="static")

# ── LiveKit 설정 ───────────────────────────────────
LIVEKIT_URL        = os.getenv("LIVEKIT_URL",        "ws://localhost:7880")
LIVEKIT_API_KEY    = os.getenv("LIVEKIT_API_KEY",    "devkey")
LIVEKIT_API_SECRET = os.getenv("LIVEKIT_API_SECRET", "secret")
LIVEKIT_PUBLIC_URL = LIVEKIT_URL.replace("ws://", "wss://") if LIVEKIT_URL.startswith("ws://") else LIVEKIT_URL
# HTTP URL for REST API calls
LIVEKIT_HTTP_URL   = LIVEKIT_URL.replace("wss://", "https://").replace("ws://", "http://")

# ── SQLite DB ─────────────────────────────────────
DB_PATH = "glasslink.db"

def init_db():
    with sqlite3.connect(DB_PATH) as conn:
        conn.execute("""
            CREATE TABLE IF NOT EXISTS tenants (
                id          TEXT PRIMARY KEY,
                name        TEXT NOT NULL,
                api_key     TEXT UNIQUE NOT NULL,
                created_at  INTEGER NOT NULL
            )
        """)
        conn.execute("""
            CREATE TABLE IF NOT EXISTS rooms (
                room_id     TEXT PRIMARY KEY,
                tenant_id   TEXT NOT NULL,
                created_at  INTEGER NOT NULL,
                expires_at  INTEGER NOT NULL,
                FOREIGN KEY (tenant_id) REFERENCES tenants(id)
            )
        """)
        conn.commit()

init_db()

@contextmanager
def get_db():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    try:
        yield conn
    finally:
        conn.close()


# ── 테넌트 인증 의존성 ────────────────────────────
def require_tenant(x_api_key: str = Header(...)):
    """X-Api-Key 헤더로 테넌트 인증"""
    with get_db() as db:
        row = db.execute(
            "SELECT * FROM tenants WHERE api_key = ?", (x_api_key,)
        ).fetchone()
    if not row:
        raise HTTPException(status_code=401, detail="유효하지 않은 API 키입니다")
    return dict(row)


# ── LiveKit 토큰 생성 ─────────────────────────────
def make_livekit_token(room: str, identity: str, can_publish: bool, ttl: int = 3600) -> str:
    now = int(time.time())
    claims = {
        "exp": now + ttl,
        "nbf": now,
        "iss": LIVEKIT_API_KEY,
        "sub": identity,
        "jti": f"{identity}-{uuid.uuid4().hex[:6]}",
        "video": {
            "roomJoin":     True,
            "room":         room,
            "canPublish":   can_publish,
            "canSubscribe": True,
        },
    }
    return jwt.encode(claims, LIVEKIT_API_SECRET, algorithm="HS256")


def make_livekit_admin_token(room: str = "") -> str:
    """LiveKit RoomService API 호출용 관리자 토큰 (단기 60초)"""
    now = int(time.time())
    claims = {
        "exp": now + 60,
        "nbf": now,
        "iss": LIVEKIT_API_KEY,
        "sub": "server-admin",
        "jti": uuid.uuid4().hex,
        "video": {
            "roomAdmin": True,
            "room":      room,
        },
    }
    return jwt.encode(claims, LIVEKIT_API_SECRET, algorithm="HS256")


# ════════════════════════════════════════════════
# 관리자 API (테넌트 등록)
# ════════════════════════════════════════════════

ADMIN_KEY = os.getenv("ADMIN_KEY", "glasslink-admin-2026")

class TenantCreate(BaseModel):
    name: str

@app.post("/admin/tenants")
async def create_tenant(
    body: TenantCreate,
    x_admin_key: str = Header(...)
):
    """새 테넌트(고객사) 등록 — 관리자 전용"""
    if x_admin_key != ADMIN_KEY:
        raise HTTPException(status_code=403, detail="관리자 권한 없음")

    tenant_id = uuid.uuid4().hex[:12]
    api_key   = f"gl_{uuid.uuid4().hex}"

    with get_db() as db:
        db.execute(
            "INSERT INTO tenants (id, name, api_key, created_at) VALUES (?, ?, ?, ?)",
            (tenant_id, body.name, api_key, int(time.time()))
        )
        db.commit()

    return {
        "tenant_id": tenant_id,
        "name":      body.name,
        "api_key":   api_key,
        "message":   "이 api_key를 Android 앱의 TENANT_API_KEY 상수에 설정하세요"
    }

@app.get("/admin/tenants")
async def list_tenants(x_admin_key: str = Header(...)):
    """테넌트 목록 조회"""
    if x_admin_key != ADMIN_KEY:
        raise HTTPException(status_code=403, detail="관리자 권한 없음")
    with get_db() as db:
        rows = db.execute("SELECT id, name, created_at FROM tenants").fetchall()
    return [dict(r) for r in rows]


# ════════════════════════════════════════════════
# 스트리밍 API (테넌트 인증 필요)
# ════════════════════════════════════════════════

@app.post("/api/rooms/create")
async def create_room(
    host: str = "localhost:8000",
    public_host: str = "",
    tenant: dict = Depends(require_tenant)
):
    """방 생성 + LiveKit 퍼블리셔 토큰 반환 (테넌트 인증 필요)"""
    room_id   = f"{tenant['id']}_{uuid.uuid4().hex[:8]}"
    now       = int(time.time())
    expires   = now + 3600

    with get_db() as db:
        db.execute(
            "INSERT INTO rooms (room_id, tenant_id, created_at, expires_at) VALUES (?, ?, ?, ?)",
            (room_id, tenant["id"], now, expires)
        )
        db.commit()

    publisher_token = make_livekit_token(room_id, "glasses", can_publish=True)
    viewer_base     = f"https://{public_host}" if public_host else f"http://{host}"

    return {
        "room_id":         room_id,
        "publisher_token": publisher_token,
        "livekit_url":     LIVEKIT_URL,
        "viewer_url":      f"{viewer_base}/watch?room={room_id}",
        "expires_at":      expires,
    }


@app.get("/api/rooms/{room_id}/viewer-token")
async def viewer_token(room_id: str):
    """브라우저용 뷰어 토큰 발급"""
    with get_db() as db:
        row = db.execute(
            "SELECT * FROM rooms WHERE room_id = ?", (room_id,)
        ).fetchone()

    if not row:
        raise HTTPException(status_code=404, detail="존재하지 않는 방입니다")

    if int(time.time()) > row["expires_at"]:
        raise HTTPException(status_code=410, detail="만료된 링크입니다")

    token = make_livekit_token(room_id, f"viewer-{uuid.uuid4().hex[:4]}", can_publish=True)
    return {
        "token":       token,
        "livekit_url": LIVEKIT_PUBLIC_URL,
    }


@app.get("/api/rooms/{room_id}/stats")
async def room_stats(room_id: str):
    """방 통계 — LiveKit API로 실시간 참가자 수 조회"""
    with get_db() as db:
        row = db.execute("SELECT * FROM rooms WHERE room_id = ?", (room_id,)).fetchone()
    if not row:
        raise HTTPException(status_code=404, detail="방 없음")

    viewer_count = 0
    is_live      = False
    try:
        token = make_livekit_admin_token(room_id)
        async with httpx.AsyncClient(timeout=5.0) as client:
            resp = await client.post(
                f"{LIVEKIT_HTTP_URL}/twirp/livekit.RoomService/ListParticipants",
                headers={
                    "Authorization": f"Bearer {token}",
                    "Content-Type":  "application/json",
                },
                content=json.dumps({"room": room_id}).encode(),
            )
        if resp.status_code == 200:
            participants = resp.json().get("participants", [])
            is_live      = len(participants) > 0
            # glasses publisher(identity="glasses") 제외한 나머지가 시청자
            viewer_count = sum(1 for p in participants if p.get("identity", "") != "glasses")
    except Exception:
        pass

    return {
        "room_id":      room_id,
        "viewer_count": viewer_count,
        "is_live":      is_live,
        "expires_at":   row["expires_at"],
    }


# ── 시청자 페이지 ──────────────────────────────────
@app.get("/watch", response_class=HTMLResponse)
async def watch_page():
    with open("static/viewer.html", encoding="utf-8") as f:
        return f.read()


# ── 상태 확인 ──────────────────────────────────────
@app.get("/health")
async def health():
    with get_db() as db:
        tenant_count = db.execute("SELECT COUNT(*) FROM tenants").fetchone()[0]
        active_rooms = db.execute(
            "SELECT COUNT(*) FROM rooms WHERE expires_at > ?", (int(time.time()),)
        ).fetchone()[0]
    return {
        "status":       "ok",
        "livekit_url":  LIVEKIT_URL,
        "tenants":      tenant_count,
        "active_rooms": active_rooms,
    }
