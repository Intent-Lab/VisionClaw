from typing import List
from uuid import UUID

from fastapi import APIRouter, Depends
from psycopg.types.json import Jsonb

from ..auth import require_api_key
from ..db import get_conn
from ..embeddings import embed_text
from ..schemas import NeedCreate, NeedOut

router = APIRouter(
    prefix="/needs",
    tags=["needs"],
    dependencies=[Depends(require_api_key)],
)

_NEED_FIELDS = list(NeedOut.model_fields.keys())


def _row_to_need(row: dict) -> NeedOut:
    return NeedOut(**{k: row[k] for k in _NEED_FIELDS})


@router.post("", response_model=NeedOut, status_code=201)
def create_need(body: NeedCreate) -> NeedOut:
    embedding = embed_text(body.text)
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                INSERT INTO needs
                    (person_id, meeting_id, text, category, embedding,
                     confidence, metadata)
                VALUES (%s, %s, %s, %s, %s, %s, %s)
                RETURNING *
                """,
                (
                    body.person_id,
                    body.meeting_id,
                    body.text,
                    body.category,
                    embedding,
                    body.confidence,
                    Jsonb(body.metadata),
                ),
            )
            row = cur.fetchone()
        conn.commit()
    return _row_to_need(row)


@router.get("/by-person/{person_id}", response_model=List[NeedOut])
def needs_by_person(person_id: UUID) -> List[NeedOut]:
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT * FROM needs WHERE person_id = %s ORDER BY created_at DESC",
                (person_id,),
            )
            rows = cur.fetchall()
    return [_row_to_need(r) for r in rows]
