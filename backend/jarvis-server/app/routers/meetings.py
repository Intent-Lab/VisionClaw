import json
from datetime import datetime, timezone
from pathlib import Path
from typing import List, Optional
from uuid import UUID
from uuid import uuid4

from fastapi import APIRouter, Depends, File, Form, HTTPException, UploadFile
from fastapi.concurrency import run_in_threadpool
from psycopg.types.json import Jsonb

from ..auth import require_api_key
from ..config import settings
from ..db import get_conn
from ..embeddings import embed_text
from ..meeting_ai import summarize_transcript, transcribe_audio
from ..schemas import MeetingCreate, MeetingOut, MeetingSearchRequest, MeetingUpdate

router = APIRouter(
    prefix="/meetings",
    tags=["meetings"],
    dependencies=[Depends(require_api_key)],
)

_MEETING_FIELDS = list(MeetingOut.model_fields.keys())
_RECORDING_DIR = Path(__file__).resolve().parents[2] / "data" / "meeting-recordings"
_MAX_AUDIO_BYTES = 25 * 1024 * 1024


def _row_to_meeting(row: dict) -> MeetingOut:
    return MeetingOut(**{k: row[k] for k in _MEETING_FIELDS})


def _validate_person_ids(cur, person_ids: List[UUID]) -> None:
    # person_ids previously went straight into meetings/memories with no existence check --
    # any UUID (stale, mistyped, or hallucinated by the root agent) was silently accepted,
    # producing a meeting whose participants can never actually be resolved via people.
    if not person_ids:
        return
    cur.execute("SELECT id FROM people WHERE id = ANY(%s::uuid[])", (person_ids,))
    found = {row["id"] for row in cur.fetchall()}
    missing = [str(pid) for pid in person_ids if pid not in found]
    if missing:
        raise HTTPException(
            422,
            f"존재하지 않는 사람 ID가 있습니다: {', '.join(missing)}. 참석자를 먼저 저장하거나 person_id를 다시 확인해주세요.",
        )


def _meeting_memory_text(
    title: Optional[str],
    summary: Optional[str],
    transcript: Optional[str],
    location: Optional[str],
    decisions: Optional[List[str]] = None,
    action_items: Optional[List[str]] = None,
) -> str:
    return "\n".join(
        part
        for part in [
            f"미팅: {title}" if title else "미팅 기록",
            f"요약: {summary}" if summary else None,
            f"장소: {location}" if location else None,
            f"결정사항: {', '.join(decisions or [])}" if decisions else None,
            f"할일: {', '.join(action_items or [])}" if action_items else None,
            f"원문: {transcript}" if transcript else None,
        ]
        if part
    )


