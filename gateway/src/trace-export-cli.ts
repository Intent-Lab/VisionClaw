import "dotenv/config";
import { promises as fs } from "node:fs";
import path from "node:path";

/**
 * Study export of the interaction trace: per-user CSVs plus a markdown
 * summary, grouped into sessions with the same rules the dashboard uses.
 *
 *   npm run trace:export -- <userId> [--since ISO] [--out dir]
 *   npm run trace:export -- --all [--since ISO] [--out dir]
 *   npm run trace:export -- fixture --from-file gateway/test-fixtures/trace-sample.json
 *
 * Env: GATEWAY_URL (default https://api.visionagents.app) and
 * GATEWAY_SERVICE_TOKEN (service token; the user is named per request via
 * X-User-Id, exactly as the voice worker does). --from-file skips the network
 * and reads a raw {events:[...]} dump instead.
 */

type Ev = Record<string, unknown> & { ts?: string; type?: string };

interface Session {
  index: number;
  start: string;
  end?: string;
  engine?: string;
  room?: string;
  synthetic: boolean;
  events: Ev[];
}

const PAGE = 1000;

// ---------- args ----------

function parseArgs(argv: string[]) {
  const out: { user?: string; all: boolean; since?: string; out: string; fromFile?: string } = {
    all: false,
    out: "trace-export",
  };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--all") out.all = true;
    else if (a === "--since") out.since = argv[++i];
    else if (a === "--out") out.out = argv[++i];
    else if (a === "--from-file") out.fromFile = argv[++i];
    else if (!a.startsWith("--") && !out.user) out.user = a;
  }
  return out;
}

// ---------- fetching ----------

function gatewayUrl(): string {
  return (process.env.GATEWAY_URL ?? "https://api.visionagents.app").replace(/\/$/, "");
}

function serviceHeaders(userId?: string): Record<string, string> {
  const token = process.env.GATEWAY_SERVICE_TOKEN;
  if (!token) {
    console.error("GATEWAY_SERVICE_TOKEN is not set (gateway/.env or the environment).");
    process.exit(1);
  }
  const h: Record<string, string> = { Authorization: `Bearer ${token}` };
  if (userId) h["X-User-Id"] = userId;
  return h;
}

async function listUsers(): Promise<string[]> {
  const r = await fetch(`${gatewayUrl()}/users`, { headers: serviceHeaders() });
  if (!r.ok) throw new Error(`GET /users -> ${r.status}`);
  return ((await r.json()) as { users: string[] }).users;
}

/**
 * With a `since` cursor the server answers the OLDEST `limit` events at or
 * after it, so paging forward from the epoch walks the whole history. Each
 * page moves `since` to the newest ts seen and drops the boundary duplicate;
 * the loop ends when a page comes back short or adds nothing new. Only the
 * page cap can truncate, and that is reported rather than silently dropped.
 */
async function fetchAll(userId: string, since?: string): Promise<{ events: Ev[]; truncated: boolean }> {
  const seen = new Set<string>();
  const events: Ev[] = [];
  let cursor = since ?? "1970-01-01T00:00:00.000Z";
  let truncated = false;
  const MAX_PAGES = 500;
  for (let page = 0; page < MAX_PAGES; page++) {
    if (page === MAX_PAGES - 1) truncated = true;
    const q = new URLSearchParams({ limit: String(PAGE) });
    q.set("since", cursor);
    const r = await fetch(`${gatewayUrl()}/trace?${q}`, { headers: serviceHeaders(userId) });
    if (!r.ok) throw new Error(`GET /trace for ${userId} -> ${r.status}`);
    const batch = ((await r.json()) as { events: Ev[] }).events;
    let added = 0;
    for (const e of batch) {
      const key = JSON.stringify(e);
      if (seen.has(key)) continue;
      seen.add(key);
      events.push(e);
      added++;
    }
    if (batch.length < PAGE || added === 0) break;
    const newest = batch.map((e) => String(e.ts ?? "")).sort().at(-1);
    if (!newest || newest === cursor) break;
    cursor = newest;
  }
  return { events, truncated };
}

