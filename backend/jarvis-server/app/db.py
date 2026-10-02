from contextlib import contextmanager
from typing import Iterator

from psycopg.rows import dict_row
from psycopg_pool import ConnectionPool
from pgvector.psycopg import register_vector

from .config import settings


def _configure(conn) -> None:
    register_vector(conn)


pool = ConnectionPool(
    conninfo=settings.database_url,
    min_size=1,
    max_size=10,
    open=False,
    configure=_configure,
    kwargs={"row_factory": dict_row},
)


def open_pool() -> None:
    pool.open()
    pool.wait()


def close_pool() -> None:
    pool.close()


def ensure_schema() -> None:
    with pool.connection() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                CREATE EXTENSION IF NOT EXISTS pgcrypto;

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

                CREATE TABLE IF NOT EXISTS user_integrations (
                    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
                    user_id text NOT NULL,
                    provider text NOT NULL,
                    access_token_encrypted text,
                    refresh_token_encrypted text,
                    scopes text[] NOT NULL DEFAULT '{}',
                    expires_at timestamptz,
                    metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
                    created_at timestamptz NOT NULL DEFAULT now(),
                    updated_at timestamptz NOT NULL DEFAULT now(),
                    UNIQUE (user_id, provider)
                );

                CREATE TABLE IF NOT EXISTS agent_runs (
                    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
                    user_id text NOT NULL,
                    input_text text NOT NULL,
                    intent text,
                    status text NOT NULL DEFAULT 'created',
                    final_answer text,
                    metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
                    created_at timestamptz NOT NULL DEFAULT now(),
                    updated_at timestamptz NOT NULL DEFAULT now()
                );

                CREATE TABLE IF NOT EXISTS agent_tool_calls (
                    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
                    run_id uuid REFERENCES agent_runs(id) ON DELETE CASCADE,
                    tool_name text NOT NULL,
                    input_json jsonb NOT NULL DEFAULT '{}'::jsonb,
                    output_json jsonb NOT NULL DEFAULT '{}'::jsonb,
                    status text NOT NULL DEFAULT 'created',
                    created_at timestamptz NOT NULL DEFAULT now()
                );

                CREATE TABLE IF NOT EXISTS pending_actions (
                    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
                    user_id text NOT NULL,
                    action_type text NOT NULL,
                    payload_json jsonb NOT NULL DEFAULT '{}'::jsonb,
                    preview_text text NOT NULL,
                    status text NOT NULL DEFAULT 'pending',
                    expires_at timestamptz,
                    created_at timestamptz NOT NULL DEFAULT now(),
                    updated_at timestamptz NOT NULL DEFAULT now()
                );

                CREATE INDEX IF NOT EXISTS agent_runs_user_created_idx
                    ON agent_runs (user_id, created_at DESC);
                CREATE INDEX IF NOT EXISTS agent_tool_calls_run_idx
                    ON agent_tool_calls (run_id);
                CREATE INDEX IF NOT EXISTS pending_actions_user_status_idx
                    ON pending_actions (user_id, status, created_at DESC);
                """
            )
        conn.commit()


@contextmanager
def get_conn() -> Iterator:
    with pool.connection() as conn:
        yield conn
