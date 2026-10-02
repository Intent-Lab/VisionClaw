"""Proxy for Gemini 2.5 Flash generateContent calls.

The Android root agent (decision loop) and vision judgment both call this
instead of Google directly. The real Gemini API key never leaves this
server, and every request/response is logged here -- so debugging a Flash
call no longer requires adb access to the phone, just SSH to this box.

The Android client still owns the tool declarations, system prompt, and the
agent loop itself; this endpoint is a thin, schema-agnostic passthrough (it
does not know or care what "tools" contains) so there is exactly one place
(the Kotlin client) that defines the actual agent behavior -- this file
should never need to change when that behavior changes.
"""
import logging
import sys

import httpx
from fastapi import APIRouter, Depends, HTTPException

from ..auth import require_api_key
from ..config import settings

logger = logging.getLogger("jarvis.agent_flash")
logger.setLevel(logging.INFO)
# A dedicated handler on this specific logger, not the root logger -- some lazily
# imported library (sentence-transformers/insightface/onnxruntime all import heavy
# ML stacks on first use, well after startup) reconfiguring the root logger later
# was silently swallowing these logs when they only relied on root propagation.
if not logger.handlers:
    _handler = logging.StreamHandler(sys.stderr)
    _handler.setFormatter(logging.Formatter("%(asctime)s %(name)s %(levelname)s %(message)s"))
    logger.addHandler(_handler)
    logger.propagate = False

router = APIRouter(
    prefix="/agent/flash",
    tags=["agent-flash"],
    dependencies=[Depends(require_api_key)],
)

_MODEL = "gemini-2.5-flash"
_GEMINI_ENDPOINT = (
    f"https://generativelanguage.googleapis.com/v1beta/models/{_MODEL}:generateContent"
)


@router.post("/generate")
def generate(body: dict) -> dict:
    """Forwards `body` (Gemini's own systemInstruction/contents/tools/
    generationConfig shape) to generateContent with the server-held API key,
    and returns Gemini's raw JSON response unmodified."""
    if not settings.gemini_api_key:
        raise HTTPException(500, "GEMINI_API_KEY not configured on the server")

    tool_names = [
        fc.get("name")
        for tool in body.get("tools", [])
        for fc in tool.get("functionDeclarations", [])
    ]
    logger.info(
        "flash request: contents_turns=%d tools=%s",
        len(body.get("contents", [])),
        tool_names or None,
    )

    try:
        # Header, not ?key= query param -- httpx's own request logger (and any other
        # URL-based logging) would otherwise put the raw API key in plaintext into
        # this server's own log files.
        response = httpx.post(
            _GEMINI_ENDPOINT,
            headers={"x-goog-api-key": settings.gemini_api_key},
            json=body,
            timeout=30.0,
        )
    except httpx.HTTPError as e:
        logger.error("flash request failed: %s", e)
        raise HTTPException(502, f"Gemini request failed: {e}")

    if not response.is_success:
        logger.error("flash HTTP %s: %s", response.status_code, response.text[:500])
        raise HTTPException(response.status_code, response.text)

    result = response.json()
    candidates = result.get("candidates", [])
    parts = candidates[0].get("content", {}).get("parts", []) if candidates else []
    part_kinds = [next(iter(p.keys()), "?") for p in parts]
    logger.info("flash response: parts=%s", part_kinds or "EMPTY")

    return result
