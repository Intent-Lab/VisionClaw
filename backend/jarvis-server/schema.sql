-- Jarvis Memory API schema
-- Vector dims: text=1024 (BGE-M3 / KURE-v1), face=512 (FaceNet-style from phone)

CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ────────────────────────────────────────────────────────────
-- people
-- ────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS people (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name            text NOT NULL,
    aliases         text[] NOT NULL DEFAULT '{}',
    org             text,
    role            text,
    phone           text,
    email           text,
    address         text,
    first_met_at    timestamptz,
    last_met_at     timestamptz,
    face_embedding  vector(512),
    notes_summary   text,
    metadata        jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS people_face_hnsw
    ON people USING hnsw (face_embedding vector_cosine_ops);

-- ────────────────────────────────────────────────────────────
-- meetings
-- ────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS meetings (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    title               text,
    person_ids          uuid[] NOT NULL DEFAULT '{}',
    started_at          timestamptz NOT NULL,
    ended_at            timestamptz,
    location            text,
    summary             text,
    summary_embedding   vector(1024),
    raw_transcript      text,
    metadata            jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS meetings_summary_hnsw
    ON meetings USING hnsw (summary_embedding vector_cosine_ops);
CREATE INDEX IF NOT EXISTS meetings_started_at_desc ON meetings (started_at DESC);
CREATE INDEX IF NOT EXISTS meetings_person_ids_gin ON meetings USING gin (person_ids);

-- ────────────────────────────────────────────────────────────
-- memories  (episodic — camera/voice/manual)
-- ────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS memories (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    captured_at         timestamptz NOT NULL,
    text                text NOT NULL,
    embedding           vector(1024),
    related_person_ids  uuid[] NOT NULL DEFAULT '{}',
    related_meeting_id  uuid REFERENCES meetings(id) ON DELETE SET NULL,
    source              text NOT NULL DEFAULT 'manual',
    metadata            jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS memories_embedding_hnsw
    ON memories USING hnsw (embedding vector_cosine_ops);
CREATE INDEX IF NOT EXISTS memories_captured_at_desc ON memories (captured_at DESC);
CREATE INDEX IF NOT EXISTS memories_related_person_ids_gin
    ON memories USING gin (related_person_ids);

-- ────────────────────────────────────────────────────────────
-- entities  (objects/people/companies/documents extracted from memories)
-- ────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS entities (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    entity_type text NOT NULL,
    label       text NOT NULL,
    aliases     text[] NOT NULL DEFAULT '{}',
    metadata    jsonb NOT NULL DEFAULT '{}'::jsonb,
    embedding   vector(1024),
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    UNIQUE (entity_type, label)
);
CREATE INDEX IF NOT EXISTS entities_embedding_hnsw
    ON entities USING hnsw (embedding vector_cosine_ops);
CREATE INDEX IF NOT EXISTS entities_type_label_idx
    ON entities (entity_type, label);

CREATE TABLE IF NOT EXISTS memory_entities (
    memory_id   uuid NOT NULL REFERENCES memories(id) ON DELETE CASCADE,
    entity_id   uuid NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
    relation    text NOT NULL DEFAULT 'mentions',
    confidence  real NOT NULL DEFAULT 1.0,
    created_at  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (memory_id, entity_id, relation)
);
CREATE INDEX IF NOT EXISTS memory_entities_entity_idx
    ON memory_entities (entity_id);

-- ────────────────────────────────────────────────────────────
-- needs  (sales/CRM signals extracted per person/meeting)
-- ────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS needs (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    person_id   uuid REFERENCES people(id) ON DELETE CASCADE,
    meeting_id  uuid REFERENCES meetings(id) ON DELETE SET NULL,
    text        text NOT NULL,
    category    text NOT NULL DEFAULT 'interest',
    embedding   vector(1024),
    confidence  real NOT NULL DEFAULT 1.0,
    metadata    jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS needs_embedding_hnsw
    ON needs USING hnsw (embedding vector_cosine_ops);
CREATE INDEX IF NOT EXISTS needs_person_id ON needs (person_id);

-- ────────────────────────────────────────────────────────────
-- proposal_points  (cached generations; optional)
-- ────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS proposal_points (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    person_id       uuid REFERENCES people(id) ON DELETE CASCADE,
    text            text NOT NULL,
    rationale       text,
    source_need_ids uuid[] NOT NULL DEFAULT '{}',
    generated_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS proposal_points_person_id ON proposal_points (person_id);
-- Multiple reference photos per person.
--
-- ArcFace compares one probe vector against one stored vector, so with a single stored
-- photo per person the recognition ceiling is fixed by whatever angle/lighting that one
-- capture happened to have. Production logs (jarvis.people, 2026-08-06..08-14) showed the
-- same person scoring 0.29-0.36 against a poor stored reference across 7+ attempts, and
-- 0.75-0.87 once a better photo replaced it. Storing several photos per person and taking
-- the per-person max lets recognition improve with use instead of being capped at the
-- first capture.
CREATE TABLE IF NOT EXISTS person_faces (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    person_id   uuid NOT NULL REFERENCES people(id) ON DELETE CASCADE,
    embedding   vector(512) NOT NULL,
    quality     jsonb NOT NULL DEFAULT '{}'::jsonb,
    source      text,
    created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS person_faces_person_id ON person_faces (person_id);
CREATE INDEX IF NOT EXISTS person_faces_hnsw
    ON person_faces USING hnsw (embedding vector_cosine_ops);

-- Backfill every face already stored on people.face_embedding. Guarded so re-running the
-- migration cannot duplicate them (the source tag is what marks a backfilled row).
INSERT INTO person_faces (person_id, embedding, quality, source)
SELECT p.id, p.face_embedding, '{}'::jsonb, 'migrated_from_people'
FROM people p
WHERE p.face_embedding IS NOT NULL
  AND NOT EXISTS (
      SELECT 1 FROM person_faces f
      WHERE f.person_id = p.id AND f.source = 'migrated_from_people'
  );
