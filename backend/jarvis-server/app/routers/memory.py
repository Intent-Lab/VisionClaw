import base64
import re
from datetime import timezone
from pathlib import Path
from typing import List, Optional
from uuid import uuid4
from zoneinfo import ZoneInfo

from fastapi import APIRouter, Depends, HTTPException
from fastapi.responses import FileResponse
from psycopg.types.json import Jsonb

from ..auth import require_api_key
from ..db import get_conn
from ..embeddings import embed_text
from ..schemas import (
    LifeMemoryCreate,
    MemoryCreate,
    MemoryMatch,
    MemoryOut,
    MemoryRecentRequest,
    MemorySearchRequest,
    MemoryUpdate,
    PersonCandidate,
    UniversalSearchResult,
)

router = APIRouter(
    prefix="/memory",
    tags=["memory"],
    dependencies=[Depends(require_api_key)],
)

_MEMORY_FIELDS = list(MemoryOut.model_fields.keys())
_IMAGE_DIR = Path(__file__).resolve().parents[2] / "data" / "memory-images"
_IMAGE_EXTENSIONS = {
    "image/jpeg": ".jpg",
    "image/png": ".png",
    "image/webp": ".webp",
}
_KST = ZoneInfo("Asia/Seoul")
_ENTITY_TYPES = {"person", "company", "object", "place", "document", "business_card", "vehicle", "food"}


def _row_to_memory(row: dict) -> MemoryOut:
    return MemoryOut(**{k: row[k] for k in _MEMORY_FIELDS})


def _save_memory_image(image_base64: str, mime_type: str) -> dict:
    raw_base64 = image_base64.split(",", 1)[-1]
    image_bytes = base64.b64decode(raw_base64, validate=True)
    extension = _IMAGE_EXTENSIONS.get(mime_type, ".jpg")
    _IMAGE_DIR.mkdir(parents=True, exist_ok=True)
    filename = f"{uuid4()}{extension}"
    path = _IMAGE_DIR / filename
    path.write_bytes(image_bytes)
    return {
        "image_path": str(path),
        "image_filename": filename,
        "image_mime_type": mime_type,
        "image_size_bytes": len(image_bytes),
    }


def _delete_memory_image(metadata: dict) -> None:
    image_path = metadata.get("image_path")
    if not image_path:
        return
    try:
        path = Path(image_path)
        if path.exists() and path.is_file():
            path.unlink()
    except OSError:
        pass


def _captured_at_kst(captured_at) -> str:
    if captured_at.tzinfo is None:
        captured_at = captured_at.replace(tzinfo=timezone.utc)
    return captured_at.astimezone(_KST).isoformat()


def _clean_label(value: str) -> str:
    return re.sub(r"\s+", " ", value.strip())


def _auto_labels(body: LifeMemoryCreate) -> list[str]:
    source = f"{body.user_note}\n{body.ai_interpretation}\n{body.people_text or ''}".lower()
    labels = {_clean_label(label) for label in body.labels if _clean_label(label)}
    if "명함" in source or "business card" in source:
        labels.add("business_card")
        labels.add("document")
    if "자동차" in source or "차량" in source or "차 " in source:
        labels.add("vehicle")
    if "문서" in source or "계약서" in source or "견적서" in source:
        labels.add("document")
    return sorted(labels)


def _build_life_memory_text(user_note: str, ai_interpretation: str, people_text: Optional[str], labels: list[str], entities: list[dict]) -> str:
    text_parts = [
        f"사용자 메모: {user_note}",
        f"AI 장면 해석: {ai_interpretation}",
    ]
    if people_text:
        text_parts.append(f"관련 사람: {people_text}")
    if labels:
        text_parts.append(f"라벨: {', '.join(labels)}")
    if entities:
        text_parts.append(
            "객체: "
            + ", ".join(f"{entity['type']}={entity['label']}" for entity in entities)
        )
    return "\n".join(text_parts)


