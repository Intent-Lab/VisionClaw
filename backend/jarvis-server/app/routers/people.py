import logging
import sys
from datetime import datetime, timezone
from typing import List, Optional
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException
from psycopg.types.json import Jsonb

from ..auth import require_api_key
from ..db import get_conn
from ..embeddings import embed_text
from ..face_embeddings import FaceQuality, embed_face_from_base64
from ..schemas import (
    PersonCreate,
    PersonFaceAddRequest,
    PersonFaceOut,
    PersonIdentifyRequest,
    PersonIdentifyResponse,
    PersonMatch,
    PersonOut,
    PersonSearchRequest,
    PersonUpdate,
)

router = APIRouter(
    prefix="/people",
    tags=["people"],
    dependencies=[Depends(require_api_key)],
)

# Every match attempt is logged with its full score vector -- the thresholds below were
# derived from these logs and should be re-tuned against them as more people enroll. Same
# pattern as app/routers/agent_flash.py's logger (dedicated handler, not root logger --
# uvicorn's own root config swallows plain logging.basicConfig() calls).
logger = logging.getLogger("jarvis.people")
logger.setLevel(logging.INFO)
if not logger.handlers:
    _handler = logging.StreamHandler(sys.stderr)
    _handler.setFormatter(logging.Formatter("%(asctime)s %(name)s %(levelname)s %(message)s"))
    logger.addHandler(_handler)
    logger.propagate = False

_PERSON_FIELDS = list(PersonOut.model_fields.keys())

# Face count 0 or >1 both come back as this "no usable embedding" error text so the
# root agent can relay it to the user verbatim instead of guessing which face was meant.
_NO_FACE_ERROR = "얼굴이 잘 안 보여요. 정면으로 다시 비춰주시겠어요?"
_MULTI_FACE_ERROR = "여러 사람이 보여서 정확히 인식할 수 없어요. 한 분만 나오게 다시 비춰주시겠어요?"


def _row_to_person(row: dict) -> PersonOut:
    return PersonOut(**{k: row[k] for k in _PERSON_FIELDS})


def _face_error(face_count: int) -> HTTPException:
    return HTTPException(422, _MULTI_FACE_ERROR if face_count > 1 else _NO_FACE_ERROR)


# ─── Match decision thresholds ────────────────────────────────────────────────
#
# Tuned against real logged score distributions from this deployment (jarvis.people
# "identify_person: top matches" lines, 2026-08-06 .. 2026-08-14):
#   confirmed same-person, good reference photo : 0.75, 0.87, 0.97
#   confirmed same-person, poor reference photo : 0.29 - 0.36  (7+ separate attempts)
#   confirmed different person                  : -0.01 - 0.14
#
# The previous design stated a flat 0.4 floor in the *language model's prompt*, which
# rejected that entire 0.29-0.36 band of genuine matches as strangers -- the reported
# "얼굴인식 정확도 떨어짐". The floor is now 0.25, just above the observed non-match
# ceiling, with a margin rule so a low-but-top score still has to clearly beat the
# runner-up before it is asserted as a confident identification.
_CONFIDENT_SCORE = 0.45          # unambiguous on its own, no margin needed
_MIN_SCORE = 0.25                # below this, treat as nobody we know
_MIN_MARGIN = 0.10               # between the two, must beat the next *person* by this


