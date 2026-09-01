import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { dirname } from "node:path";

/**
 * Tiny JSON-file persistence for provisioned resource IDs.
 * Swap for Redis/Postgres when the user count justifies it - the interface is
 * three functions and one shape.
 */

export interface SharedResources {
  environmentId?: string;
  agentId?: string;
  agentVersion?: number;
}

export interface RecentTask {
  ts: string;
  prompt: string;
  result: string;
}

export interface Note {
  id: string;
  ts: string;
  text: string;
  /** Optional grouping, e.g. "shopping" -- lets one voice command recall a whole list. */
  tag?: string;
}

export interface UserResources {
  memoryStoreId?: string;
  vaultId?: string;
  sessionId?: string;
  /** Task results that had no live channel to land on; drained at next call start. */
  pendingNotifications?: string[];
  /** Rolling ledger of delegated tasks. Sessions are ephemeral (rotated per
   * call); cross-call continuity is a briefing built from this ledger, not a
   * replayed transcript. Also serves the app's Recent Tasks view. */
  recentTasks?: RecentTask[];
  /** True once the current session has run a turn. Untouched sessions are
   * reused instead of rotated -- rotating them would re-queue briefings that
   * pile up across calls that never delegate a task. */
  sessionUsed?: boolean;
  /** Voice-created notes and lists. Lives here, not in the agent sandbox:
   * sessions are ephemeral, so anything the sandbox holds dies with the call. */
  notes?: Note[];
}

export type AccountStatus = "pending" | "approved" | "revoked";

/** A self-registered (Google sign-in) identity. Static GATEWAY_TOKENS users
 * never appear here; their identity is the env var. */
export interface Account {
  /** Google's stable subject id; the userId is derived from it, never from the email. */
  sub: string;
  email: string;
  name: string;
  status: AccountStatus;
  createdAt: string;
  lastSeenAt: string;
  /** sha256 hex of each live bearer token, newest last. Raw tokens are never stored. */
  tokenHashes: string[];
}

export interface StoreShape {
  shared: SharedResources;
  users: Record<string, UserResources>;
  accounts?: Record<string, Account>;
}

let cache: StoreShape | null = null;
let path = "./data/gateway-store.json";

export function initStore(storePath: string): void {
  path = storePath;
}

export async function loadStore(): Promise<StoreShape> {
  if (cache) return cache;
  try {
    cache = JSON.parse(await readFile(path, "utf8")) as StoreShape;
  } catch {
    cache = { shared: {}, users: {} };
  }
  return cache;
}

export async function saveStore(): Promise<void> {
  if (!cache) return;
  await mkdir(dirname(path), { recursive: true });
  const tmp = `${path}.tmp`;
  await writeFile(tmp, JSON.stringify(cache, null, 2));
  await rename(tmp, path);
}

export async function accounts(): Promise<Record<string, Account>> {
  const store = await loadStore();
  store.accounts ??= {};
  return store.accounts;
}

export async function userResources(userId: string): Promise<UserResources> {
  const store = await loadStore();
  store.users[userId] ??= {};
  return store.users[userId];
}
