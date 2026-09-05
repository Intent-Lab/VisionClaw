import { anthropic } from "./cma.js";

/**
 * A tool gated by `always_ask` parks the session in `requires_action` until the
 * client answers. Nothing else answers for us, so approve automatically and let
 * the drain continue; without this the loop waits forever. Returns false when
 * the pending action is something we cannot resolve, so the caller can stop.
 *
 * When destructive tools arrive, this is the hook that should instead surface a
 * spoken confirmation and wait for the user's actual answer.
 */
async function resolvePendingAction(sessionId: string, eventIds: string[]): Promise<boolean> {
  if (eventIds.length === 0) return false;
  let resolved = false;
  for (const toolUseId of eventIds) {
    try {
      await anthropic.beta.sessions.events.send(sessionId, {
        events: [{ type: "user.tool_confirmation", tool_use_id: toolUseId, result: "allow" }],
      });
      resolved = true;
    } catch (err) {
      console.warn("[turn] could not confirm pending tool use", toolUseId, err);
    }
  }
  return resolved;
}

/**
 * Find and answer any confirmation the session is already parked on. A turn
 * abandoned mid-flight (client hang-up, gateway restart) leaves the session in
 * `requires_action`, and the API then rejects every new `user.message` until it
 * is answered — so without this a single interrupted turn wedges the user for good.
 */
async function clearPendingActions(sessionId: string): Promise<void> {
  const recent: Array<{ type: string; stop_reason?: { type?: string; event_ids?: string[] } }> = [];
  for await (const ev of anthropic.beta.sessions.events.list(sessionId)) {
    recent.push(ev as (typeof recent)[number]);
    if (recent.length >= 400) break;
  }
  for (let i = recent.length - 1; i >= 0 && i > recent.length - 12; i--) {
    const ev = recent[i];
    if (ev.type === "session.status_idle" && ev.stop_reason?.type === "requires_action") {
      const ids = ev.stop_reason.event_ids ?? [];
      if (ids.length > 0) {
        console.log("[turn] clearing stale pending confirmation(s):", ids.join(","));
        await resolvePendingAction(sessionId, ids);
      }
      return;
    }
  }
}

/** Send a turn, self-healing if the session is parked on an unanswered confirmation. */
async function sendUserTurn(
  sessionId: string,
  userText: string,
  contextNotes: string[],
  imageBase64?: string,
): Promise<void> {
  // The user turn is text plus, optionally, what the user is looking at: the
  // voice layer attaches the current camera frame when the task refers to
  // something visible, so the agent reads pixels instead of a lossy verbal
  // description. The API accepts at most ONE system.message per request, so
  // however many notes queued up between turns, they travel as a single event.
  const userContent: Array<
    | { type: "text"; text: string }
    | { type: "image"; source: { type: "base64"; media_type: string; data: string } }
  > = [{ type: "text", text: userText }];
  if (imageBase64) {
    userContent.push({
      type: "image",
      source: { type: "base64", media_type: "image/jpeg", data: imageBase64 },
    });
  }
  const events = [
    { type: "user.message" as const, content: userContent },
    ...(contextNotes.length > 0
      ? [
          {
            type: "system.message" as const,
            content: [{ type: "text" as const, text: contextNotes.join("\n\n") }],
          },
        ]
      : []),
  ];
  try {
    await anthropic.beta.sessions.events.send(sessionId, { events });
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    if (!msg.includes("waiting on responses to events")) throw err;
    await clearPendingActions(sessionId);
    await anthropic.beta.sessions.events.send(sessionId, { events });
  }
}

/** One tool call the managed agent made during a turn, as seen on the event stream. */
export interface TurnToolCall {
  name: string;
  server?: string;
  ok: boolean | null;
  ms: number | null;
  args: string;
  result: string;
}

/** What the subagent did during a turn -- the study's tool-depth and tool-mix data. */
export interface TurnStats {
  tools: TurnToolCall[];
  thinking: number;
  messages: number;
  stop_reason: string | null;
  duration_ms: number;
}

export interface TurnResult {
  /** Final text if it finished within the wait budget, else null. */
  text: string | null;
  /** True when the turn is still running and the result will arrive via onLateResult. */
  deferred: boolean;
  stats?: TurnStats;
}

