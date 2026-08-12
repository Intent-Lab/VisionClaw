"""VisionClaw voice agent: LiveKit room <-> realtime model, tools via the gateway.

The phone publishes mic + camera into a LiveKit room and this worker joins as
the assistant. Which brain answers is the user's choice, carried in their
participant metadata: Gemini Live (native audio+video) or OpenAI Realtime
(gpt-realtime-2; video frames arrive as image items). The framework owns what
the direct-connection client had to hand-roll -- echo cancellation lives in
WebRTC on the phone, interruption is playback-position-aware here.

Per-user identity: the room token's identity IS the gateway userId, so tool
calls hit the gateway with the service token plus X-User-Id, landing in that
user's own CMA session, vault and calendar.

Env (Fly secrets): LIVEKIT_URL, LIVEKIT_API_KEY, LIVEKIT_API_SECRET,
GOOGLE_API_KEY, OPENAI_API_KEY (optional; absent disables the openai engine),
GATEWAY_URL, GATEWAY_SERVICE_TOKEN. Models via GEMINI_MODEL /
OPENAI_REALTIME_MODEL.
"""

import asyncio
import base64
import io
import json
import logging
import os
import time
from dataclasses import dataclass

import aiohttp
from google import genai
from google.genai import types as genai_types
from livekit import rtc
from PIL import Image
from livekit.agents import (
    Agent,
    AgentSession,
    JobContext,
    RoomInputOptions,
    RunContext,
    WorkerOptions,
    cli,
    function_tool,
)
from livekit.plugins import google, openai

logger = logging.getLogger("visionclaw-agent")

INSTRUCTIONS = """You are VisionClaw, an AI assistant the user talks to while showing you the
world through their phone camera or smart glasses. Keep responses concise and natural.

You can see live video. Answer visual questions directly from what you see.

For quick factual lookups -- weather, sports scores, stock prices, news, opening hours,
current facts about the world -- use quick_search. It answers in a couple of seconds;
just relay the result. This includes looking up things you can see on camera.

Whenever your answer contains data with visual structure -- weather, forecasts,
schedules, scores, prices, lists, comparisons, step-by-step results -- you MUST call
show_card with the essentials in the same turn as your spoken answer. Card first or
alongside, then speak a short summary; never read the card aloud row by row. One card
per answer; reuse its uuid to update it.

For anything requiring action or multi-step work -- messages, lists, reminders, calendars,
research, smart home -- use the execute tool. Speak a brief natural acknowledgment BEFORE
calling it, never call it silently. Results may arrive as a follow-up; relay them as the
answer to what was asked, not as a notification. If the task is about something the user
is showing on camera, set attach_view=true so the actual image travels with the task --
still describe what you see in the task text as well."""


class FrameHolder:
    """Most recent camera frame from the user's video track. When the user
    freezes/pins a frame, the phone mutes the track, so the pinned frame stays
    the latest one here -- pin semantics carry through to attached images."""

    def __init__(self) -> None:
        self.frame: rtc.VideoFrame | None = None
        self.rotation: int = 0


def encode_latest_frame(holder: FrameHolder) -> str | None:
    """JPEG-encode the latest frame (capped at 1024px, rotation applied) as base64."""
    frame = holder.frame
    if frame is None:
        return None
    rgba = frame.convert(rtc.VideoBufferType.RGBA)
    img = Image.frombuffer("RGBA", (rgba.width, rgba.height), bytes(rgba.data)).convert("RGB")
    rot = holder.rotation % 360
    if rot:
        img = img.rotate(-rot, expand=True)
    img.thumbnail((1024, 1024))
    buf = io.BytesIO()
    img.save(buf, "JPEG", quality=80)
    return base64.b64encode(buf.getvalue()).decode()


@dataclass
class Userdata:
    user_id: str
    frames: FrameHolder


_search_client: genai.Client | None = None


def _get_search_client() -> genai.Client:
    global _search_client
    if _search_client is None:
        _search_client = genai.Client()
    return _search_client


