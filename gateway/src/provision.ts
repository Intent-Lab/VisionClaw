import { anthropic } from "./cma.js";
import { config } from "./config.js";
import { loadStore, saveStore, userResources, type UserResources } from "./store.js";
import { activeApps } from "./apps.js";

const AGENT_SYSTEM_PROMPT = `You are the action agent behind a voice assistant that runs on smart glasses and phones.
The user talks to a real-time voice layer; that layer delegates tasks to you and speaks your replies aloud.

Ground rules:
- Reply in plain spoken prose. No markdown, no headers, no bullet lists, no URLs read out character by character.
- Lead with the answer in one or two sentences. Add detail only when the task genuinely needs it.
- Connected apps (calendar and similar) appear as tools when the owner has linked them. If a tool reports that
  authorization is required, do not retry it and never read a URL aloud: say in one sentence that the app needs to be
  connected in the app's settings, and carry on with what you can do.
- For multi-step work, start immediately and keep intermediate narration to a single short sentence.
- If a task cannot be completed, say what you tried and what is missing, in one sentence.`;

// Drift checks cost Anthropic API round-trips before every task; config only
// changes on deploy, so verify at most once per interval per process.
const RECONCILE_TTL_MS = 10 * 60 * 1000;
let sharedVerifiedAt = 0;
const sessionVerifiedAt = new Map<string, number>();

/** Create the shared environment + agent once; IDs persist in the store. */
export async function ensureShared(): Promise<{ agentId: string; environmentId: string }> {
  const store = await loadStore();
  if (!store.shared.environmentId) {
    const env = await anthropic.beta.environments.create({
      name: "visionclaw-cloud",
      config: { type: "cloud", networking: { type: "unrestricted" } },
    });
    store.shared.environmentId = env.id;
    console.log("[provision] environment created:", env.id);
  }
  if (!store.shared.agentId) {
    const agent = await anthropic.beta.agents.create({
      name: "VisionClaw Action Agent",
      model: wantModel(),
      system: AGENT_SYSTEM_PROMPT,
      mcp_servers: mcpServers(),
      tools: agentTools(),
    });
    store.shared.agentId = agent.id;
    store.shared.agentVersion = agent.version;
    console.log("[provision] agent created:", agent.id, "version", agent.version);
  } else if (Date.now() - sharedVerifiedAt > RECONCILE_TTL_MS) {
    sharedVerifiedAt = Date.now();
    // Reconcile: adding an app to the registry must reach an agent that already
    // exists, or its new tools are silently missing. Version-bump only on drift.
    const agent = await anthropic.beta.agents.retrieve(store.shared.agentId);
    // Compare servers *and* tool config: a changed permission policy is drift
    // just as much as a new app is.
    const appsDrifted =
      appSignature(agent.mcp_servers ?? [], agent.tools ?? []) !== appSignature(mcpServers(), agentTools());
    const modelDrifted = modelSignature(agent.model) !== modelSignature(wantModel());
    const systemDrifted = (agent.system ?? "") !== AGENT_SYSTEM_PROMPT;
    if (appsDrifted || modelDrifted || systemDrifted) {
      const updated = await anthropic.beta.agents.update(store.shared.agentId, {
        mcp_servers: mcpServers(),
        tools: agentTools(),
        model: wantModel(),
        system: AGENT_SYSTEM_PROMPT,
      });
      store.shared.agentVersion = updated.version;
      const what = [appsDrifted && "apps", modelDrifted && "model", systemDrifted && "system"]
        .filter(Boolean)
        .join(" + ");
      console.log(`[provision] agent ${what} reconciled, version`, updated.version);
    }
  }
  await saveStore();
  return { agentId: store.shared.agentId, environmentId: store.shared.environmentId };
}

/**
 * Model config as stored on the agent. Reconciled alongside the app surface,
 * because AGENT_MODEL / AGENT_EFFORT are otherwise read only when the agent is
 * first created -- changing them later looks like it works and silently does
 * nothing, which cost us a round of latency measurements against a setting that
 * was never applied.
 */
function modelSignature(model: unknown): string {
  const m = model as { id?: string; effort?: { type?: string } } | null;
  return `${m?.id ?? ""}:${m?.effort?.type ?? ""}`;
}

function wantModel() {
  return { id: config.agentModel, effort: config.agentEffort ? { type: config.agentEffort } : null };
}