const clip = (s: string, n: number): string => (s.length > n ? `${s.slice(0, n)}...` : s);

function blockText(content: unknown): string {
  if (!Array.isArray(content)) return "";
  return content
    .filter((b) => b && typeof b === "object" && (b as { type?: string }).type === "text")
    .map((b) => String((b as { text?: string }).text ?? ""))
    .join("\n")
    .trim();
}

/**
 * Run one conversational turn against a managed-agents session.
 *
 * Opens the event stream FIRST (events emitted before the stream opens are not
 * replayed), then sends the user message, then drains until the session goes
 * idle with a terminal stop reason. If the drain exceeds maxWaitMs the call
 * returns { deferred: true } and keeps consuming in the background; the final
 * text is delivered through onLateResult.
 */
export async function runTurn(
  sessionId: string,
  userText: string,
  maxWaitMs: number,
  onLateResult: (text: string, stats: TurnStats) => void,
  contextNotes: string[] = [],
  imageBase64?: string,
): Promise<TurnResult> {
  const stream = await anthropic.beta.sessions.events.stream(sessionId);

  // system.message events are only accepted immediately after a user.message
  // in the same request, so queued context rides along with the next turn.
  await sendUserTurn(sessionId, userText, contextNotes, imageBase64);

  const parts: string[] = [];
  let timedOut = false;
  let sawError = false;

  // Subagent activity for the trace: tool calls paired with their results by id.
  const startedAt = Date.now();
  const stats: TurnStats = { tools: [], thinking: 0, messages: 0, stop_reason: null, duration_ms: 0 };
  const pendingTools = new Map<string, { call: TurnToolCall; at: number }>();
  const drain = (async () => {
    for await (const event of stream) {
      const ev = event as unknown as {
        type: string;
        id?: string;
        name?: string;
        input?: unknown;
        content?: unknown;
        mcp_server_name?: string;
        mcp_tool_use_id?: string;
        tool_use_id?: string;
        is_error?: boolean;
        stop_reason?: { type?: string };
      };
      if (ev.type === "agent.tool_use" || ev.type === "agent.mcp_tool_use") {
        const call: TurnToolCall = {
          name: ev.name ?? "?",
          server: ev.mcp_server_name,
          ok: null,
          ms: null,
          args: clip(JSON.stringify(ev.input ?? {}), 200),
          result: "",
        };
        stats.tools.push(call);
        if (ev.id) pendingTools.set(ev.id, { call, at: Date.now() });
      } else {
        const ref = ev.mcp_tool_use_id ?? ev.tool_use_id;
        if (ref && pendingTools.has(ref)) {
          const { call, at } = pendingTools.get(ref)!;
          call.ok = !ev.is_error;
          call.ms = Date.now() - at;
          call.result = clip(blockText(ev.content).replace(/\s+/g, " "), 200);
          pendingTools.delete(ref);
        }
      }
      if (ev.type === "agent.thinking") stats.thinking++;
      if (ev.type === "session.status_idle") stats.stop_reason = ev.stop_reason?.type ?? null;
      stats.duration_ms = Date.now() - startedAt;
      if (event.type === "agent.message") {
        stats.messages++;
        for (const block of event.content) {
          if (block.type === "text") parts.push(block.text);
        }
      } else if (event.type === "session.error") {
        // Error events can be transient and precede a successful answer;
        // keep draining and let a terminal status end the turn. Only if the
        // stream ends with no text at all does this become the user's answer.
        console.error("[turn] session.error event:", JSON.stringify(event).slice(0, 500));
        sawError = true;
      } else if (event.type === "session.status_terminated") {
        break;
      } else if (event.type === "session.status_idle") {
        // Idle pending a client action is not terminal, but only if we actually
        // resolve it; otherwise the drain would hang until the socket dies.
        const stop = (event as { stop_reason?: { type?: string; event_ids?: string[] } }).stop_reason;
        if (stop?.type !== "requires_action") break;
        if (!(await resolvePendingAction(sessionId, stop.event_ids ?? []))) break;
      }
    }
    if (parts.length === 0 && sawError) {
      parts.push("Something went wrong while working on that. Try again in a moment.");
    }
    return parts.join("\n\n").trim();
  })();

  const timeout = new Promise<null>((resolve) => {
    setTimeout(() => {
      timedOut = true;
      resolve(null);
    }, maxWaitMs).unref?.();
  });

  const finished = await Promise.race([drain, timeout]);

  if (finished !== null) {
    return { text: finished || "Done.", deferred: false, stats };
  }

  // Deferred: keep draining in the background and hand the result to the caller.
  void drain
    .then((text) => {
      if (timedOut && text) onLateResult(text, stats);
    })
    .catch((err) => console.error("[turn] background drain failed:", err));

  return { text: null, deferred: true };
}