@function_tool
async def quick_search(ctx: RunContext[Userdata], query: str) -> str:
    """Fast grounded web lookup for facts that change: weather, sports scores, stock
    prices, news, opening hours, and quick factual questions. Returns a spoken-ready
    answer in about two seconds. For actions or multi-step research, use execute."""
    t0 = time.monotonic()
    try:
        resp = await _get_search_client().aio.models.generate_content(
            model=os.environ.get("QUICK_SEARCH_MODEL", "gemini-3.5-flash-lite"),
            contents=query,
            config=genai_types.GenerateContentConfig(
                # Grounded generation: Google searches internally and returns a
                # synthesized answer in one round-trip -- no link-reading loop.
                # thinking_level has no "off"; "low" measured faster than default.
                tools=[genai_types.Tool(google_search=genai_types.GoogleSearch())],
                thinking_config=genai_types.ThinkingConfig(thinking_level="low"),
            ),
        )
    except Exception:
        logger.exception("quick_search failed: user=%s query=%r", ctx.userdata.user_id, query[:120])
        return "The quick search failed. Offer to try again, or use execute for a deeper attempt."
    text = (resp.text or "").strip()
    logger.info(
        "quick_search: user=%s query=%r latency_s=%.2f len=%d",
        ctx.userdata.user_id, query[:120], time.monotonic() - t0, len(text),
    )
    return text or "The search returned nothing useful; try execute for a deeper attempt."


# How long a tool call may hold the model's turn open before the answer is
# demoted to a follow-up. Past this, users assume the call is dead and hang up
# -- which kills the session, the tool call, and the answer with it. Simple
# CMA tasks measure 8-9s on fresh sessions; 10 keeps them one clean answer
# instead of a progress beat plus a follow-up.
QUICK_ANSWER_S = 10

# While a slow task runs, keep the channel alive with brief spoken progress
# notes: a working agent should never be indistinguishable from a dead one.
HEARTBEAT_S = 30
MAX_HEARTBEATS = 4

# The gateway echoes this ack when a task outlives its own 110s wait; it is an
# instruction blob for a voice model, not an answer, so never relay it as one.
GATEWAY_DEFERRAL_PREFIX = "[task started]"

_relay_tasks: set[asyncio.Task] = set()


def _gateway_headers(user_id: str) -> dict[str, str]:
    return {
        "Authorization": f"Bearer {os.environ['GATEWAY_SERVICE_TOKEN']}",
        "X-User-Id": user_id,
    }


def _gateway_url() -> str:
    return os.environ["GATEWAY_URL"].rstrip("/")


async def _gateway_execute(user_id: str, task: str, image_b64: str | None = None) -> str:
    payload: dict = {"messages": [{"role": "user", "content": task}]}
    if image_b64:
        payload["image"] = image_b64
    async with aiohttp.ClientSession() as http:
        async with http.post(
            f"{_gateway_url()}/v1/chat/completions",
            headers=_gateway_headers(user_id),
            json=payload,
            timeout=aiohttp.ClientTimeout(total=120),
        ) as resp:
            body = await resp.json()
    try:
        return body["choices"][0]["message"]["content"]
    except (KeyError, IndexError):
        logger.warning("gateway returned unexpected shape: %s", json.dumps(body)[:300])
        return "The action agent returned an unexpected response."


async def _park_result(user_id: str, task: str, result: str) -> None:
    """Hand a result we can no longer speak (call over) back to the gateway;
    the next call's worker drains and delivers it."""
    text = f"A task from an earlier call finished. Task: {task[:200]}\nResult: {result}"
    try:
        async with aiohttp.ClientSession() as http:
            async with http.post(
                f"{_gateway_url()}/pending-notifications",
                headers=_gateway_headers(user_id),
                json={"text": text},
                timeout=aiohttp.ClientTimeout(total=10),
            ) as resp:
                resp.raise_for_status()
        logger.info("parked result for next call: user=%s", user_id)
    except Exception:
        logger.exception("failed to park result: user=%s", user_id)


async def _drain_pending(user_id: str) -> list[str]:
    try:
        async with aiohttp.ClientSession() as http:
            async with http.get(
                f"{_gateway_url()}/pending-notifications",
                headers=_gateway_headers(user_id),
                timeout=aiohttp.ClientTimeout(total=10),
            ) as resp:
                body = await resp.json()
        return [str(n) for n in body.get("notifications") or []]
    except Exception:
        logger.exception("pending drain failed: user=%s", user_id)
        return []