def _people_text_to_entity(people_text: Optional[str]) -> Optional[dict]:
    if not people_text:
        return None
    first = re.split(r"[,/\n]", people_text, maxsplit=1)[0]
    label = _clean_label(first)
    if not label:
        return None
    return {
        "type": "person",
        "label": label,
        "metadata": {"source": "people_text", "raw": people_text},
    }


def _normalize_entities(body: LifeMemoryCreate, labels: list[str]) -> list[dict]:
    normalized: list[dict] = []
    seen: set[tuple[str, str]] = set()

    def add(
        entity_type: str,
        label: str,
        metadata: Optional[dict] = None,
        aliases: Optional[List[str]] = None,
    ):
        entity_type = entity_type if entity_type in _ENTITY_TYPES else "object"
        label = _clean_label(label)
        if not label:
            return
        key = (entity_type, label.lower())
        if key in seen:
            return
        seen.add(key)
        normalized.append(
            {
                "type": entity_type,
                "label": label,
                "aliases": aliases or [],
                "metadata": metadata or {},
            }
        )

    for item in body.entities:
        if not isinstance(item, dict):
            continue
        add(
            str(item.get("type") or item.get("entity_type") or "object"),
            str(item.get("label") or item.get("name") or ""),
            item.get("metadata") if isinstance(item.get("metadata"), dict) else {},
            item.get("aliases") if isinstance(item.get("aliases"), list) else [],
        )

    people_entity = _people_text_to_entity(body.people_text)
    if people_entity:
        add(people_entity["type"], people_entity["label"], people_entity["metadata"])

    for label in labels:
        add("business_card" if label == "business_card" else "object", label, {"source": "label"})

    return normalized


def _upsert_entity(cur, entity: dict):
    searchable = f"{entity['type']} {entity['label']} {' '.join(entity.get('aliases') or [])}"
    cur.execute(
        """
        INSERT INTO entities (entity_type, label, aliases, metadata, embedding)
        VALUES (%s, %s, %s, %s, %s)
        ON CONFLICT (entity_type, label)
        DO UPDATE SET
            aliases = (
                SELECT ARRAY(
                    SELECT DISTINCT x
                    FROM unnest(entities.aliases || EXCLUDED.aliases) AS x
                    WHERE x <> ''
                )
            ),
            metadata = entities.metadata || EXCLUDED.metadata,
            embedding = EXCLUDED.embedding,
            updated_at = now()
        RETURNING id
        """,
        (
            entity["type"],
            entity["label"],
            entity.get("aliases") or [],
            Jsonb(entity.get("metadata") or {}),
            embed_text(searchable),
        ),
    )
    return cur.fetchone()["id"]


def _upsert_person_from_entity(cur, entity: dict, captured_at):
    if entity["type"] != "person":
        return None
    name = entity["label"]
    metadata = dict(entity.get("metadata") or {})
    metadata["source"] = metadata.get("source") or "life_memory_entity"
    # Business-card saves put company/role/phone/email/address here (see
    # ToolDeclarations.entityArrayProp on the Android side) -- these are the fields that used
    # to only survive as buried prose in a memory's ai_interpretation text and never made it
    # onto the person record itself.
    org = metadata.get("org") or metadata.get("company")
    role = metadata.get("role")
    phone = metadata.get("phone")
    email = metadata.get("email")
    address = metadata.get("address")

    # Name-only matching used to merge/miss people across different companies who share a
    # name. Prefer a same-org match; only fall back to a same-name/no-org match so we don't
    # spuriously create a new row every time org is missing from a later mention.
    cur.execute(
        """
        SELECT id FROM people
        WHERE lower(name) = lower(%s)
          AND (%s::text IS NULL OR org IS NULL OR lower(org) = lower(%s))
        ORDER BY (org IS NOT NULL) DESC, updated_at DESC
        LIMIT 1
        """,
        (name, org, org),
    )
    row = cur.fetchone()
    if row:
        cur.execute(
            """
            UPDATE people SET
                org = COALESCE(%s, org),
                role = COALESCE(%s, role),
                phone = COALESCE(%s, phone),
                email = COALESCE(%s, email),
                address = COALESCE(%s, address),
                last_met_at = GREATEST(COALESCE(last_met_at, %s), %s),
                updated_at = now()
            WHERE id = %s
            """,
            (org, role, phone, email, address, captured_at, captured_at, row["id"]),
        )
        return row["id"]
    cur.execute(
        """
        INSERT INTO people (name, aliases, org, role, phone, email, address,
                             first_met_at, last_met_at, notes_summary, metadata)
        VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
        RETURNING id
        """,
        (
            name,
            entity.get("aliases") or [],
            org,
            role,
            phone,
            email,
            address,
            captured_at,
            captured_at,
            metadata.get("raw") or "Saved from life memory",
            Jsonb(metadata),
        ),
    )
    row = cur.fetchone()
    if row:
        return row["id"]
    return None


