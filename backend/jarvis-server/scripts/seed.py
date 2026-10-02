"""Seed the DB with dummy people / meetings / needs / memories for offline testing.

Idempotent: TRUNCATES first. Loads the embedding model on first call,
so the first run takes ~30s-2min (model download). Subsequent runs ~seconds.
"""
import os
import sys
from datetime import datetime, timedelta, timezone

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from app.db import close_pool, open_pool, pool  # noqa: E402
from app.embeddings import embed_text  # noqa: E402


def main() -> None:
    open_pool()
    try:
        with pool.connection() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    "TRUNCATE proposal_points, needs, memories, meetings, people "
                    "RESTART IDENTITY CASCADE"
                )

                # ── People
                yuseop = _insert_person(cur, "김유섭", ["유섭", "Yuseop"], "워트인텔리전스", "대표")
                bob = _insert_person(cur, "박배터리", ["박부장"], "DH배터리", "구매부장")
                cara = _insert_person(cur, "최셀", [], "셀팩솔루션", "CTO")

                # ── Meetings
                now = datetime.now(timezone.utc)
                m1 = _insert_meeting(
                    cur, "DH배터리 1차 미팅", [bob], now - timedelta(days=30),
                    "강남 카페",
                    "10kWh 배터리 1000개 단가 협상. 안전성 인증 자료 요청. Q4 결정.",
                )
                m2 = _insert_meeting(
                    cur, "셀팩 기술 미팅", [cara], now - timedelta(days=14),
                    "분당 본사",
                    "차세대 셀 화학에 대한 기술 교류. CTO가 LFP 안전성에 관심 강함.",
                )
                m3 = _insert_meeting(
                    cur, "DH배터리 2차 미팅", [bob], now - timedelta(days=7),
                    "DH 본사",
                    "단가 안 1차안 거절. 12월 결정 시한. 안전성 보증 우려 재차 강조.",
                )

                # ── Needs
                _insert_need(cur, bob, m1, "10kWh 배터리 1000개 단가가 시장보다 비싸다고 느낌", "pain")
                _insert_need(cur, bob, m1, "안전성 인증서 요구 (KS / IEC)", "constraint")
                _insert_need(cur, bob, m3, "12월 말까지 최종 결정 필요", "timeline")
                _insert_need(cur, bob, m3, "장기 안전성 보증 (5년)에 관심", "interest")
                _insert_need(cur, cara, m2, "LFP 셀 안전성 데이터 공유 희망", "interest")
                _insert_need(cur, cara, m2, "공동 R&D 예산 한정적", "budget")

                # ── Memories
                _insert_memory(
                    cur, now - timedelta(days=30),
                    "DH배터리 박부장과 첫 미팅 — 단가에 매우 민감",
                    related_person_ids=[bob], related_meeting_id=m1, source="voice",
                )
                _insert_memory(
                    cur, now - timedelta(hours=2),
                    "지금 보고 있는 책: 『전고체 배터리 입문』",
                    source="camera",
                )

            conn.commit()
        print("seeded ✓")
    finally:
        close_pool()


def _insert_person(cur, name, aliases, org, role):
    cur.execute(
        "INSERT INTO people (name, aliases, org, role) "
        "VALUES (%s, %s, %s, %s) RETURNING id",
        (name, aliases, org, role),
    )
    return cur.fetchone()["id"]


def _insert_meeting(cur, title, person_ids, started_at, location, summary):
    emb = embed_text(summary)
    cur.execute(
        """
        INSERT INTO meetings
            (title, person_ids, started_at, location, summary, summary_embedding)
        VALUES (%s, %s, %s, %s, %s, %s) RETURNING id
        """,
        (title, person_ids, started_at, location, summary, emb),
    )
    return cur.fetchone()["id"]


def _insert_need(cur, person_id, meeting_id, text, category):
    emb = embed_text(text)
    cur.execute(
        """
        INSERT INTO needs (person_id, meeting_id, text, category, embedding)
        VALUES (%s, %s, %s, %s, %s)
        """,
        (person_id, meeting_id, text, category, emb),
    )


def _insert_memory(
    cur, captured_at, text, related_person_ids=None, related_meeting_id=None,
    source="manual",
):
    emb = embed_text(text)
    cur.execute(
        """
        INSERT INTO memories
            (captured_at, text, embedding, related_person_ids,
             related_meeting_id, source)
        VALUES (%s, %s, %s, %s, %s, %s)
        """,
        (captured_at, text, emb, related_person_ids or [],
         related_meeting_id, source),
    )


if __name__ == "__main__":
    main()