@function_tool
async def execute(ctx: RunContext[Userdata], task: str, attach_view: bool = False) -> str:
    """Delegate an action or lookup to the user's personal action agent: sending
    messages, web search, managing lists and reminders, Google Calendar, research,
    notes, smart home control. Describe the task completely, with names, content
    and platforms. Set attach_view=true when the task concerns something the user
    is showing on camera: the current camera frame is then attached so the agent
    can read it directly (labels, receipts, flyers, dense text)."""
    # Eval override: "never"/"always" force the A/B conditions; "auto" (default)
    # leaves the decision to the voice model's attach_view judgment.
    mode = os.environ.get("ATTACH_VIEW_MODE", "auto")
    should_attach = attach_view if mode == "auto" else (mode == "always")
    image_b64 = encode_latest_frame(ctx.userdata.frames) if should_attach else None
    logger.info(
        "execute start: user=%s attach_view=%s image_kb=%d task=%r",
        ctx.userdata.user_id, attach_view, len(image_b64 or "") * 3 // 4096, task[:200],
    )
    task_start = time.monotonic()
    job = asyncio.ensure_future(_gateway_execute(ctx.userdata.user_id, task, image_b64))
    done, _ = await asyncio.wait({job}, timeout=QUICK_ANSWER_S)
    if done:
        result = await job
        logger.info(
            "execute quick result: user=%s len=%d agent_task_time_s=%.1f",
            ctx.userdata.user_id, len(result), time.monotonic() - task_start,
        )
        return result

    # Slow path: free the model to keep talking, heartbeat while the task runs,
    # then speak the result when it lands. If the user hangs up first, the
    # result is parked at the gateway and delivered at the start of their next
    # call instead of being discarded.
    session = ctx.session
    user_id = ctx.userdata.user_id

    async def relay() -> None:
        heartbeats = 0
        while True:
            done, _ = await asyncio.wait({job}, timeout=HEARTBEAT_S)
            if done:
                break
            if heartbeats < MAX_HEARTBEATS:
                heartbeats += 1
                try:
                    session.generate_reply(
                        instructions=(
                            "The background task is still running. Give a very brief progress "
                            "note -- a few words at most, woven into the conversation, not an "
                            "announcement."
                        )
                    )
                except Exception:
                    # Session gone; stop talking but keep waiting so the result can be parked.
                    heartbeats = MAX_HEARTBEATS
        try:
            result = await job
        except Exception:
            logger.exception(
                "execute background task failed: user=%s agent_task_time_s=%.1f",
                user_id, time.monotonic() - task_start,
            )
            result = None
        if result is None:
            instructions = (
                "The background task failed. Tell the user briefly and offer to try again."
            )
        elif result.startswith(GATEWAY_DEFERRAL_PREFIX):
            # Past the gateway's own wait the result is no longer in our hands;
            # when it lands with no client connected, the gateway parks it itself.
            # Elapsed here is the gateway wait, not the task's true duration.
            logger.info(
                "execute deferred past gateway wait: user=%s elapsed_s=%.1f",
                user_id, time.monotonic() - task_start,
            )
            instructions = (
                "The background task is taking longer than expected and is still running. "
                "Tell the user briefly; the result will be delivered when it's ready, "
                "at the start of their next call if needed."
            )
        else:
            logger.info(
                "execute late result: user=%s len=%d agent_task_time_s=%.1f",
                user_id, len(result), time.monotonic() - task_start,
            )
            instructions = (
                "The result of the earlier background task just arrived. Relay it naturally "
                f"as the answer to what the user asked:\n\n{result}"
            )
        try:
            session.generate_reply(instructions=instructions)
        except Exception:
            logger.warning("session closed before result could be spoken: user=%s", user_id)
            if result is not None and not result.startswith(GATEWAY_DEFERRAL_PREFIX):
                await _park_result(user_id, task, result)

    t = asyncio.create_task(relay())
    _relay_tasks.add(t)
    t.add_done_callback(_relay_tasks.discard)
    return (
        "[running] The task needs more time and keeps running in the background. Tell the user "
        "briefly, in your own words, that you're still on it -- do NOT guess at the answer. "
        "The real result will arrive shortly as a follow-up for you to relay."
    )