@router.post("/save", response_model=MemoryOut, status_code=201)
def save_memory(body: MemoryCreate) -> MemoryOut:
    embedding = embed_text(body.text)
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                INSERT INTO memories
                    (captured_at, text, embedding, related_person_ids,
                     related_meeting_id, source, metadata)
                VALUES (%s, %s, %s, %s, %s, %s, %s)
                RETURNING *
                """,
                (
                    body.captured_at,
                    body.text,
                    embedding,
                    body.related_person_ids,
                    body.related_meeting_id,
                    body.source,
                    Jsonb(body.metadata),
                ),
            )
            row = cur.fetchone()
        conn.commit()
    return _row_to_memory(row)


@router.post("/recent", response_model=List[MemoryOut])
def recent_memories(body: MemoryRecentRequest) -> List[MemoryOut]:
    limit = max(1, min(body.limit, 100))
    sql = [
        "SELECT *",
        "FROM memories",
        "WHERE 1 = 1",
    ]
    params: list = []
    if body.memory_type:
        sql.append("AND metadata->>'memory_type' = %s")
        params.append(body.memory_type)
    sql.append("ORDER BY captured_at DESC, created_at DESC LIMIT %s")
    params.append(limit)

    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute("\n".join(sql), params)
            rows = cur.fetchall()

    return [_row_to_memory(r) for r in rows]


@router.get("/images/{filename}")
def memory_image(filename: str):
    if "/" in filename or "\\" in filename or ".." in filename:
        raise HTTPException(status_code=400, detail="invalid filename")
    path = _IMAGE_DIR / filename
    if not path.exists() or not path.is_file():
        raise HTTPException(status_code=404, detail="image not found")
    return FileResponse(path)


@router.post("/life/save", response_model=MemoryOut, status_code=201)
def save_life_memory(body: LifeMemoryCreate) -> MemoryOut:
    labels = _auto_labels(body)
    entities = _normalize_entities(body, labels)
    related_person_ids = list(body.related_person_ids)
    text = _build_life_memory_text(
        body.user_note,
        body.ai_interpretation,
        body.people_text,
        labels,
        entities,
    )
    embedding = embed_text(text)

    metadata = dict(body.metadata)
    metadata.update(
        {
            "memory_type": "life_scene",
            "user_note": body.user_note,
            "ai_interpretation": body.ai_interpretation,
            "people_text": body.people_text,
            "labels": labels,
            "entities": entities,
            "captured_at_kst": metadata.get("captured_at_kst") or _captured_at_kst(body.captured_at),
        }
    )
    if body.image_base64:
        metadata.update(_save_memory_image(body.image_base64, body.image_mime_type))

    with get_conn() as conn:
        with conn.cursor() as cur:
            entity_ids = []
            for entity in entities:
                entity_id = _upsert_entity(cur, entity)
                entity_ids.append((entity_id, entity))
                person_id = _upsert_person_from_entity(cur, entity, body.captured_at)
                if person_id and person_id not in related_person_ids:
                    related_person_ids.append(person_id)

            cur.execute(
                """
                INSERT INTO memories
                    (captured_at, text, embedding, related_person_ids,
                     related_meeting_id, source, metadata)
                VALUES (%s, %s, %s, %s, NULL, %s, %s)
                RETURNING *
                """,
                (
                    body.captured_at,
                    text,
                    embedding,
                    related_person_ids,
                    body.source,
                    Jsonb(metadata),
                ),
            )
            row = cur.fetchone()
            for entity_id, entity in entity_ids:
                cur.execute(
                    """
                    INSERT INTO memory_entities
                        (memory_id, entity_id, relation, confidence)
                    VALUES (%s, %s, %s, %s)
                    ON CONFLICT DO NOTHING
                    """,
                    (
                        row["id"],
                        entity_id,
                        "contains" if entity["type"] in {"business_card", "document", "object"} else "mentions",
                        1.0,
                    ),
                )
        conn.commit()
    return _row_to_memory(row)


@router.get("/{memory_id}", response_model=MemoryOut)
def get_memory(memory_id: str) -> MemoryOut:
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT * FROM memories WHERE id = %s", (memory_id,))
            row = cur.fetchone()
            if not row:
                raise HTTPException(404, "memory not found")
    return _row_to_memory(row)


@router.put("/{memory_id}", response_model=MemoryOut)
def update_memory(memory_id: str, body: MemoryUpdate) -> MemoryOut:
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT * FROM memories WHERE id = %s", (memory_id,))
            row = cur.fetchone()
            if not row:
                raise HTTPException(404, "memory not found")

            metadata = dict(row["metadata"] or {})
            if body.metadata:
                metadata.update(body.metadata)

            user_note = body.user_note if body.user_note is not None else metadata.get("user_note")
            ai_interpretation = (
                body.ai_interpretation
                if body.ai_interpretation is not None
                else metadata.get("ai_interpretation")
            )
            people_text = body.people_text if body.people_text is not None else metadata.get("people_text")

            if body.user_note is not None:
                metadata["user_note"] = body.user_note
            if body.ai_interpretation is not None:
                metadata["ai_interpretation"] = body.ai_interpretation
            if body.people_text is not None:
                metadata["people_text"] = body.people_text

            text = body.text if body.text is not None else row["text"]
            if metadata.get("memory_type") == "life_scene" and user_note and ai_interpretation:
                labels = metadata.get("labels") if isinstance(metadata.get("labels"), list) else []
                entities = metadata.get("entities") if isinstance(metadata.get("entities"), list) else []
                text = _build_life_memory_text(
                    user_note=user_note,
                    ai_interpretation=ai_interpretation,
                    people_text=people_text,
                    labels=labels,
                    entities=entities,
                )

            captured_at = body.captured_at or row["captured_at"]
            metadata["captured_at_kst"] = _captured_at_kst(captured_at)

            cur.execute(
                """
                UPDATE memories
                SET captured_at = %s,
                    text = %s,
                    embedding = %s,
                    metadata = %s
                WHERE id = %s
                RETURNING *
                """,
                (
                    captured_at,
                    text,
                    embed_text(text),
                    Jsonb(metadata),
                    memory_id,
                ),
            )
            updated = cur.fetchone()
        conn.commit()
    return _row_to_memory(updated)


@router.delete("/{memory_id}", status_code=204)
def delete_memory(memory_id: str):
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT metadata FROM memories WHERE id = %s", (memory_id,))
            row = cur.fetchone()
            if not row:
                raise HTTPException(404, "memory not found")
            metadata = dict(row["metadata"] or {})
            cur.execute("DELETE FROM memories WHERE id = %s", (memory_id,))
        conn.commit()
    _delete_memory_image(metadata)
    return None


def _search_memory_rows(body: MemorySearchRequest) -> list:
    qvec = embed_text(body.query)
    limit = max(1, min(body.top_k, 20))
    like = f"%{body.query}%"

    filters: list[str] = []
    filter_params: list = []
    if body.time_from:
        filters.append("m.captured_at >= %s")
        filter_params.append(body.time_from)
    if body.time_to:
        filters.append("m.captured_at <= %s")
        filter_params.append(body.time_to)
    if body.person_id:
        filters.append("%s = ANY(m.related_person_ids)")
        filter_params.append(body.person_id)
    filter_sql = " AND ".join(filters)
    if filter_sql:
        filter_sql = f"AND {filter_sql}"

    # A need ("안전성 인증서 요구") lives only in the needs table -- its wording never makes it
    # into any memory's text, so asking about the need itself used to match nothing at all. The
    # EXISTS below lets a memory be found by a need attached to its person or its meeting.
    #
    # related_meeting_id links a "meeting" memory row to its meetings record, but the memory's
    # own synthesized text (title/summary/location only, see _meeting_memory_text) can miss a
    # keyword that's actually in the meeting's full summary or raw_transcript. Joining meetings
    # directly and matching against its own fields too means a meeting is findable by its real
    # content, not just by whatever happened to make it into the synthesized memory text.
    exact_sql = f"""
        SELECT DISTINCT m.*, 1.15::float AS _score
        FROM memories m
        LEFT JOIN memory_entities me ON me.memory_id = m.id
        LEFT JOIN entities e ON e.id = me.entity_id
        LEFT JOIN meetings mt ON mt.id = m.related_meeting_id
        WHERE 1 = 1
          {filter_sql}
          AND (
              m.text ILIKE %s
              OR m.metadata->>'user_note' ILIKE %s
              OR m.metadata->>'ai_interpretation' ILIKE %s
              OR m.metadata->>'people_text' ILIKE %s
              OR EXISTS (
                  SELECT 1
                  FROM jsonb_array_elements_text(COALESCE(m.metadata->'labels', '[]'::jsonb)) AS label
                  WHERE label ILIKE %s
              )
              OR e.label ILIKE %s
              OR e.entity_type ILIKE %s
              OR mt.title ILIKE %s
              OR mt.summary ILIKE %s
              OR mt.raw_transcript ILIKE %s
              OR EXISTS (
                  SELECT 1
                  FROM needs n
                  WHERE n.text ILIKE %s
                    AND (
                        n.meeting_id = m.related_meeting_id
                        OR n.person_id = ANY(COALESCE(m.related_person_ids, ARRAY[]::uuid[]))
                    )
              )
          )
        ORDER BY m.captured_at DESC, m.created_at DESC
        LIMIT %s
    """

    vector_sql = f"""
        SELECT m.*, 1 - (m.embedding <=> %s::vector) AS _score
        FROM memories m
        WHERE m.embedding IS NOT NULL
          {filter_sql}
        ORDER BY m.embedding <=> %s::vector
        LIMIT %s
    """

    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                exact_sql,
                filter_params + [like] * 11 + [limit],
            )
            exact_rows = cur.fetchall()
            cur.execute(
                vector_sql,
                [qvec] + filter_params + [qvec, limit],
            )
            vector_rows = cur.fetchall()

    merged: dict = {}
    for row in exact_rows + vector_rows:
        memory_id = row["id"]
        score = float(row["_score"])
        if memory_id not in merged or score > merged[memory_id]["_score"]:
            merged[memory_id] = dict(row)

    rows = sorted(
        merged.values(),
        key=lambda r: (float(r["_score"]), r["captured_at"]),
        reverse=True,
    )[:limit]

    return rows


@router.post("/search", response_model=List[MemoryMatch])
def search_memories(body: MemorySearchRequest) -> List[MemoryMatch]:
    rows = _search_memory_rows(body)
    return [MemoryMatch(memory=_row_to_memory(r), score=float(r["_score"])) for r in rows]


# A person's needs are a strong claim ("this person wants X"), so they are only attached to a
# result that actually matched -- not to whatever filled out the top-N. Measured on this
# deployment: a genuine hit for a needs question scores 0.57+ ("박배터리가 뭘 원한다고 했지"
# 0.576, "박배터리 니즈" 0.572), while rows that merely padded the result set scored 0.38-0.47
# ("이유하" 0.388, "최셀 예산" 0.381). Without this floor those padding rows dragged an unrelated
# person's needs into the answer, which reads to the model as fact.
_NEEDS_MIN_SCORE = 0.5


@router.post("/universal-search", response_model=List[UniversalSearchResult])
def universal_search(body: MemorySearchRequest) -> List[UniversalSearchResult]:
    rows = _search_memory_rows(body)
    if not rows:
        return []

    result_payloads = []
    candidates_by_person_id: dict = {}
    with get_conn() as conn:
        with conn.cursor() as cur:
            for row in rows:
                person_ids = row["related_person_ids"] or []
                meeting_id = row["related_meeting_id"]
                people = []
                needs = []
                if person_ids:
                    cur.execute(
                        "SELECT * FROM people WHERE id = ANY(%s::uuid[])",
                        (person_ids,),
                    )
                    people = cur.fetchall()
                # Person needs and meeting needs are unioned rather than chosen between. The old
                # either/or meant a memory that happened to carry a meeting id returned only that
                # one meeting's needs, hiding everything else known about the same person -- so
                # "김윤섭이 뭘 원한다고 했지?" answered from a single meeting instead of all of them.
                # Also runs when only a meeting is linked; needs used to be skipped entirely then.
                if (person_ids or meeting_id) and float(row["_score"]) >= _NEEDS_MIN_SCORE:
                    cur.execute(
                        """
                        SELECT id, person_id, meeting_id, text, category,
                               confidence, metadata, created_at
                        FROM needs
                        WHERE person_id = ANY(%s::uuid[])
                           OR (%s::uuid IS NOT NULL AND meeting_id = %s::uuid)
                        ORDER BY created_at DESC
                        LIMIT 20
                        """,
                        (person_ids, meeting_id, meeting_id),
                    )
                    needs = cur.fetchall()

                meeting = None
                if row["related_meeting_id"]:
                    cur.execute(
                        "SELECT * FROM meetings WHERE id = %s",
                        (row["related_meeting_id"],),
                    )
                    meeting = cur.fetchone()

                cur.execute(
                    """
                    SELECT e.id, e.entity_type, e.label, e.aliases, e.metadata,
                           me.relation, me.confidence
                    FROM memory_entities me
                    JOIN entities e ON e.id = me.entity_id
                    WHERE me.memory_id = %s
                    ORDER BY me.confidence DESC, e.label
                    """,
                    (row["id"],),
                )
                entities = cur.fetchall()

                memory_score = float(row["_score"])
                memory_text = str(row["text"] or "")
                for person in people:
                    person_id = person["id"]
                    existing = candidates_by_person_id.get(person_id)
                    if existing is None or memory_score > existing["score"]:
                        candidates_by_person_id[person_id] = {
                            "person": person,
                            "score": memory_score,
                            "evidence": memory_text[:160],
                        }

                result_payloads.append(
                    {
                        "memory": _row_to_memory(row),
                        "score": memory_score,
                        "people": people,
                        "meeting": meeting,
                        "entities": entities,
                        "needs": needs,
                    }
                )

    person_candidates = [
        PersonCandidate(
            person=item["person"],
            score=float(item["score"]),
            evidence=item["evidence"],
        )
        for item in sorted(
            candidates_by_person_id.values(),
            key=lambda candidate: candidate["score"],
            reverse=True,
        )[: max(1, min(body.top_k, 5))]
    ]

    return [
        UniversalSearchResult(
            memory=payload["memory"],
            score=payload["score"],
            people=payload["people"],
            person_candidates=person_candidates,
            meeting=payload["meeting"],
            entities=payload["entities"],
            needs=payload["needs"],
        )
        for payload in result_payloads
    ]