/**
 * Streaming variant: forwards text as it is generated via `emit`, using CMA
 * live previews (event_deltas). Deltas are best-effort prefixes; the buffered
 * agent.message is authoritative, so on arrival any text the preview missed is
 * emitted as a remainder. Returns the final full text.
 */
export async function runTurnStreaming(
  sessionId: string,
  userText: string,
  contextNotes: string[],
  emit: (text: string) => void,
): Promise<string> {
  const stream = await anthropic.beta.sessions.events.stream(sessionId, {
    event_deltas: ["agent.message"],
  });

  await sendUserTurn(sessionId, userText, contextNotes);

  const parts: string[] = [];
  let sawError = false;
  // event_id -> content index -> text already emitted from deltas
  const previews = new Map<string, Map<number, string>>();
  let currentEventId: string | null = null;

  const separatorFor = (eventId: string) => {
    if (currentEventId !== null && currentEventId !== eventId) emit("\n\n");
    currentEventId = eventId;
  };

  for await (const event of stream) {
    if (event.type === "event_delta") {
      const d = event.delta;
      if (d.type === "content_delta" && d.content.type === "text" && d.content.text) {
        separatorFor(event.event_id);
        let byIndex = previews.get(event.event_id);
        if (!byIndex) {
          byIndex = new Map();
          previews.set(event.event_id, byIndex);
        }
        const i = d.index ?? 0;
        byIndex.set(i, (byIndex.get(i) ?? "") + d.content.text);
        emit(d.content.text);
      }
    } else if (event.type === "agent.message") {
      const byIndex = previews.get(event.id) ?? new Map<number, string>();
      separatorFor(event.id);
      const blockTexts: string[] = [];
      event.content.forEach((block, i) => {
        if (block.type !== "text" || !block.text) return;
        const seen = byIndex.get(i) ?? "";
        if (block.text.length > seen.length) emit(block.text.slice(seen.length));
        blockTexts.push(block.text);
      });
      previews.delete(event.id);
      const full = blockTexts.join("\n").trim();
      if (full) parts.push(full);
    } else if (event.type === "session.error") {
      // Transient error events can precede a successful answer; keep draining.
      console.error("[turn] session.error event:", JSON.stringify(event).slice(0, 500));
      sawError = true;
    } else if (event.type === "session.status_terminated") {
      break;
    } else if (event.type === "session.status_idle") {
      const stop = (event as { stop_reason?: { type?: string; event_ids?: string[] } }).stop_reason;
      if (stop?.type !== "requires_action") break;
      if (!(await resolvePendingAction(sessionId, stop.event_ids ?? []))) break;
    }
  }

  if (parts.length === 0 && sawError) {
    const msg = "Something went wrong while working on that. Try again in a moment.";
    emit(msg);
    parts.push(msg);
  }
  return parts.join("\n\n").trim();
}

// ---------- queued context ----------
// The API rejects a standalone system.message, so context is queued per user
// and attached to that user's next turn. In-memory: acceptable loss on restart
// (context is advisory), persist alongside the store if that changes.

const pendingContext = new Map<string, string[]>();

/** Queue side-channel context (e.g. a voice-session summary) for the user's next turn. */
export function queueContext(userId: string, context: string): void {
  const list = pendingContext.get(userId) ?? [];
  list.push(`Context from the live voice session: ${context}`);
  // Keep only the most recent notes; old context goes stale fast.
  pendingContext.set(userId, list.slice(-5));
}

/** Drain queued context for a user (called when their next turn is sent). */
export function drainContext(userId: string): string[] {
  const list = pendingContext.get(userId) ?? [];
  pendingContext.delete(userId);
  return list;
}