/** Canonical projection of the app surface, for drift detection. */
function appSignature(servers: readonly unknown[], tools: readonly unknown[]): string {
  const s = servers
    .map((raw) => {
      const x = raw as { name?: string; url?: string };
      return `${x.name}@${x.url}`;
    })
    .sort();
  const t = tools
    .map((raw) => {
      const x = raw as {
        type?: string;
        mcp_server_name?: string;
        default_config?: { permission_policy?: { type?: string } } | null;
      };
      // Compare only what we manage. The server normalizes stored configs --
      // agent_toolset comes back with a default_config we never sent -- so
      // comparing the whole shape meant have != want on every request: an
      // agents.update (deduped server-side, version never moved) plus a
      // sessions.update before every single turn, forever.
      if (x.type !== "mcp_toolset") return `${x.type}`;
      return `${x.type}:${x.mcp_server_name ?? ""}:${x.default_config?.permission_policy?.type ?? ""}`;
    })
    .sort();
  return JSON.stringify({ s, t });
}

function mcpServers() {
  return activeApps().map((a) => ({ type: "url" as const, name: a.id, url: a.mcpUrl }));
}

function agentTools() {
  return [
    { type: "agent_toolset_20260401" as const },
    ...activeApps().map((a) => ({
      type: "mcp_toolset" as const,
      mcp_server_name: a.id,
      // Connected apps are read-only today, so a confirmation prompt would only
      // stall a hands-free voice turn. Destructive tools should flip to
      // always_ask and be surfaced as a spoken confirmation instead.
      default_config: { permission_policy: { type: "always_allow" as const } },
    })),
  ];
}

async function sessionUsable(sessionId: string): Promise<boolean> {
  try {
    const s = await anthropic.beta.sessions.retrieve(sessionId);
    return s.status !== "terminated" && s.archived_at == null;
  } catch {
    return false;
  }
}

/**
 * Lazily provision a user's vault and long-lived session.
 *
 * Memory stores are deliberately NOT provisioned or mounted (2026-08-06): the
 * agent dutifully wrote owner notes mid-task, putting 5-10s of bookkeeping on
 * the critical path of a voice answer. Existing memoryStoreId values in the
 * store are kept but unused; re-mounting is one resources entry away if a
 * memory feature earns its latency.
 */
export async function ensureUser(userId: string): Promise<UserResources & { sessionId: string; vaultId: string }> {
  const { agentId, environmentId } = await ensureShared();
  const u = await userResources(userId);

  if (!u.vaultId) {
    const vault = await anthropic.beta.vaults.create({ display_name: `visionclaw-vault-${userId}` });
    u.vaultId = vault.id;
    console.log(`[provision] vault for ${userId}:`, vault.id);
  }

  const verifiedAt = u.sessionId ? (sessionVerifiedAt.get(u.sessionId) ?? 0) : 0;
  const needsCheck = Date.now() - verifiedAt > RECONCILE_TTL_MS;
  if (!u.sessionId || (needsCheck && !(await sessionUsable(u.sessionId)))) {
    const session = await anthropic.beta.sessions.create({
      agent: agentId,
      environment_id: environmentId,
      title: `visionclaw:${userId}`,
      vault_ids: [u.vaultId],
    });
    u.sessionId = session.id;
    sessionVerifiedAt.set(session.id, Date.now());
    console.log(`[provision] session for ${userId}:`, session.id);
  } else if (needsCheck) {
    sessionVerifiedAt.set(u.sessionId, Date.now());
    // A live session keeps the tool slate it was created with, so newly added
    // apps need a session-local update too. History is preserved.
    try {
      const live = await anthropic.beta.sessions.retrieve(u.sessionId);
      const have = appSignature(live.agent?.mcp_servers ?? [], live.agent?.tools ?? []);
      const want = appSignature(mcpServers(), agentTools());
      if (have !== want && live.status === "idle") {
        await anthropic.beta.sessions.update(u.sessionId, {
          agent: { mcp_servers: mcpServers(), tools: agentTools() },
        });
        console.log(`[provision] session apps reconciled for ${userId}`);
      }
    } catch (err) {
      console.warn(`[provision] could not reconcile session apps for ${userId}:`, err);
    }
  }

  await saveStore();
  return u as UserResources & { sessionId: string; vaultId: string };
}