@router.get("", response_model=List[MeetingOut])
def list_meetings(limit: int = 30, offset: int = 0) -> List[MeetingOut]:
    limit = max(1, min(limit, 100))
    offset = max(0, offset)
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT *
                FROM meetings
                ORDER BY started_at DESC NULLS LAST, created_at DESC
                LIMIT %s OFFSET %s
                """,
                (limit, offset),
            )
            rows = cur.fetchall()
    return [_row_to_meeting(row) for row in rows]


@router.post("", response_model=MeetingOut, status_code=201)
def create_meeting(body: MeetingCreate) -> MeetingOut:
    summary_embedding = embed_text(body.summary) if body.summary else None
    with get_conn() as conn:
        with conn.cursor() as cur:
            _validate_person_ids(cur, body.person_ids)
            cur.execute(
                """
                INSERT INTO meetings
                    (title, person_ids, started_at, ended_at, location,
                     summary, summary_embedding, raw_transcript, metadata)
                VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s)
                RETURNING *
                """,
                (
                    body.title,
                    body.person_ids,
                    body.started_at,
                    body.ended_at,
                    body.location,
                    body.summary,
                    summary_embedding,
                    body.raw_transcript,
                    Jsonb(body.metadata),
                ),
            )
            row = cur.fetchone()

            memory_text = _meeting_memory_text(
                body.title,
                body.summary,
                body.raw_transcript,
                body.location,
            )
            cur.execute(
                """
                INSERT INTO memories
                    (captured_at, text, embedding, related_person_ids,
                     related_meeting_id, source, metadata)
                VALUES (%s, %s, %s, %s, %s, 'derived', %s)
                """,
                (
                    body.started_at,
                    memory_text,
                    embed_text(memory_text),
                    body.person_ids,
                    row["id"],
                    Jsonb(
                        {
                            "memory_type": "meeting",
                            "origin_meeting_id": str(row["id"]),
                        }
                    ),
                ),
            )

            if body.person_ids:
                # Touch first_met_at / last_met_at on each person.
                cur.execute(
                    """
                    UPDATE people SET
                        last_met_at  = GREATEST(COALESCE(last_met_at,  %s), %s),
                        first_met_at = LEAST(   COALESCE(first_met_at, %s), %s),
                        updated_at   = now()
                    WHERE id = ANY(%s::uuid[])
                    """,
                    (
                        body.started_at, body.started_at,
                        body.started_at, body.started_at,
                        body.person_ids,
                    ),
                )
        conn.commit()
    return _row_to_meeting(row)


@router.post("/recordings", status_code=201)
async def create_meeting_from_recording(
    audio: UploadFile = File(...),
    title: str = Form(""),
    started_at: str = Form(""),
    ended_at: str = Form(""),
    person_ids: str = Form("[]"),
):
    suffix = Path(audio.filename or "meeting.wav").suffix.lower()
    if suffix not in {".wav", ".mp3", ".m4a", ".mp4", ".webm", ".mpeg", ".mpga"}:
        raise HTTPException(400, "unsupported audio format")

    audio_bytes = await audio.read(_MAX_AUDIO_BYTES + 1)
    if not audio_bytes:
        raise HTTPException(400, "empty audio file")
    if len(audio_bytes) > _MAX_AUDIO_BYTES:
        raise HTTPException(413, "audio file exceeds 25 MB")

    _RECORDING_DIR.mkdir(parents=True, exist_ok=True)
    filename = f"{uuid4()}{suffix}"
    path = _RECORDING_DIR / filename
    path.write_bytes(audio_bytes)

    try:
        parsed_person_ids = [UUID(value) for value in json.loads(person_ids)]
    except (ValueError, TypeError, json.JSONDecodeError):
        raise HTTPException(400, "person_ids must be a JSON UUID array")

    # Validate before the paid transcription/summarization calls below, not after -- no point
    # burning that cost on a request that's going to fail anyway.
    with get_conn() as conn:
        with conn.cursor() as cur:
            _validate_person_ids(cur, parsed_person_ids)

    try:
        started = datetime.fromisoformat(started_at) if started_at else datetime.now(timezone.utc)
        ended = datetime.fromisoformat(ended_at) if ended_at else datetime.now(timezone.utc)
        transcript = await run_in_threadpool(transcribe_audio, path)
        if not transcript:
            raise HTTPException(422, "no speech was transcribed")
        summary_data = await run_in_threadpool(summarize_transcript, transcript, title)
    except HTTPException:
        raise
    except Exception as exc:
        raise HTTPException(502, f"meeting AI processing failed: {exc}") from exc

    meeting_title = summary_data.get("title") or title or "회의 녹음"
    summary = summary_data.get("summary") or transcript[:500]
    metadata = {
        "recording_filename": filename,
        "recording_path": str(path),
        "recording_mime_type": audio.content_type or "audio/wav",
        "recording_size_bytes": len(audio_bytes),
        "transcription_model": settings.openai_transcription_model,
        "summary_model": settings.openai_summary_model,
        "markdown_summary": summary_data.get("markdown_summary", ""),
        "decisions": summary_data.get("decisions", []),
        "action_items": summary_data.get("action_items", []),
        "people": summary_data.get("people", []),
        "companies": summary_data.get("companies", []),
        "keywords": summary_data.get("keywords", []),
    }

    meeting_embedding = embed_text(summary)
    memory_text = "\n".join(
        [
            f"미팅: {meeting_title}",
            f"요약: {summary}",
            f"결정사항: {', '.join(metadata['decisions'])}",
            f"할일: {', '.join(metadata['action_items'])}",
            f"원문: {transcript}",
        ]
    )
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                INSERT INTO meetings
                    (title, person_ids, started_at, ended_at, summary,
                     summary_embedding, raw_transcript, metadata)
                VALUES (%s, %s, %s, %s, %s, %s, %s, %s)
                RETURNING *
                """,
                (
                    meeting_title,
                    parsed_person_ids,
                    started,
                    ended,
                    summary,
                    meeting_embedding,
                    transcript,
                    Jsonb(metadata),
                ),
            )
            meeting = cur.fetchone()
            cur.execute(
                """
                INSERT INTO memories
                    (captured_at, text, embedding, related_person_ids,
                     related_meeting_id, source, metadata)
                VALUES (%s, %s, %s, %s, %s, 'voice', %s)
                RETURNING *
                """,
                (
                    started,
                    memory_text,
                    embed_text(memory_text),
                    parsed_person_ids,
                    meeting["id"],
                    Jsonb(
                        {
                            "memory_type": "meeting_recording",
                            "origin_meeting_id": str(meeting["id"]),
                            **metadata,
                        }
                    ),
                ),
            )
            memory = cur.fetchone()
        conn.commit()

    return {
        "meeting": _row_to_meeting(meeting).model_dump(mode="json"),
        "memory_id": str(memory["id"]),
        "summary": summary_data,
        "transcript": transcript,
    }


