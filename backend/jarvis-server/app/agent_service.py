from datetime import datetime, timedelta
from typing import Any, Optional
from uuid import UUID
from zoneinfo import ZoneInfo

from openai import OpenAI
from psycopg.types.json import Jsonb

from .config import settings
from .db import get_conn
from .mcp_tools import call_tool, create_pending_action, get_tool


def create_agent_run(user_id: str, text: str, metadata: Optional[dict[str, Any]] = None) -> str:
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                INSERT INTO agent_runs (user_id, input_text, metadata)
                VALUES (%s, %s, %s)
                RETURNING id
                """,
                (user_id, text, Jsonb(metadata or {})),
            )
            row = cur.fetchone()
        conn.commit()
    return str(row["id"])


def update_agent_run(run_id: str, *, intent: str, status: str, final_answer: str, metadata: Optional[dict[str, Any]] = None) -> None:
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                UPDATE agent_runs
                SET intent = %s,
                    status = %s,
                    final_answer = %s,
                    metadata = metadata || %s,
                    updated_at = now()
                WHERE id = %s
                """,
                (intent, status, final_answer, Jsonb(metadata or {}), UUID(run_id)),
            )
        conn.commit()


def log_tool_call(run_id: str, tool_name: str, input_json: dict[str, Any], output_json: dict[str, Any], status: str) -> None:
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                INSERT INTO agent_tool_calls
                    (run_id, tool_name, input_json, output_json, status)
                VALUES (%s, %s, %s, %s, %s)
                """,
                (UUID(run_id), tool_name, Jsonb(input_json), Jsonb(output_json), status),
            )
        conn.commit()


def run_agent_query(
    *,
    user_id: str,
    text: str,
    timezone: str = "Asia/Seoul",
    image_id: Optional[str] = None,
    client_context: Optional[dict[str, Any]] = None,
) -> dict[str, Any]:
    run_id = create_agent_run(
        user_id,
        text,
        {
            "timezone": timezone,
            "image_id": image_id,
            "client_context": client_context or {},
        },
    )
    plan = plan_tool_call(text=text, timezone=timezone)
    tool = get_tool(plan["tool_name"])
    if tool is None:
        answer = "아직 처리할 수 없는 요청입니다. 일정, 회의록, 슬랙, 노션 검색부터 지원합니다."
        update_agent_run(run_id, intent=plan["intent"], status="unsupported", final_answer=answer)
        return {
            "run_id": run_id,
            "intent": plan["intent"],
            "answer": answer,
            "tool_results": [],
        }

    if tool.requires_confirmation:
        preview = build_pending_preview(plan["tool_name"], plan["arguments"])
        pending_action_id = create_pending_action(
            user_id=user_id,
            action_type=plan["tool_name"],
            payload=plan["arguments"],
            preview_text=preview,
        )
        answer = preview
        update_agent_run(
            run_id,
            intent=plan["intent"],
            status="pending_confirmation",
            final_answer=answer,
            metadata={"pending_action_id": pending_action_id},
        )
        return {
            "run_id": run_id,
            "intent": plan["intent"],
            "answer": answer,
            "pending_action": {
                "id": pending_action_id,
                "type": plan["tool_name"],
                "preview_text": preview,
                "payload": plan["arguments"],
            },
            "tool_results": [],
        }

    result = call_tool(plan["tool_name"], plan["arguments"], user_id=user_id)
    log_tool_call(
        run_id,
        plan["tool_name"],
        plan["arguments"],
        result,
        "failed" if result.get("is_error") else "completed",
    )
    answer = synthesize_answer(text, plan, result)
    update_agent_run(
        run_id,
        intent=plan["intent"],
        status="failed" if result.get("is_error") else "completed",
        final_answer=answer,
    )
    return {
        "run_id": run_id,
        "intent": plan["intent"],
        "answer": answer,
        "tool_results": [result],
    }


def confirm_pending_action(user_id: str, pending_action_id: str, approved: bool) -> dict[str, Any]:
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT *
                FROM pending_actions
                WHERE id = %s AND user_id = %s AND status = 'pending'
                """,
                (UUID(pending_action_id), user_id),
            )
            action = cur.fetchone()
            if not action:
                return {
                    "status": "not_found",
                    "answer": "확인할 대기 작업을 찾지 못했습니다.",
                }
            if not approved:
                cur.execute(
                    "UPDATE pending_actions SET status = 'cancelled', updated_at = now() WHERE id = %s",
                    (UUID(pending_action_id),),
                )
                conn.commit()
                return {
                    "status": "cancelled",
                    "answer": "작업을 취소했습니다.",
                }

            result = call_tool(
                action["action_type"],
                dict(action["payload_json"] or {}),
                user_id=user_id,
            )
            cur.execute(
                """
                UPDATE pending_actions
                SET status = %s, updated_at = now()
                WHERE id = %s
                """,
                ("failed" if result.get("is_error") else "executed", UUID(pending_action_id)),
            )
        conn.commit()
    return {
        "status": "failed" if result.get("is_error") else "executed",
        "answer": result.get("error") or result.get("content") or "작업을 실행했습니다.",
        "tool_result": result,
    }