def _match_faces(embedding: List[float], top_k: int) -> List[PersonMatch]:
    """Best-scoring reference photo per person, ranked across people.

    Aggregating to one row per person before ranking is essential now that a person can
    have several enrolled photos: ranking raw face rows would let a person's own second
    photo occupy the runner-up slot and silently destroy the margin test in
    _decide_match, turning the clearest possible match into an "uncertain" one.

    Deliberately a sequential scan + aggregate rather than an HNSW index lookup: the
    index can rank individual face rows but cannot do the per-person max, and at this
    corpus size (tens of faces) the scan is trivial. Revisit if enrollment ever reaches
    the thousands.
    """
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT p.*,
                       MAX(1 - (f.embedding <=> %s::vector)) AS _score,
                       COUNT(*) AS _face_count
                FROM person_faces f
                JOIN people p ON p.id = f.person_id
                GROUP BY p.id
                ORDER BY _score DESC
                LIMIT %s
                """,
                (embedding, top_k),
            )
            rows = cur.fetchall()
    return [
        PersonMatch(
            person=_row_to_person(r),
            score=float(r["_score"]),
            face_count=int(r["_face_count"]),
        )
        for r in rows
    ]


def _decide_match(matches: List[PersonMatch]) -> tuple:
    """Returns (decision, guidance) for a ranked, per-person match list."""
    if not matches or matches[0].score < _MIN_SCORE:
        return "no_match", "저장된 분 중에 일치하는 사람이 없어요. 처음 뵙는 분 같습니다."

    top = matches[0]
    runner_up = matches[1].score if len(matches) > 1 else -1.0

    if top.score >= _CONFIDENT_SCORE or (top.score - runner_up) >= _MIN_MARGIN:
        # A confident match off a single mediocre reference photo is exactly the case that
        # degrades over time -- prompt for a second photo while the person is still in frame.
        if top.face_count < 2:
            return (
                "confident",
                f"{top.person.name}님이 맞습니다. (등록된 얼굴 사진이 1장뿐이라 인식이 불안정할 수 있어요 "
                f"-- 지금 한 장 더 등록해두면 다음부터 훨씬 잘 알아봅니다.)",
            )
        return "confident", f"{top.person.name}님이 맞습니다."

    others = ", ".join(m.person.name for m in matches[1:3])
    return (
        "uncertain",
        f"{top.person.name}님인 것 같은데 확신이 안 서요({others} 님일 수도 있어요). "
        f"맞는지 여쭤보거나, 조금 더 가까이서 정면으로 다시 비춰주시겠어요?",
    )


@router.post("/identify", response_model=PersonIdentifyResponse)
def identify_person(body: PersonIdentifyRequest) -> PersonIdentifyResponse:
    embedding, face_count, quality = embed_face_from_base64(body.image_base64)
    if embedding is None:
        logger.info("identify_person: no usable embedding (face_count=%d)", face_count)
        raise _face_error(face_count)

    matches = _match_faces(embedding, body.top_k)
    decision, guidance = _decide_match(matches)
    logger.info(
        "identify_person: decision=%s probe=%s matches=%s",
        decision,
        quality.as_dict() if quality else None,
        [(m.person.name, round(m.score, 4), m.face_count) for m in matches],
    )
    return PersonIdentifyResponse(
        decision=decision,
        guidance=guidance,
        matches=matches,
        probe_quality=quality.as_dict() if quality else None,
    )


def _find_existing_person(cur, name: str, org: Optional[str]):
    # Same (name, org)-aware soft match as memory.py's _upsert_person_from_entity -- a person
    # met via business card (name+org, no face) and later saved via save_person(name,
    # attach_current_photo=true) (face, usually no org yet) are the same real person and must
    # land on the same row, or identify_person can never find anyone who was first met through
    # a business card, and a duplicate no-face/face pair accumulates per person.
    #
    # Whitespace is stripped (not just lowercased) on both sides before comparing: a real
    # duplicate 김윤섭 pair was created in production on 2026-08-14 purely because one save
    # spelled the org "DH 배터리" and the earlier one "DH배터리". Korean org/person names get
    # spaced inconsistently by both OCR and speech-to-text, so exact-string org equality is
    # not a safe dedup key.
    cur.execute(
        """
        SELECT id FROM people
        WHERE regexp_replace(lower(name), '\\s+', '', 'g')
              = regexp_replace(lower(%s), '\\s+', '', 'g')
          AND (
                %s::text IS NULL
                OR org IS NULL
                OR regexp_replace(lower(org), '\\s+', '', 'g')
                   = regexp_replace(lower(%s), '\\s+', '', 'g')
              )
        ORDER BY (org IS NOT NULL) DESC, updated_at DESC
        LIMIT 1
        """,
        (name, org, org),
    )
    return cur.fetchone()


def _insert_face(cur, person_id, embedding: List[float], quality: Optional[FaceQuality], source: Optional[str]):
    """Adds one reference photo for a person, and mirrors it onto people.face_embedding.

    person_faces is the source of truth for matching; the people.face_embedding column is
    kept in sync with the most recent face purely so existing reads of that column (and
    "does this person have a face at all" checks) keep working during and after the
    migration -- nothing matches against it any more.
    """
    cur.execute(
        """
        INSERT INTO person_faces (person_id, embedding, quality, source)
        VALUES (%s, %s::vector, %s, %s)
        RETURNING *
        """,
        (person_id, embedding, Jsonb(quality.as_dict() if quality else {}), source),
    )
    row = cur.fetchone()
    cur.execute(
        "UPDATE people SET face_embedding = %s::vector, updated_at = now() WHERE id = %s",
        (embedding, person_id),
    )
    return row


@router.post("", response_model=PersonOut, status_code=201)
def create_person(body: PersonCreate) -> PersonOut:
    face_embedding = body.face_embedding
    face_quality = None
    if face_embedding is None and body.image_base64:
        face_embedding, face_count, face_quality = embed_face_from_base64(body.image_base64)
        if face_embedding is None:
            raise _face_error(face_count)
        # Refuse a poor enrollment photo instead of storing it. A bad reference is worse
        # than no reference: it is invisible at save time (the save "succeeds"), and then
        # silently caps every future identify of that person -- exactly what the logged
        # 0.29-0.36 same-person band was. Asking for one better photo now is far cheaper.
        if face_quality is not None and not face_quality.is_good_enough_to_enroll:
            logger.info(
                "create_person: rejected low-quality enrollment photo name=%s quality=%s",
                body.name,
                face_quality.as_dict(),
            )
            raise HTTPException(422, face_quality.rejection_reason())

    with get_conn() as conn:
        with conn.cursor() as cur:
            existing = _find_existing_person(cur, body.name, body.org)
            if existing:
                cur.execute(
                    """
                    UPDATE people SET
                        aliases = (
                            SELECT ARRAY(SELECT DISTINCT x FROM unnest(aliases || %s::text[]) AS x WHERE x <> '')
                        ),
                        org = COALESCE(%s, org),
                        role = COALESCE(%s, role),
                        phone = COALESCE(%s, phone),
                        email = COALESCE(%s, email),
                        address = COALESCE(%s, address),
                        notes_summary = COALESCE(%s, notes_summary),
                        first_met_at = LEAST(COALESCE(first_met_at, %s), COALESCE(%s, first_met_at, now())),
                        last_met_at = GREATEST(COALESCE(last_met_at, %s), COALESCE(%s, last_met_at, now())),
                        metadata = metadata || %s,
                        updated_at = now()
                    WHERE id = %s
                    RETURNING *
                    """,
                    (
                        body.aliases,
                        body.org,
                        body.role,
                        body.phone,
                        body.email,
                        body.address,
                        body.notes_summary,
                        body.first_met_at,
                        body.first_met_at,
                        body.last_met_at,
                        body.last_met_at,
                        Jsonb(body.metadata),
                        existing["id"],
                    ),
                )
                row = cur.fetchone()
                # Adds to this person's reference set rather than replacing it -- re-saving a
                # known person is the main way their recognition improves over time, so an
                # extra angle/lighting sample is exactly what we want to keep.
                if face_embedding is not None:
                    _insert_face(cur, row["id"], face_embedding, face_quality, "save_person")
                    cur.execute("SELECT * FROM people WHERE id = %s", (row["id"],))
                    row = cur.fetchone()
                logger.info(
                    "create_person: merged into existing person id=%s name=%s added_face=%s",
                    row["id"],
                    body.name,
                    face_embedding is not None,
                )
                conn.commit()
                return _row_to_person(row)

            cur.execute(
                """
                INSERT INTO people
                    (name, aliases, org, role, phone, email, address, first_met_at, last_met_at,
                     face_embedding, notes_summary, metadata)
                VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
                RETURNING *
                """,
                (
                    body.name,
                    body.aliases,
                    body.org,
                    body.role,
                    body.phone,
                    body.email,
                    body.address,
                    body.first_met_at,
                    body.last_met_at,
                    face_embedding,
                    body.notes_summary,
                    Jsonb(body.metadata),
                ),
            )
            row = cur.fetchone()
            if face_embedding is not None:
                _insert_face(cur, row["id"], face_embedding, face_quality, "save_person")
                cur.execute("SELECT * FROM people WHERE id = %s", (row["id"],))
                row = cur.fetchone()
            captured_at = body.first_met_at or body.last_met_at or datetime.now(timezone.utc)
            memory_text = "\n".join(
                part
                for part in [
                    f"사람: {body.name}",
                    f"별칭: {', '.join(body.aliases)}" if body.aliases else None,
                    f"소속: {body.org}" if body.org else None,
                    f"직책: {body.role}" if body.role else None,
                    f"메모: {body.notes_summary}" if body.notes_summary else None,
                ]
                if part
            )
            cur.execute(
                """
                INSERT INTO memories
                    (captured_at, text, embedding, related_person_ids,
                     source, metadata)
                VALUES (%s, %s, %s, %s, 'derived', %s)
                """,
                (
                    captured_at,
                    memory_text,
                    embed_text(memory_text),
                    [row["id"]],
                    Jsonb(
                        {
                            "memory_type": "person_profile",
                            "origin_person_id": str(row["id"]),
                        }
                    ),
                ),
            )
        conn.commit()
    return _row_to_person(row)


@router.get("", response_model=List[PersonOut])
def list_people(limit: int = 100, offset: int = 0) -> List[PersonOut]:
    # Powers the app's Settings > 저장된 사람 list -- editing needs a browsable list, not just
    # name/face search, since the whole point is to find and fix a person whose stored name is
    # wrong or ambiguous.
    limit = max(1, min(limit, 200))
    offset = max(0, offset)
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT * FROM people ORDER BY updated_at DESC LIMIT %s OFFSET %s",
                (limit, offset),
            )
            rows = cur.fetchall()
    return [_row_to_person(row) for row in rows]


@router.get("/{person_id}", response_model=PersonOut)
def get_person(person_id: UUID) -> PersonOut:
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT * FROM people WHERE id = %s", (person_id,))
            row = cur.fetchone()
            if not row:
                raise HTTPException(404, "person not found")
    return _row_to_person(row)


@router.get("/{person_id}/faces", response_model=List[PersonFaceOut])
def list_person_faces(person_id: UUID) -> List[PersonFaceOut]:
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT id, person_id, quality, source, created_at FROM person_faces "
                "WHERE person_id = %s ORDER BY created_at DESC",
                (person_id,),
            )
            rows = cur.fetchall()
    return [PersonFaceOut(**row) for row in rows]


@router.post("/{person_id}/faces", response_model=PersonFaceOut, status_code=201)
def add_person_face(person_id: UUID, body: PersonFaceAddRequest) -> PersonFaceOut:
    """Enrolls one more reference photo for a person who is already saved.

    This is the main accuracy lever available to the user. ArcFace matches a single probe
    against a single stored vector, so recognition is capped by how well the stored photos
    happen to cover the angle/lighting the person is later seen in -- production logs showed
    the same person scoring 0.29-0.36 off one poor reference and 0.75-0.87 off a good one.
    Adding a few photos taken at different moments raises the per-person maximum in
    _match_faces and is what makes recognition get better with use rather than staying
    stuck at whatever the first capture happened to look like.
    """
    embedding, face_count, quality = embed_face_from_base64(body.image_base64)
    if embedding is None:
        raise _face_error(face_count)
    if quality is not None and not quality.is_good_enough_to_enroll:
        logger.info(
            "add_person_face: rejected low-quality photo person_id=%s quality=%s",
            person_id,
            quality.as_dict(),
        )
        raise HTTPException(422, quality.rejection_reason())

    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT id FROM people WHERE id = %s", (person_id,))
            if not cur.fetchone():
                raise HTTPException(404, "person not found")
            row = _insert_face(cur, person_id, embedding, quality, body.source or "add_person_face")
            cur.execute("SELECT COUNT(*) AS n FROM person_faces WHERE person_id = %s", (person_id,))
            total = cur.fetchone()["n"]
        conn.commit()
    logger.info("add_person_face: person_id=%s total_faces=%d quality=%s", person_id, total, quality.as_dict())
    return PersonFaceOut(
        id=row["id"],
        person_id=row["person_id"],
        quality=row["quality"],
        source=row["source"],
        created_at=row["created_at"],
    )


@router.patch("/{person_id}", response_model=PersonOut)
def update_person(person_id: UUID, body: PersonUpdate) -> PersonOut:
    # Direct field-by-field edit -- deliberately NOT the COALESCE-merge semantics create_person
    # uses for its dedup path. Only fields the caller actually set are touched (model_fields_set,
    # not "is not None") so a correction like "이메일 빼줘" (explicit null) can clear a field,
    # while every field the caller didn't mention stays exactly as-is. Powers both the voice
    # update_person tool and the Settings edit screen -- same endpoint, same semantics either way.
    set_fields = body.model_fields_set
    if not set_fields:
        raise HTTPException(400, "no fields to update")
    if "name" in set_fields and not body.name:
        raise HTTPException(422, "name cannot be cleared")

    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT * FROM people WHERE id = %s", (person_id,))
            existing = cur.fetchone()
            if not existing:
                raise HTTPException(404, "person not found")

            updates = {field: getattr(body, field) for field in set_fields}
            columns = list(updates.keys())
            set_clause = ", ".join(f"{col} = %s" for col in columns)
            cur.execute(
                f"""
                UPDATE people SET {set_clause}, updated_at = now()
                WHERE id = %s
                RETURNING *
                """,
                [updates[col] for col in columns] + [person_id],
            )
            row = cur.fetchone()
        conn.commit()
    logger.info("update_person: id=%s fields=%s", person_id, columns)
    return _row_to_person(row)


@router.post("/search", response_model=List[PersonMatch])
def search_people(body: PersonSearchRequest) -> List[PersonMatch]:
    if body.face_embedding is None and not body.query:
        raise HTTPException(400, "either face_embedding or query is required")

    if body.face_embedding is not None:
        return _match_faces(body.face_embedding, body.top_k)

    like = f"%{body.query}%"
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT *, 1.0::float AS _score
                FROM people
                WHERE name ILIKE %s
                   OR EXISTS (SELECT 1 FROM unnest(aliases) a WHERE a ILIKE %s)
                   OR org ILIKE %s
                LIMIT %s
                """,
                (like, like, like, body.top_k),
            )
            rows = cur.fetchall()

    return [
        PersonMatch(person=_row_to_person(r), score=float(r["_score"]))
        for r in rows
    ]