// ---------- shaping ----------

function sortEvents(events: Ev[]): Ev[] {
  return [...events].sort((a, b) => String(a.ts ?? "").localeCompare(String(b.ts ?? "")));
}

function groupSessions(events: Ev[]): Session[] {
  const sessions: Session[] = [];
  let cur: Session | null = null;
  for (const e of events) {
    if (e.type === "session_start" || cur === null) {
      cur = {
        index: sessions.length,
        start: String(e.ts ?? ""),
        engine: typeof e.engine === "string" ? e.engine : undefined,
        room: typeof e.room === "string" ? e.room : undefined,
        synthetic: e.type !== "session_start",
        events: [],
      };
      sessions.push(cur);
    }
    cur.events.push(e);
    if (e.type === "session_end") {
      cur.end = String(e.ts ?? "");
      cur = null;
    }
  }
  return sessions;
}

const isAction = (e: Ev) => String(e.type).startsWith("agent_action");

function roleOrTool(e: Ev): string {
  if (e.type === "user_utterance") return "user";
  if (e.type === "agent_utterance") return "agent";
  if (isAction(e)) return String(e.tool ?? "");
  return "";
}

function primaryText(e: Ev): string {
  const pick = (...keys: string[]) => {
    for (const k of keys) if (typeof e[k] === "string" && e[k]) return e[k] as string;
    return "";
  };
  switch (e.type) {
    case "user_utterance":
    case "agent_utterance":
    case "result_parked":
      return pick("text");
    case "session_start":
      return pick("room");
    case "agent_action":
    case "agent_action_result":
      return pick("query", "task", "text", "title", "match");
    default:
      return "";
  }
}

const PRIMARY_KEYS = new Set(["ts", "type", "tool", "text", "query", "task", "title", "match", "room"]);

function detailsJson(e: Ev): string {
  const rest: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(e)) if (!PRIMARY_KEYS.has(k)) rest[k] = v;
  return Object.keys(rest).length ? JSON.stringify(rest) : "";
}

function durationS(s: Session): number | "" {
  if (!s.end) return "";
  return Math.round((Date.parse(s.end) - Date.parse(s.start)) / 1000);
}

function sessionStats(s: Session) {
  let userTurns = 0;
  let agentTurns = 0;
  let cards = 0;
  const byTool: Record<string, number> = {};
  for (const e of s.events) {
    if (e.type === "user_utterance") userTurns++;
    else if (e.type === "agent_utterance") agentTurns++;
    else if (isAction(e)) {
      const tool = String(e.tool ?? "unknown");
      byTool[tool] = (byTool[tool] ?? 0) + 1;
      if (tool === "show_card") cards++;
    }
  }
  return { userTurns, agentTurns, cards, byTool };
}

// ---------- writers ----------

