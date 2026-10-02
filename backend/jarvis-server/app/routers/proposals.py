"""Proposal-points context endpoint.

This intentionally does NOT call an LLM server-side. It returns the assembled
RAG context (person + needs + recent meetings) so the *client's* Gemini Live
can synthesize the proposal points itself. Keeps server cost at $0 and lets the
voice agent speak the answer naturally.
"""
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException

from ..auth import require_api_key
from ..db import get_conn
from ..schemas import MeetingOut, NeedOut, PersonOut, ProposalContext

router = APIRouter(
    prefix="/people",
    tags=["proposals"],
    dependencies=[Depends(require_api_key)],
)

_PERSON_FIELDS = list(PersonOut.model_fields.keys())
_NEED_FIELDS = list(NeedOut.model_fields.keys())
_MEETING_FIELDS = list(MeetingOut.model_fields.keys())


@router.get("/{person_id}/context", response_model=ProposalContext)
def proposal_context(person_id: UUID, top_meetings: int = 5) -> ProposalContext:
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT * FROM people WHERE id = %s", (person_id,))
            person_row = cur.fetchone()
            if not person_row:
                raise HTTPException(404, "person not found")

            cur.execute(
                "SELECT * FROM needs WHERE person_id = %s ORDER BY created_at DESC",
                (person_id,),
            )
            need_rows = cur.fetchall()

            cur.execute(
                """
                SELECT * FROM meetings
                WHERE %s = ANY(person_ids)
                ORDER BY started_at DESC
                LIMIT %s
                """,
                (person_id, top_meetings),
            )
            meeting_rows = cur.fetchall()

    return ProposalContext(
        person=PersonOut(**{k: person_row[k] for k in _PERSON_FIELDS}),
        needs=[NeedOut(**{k: r[k] for k in _NEED_FIELDS}) for r in need_rows],
        recent_meetings=[
            MeetingOut(**{k: r[k] for k in _MEETING_FIELDS}) for r in meeting_rows
        ],
    )
