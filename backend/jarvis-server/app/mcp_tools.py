import json
import urllib.parse
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timedelta
from typing import Any, Callable, Optional
from zoneinfo import ZoneInfo

from psycopg.types.json import Jsonb

from .config import settings
from .db import get_conn


ToolHandler = Callable[[dict[str, Any], str], dict[str, Any]]


@dataclass(frozen=True)
class McpTool:
    name: str
    title: str
    description: str
    input_schema: dict[str, Any]
    handler: ToolHandler
    requires_confirmation: bool = False

    def to_manifest(self) -> dict[str, Any]:
        return {
            "name": self.name,
            "title": self.title,
            "description": self.description,
            "inputSchema": self.input_schema,
            "annotations": {
                "requires_confirmation": self.requires_confirmation,
            },
        }


def list_tools() -> list[dict[str, Any]]:
    return [tool.to_manifest() for tool in _TOOLS.values()]


def call_tool(name: str, arguments: dict[str, Any], user_id: str = "default") -> dict[str, Any]:
    tool = _TOOLS.get(name)
    if tool is None:
        return {
            "is_error": True,
            "error": f"unknown tool: {name}",
        }
    try:
        return tool.handler(arguments, user_id)
    except Exception as exc:
        return {
            "is_error": True,
            "error": str(exc),
        }


def get_tool(name: str) -> Optional[McpTool]:
    return _TOOLS.get(name)


