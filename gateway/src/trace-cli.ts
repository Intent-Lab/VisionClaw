import "dotenv/config";
import { anthropic } from "./cma.js";
import { loadStore } from "./store.js";
import { config } from "./config.js";
import { initStore } from "./store.js";

/**
 * Turn-by-turn trace of a user's session, read from the CMA event log.
 *
 * The /tasks endpoint keeps only prompts and answers; this keeps the parts you
 * need when something goes wrong -- which tool ran, with what arguments, how
 * long it took, whether it errored, and why the turn stopped.
 *
 *   npm run trace              # default user, last 5 turns
 *   npm run trace -- demo 20
 */

interface Ev {
  id: string;
  type: string;
  processed_at?: string | null;
  content?: Array<{ type: string; text?: string }>;
  name?: string;
  input?: unknown;
  is_error?: boolean;
  evaluated_permission?: string;
  mcp_server_name?: string;
  mcp_tool_use_id?: string;
  stop_reason?: { type?: string };
}

const text = (c: Ev["content"]): string =>
  (c ?? [])
    .filter((b) => b.type === "text" && b.text)
    .map((b) => b.text)
    .join("\n")
    .trim();

const clip = (s: string, n: number): string =>
  s.length > n ? `${s.slice(0, n)}...` : s;

const clock = (ts?: string | null): string =>
  ts ? new Date(ts).toISOString().slice(11, 19) : "--:--:--";

async function main(): Promise<void> {
  const [userArg, limitArg] = process.argv.slice(2);
  const userId = userArg ?? "demo";
  const turns = Number(limitArg ?? 5);

  initStore(config.storePath);
  const store = await loadStore();
  const sessionId = store.users[userId]?.sessionId;
  if (!sessionId) {
    console.error(`no session for user "${userId}" in ${config.storePath}`);
    console.error(`known users: ${Object.keys(store.users).join(", ") || "(none)"}`);
    process.exit(1);
  }

  const events: Ev[] = [];
  for await (const ev of anthropic.beta.sessions.events.list(sessionId)) {
    events.push(ev as unknown as Ev);
    if (events.length >= 1000) break;
  }

  // Tool call and result are separate events; pair them to time and score each call.
  const results = new Map<string, Ev>();
  for (const ev of events) {
    if (ev.mcp_tool_use_id) results.set(ev.mcp_tool_use_id, ev);
  }

  const starts = events.filter((e) => e.type === "user.message");
  const from = starts.length > turns ? starts[starts.length - turns].id : starts[0]?.id;
  const begin = from ? events.findIndex((e) => e.id === from) : 0;

  console.log(`session ${sessionId}  user ${userId}  (${events.length} events)\n`);

  let errors = 0;
  for (const ev of events.slice(Math.max(begin, 0))) {
    const t = clock(ev.processed_at);
    switch (ev.type) {
      case "user.message":
        console.log(`\n${t}  USER   ${clip(text(ev.content), 160)}`);
        break;
      case "agent.thinking":
        console.log(`${t}  think  ${clip(text(ev.content).replace(/\s+/g, " "), 110)}`);
        break;
      case "agent.mcp_tool_use":
      case "agent.tool_use": {
        const res = results.get(ev.id);
        const ms = res?.processed_at && ev.processed_at
          ? new Date(res.processed_at).getTime() - new Date(ev.processed_at).getTime()
          : null;
        const where = ev.mcp_server_name ? `${ev.mcp_server_name}/` : "";
        const verdict = res?.is_error ? "ERROR" : res ? "ok" : "no result";
        if (res?.is_error) errors++;
        console.log(
          `${t}  TOOL   ${where}${ev.name}  [${verdict}${ms === null ? "" : ` ${ms}ms`}]` +
            (ev.evaluated_permission && ev.evaluated_permission !== "allow"
              ? `  permission=${ev.evaluated_permission}`
              : "")
        );
        console.log(`               args ${clip(JSON.stringify(ev.input ?? {}), 150)}`);
        if (res) console.log(`               ->   ${clip(text(res.content).replace(/\s+/g, " "), 150)}`);
        break;
      }
      case "agent.message":
        if (text(ev.content)) console.log(`${t}  AGENT  ${clip(text(ev.content), 200)}`);
        break;
      case "session.status_idle": {
        const reason = ev.stop_reason?.type ?? "unknown";
        console.log(`${t}  idle   stop_reason=${reason}${reason !== "end_turn" ? "   <-- turn did not complete" : ""}`);
        break;
      }
    }
  }

  console.log(`\n${errors === 0 ? "no tool errors" : `${errors} tool error(s) above`}`);
}

await main();
