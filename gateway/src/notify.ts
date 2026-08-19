import type { WebSocket } from "ws";
import { saveStore, userResources } from "./store.js";
import { appendTrace } from "./trace.js";

/**
 * Registry of connected app sockets per user, plus helpers that emit events in
 * the exact shape the VisionClaw clients already parse (OpenClawEventClient):
 *   - assistant notifications ride the "heartbeat" event (status "sent" + preview)
 *   - scheduled-task results ride the "cron" event (action "finished" + summary)
 */

const sockets = new Map<string, Set<WebSocket>>();

export function registerSocket(userId: string, ws: WebSocket): void {
  let set = sockets.get(userId);
  if (!set) {
    set = new Set();
    sockets.set(userId, set);
  }
  set.add(ws);
  ws.on("close", () => {
    set.delete(ws);
    if (set.size === 0) sockets.delete(userId);
  });
}

function broadcast(userId: string, message: unknown): boolean {
  const set = sockets.get(userId);
  if (!set || set.size === 0) return false;
  const payload = JSON.stringify(message);
  for (const ws of set) {
    if (ws.readyState === ws.OPEN) ws.send(payload);
  }
  return true;
}

/** Push an assistant notification; the app renders it as a proactive message. */
export function notifyUser(userId: string, preview: string): boolean {
  return broadcast(userId, {
    type: "event",
    event: "heartbeat",
    payload: { status: "sent", preview, silent: false },
  });
}

/** Push a finished scheduled-task summary. */
export function notifyScheduled(userId: string, summary: string): boolean {
  return broadcast(userId, {
    type: "event",
    event: "cron",
    payload: { action: "finished", summary },
  });
}

// ---------- parked results (no live channel at delivery time) ----------

const MAX_PENDING = 20;

/** Park a result that had nowhere to land (call over, no client connected).
 * The voice worker drains these at the start of the user's next call and
 * speaks them, so a hangup no longer discards a finished task's answer. */
export async function queuePending(userId: string, text: string): Promise<void> {
  const user = await userResources(userId);
  user.pendingNotifications ??= [];
  user.pendingNotifications.push(text);
  if (user.pendingNotifications.length > MAX_PENDING) {
    user.pendingNotifications = user.pendingNotifications.slice(-MAX_PENDING);
  }
  appendTrace(userId, [{ type: "result_parked", text: text.slice(0, 300) }]);
  await saveStore();
}

export async function drainPending(userId: string): Promise<string[]> {
  const user = await userResources(userId);
  const pending = user.pendingNotifications ?? [];
  if (pending.length === 0) return [];
  user.pendingNotifications = [];
  appendTrace(userId, [{ type: "parked_delivered", count: pending.length }]);
  await saveStore();
  return pending;
}