def _integration_token(user_id: str, provider: str) -> Optional[str]:
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT access_token_encrypted
                FROM user_integrations
                WHERE user_id = %s AND provider = %s
                """,
                (user_id, provider),
            )
            row = cur.fetchone()
    if not row:
        return None
    return row["access_token_encrypted"]


def _needs_auth(provider: str, message: str) -> dict[str, Any]:
    return {
        "is_error": False,
        "needs_auth": True,
        "provider": provider,
        "content": message,
        "structured_content": {
            "needs_auth": True,
            "provider": provider,
        },
    }


def _http_json(
    url: str,
    *,
    method: str = "GET",
    headers: Optional[dict[str, str]] = None,
    body: Optional[dict[str, Any]] = None,
) -> dict[str, Any]:
    data = None
    request_headers = headers or {}
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        request_headers = {"Content-Type": "application/json", **request_headers}
    request = urllib.request.Request(url, data=data, headers=request_headers, method=method)
    with urllib.request.urlopen(request, timeout=20) as response:
        payload = response.read().decode("utf-8")
    return json.loads(payload) if payload else {}


def _calendar_list_events(args: dict[str, Any], user_id: str) -> dict[str, Any]:
    token = _integration_token(user_id, "google")
    if not token:
        return _needs_auth("google", "Google Calendar 연결이 필요합니다.")
    query = {
        "timeMin": args["time_min"],
        "timeMax": args["time_max"],
        "singleEvents": "true",
        "orderBy": "startTime",
        "timeZone": args.get("time_zone", "Asia/Seoul"),
        "maxResults": str(args.get("max_results", 20)),
    }
    if args.get("query"):
        query["q"] = args["query"]
    url = "https://www.googleapis.com/calendar/v3/calendars/primary/events?" + urllib.parse.urlencode(query)
    data = _http_json(url, headers={"Authorization": f"Bearer {token}"})
    events = []
    for item in data.get("items", []):
        events.append(
            {
                "id": item.get("id"),
                "title": item.get("summary", "(제목 없음)"),
                "start": item.get("start", {}).get("dateTime") or item.get("start", {}).get("date"),
                "end": item.get("end", {}).get("dateTime") or item.get("end", {}).get("date"),
                "location": item.get("location"),
                "html_link": item.get("htmlLink"),
            }
        )
    return {
        "is_error": False,
        "content": f"{len(events)}개의 일정을 찾았습니다.",
        "structured_content": {"events": events},
    }


def _slack_post_message(args: dict[str, Any], user_id: str) -> dict[str, Any]:
    token = _integration_token(user_id, "slack")
    if not token:
        return _needs_auth("slack", "Slack 연결이 필요합니다.")
    channel_id = args.get("channel_id") or settings.slack_default_channel_id
    if not channel_id:
        return {
            "is_error": True,
            "error": "SLACK_DEFAULT_CHANNEL_ID가 설정되지 않았습니다.",
        }
    data = _http_json(
        "https://slack.com/api/chat.postMessage",
        method="POST",
        headers={"Authorization": f"Bearer {token}"},
        body={"channel": channel_id, "text": args["text"]},
    )
    if not data.get("ok"):
        return {"is_error": True, "error": data.get("error", "slack post failed")}
    return {
        "is_error": False,
        "content": "Slack 메시지를 전송했습니다.",
        "structured_content": {"channel": channel_id, "ts": data.get("ts")},
    }


def _notion_search(args: dict[str, Any], user_id: str) -> dict[str, Any]:
    token = _integration_token(user_id, "notion")
    if not token:
        return _needs_auth("notion", "Notion 연결이 필요합니다.")
    body = {
        "query": args.get("query", ""),
        "page_size": args.get("page_size", 10),
        "sort": {"direction": "descending", "timestamp": "last_edited_time"},
    }
    data = _http_json(
        "https://api.notion.com/v1/search",
        method="POST",
        headers={
            "Authorization": f"Bearer {token}",
            "Notion-Version": "2026-03-11",
        },
        body=body,
    )
    results = []
    for item in data.get("results", []):
        results.append(
            {
                "id": item.get("id"),
                "object": item.get("object"),
                "url": item.get("url"),
                "last_edited_time": item.get("last_edited_time"),
            }
        )
    return {
        "is_error": False,
        "content": f"Notion에서 {len(results)}개의 후보를 찾았습니다.",
        "structured_content": {"results": results},
    }


def _meeting_search(args: dict[str, Any], user_id: str) -> dict[str, Any]:
    query = (args.get("query") or "").strip()
    limit = int(args.get("limit") or 5)
    with get_conn() as conn:
        with conn.cursor() as cur:
            if "오늘" in query:
                kst = ZoneInfo("Asia/Seoul")
                start = datetime.now(kst).replace(hour=0, minute=0, second=0, microsecond=0)
                end = start + timedelta(days=1)
                cur.execute(
                    """
                    SELECT id, title, started_at, summary, raw_transcript, metadata
                    FROM meetings
                    WHERE started_at >= %s AND started_at < %s
                    ORDER BY started_at DESC
                    LIMIT %s
                    """,
                    (start, end, limit),
                )
            else:
                pattern = f"%{query}%"
                cur.execute(
                    """
                    SELECT id, title, started_at, summary, raw_transcript, metadata
                    FROM meetings
                    WHERE title ILIKE %s OR summary ILIKE %s OR raw_transcript ILIKE %s
                    ORDER BY started_at DESC
                    LIMIT %s
                    """,
                    (pattern, pattern, pattern, limit),
                )
            rows = cur.fetchall()
    meetings = [
        {
            "id": str(row["id"]),
            "title": row["title"],
            "started_at": row["started_at"].isoformat() if row["started_at"] else None,
            "summary": row["summary"],
            "markdown_summary": (row["metadata"] or {}).get("markdown_summary", ""),
        }
        for row in rows
    ]
    return {
        "is_error": False,
        "content": f"{len(meetings)}개의 회의 기록을 찾았습니다.",
        "structured_content": {"meetings": meetings},
    }


_TOOLS: dict[str, McpTool] = {
    "calendar_list_events": McpTool(
        name="calendar_list_events",
        title="Google Calendar 일정 조회",
        description="사용자의 Google Calendar에서 지정 기간 일정을 조회합니다.",
        input_schema={
            "type": "object",
            "properties": {
                "time_min": {"type": "string"},
                "time_max": {"type": "string"},
                "time_zone": {"type": "string"},
                "query": {"type": "string"},
                "max_results": {"type": "integer"},
            },
            "required": ["time_min", "time_max"],
        },
        handler=_calendar_list_events,
    ),
    "slack_post_message": McpTool(
        name="slack_post_message",
        title="Slack 메시지 전송",
        description="Slack 채널에 메시지를 전송합니다. 실행 전 사용자 확인이 필요합니다.",
        input_schema={
            "type": "object",
            "properties": {
                "channel_id": {"type": "string"},
                "text": {"type": "string"},
            },
            "required": ["text"],
        },
        handler=_slack_post_message,
        requires_confirmation=True,
    ),
    "notion_search": McpTool(
        name="notion_search",
        title="Notion 조직 범위 검색",
        description="Jarvis Notion integration에 공유된 페이지와 데이터베이스를 검색합니다.",
        input_schema={
            "type": "object",
            "properties": {
                "query": {"type": "string"},
                "page_size": {"type": "integer"},
            },
            "required": ["query"],
        },
        handler=_notion_search,
    ),
    "meeting_search": McpTool(
        name="meeting_search",
        title="Jarvis 회의록 검색",
        description="Jarvis DB에 저장된 회의록을 검색합니다.",
        input_schema={
            "type": "object",
            "properties": {
                "query": {"type": "string"},
                "limit": {"type": "integer"},
            },
            "required": ["query"],
        },
        handler=_meeting_search,
    ),
}


def create_pending_action(user_id: str, action_type: str, payload: dict[str, Any], preview_text: str) -> str:
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                INSERT INTO pending_actions
                    (user_id, action_type, payload_json, preview_text, expires_at)
                VALUES (%s, %s, %s, %s, now() + interval '15 minutes')
                RETURNING id
                """,
                (user_id, action_type, Jsonb(payload), preview_text),
            )
            row = cur.fetchone()
        conn.commit()
    return str(row["id"])