@router.get("/{meeting_id}", response_model=MeetingOut)
def get_meeting(meeting_id: UUID) -> MeetingOut:
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT * FROM meetings WHERE id = %s", (meeting_id,))
            row = cur.fetchone()
            if not row:
                raise HTTPException(404, "meeting not found")
    return _row_to_meeting(row)


@router.put("/{meeting_id}", response_model=MeetingOut)
def update_meeting(meeting_id: UUID, body: MeetingUpdate) -> MeetingOut:
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT * FROM meetings WHERE id = %s", (meeting_id,))
            existing = cur.fetchone()
            if not existing:
                raise HTTPException(404, "meeting not found")

            metadata = dict(existing["metadata"] or {})
            if body.metadata:
                metadata.update(body.metadata)

            title = body.title if body.title is not None else existing["title"]
            started_at = body.started_at or existing["started_at"]
            ended_at = body.ended_at if body.ended_at is not None else existing["ended_at"]
            location = body.location if body.location is not None else existing["location"]
            summary = body.summary if body.summary is not None else existing["summary"]
            raw_transcript = (
                body.raw_transcript if body.raw_transcript is not None else existing["raw_transcript"]
            )
            decisions = metadata.get("decisions") if isinstance(metadata.get("decisions"), list) else []
            action_items = metadata.get("action_items") if isinstance(metadata.get("action_items"), list) else []

            cur.execute(
                """
                UPDATE meetings
                SET title = %s,
                    started_at = %s,
                    ended_at = %s,
                    location = %s,
                    summary = %s,
                    summary_embedding = %s,
                    raw_transcript = %s,
                    metadata = %s
                WHERE id = %s
                RETURNING *
                """,
                (
                    title,
                    started_at,
                    ended_at,
                    location,
                    summary,
                    embed_text(summary) if summary else None,
                    raw_transcript,
                    Jsonb(metadata),
                    meeting_id,
                ),
            )
            updated = cur.fetchone()

            memory_text = _meeting_memory_text(
                title,
                summary,
                raw_transcript,
                location,
                decisions=decisions,
                action_items=action_items,
            )
            cur.execute(
                """
                UPDATE memories
                SET captured_at = %s,
                    text = %s,
                    embedding = %s,
                    metadata = metadata || %s
                WHERE related_meeting_id = %s
                """,
                (
                    started_at,
                    memory_text,
                    embed_text(memory_text),
                    Jsonb({"origin_meeting_id": str(meeting_id)}),
                    meeting_id,
                ),
            )
        conn.commit()
    return _row_to_meeting(updated)


@router.delete("/{meeting_id}", status_code=204)
def delete_meeting(meeting_id: UUID):
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT metadata FROM meetings WHERE id = %s", (meeting_id,))
            row = cur.fetchone()
            if not row:
                raise HTTPException(404, "meeting not found")
            metadata = dict(row["metadata"] or {})
            recording_path = metadata.get("recording_path")
            cur.execute("DELETE FROM memories WHERE related_meeting_id = %s", (meeting_id,))
            cur.execute("DELETE FROM meetings WHERE id = %s", (meeting_id,))
        conn.commit()
    if recording_path:
        try:
            path = Path(recording_path)
            if path.exists() and path.is_file():
                path.unlink()
        except OSError:
            pass
    return None


@router.post("/search", response_model=List[MeetingOut])
def search_meetings(body: MeetingSearchRequest) -> List[MeetingOut]:
    qvec = embed_text(body.query)
    sql = [
        "SELECT *, 1 - (summary_embedding <=> %s::vector) AS _score",
        "FROM meetings",
        "WHERE summary_embedding IS NOT NULL",
    ]
    params: list = [qvec]
    if body.time_from:
        sql.append("AND started_at >= %s"); params.append(body.time_from)
    if body.time_to:
        sql.append("AND started_at <= %s"); params.append(body.time_to)
    if body.person_id:
        sql.append("AND %s = ANY(person_ids)"); params.append(body.person_id)
    sql.append("ORDER BY summary_embedding <=> %s::vector LIMIT %s")
    params.extend([qvec, body.top_k])

    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute("\n".join(sql), params)
            rows = cur.fetchall()
    return [_row_to_meeting(r) for r in rows]
