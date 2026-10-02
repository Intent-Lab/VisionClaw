from datetime import datetime
from typing import List, Literal, Optional
from uuid import UUID

from pydantic import BaseModel, Field


# ─── People ───────────────────────────────────────────────────
class PersonCreate(BaseModel):
    name: str
    aliases: List[str] = Field(default_factory=list)
    org: Optional[str] = None
    role: Optional[str] = None
    phone: Optional[str] = None
    email: Optional[str] = None
    address: Optional[str] = None
    first_met_at: Optional[datetime] = None
    last_met_at: Optional[datetime] = None
    face_embedding: Optional[List[float]] = None
    # Raw photo, alternative to a pre-computed face_embedding -- the server detects the
    # face and computes the embedding itself (see app/face_embeddings.py). Ignored if
    # face_embedding is already provided.
    image_base64: Optional[str] = None
    image_mime_type: str = "image/jpeg"
    notes_summary: Optional[str] = None
    metadata: dict = Field(default_factory=dict)


class PersonOut(BaseModel):
    id: UUID
    name: str
    aliases: List[str]
    org: Optional[str]
    role: Optional[str]
    phone: Optional[str] = None
    email: Optional[str] = None
    address: Optional[str] = None
    first_met_at: Optional[datetime]
    last_met_at: Optional[datetime]
    notes_summary: Optional[str]
    metadata: dict
    created_at: datetime
    updated_at: datetime


class PersonUpdate(BaseModel):
    # All fields optional and unset-vs-null-aware (see PATCH /people/{id}): a field omitted from
    # the request body is left untouched, but a field explicitly sent as null clears it -- unlike
    # PersonCreate's merge-on-create semantics (COALESCE onto an existing row), this is a direct
    # field-by-field edit, so a user correcting a wrong phone number must be able to blank it out.
    name: Optional[str] = None
    aliases: Optional[List[str]] = None
    org: Optional[str] = None
    role: Optional[str] = None
    phone: Optional[str] = None
    email: Optional[str] = None
    address: Optional[str] = None
    notes_summary: Optional[str] = None


class PersonSearchRequest(BaseModel):
    face_embedding: Optional[List[float]] = None
    query: Optional[str] = None
    top_k: int = 5


class PersonMatch(BaseModel):
    person: PersonOut
    score: float
    # How many reference photos this person has enrolled. Surfaced so the caller can tell a
    # weak match caused by too few/poor references apart from a genuine stranger, and suggest
    # adding another photo rather than re-registering the same person from scratch.
    face_count: int = 0


class PersonIdentifyRequest(BaseModel):
    image_base64: str
    image_mime_type: str = "image/jpeg"
    top_k: int = 5


class PersonIdentifyResponse(BaseModel):
    # The scoring decision is made server-side rather than handed to the language model as raw
    # cosine floats. Real production logs showed the model being asked to reason about a
    # prompt-stated 0.4 threshold and rejecting genuine 0.29-0.36 matches as strangers -- the
    # numeric call belongs where it can be tuned against logged score distributions, and the
    # model should only relay the outcome.
    decision: Literal["confident", "uncertain", "no_match"]
    guidance: str
    matches: List[PersonMatch] = Field(default_factory=list)
    probe_quality: Optional[dict] = None


class PersonFaceOut(BaseModel):
    id: UUID
    person_id: UUID
    quality: dict
    source: Optional[str] = None
    created_at: datetime


class PersonFaceAddRequest(BaseModel):
    image_base64: str
    image_mime_type: str = "image/jpeg"
    source: Optional[str] = None


# ─── Meetings ─────────────────────────────────────────────────
class MeetingCreate(BaseModel):
    title: Optional[str] = None
    person_ids: List[UUID] = Field(default_factory=list)
    started_at: datetime
    ended_at: Optional[datetime] = None
    location: Optional[str] = None
    summary: Optional[str] = None
    raw_transcript: Optional[str] = None
    metadata: dict = Field(default_factory=dict)


