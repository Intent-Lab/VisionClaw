"""Create derived memory index rows for existing people and meetings."""

import os
import sys
from datetime import timezone

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from psycopg.types.json import Jsonb

from app.db import close_pool, get_conn, open_pool  # noqa: E402
from app.embeddings import embed_text  # noqa: E402


def backfill_people(cur) -> int:
    cur.execute(
        """
        SELECT p.*
        FROM people p
        WHERE NOT EXISTS (
            SELECT 1
            FROM memories m
            WHERE m.metadata->>'origin_person_id' = p.id::text
        )
        ORDER BY p.created_at
        """
    )
    rows = cur.fetchall()
    for row in rows:
        text = "\n".join(
            part
            for part in [
                f"사람: {row['name']}",
                f"별칭: {', '.join(row['aliases'])}" if row["aliases"] else None,
                f"소속: {row['org']}" if row["org"] else None,
                f"직책: {row['role']}" if row["role"] else None,
                f"메모: {row['notes_summary']}" if row["notes_summary"] else None,
            ]
            if part
        )
        captured_at = (
            row["first_met_at"]
            or row["last_met_at"]
            or row["created_at"]
        )
        if captured_at.tzinfo is None:
            captured_at = captured_at.replace(tzinfo=timezone.utc)
        cur.execute(
            """
            INSERT INTO memories
                (captured_at, text, embedding, related_person_ids,
                 source, metadata)
            VALUES (%s, %s, %s, %s, 'derived', %s)
            """,
            (
                captured_at,
                text,
                embed_text(text),
                [row["id"]],
                Jsonb(
                    {
                        "memory_type": "person_profile",
                        "origin_person_id": str(row["id"]),
                        "backfilled": True,
                    }
                ),
            ),
        )
    return len(rows)


def backfill_meetings(cur) -> int:
    cur.execute(
        """
        SELECT mt.*
        FROM meetings mt
        WHERE NOT EXISTS (
            SELECT 1
            FROM memories m
            WHERE m.metadata->>'origin_meeting_id' = mt.id::text
        )
        ORDER BY mt.started_at
        """
    )
    rows = cur.fetchall()
    for row in rows:
        text = "\n".join(
            part
            for part in [
                f"미팅: {row['title']}" if row["title"] else "미팅 기록",
                f"요약: {row['summary']}" if row["summary"] else None,
                f"장소: {row['location']}" if row["location"] else None,
                f"원문: {row['raw_transcript']}" if row["raw_transcript"] else None,
            ]
            if part
        )
        cur.execute(
            """
            INSERT INTO memories
                (captured_at, text, embedding, related_person_ids,
                 related_meeting_id, source, metadata)
            VALUES (%s, %s, %s, %s, %s, 'derived', %s)
            """,
            (
                row["started_at"],
                text,
                embed_text(text),
                row["person_ids"],
                row["id"],
                Jsonb(
                    {
                        "memory_type": "meeting",
                        "origin_meeting_id": str(row["id"]),
                        "backfilled": True,
                    }
                ),
            ),
        )
    return len(rows)


def main() -> None:
    open_pool()
    try:
        with get_conn() as conn:
            with conn.cursor() as cur:
                people_count = backfill_people(cur)
                meeting_count = backfill_meetings(cur)
            conn.commit()
        print(
            f"backfilled people={people_count} meetings={meeting_count}"
        )
    finally:
        close_pool()


if __name__ == "__main__":
    main()