def build_llm(engine: str):
    if engine == "openai":
        if not os.environ.get("OPENAI_API_KEY"):
            logger.warning("openai engine requested but OPENAI_API_KEY unset; using gemini")
        else:
            return openai.realtime.RealtimeModel(
                model=os.environ.get("OPENAI_REALTIME_MODEL", "gpt-realtime-2.1"),
            )
    return google.beta.realtime.RealtimeModel(
        model=os.environ.get("GEMINI_MODEL", "gemini-2.5-flash-native-audio-preview-12-2025"),
        voice=os.environ.get("GEMINI_VOICE", "Puck"),
        # Off unless asked: these feed the lk.transcription text streams that
        # drive the clients' live captions.
        input_audio_transcription=genai_types.AudioTranscriptionConfig(),
        output_audio_transcription=genai_types.AudioTranscriptionConfig(),
    )


# Card protocol v1: typed templates the voice model fills, published as JSON on
# the "vc.ui" text-stream topic. Clients render natively; an unknown type
# degrades to info; the same uuid replaces a card in place. This schema is the
# single source of truth for worker and both clients.
CARD_TOOL_SCHEMA = {
    "name": "show_card",
    "description": (
        "Display a visual card on the user's screen alongside your speech. Use it when visual "
        "structure genuinely helps: weather, forecasts, schedules, scores, prices, lists, "
        "comparisons, task results. Keep cards skeletal -- they support what you say, never "
        "replace it. Reusing a uuid updates that card in place instead of adding a new one."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "uuid": {"type": "string", "description": "Stable card id; reuse it to update the card in place."},
            "type": {"type": "string", "enum": ["info", "list", "image"]},
            "title": {"type": "string"},
            "value": {"type": "string", "description": "One big highlighted value, e.g. '91°F' or '$189.44'."},
            "body": {"type": "string", "description": "One short supporting sentence."},
            "facts": {
                "type": "array",
                "description": "Label/value rows (info cards): forecast days, stats, key fields.",
                "items": {
                    "type": "object",
                    "properties": {"label": {"type": "string"}, "value": {"type": "string"}},
                    "required": ["label", "value"],
                },
            },
            "items": {
                "type": "array",
                "description": "Rows for list cards: schedules, results, tasks.",
                "items": {
                    "type": "object",
                    "properties": {
                        "glyph": {"type": "string", "description": "Optional single leading character."},
                        "title": {"type": "string"},
                        "subtitle": {"type": "string"},
                        "trailing": {"type": "string", "description": "Right-aligned text, e.g. a time or price."},
                    },
                    "required": ["title"],
                },
            },
            "image_url": {"type": "string", "description": "https image URL (image cards only)."},
            "fallback_text": {"type": "string", "description": "One plain-text line summarizing the card."},
        },
        "required": ["uuid", "type", "fallback_text"],
    },
}


def _watch_video(ctx: JobContext, holder: FrameHolder) -> None:
    """Keep holder current with the user's camera. Runs beside the realtime
    model's own video consumption; this copy exists so tool calls can attach
    the exact frame the user is looking at."""

    def start_reader(track: rtc.Track) -> None:
        async def read() -> None:
            stream = rtc.VideoStream(track)
            async for ev in stream:
                holder.frame = ev.frame
                holder.rotation = int(getattr(ev, "rotation", 0) or 0)

        t = asyncio.create_task(read())
        _relay_tasks.add(t)
        t.add_done_callback(_relay_tasks.discard)

    @ctx.room.on("track_subscribed")
    def _on_track(track: rtc.Track, publication: rtc.TrackPublication, participant: rtc.RemoteParticipant) -> None:
        if track.kind == rtc.TrackKind.KIND_VIDEO:
            start_reader(track)

    for p in ctx.room.remote_participants.values():
        for pub in p.track_publications.values():
            if pub.track is not None and pub.track.kind == rtc.TrackKind.KIND_VIDEO:
                start_reader(pub.track)