class MeetingOut(BaseModel):
    id: UUID
    title: Optional[str]
    person_ids: List[UUID]
    started_at: datetime
    ended_at: Optional[datetime]
    location: Optional[str]
    summary: Optional[str]
    raw_transcript: Optional[str]
    metadata: dict
    created_at: datetime


class MeetingSearchRequest(BaseModel):
    query: str
    top_k: int = 5
    time_from: Optional[datetime] = None
    time_to: Optional[datetime] = None
    person_id: Optional[UUID] = None


class MeetingUpdate(BaseModel):
    title: Optional[str] = None
    started_at: Optional[datetime] = None
    ended_at: Optional[datetime] = None
    location: Optional[str] = None
    summary: Optional[str] = None
    raw_transcript: Optional[str] = None
    metadata: Optional[dict] = None


# ─── Memories ─────────────────────────────────────────────────
class MemoryCreate(BaseModel):
    captured_at: datetime
    text: str
    related_person_ids: List[UUID] = Field(default_factory=list)
    related_meeting_id: Optional[UUID] = None
    source: Literal["camera", "voice", "manual", "derived"] = "manual"
    metadata: dict = Field(default_factory=dict)


class LifeMemoryCreate(BaseModel):
    captured_at: datetime
    user_note: str
    ai_interpretation: str
    people_text: Optional[str] = None
    labels: List[str] = Field(default_factory=list)
    entities: List[dict] = Field(default_factory=list)
    related_person_ids: List[UUID] = Field(default_factory=list)
    image_base64: Optional[str] = None
    image_mime_type: str = "image/jpeg"
    source: Literal["camera", "voice", "manual", "derived"] = "camera"
    metadata: dict = Field(default_factory=dict)


class MemoryOut(BaseModel):
    id: UUID
    captured_at: datetime
    text: str
    related_person_ids: List[UUID]
    related_meeting_id: Optional[UUID]
    source: str
    metadata: dict
    created_at: datetime


class MemorySearchRequest(BaseModel):
    query: str
    top_k: int = 5
    time_from: Optional[datetime] = None
    time_to: Optional[datetime] = None
    person_id: Optional[UUID] = None


class MemoryUpdate(BaseModel):
    captured_at: Optional[datetime] = None
    text: Optional[str] = None
    user_note: Optional[str] = None
    ai_interpretation: Optional[str] = None
    people_text: Optional[str] = None
    metadata: Optional[dict] = None


class MemoryRecentRequest(BaseModel):
    limit: int = 20
    memory_type: Optional[str] = "life_scene"


class MemoryMatch(BaseModel):
    memory: MemoryOut
    score: float


class PersonCandidate(BaseModel):
    person: PersonOut
    score: float
    evidence: str


class UniversalSearchResult(BaseModel):
    memory: MemoryOut
    score: float
    people: List[PersonOut] = Field(default_factory=list)
    person_candidates: List[PersonCandidate] = Field(default_factory=list)
    meeting: Optional[MeetingOut] = None
    entities: List[dict] = Field(default_factory=list)
    needs: List[dict] = Field(default_factory=list)


# ─── Needs ────────────────────────────────────────────────────
class NeedCreate(BaseModel):
    person_id: UUID
    meeting_id: Optional[UUID] = None
    text: str
    category: Literal["pain", "interest", "constraint", "budget", "timeline"] = "interest"
    confidence: float = 1.0
    metadata: dict = Field(default_factory=dict)


class NeedOut(BaseModel):
    id: UUID
    person_id: UUID
    meeting_id: Optional[UUID]
    text: str
    category: str
    confidence: float
    metadata: dict
    created_at: datetime


# ─── Proposal context (for client-side Gemini synthesis) ──────
class ProposalContext(BaseModel):
    person: PersonOut
    needs: List[NeedOut]
    recent_meetings: List[MeetingOut]
