import base64
import json
import urllib.parse
import urllib.request
from typing import Any, Optional

from fastapi import APIRouter, Depends, HTTPException, Query
from fastapi.responses import HTMLResponse, RedirectResponse
from psycopg.types.json import Jsonb

from ..auth import require_api_key
from ..config import settings
from ..db import get_conn


router = APIRouter(
    prefix="/integrations",
    tags=["integrations"],
)


_PROVIDERS = ("google", "slack", "notion")


def _form_post(url: str, data: dict[str, Any], headers: Optional[dict[str, str]] = None) -> dict[str, Any]:
    encoded = urllib.parse.urlencode(data).encode("utf-8")
    request = urllib.request.Request(
        url,
        data=encoded,
        headers={"Content-Type": "application/x-www-form-urlencoded", **(headers or {})},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=20) as response:
        payload = response.read().decode("utf-8")
    return json.loads(payload) if payload else {}


def _upsert_integration(
    *,
    user_id: str,
    provider: str,
    access_token: str,
    refresh_token: Optional[str] = None,
    scopes: Optional[list[str]] = None,
    metadata: Optional[dict[str, Any]] = None,
) -> None:
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                INSERT INTO user_integrations
                    (user_id, provider, access_token_encrypted,
                     refresh_token_encrypted, scopes, metadata)
                VALUES (%s, %s, %s, %s, %s, %s)
                ON CONFLICT (user_id, provider)
                DO UPDATE SET
                    access_token_encrypted = EXCLUDED.access_token_encrypted,
                    refresh_token_encrypted = COALESCE(EXCLUDED.refresh_token_encrypted, user_integrations.refresh_token_encrypted),
                    scopes = EXCLUDED.scopes,
                    metadata = user_integrations.metadata || EXCLUDED.metadata,
                    updated_at = now()
                """,
                (
                    user_id,
                    provider,
                    access_token,
                    refresh_token,
                    scopes or [],
                    Jsonb(metadata or {}),
                ),
            )
        conn.commit()


@router.get("/status", dependencies=[Depends(require_api_key)])
def status(user_id: str = "default"):
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT provider, scopes, updated_at
                FROM user_integrations
                WHERE user_id = %s
                """,
                (user_id,),
            )
            rows = cur.fetchall()
    by_provider = {row["provider"]: row for row in rows}
    return {
        provider: {
            "connected": provider in by_provider,
            "scopes": by_provider.get(provider, {}).get("scopes", []),
            "updated_at": (
                by_provider[provider]["updated_at"].isoformat()
                if provider in by_provider and by_provider[provider]["updated_at"]
                else None
            ),
        }
        for provider in _PROVIDERS
    }


@router.get("/{provider}/connect")
def connect(provider: str, user_id: str = "default"):
    if provider == "google":
        if not settings.google_client_id or not settings.google_redirect_uri:
            raise HTTPException(400, "GOOGLE_CLIENT_ID and GOOGLE_REDIRECT_URI are required")
        params = {
            "client_id": settings.google_client_id,
            "redirect_uri": settings.google_redirect_uri,
            "response_type": "code",
            "scope": "https://www.googleapis.com/auth/calendar.events.readonly",
            "access_type": "offline",
            "prompt": "consent",
            "state": user_id,
        }
        return RedirectResponse("https://accounts.google.com/o/oauth2/v2/auth?" + urllib.parse.urlencode(params))

    if provider == "slack":
        if not settings.slack_client_id or not settings.slack_redirect_uri:
            raise HTTPException(400, "SLACK_CLIENT_ID and SLACK_REDIRECT_URI are required")
        params = {
            "client_id": settings.slack_client_id,
            "redirect_uri": settings.slack_redirect_uri,
            "scope": "chat:write,channels:read,groups:read,im:write",
            "state": user_id,
        }
        return RedirectResponse("https://slack.com/oauth/v2/authorize?" + urllib.parse.urlencode(params))

    if provider == "notion":
        if not settings.notion_client_id or not settings.notion_redirect_uri:
            raise HTTPException(400, "NOTION_CLIENT_ID and NOTION_REDIRECT_URI are required")
        params = {
            "client_id": settings.notion_client_id,
            "redirect_uri": settings.notion_redirect_uri,
            "response_type": "code",
            "owner": "user",
            "state": user_id,
        }
        return RedirectResponse("https://api.notion.com/v1/oauth/authorize?" + urllib.parse.urlencode(params))

    raise HTTPException(404, "unknown integration provider")


@router.get("/{provider}/callback")
def callback(provider: str, code: str = Query(...), state: str = "default"):
    user_id = state or "default"
    if provider == "google":
        data = _form_post(
            "https://oauth2.googleapis.com/token",
            {
                "client_id": settings.google_client_id,
                "client_secret": settings.google_client_secret,
                "code": code,
                "grant_type": "authorization_code",
                "redirect_uri": settings.google_redirect_uri,
            },
        )
        if "access_token" not in data:
            raise HTTPException(400, f"google token exchange failed: {data}")
        _upsert_integration(
            user_id=user_id,
            provider="google",
            access_token=data["access_token"],
            refresh_token=data.get("refresh_token"),
            scopes=(data.get("scope") or "").split(),
            metadata={"token_type": data.get("token_type"), "expires_in": data.get("expires_in")},
        )
        return _connected_html("Google Calendar")

    if provider == "slack":
        data = _form_post(
            "https://slack.com/api/oauth.v2.access",
            {
                "client_id": settings.slack_client_id,
                "client_secret": settings.slack_client_secret,
                "code": code,
                "redirect_uri": settings.slack_redirect_uri,
            },
        )
        if not data.get("ok") or not data.get("access_token"):
            raise HTTPException(400, f"slack token exchange failed: {data}")
        _upsert_integration(
            user_id=user_id,
            provider="slack",
            access_token=data["access_token"],
            scopes=(data.get("scope") or "").split(","),
            metadata={"team": data.get("team"), "authed_user": data.get("authed_user")},
        )
        return _connected_html("Slack")

    if provider == "notion":
        if not settings.notion_client_id or not settings.notion_client_secret:
            raise HTTPException(400, "NOTION_CLIENT_ID and NOTION_CLIENT_SECRET are required")
        basic = base64.b64encode(
            f"{settings.notion_client_id}:{settings.notion_client_secret}".encode("utf-8")
        ).decode("ascii")
        data = _form_post(
            "https://api.notion.com/v1/oauth/token",
            {
                "grant_type": "authorization_code",
                "code": code,
                "redirect_uri": settings.notion_redirect_uri,
            },
            headers={"Authorization": f"Basic {basic}"},
        )
        if "access_token" not in data:
            raise HTTPException(400, f"notion token exchange failed: {data}")
        _upsert_integration(
            user_id=user_id,
            provider="notion",
            access_token=data["access_token"],
            metadata={"workspace_name": data.get("workspace_name"), "owner": data.get("owner")},
        )
        return _connected_html("Notion")

    raise HTTPException(404, "unknown integration provider")


def _connected_html(provider_name: str) -> HTMLResponse:
    return HTMLResponse(
        f"""
        <html>
          <head><title>Jarvis {provider_name} Connected</title></head>
          <body style="font-family: sans-serif; padding: 24px;">
            <h2>{provider_name} 연결 완료</h2>
            <p>Jarvis 앱으로 돌아가 테스트를 계속하세요.</p>
          </body>
        </html>
        """
    )