async def entrypoint(ctx: JobContext):
    await ctx.connect()

    # The phone's room token carries identity (= gateway userId) and metadata
    # (= engine choice from Settings). Both decided client-side, minted
    # server-side, read here.
    participant = await ctx.wait_for_participant()
    try:
        meta = json.loads(participant.metadata) if participant.metadata else {}
    except json.JSONDecodeError:
        meta = {}
    engine = meta.get("engine", "gemini")
    user_id = participant.identity or "demo"
    logger.info("session start: user=%s engine=%s", user_id, engine)

    frames = FrameHolder()
    _watch_video(ctx, frames)

    # Flat scalar signature: the Gemini realtime plugin silently drops
    # raw-schema tools when building provider declarations, and nested object
    # params risk $ref-style schemas the converters mangle. Rows travel as
    # JSON-in-string; the wire payload (vc.ui) keeps the CARD_TOOL_SCHEMA shape.
    async def _show_card(
        uuid: str,
        card_type: str,
        fallback_text: str,
        title: str | None = None,
        value: str | None = None,
        body: str | None = None,
        facts_json: str | None = None,
        items_json: str | None = None,
        image_url: str | None = None,
    ) -> str:
        """Display a visual card on the user's screen alongside your speech. Use it whenever
        your answer has visual structure: weather, forecasts, schedules, scores, prices,
        lists, comparisons. Keep it skeletal -- the card supports what you say.

        card_type: one of "info", "list", "image".
        fallback_text: one plain-text line summarizing the card.
        value: one big highlighted value, e.g. "91°F".
        facts_json: JSON array of {"label","value"} rows, e.g.
          '[{"label":"Wed","value":"91° / 63°"},{"label":"Thu","value":"85° / 61°"}]'.
        items_json: JSON array of {"title","subtitle","trailing","glyph"} rows (title required).
        Reusing a uuid updates that card in place."""

        def rows(raw: str | None) -> list:
            if not raw:
                return []
            try:
                parsed = json.loads(raw)
                return parsed if isinstance(parsed, list) else []
            except json.JSONDecodeError:
                logger.warning("show_card: bad rows json: %s", raw[:120])
                return []

        card = {
            "uuid": uuid,
            "version": 1,
            "type": card_type if card_type in ("info", "list", "image") else "info",
            "title": title,
            "value": value,
            "body": body,
            "facts": rows(facts_json),
            "items": rows(items_json),
            "image_url": image_url,
            "fallback_text": fallback_text,
        }
        payload = json.dumps({k: v for k, v in card.items() if v is not None})
        if len(payload) > 16_384:
            return "Card too large -- show fewer rows."
        await ctx.room.local_participant.send_text(payload, topic="vc.ui")
        logger.info(
            "show_card: user=%s type=%s uuid=%s bytes=%d",
            user_id, card["type"], uuid, len(payload),
        )
        return "Card shown. Continue speaking naturally."

    show_card = function_tool(_show_card, name="show_card")

    session = AgentSession(
        llm=build_llm(engine),
        userdata=Userdata(user_id=user_id, frames=frames),
    )

    await session.start(
        agent=Agent(instructions=INSTRUCTIONS, tools=[execute, quick_search, show_card]),
        room=ctx.room,
        # Video is opt-in (RoomInputOptions.video_enabled defaults to False);
        # without this the model gets no frames and hallucinates a scene when
        # asked what it sees.
        room_input_options=RoomInputOptions(video_enabled=True),
    )

    # Results that finished after a previous call ended are waiting at the
    # gateway; deliver them up front so a hangup never discards an answer.
    pending = await _drain_pending(user_id)
    if pending:
        logger.info("delivering parked results: user=%s count=%d", user_id, len(pending))
        joined = "\n\n".join(pending)
        try:
            session.generate_reply(
                instructions=(
                    "Tasks the user started during an earlier call finished while they were "
                    "away. Greet them briefly and relay the results naturally:\n\n" + joined
                )
            )
        except Exception:
            logger.exception("failed to deliver parked results: user=%s content=%s", user_id, joined[:500])


if __name__ == "__main__":
    cli.run_app(WorkerOptions(entrypoint_fnc=entrypoint))