function csvCell(v: unknown): string {
  const s = v === undefined || v === null ? "" : String(v);
  return /[",\n\r]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
}

const csv = (rows: unknown[][]): string => rows.map((r) => r.map(csvCell).join(",")).join("\n") + "\n";

function eventsCsv(sessions: Session[]): string {
  const rows: unknown[][] = [["ts", "session_index", "type", "role_or_tool", "text", "details_json"]];
  for (const s of sessions)
    for (const e of s.events) rows.push([e.ts, s.index, e.type, roleOrTool(e), primaryText(e), detailsJson(e)]);
  return csv(rows);
}

function sessionsCsv(sessions: Session[]): string {
  const rows: unknown[][] = [
    ["index", "start", "end", "duration_s", "engine", "user_turns", "agent_turns", "actions_by_tool", "cards", "partial"],
  ];
  for (const s of sessions) {
    const st = sessionStats(s);
    rows.push([
      s.index,
      s.start,
      s.end ?? "",
      durationS(s),
      s.engine ?? "",
      st.userTurns,
      st.agentTurns,
      JSON.stringify(st.byTool),
      st.cards,
      s.synthetic || !s.end ? "yes" : "",
    ]);
  }
  return csv(rows);
}

const median = (xs: number[]): number => {
  if (!xs.length) return 0;
  const s = [...xs].sort((a, b) => a - b);
  const m = Math.floor(s.length / 2);
  return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2;
};
const mean = (xs: number[]): number => (xs.length ? xs.reduce((a, b) => a + b, 0) / xs.length : 0);
const fmt = (n: number): string => (Number.isInteger(n) ? String(n) : n.toFixed(1));
const clip = (s: string, n: number): string => (s.length > n ? `${s.slice(0, n)}...` : s);

interface UserReport {
  userId: string;
  events: number;
  sessions: number;
  userTurns: number;
  agentTurns: number;
  actions: number;
  byTool: Record<string, number>;
  problems: number;
  truncated: boolean;
}

function summaryMd(userId: string, sessions: Session[], truncated: boolean): { md: string; report: UserReport } {
  const all = sessions.flatMap((s) => s.events);
  const byTool: Record<string, number> = {};
  let userTurns = 0;
  let agentTurns = 0;
  let actions = 0;
  for (const e of all) {
    if (e.type === "user_utterance") userTurns++;
    else if (e.type === "agent_utterance") agentTurns++;
    else if (isAction(e)) {
      actions++;
      const t = String(e.tool ?? "unknown");
      byTool[t] = (byTool[t] ?? 0) + 1;
    }
  }
  const perSession = sessions.map(sessionStats);
  const durations = sessions.map(durationS).filter((d): d is number => typeof d === "number");
  const longest = sessions
    .filter((s) => typeof durationS(s) === "number")
    .sort((a, b) => (durationS(b) as number) - (durationS(a) as number))[0];
  const problems = all.filter(
    (e) => e.error === true || e.deferred === true || e.found === false || e.type === "result_parked" || e.type === "parked_delivered",
  );

  const lines: string[] = [];
  lines.push(`# Trace summary: ${userId}`, "");
  if (all.length) lines.push(`Window: ${all[0].ts} to ${all[all.length - 1].ts}`, "");
  if (truncated)
    lines.push(
      `WARNING: export stopped at the page cap (${PAGE * 500} events); narrow with --since to fetch the rest.`,
      "",
    );
  lines.push("## Totals", "");
  lines.push(`- Events: ${all.length}`);
  lines.push(`- Sessions: ${sessions.length} (${sessions.filter((s) => s.synthetic || !s.end).length} partial)`);
  lines.push(`- User turns: ${userTurns}`);
  lines.push(`- Agent turns: ${agentTurns}`);
  lines.push(`- Actions: ${actions}`, "");
  lines.push("## Actions by tool", "");
  if (Object.keys(byTool).length) {
    lines.push("| Tool | Count |", "|---|---|");
    for (const [t, n] of Object.entries(byTool).sort((a, b) => b[1] - a[1])) lines.push(`| ${t} | ${n} |`);
  } else lines.push("(none)");
  lines.push("", "## Per session", "");
  lines.push(`- User turns per session: mean ${fmt(mean(perSession.map((p) => p.userTurns)))}, median ${fmt(median(perSession.map((p) => p.userTurns)))}`);
  lines.push(`- Agent turns per session: mean ${fmt(mean(perSession.map((p) => p.agentTurns)))}, median ${fmt(median(perSession.map((p) => p.agentTurns)))}`);
  lines.push(`- Actions per session: mean ${fmt(mean(perSession.map((p) => Object.values(p.byTool).reduce((a, b) => a + b, 0))))}`);
  if (durations.length) lines.push(`- Duration: mean ${fmt(mean(durations))}s, median ${fmt(median(durations))}s`);
  if (longest) {
    const st = sessionStats(longest);
    lines.push(`- Longest session: #${longest.index} at ${longest.start}, ${durationS(longest)}s, ${st.userTurns} user / ${st.agentTurns} agent turns, ${Object.values(st.byTool).reduce((a, b) => a + b, 0)} actions`);
  }
  lines.push("", "## Errors, deferrals, parked results", "");
  if (problems.length) {
    for (const e of problems) {
      const flag = e.error ? "error" : e.deferred ? "deferred" : e.found === false ? "no match" : String(e.type);
      lines.push(`- ${e.ts} ${e.type}${e.tool ? ` ${e.tool}` : ""} [${flag}] ${clip(primaryText(e), 100)}`);
    }
  } else lines.push("(none)");
  lines.push("");

  return {
    md: lines.join("\n"),
    report: { userId, events: all.length, sessions: sessions.length, userTurns, agentTurns, actions, byTool, problems: problems.length, truncated },
  };
}

function aggregateMd(reports: UserReport[]): string {
  const lines: string[] = ["# Trace summary: all users", ""];
  lines.push("| User | Events | Sessions | User turns | Agent turns | Actions | Problems |", "|---|---|---|---|---|---|---|");
  for (const r of reports)
    lines.push(`| ${r.userId}${r.truncated ? " (truncated)" : ""} | ${r.events} | ${r.sessions} | ${r.userTurns} | ${r.agentTurns} | ${r.actions} | ${r.problems} |`);
  const tot = (k: keyof UserReport) => reports.reduce((a, r) => a + (r[k] as number), 0);
  lines.push(`| **total** | ${tot("events")} | ${tot("sessions")} | ${tot("userTurns")} | ${tot("agentTurns")} | ${tot("actions")} | ${tot("problems")} |`);
  const byTool: Record<string, number> = {};
  for (const r of reports) for (const [t, n] of Object.entries(r.byTool)) byTool[t] = (byTool[t] ?? 0) + n;
  lines.push("", "## Actions by tool (all users)", "");
  if (Object.keys(byTool).length) {
    lines.push("| Tool | Count |", "|---|---|");
    for (const [t, n] of Object.entries(byTool).sort((a, b) => b[1] - a[1])) lines.push(`| ${t} | ${n} |`);
  } else lines.push("(none)");
  lines.push("");
  return lines.join("\n");
}

// ---------- main ----------

async function exportUser(userId: string, events: Ev[], truncated: boolean, outDir: string): Promise<UserReport> {
  const sessions = groupSessions(sortEvents(events));
  const dir = path.join(outDir, userId);
  await fs.mkdir(dir, { recursive: true });
  await fs.writeFile(path.join(dir, "events.csv"), eventsCsv(sessions));
  await fs.writeFile(path.join(dir, "sessions.csv"), sessionsCsv(sessions));
  const { md, report } = summaryMd(userId, sessions, truncated);
  await fs.writeFile(path.join(dir, "summary.md"), md);
  console.log(`${userId}: ${events.length} events, ${sessions.length} sessions -> ${dir}${truncated ? " (TRUNCATED)" : ""}`);
  return report;
}

async function main(): Promise<void> {
  const args = parseArgs(process.argv.slice(2));
  if (!args.user && !args.all) {
    console.error("usage: npm run trace:export -- <userId|--all> [--since ISO] [--out dir] [--from-file dump.json]");
    process.exit(1);
  }

  if (args.fromFile) {
    const raw = JSON.parse(await fs.readFile(args.fromFile, "utf8")) as { events?: Ev[] } | Ev[];
    const events = Array.isArray(raw) ? raw : (raw.events ?? []);
    await exportUser(args.user ?? path.basename(args.fromFile, path.extname(args.fromFile)), events, false, args.out);
    return;
  }

  const users = args.all ? await listUsers() : [args.user as string];
  const reports: UserReport[] = [];
  for (const u of users) {
    const { events, truncated } = await fetchAll(u, args.since);
    reports.push(await exportUser(u, events, truncated, args.out));
  }
  if (args.all) {
    await fs.writeFile(path.join(args.out, "summary.md"), aggregateMd(reports));
    console.log(`aggregate -> ${path.join(args.out, "summary.md")}`);
  }
}

main().catch((err) => {
  console.error(err instanceof Error ? err.message : err);
  process.exit(1);
});