def plan_tool_call(text: str, timezone: str) -> dict[str, Any]:
    # Deterministic first pass keeps MVP reliable. GPT planner can replace this without changing tools.
    normalized = text.replace(" ", "").lower()
    if "일정" in text or "캘린더" in text:
        if any(word in normalized for word in ["내일", "tomorrow"]):
            time_min, time_max = day_window(days_from_today=1, timezone=timezone)
        elif "오늘" in normalized:
            time_min, time_max = day_window(days_from_today=0, timezone=timezone)
        else:
            time_min, time_max = day_window(days_from_today=0, timezone=timezone)
        return {
            "intent": "calendar_query",
            "tool_name": "calendar_list_events",
            "arguments": {
                "time_min": time_min,
                "time_max": time_max,
                "time_zone": timezone,
                "max_results": 20,
            },
        }
    if "슬랙" in text or "slack" in normalized:
        return {
            "intent": "slack_send",
            "tool_name": "slack_post_message",
            "arguments": {
                "text": text,
            },
        }
    if "노션" in text or "notion" in normalized:
        query = text.replace("노션", "").replace("에서", " ").replace("찾아줘", " ").strip()
        return {
            "intent": "notion_search",
            "tool_name": "notion_search",
            "arguments": {
                "query": query or text,
                "page_size": 10,
            },
        }
    if "회의" in text or "회의록" in text:
        return {
            "intent": "meeting_search",
            "tool_name": "meeting_search",
            "arguments": {
                "query": text,
                "limit": 5,
            },
        }
    return {
        "intent": "unsupported",
        "tool_name": "",
        "arguments": {},
    }


def day_window(days_from_today: int, timezone: str) -> tuple[str, str]:
    tz = ZoneInfo(timezone)
    start = datetime.now(tz).replace(hour=0, minute=0, second=0, microsecond=0)
    start = start + timedelta(days=days_from_today)
    end = start + timedelta(days=1)
    return start.isoformat(), end.isoformat()


def build_pending_preview(tool_name: str, arguments: dict[str, Any]) -> str:
    if tool_name == "slack_post_message":
        return f"아래 내용을 Slack 기본 채널에 보낼까요?\n\n{arguments.get('text', '')}"
    return f"아래 작업을 실행할까요?\n\n{tool_name}\n{arguments}"


def synthesize_answer(question: str, plan: dict[str, Any], result: dict[str, Any]) -> str:
    if result.get("needs_auth"):
        provider = result.get("provider")
        return f"{provider} 연결이 필요합니다. 앱 설정에서 {provider} 연결을 먼저 완료해주세요."
    if result.get("is_error"):
        return f"요청 처리에 실패했습니다: {result.get('error', '알 수 없는 오류')}"
    structured = result.get("structured_content") or {}
    if plan["tool_name"] == "calendar_list_events":
        events = structured.get("events", [])
        if not events:
            return "해당 기간에 등록된 일정이 없습니다."
        lines = ["일정은 다음과 같습니다."]
        for event in events[:5]:
            lines.append(f"- {event.get('start')}: {event.get('title')}")
        return "\n".join(lines)
    if plan["tool_name"] == "notion_search":
        results = structured.get("results", [])
        if not results:
            return "Notion에서 관련 문서를 찾지 못했습니다."
        return f"Notion에서 관련 후보 {len(results)}개를 찾았습니다. 상위 결과를 앱에서 확인해주세요."
    if plan["tool_name"] == "meeting_search":
        meetings = structured.get("meetings", [])
        if not meetings:
            return "관련 회의록을 찾지 못했습니다."
        first = meetings[0]
        return f"가장 관련 있는 회의록은 '{first.get('title') or '제목 없음'}'입니다. {first.get('summary') or ''}".strip()

    # Optional GPT answer polishing. Keep deterministic fallback when key is missing.
    if settings.openai_api_key:
        try:
            client = OpenAI(api_key=settings.openai_api_key)
            response = client.responses.create(
                model=settings.jarvis_answer_model,
                input=[
                    {
                        "role": "system",
                        "content": "사용자 질문과 도구 결과를 한국어로 짧고 자연스럽게 요약하세요.",
                    },
                    {
                        "role": "user",
                        "content": f"질문: {question}\n도구 결과: {result}",
                    },
                ],
            )
            return response.output_text
        except Exception:
            pass
    return result.get("content") or "요청을 처리했습니다."
