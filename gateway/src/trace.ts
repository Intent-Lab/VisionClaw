import { promises as fs } from "node:fs";
import path from "node:path";
import { config } from "./config.js";

/**
 * Per-user interaction trace: what the user said, what the voice model said,
 * and what tools/actions ran. One JSONL file per user on the data volume, so
 * the deployment study can pull a complete text record of every call.
 *
 * Text only BY DESIGN (study privacy protocol): events never carry images.
 * Field names that could smuggle a frame are stripped at the door rather than
 * trusted away, and long strings are truncated so a runaway payload cannot
 * bloat the volume.
 */

const tracesDir = path.join(path.dirname(config.storePath), "traces");

// userIds become filenames; anything unexpected is refused, not escaped.
const SAFE_USER = /^[A-Za-z0-9_-]{1,64}$/;
const MAX_EVENTS_PER_POST = 200;
const MAX_FIELD_CHARS = 2000;
const FORBIDDEN_KEYS = new Set([
  "image",
  "images",
  "image_b64",
  "image_base64",
  "imagebase64",
  "frame",
  "frames",
  "jpeg",
  "png",
  "screenshot",
]);

function sanitize(event: unknown): Record<string, unknown> | null {
  if (typeof event !== "object" || event === null || Array.isArray(event)) return null;
  const out: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(event)) {
    if (FORBIDDEN_KEYS.has(key.toLowerCase())) continue;
    if (typeof value === "string") {
      out[key] =
        value.length > MAX_FIELD_CHARS ? value.slice(0, MAX_FIELD_CHARS) + "...[truncated]" : value;
    } else if (typeof value === "number" || typeof value === "boolean" || value === null) {
      out[key] = value;
    } else {
      const s = JSON.stringify(value) ?? "";
      out[key] = s.length > MAX_FIELD_CHARS ? s.slice(0, MAX_FIELD_CHARS) + "...[truncated]" : value;
    }
  }
  if (typeof out.ts !== "string") out.ts = new Date().toISOString();
  if (typeof out.type !== "string") out.type = "unknown";
  return out;
}

// Appends are serialized through one chain so concurrent batches (worker flush
// racing a gateway-side parked event) never interleave half-lines in the file.
let writeChain: Promise<void> = Promise.resolve();

export function appendTrace(userId: string, events: unknown[]): number {
  if (!SAFE_USER.test(userId)) return 0;
  const lines = events
    .slice(0, MAX_EVENTS_PER_POST)
    .map(sanitize)
    .filter((e): e is Record<string, unknown> => e !== null)
    .map((e) => JSON.stringify(e) + "\n");
  if (lines.length === 0) return 0;
  writeChain = writeChain
    .then(async () => {
      await fs.mkdir(tracesDir, { recursive: true });
      await fs.appendFile(path.join(tracesDir, `${userId}.jsonl`), lines.join(""), "utf8");
    })
    .catch((err) => console.error("[trace] append failed:", err));
  return lines.length;
}

export async function readTrace(
  userId: string,
  limit: number,
  since?: string,
): Promise<Record<string, unknown>[]> {
  if (!SAFE_USER.test(userId)) return [];
  // Settle queued appends first so a read-after-write sees its own events.
  await writeChain;
  let raw: string;
  try {
    raw = await fs.readFile(path.join(tracesDir, `${userId}.jsonl`), "utf8");
  } catch {
    return [];
  }
  const events: Record<string, unknown>[] = [];
  for (const line of raw.split("\n")) {
    if (!line) continue;
    try {
      events.push(JSON.parse(line));
    } catch {
      // A torn line (crash mid-append) loses one event, never the read.
    }
  }
  const filtered = since ? events.filter((e) => typeof e.ts === "string" && e.ts >= since) : events;
  return filtered.slice(-limit);
}
