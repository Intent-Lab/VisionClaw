import { anthropic } from "./cma.js";
import { appendTrace } from "./trace.js";

/**
 * Liveness of a user's app connection. The gateway never holds the OAuth
 * tokens (they live in the user's vault), so the probe is Anthropic's own
 * credential validation: it attempts the refresh-token exchange and an MCP
 * call with the stored credential and reports the verdict.
 *
 * The case this exists for: Gmail's OAuth client sits in Testing status, where
 * Google expires refresh tokens after 7 days by policy. Nothing server-side
 * can renew them; the only fix is the user reconnecting from Settings, so the
 * job here is to notice and say so, once.
 */

export interface AppHealth {
  healthy: boolean;
  needsReconnect: boolean;
  detail: string;
}

// Validation is a live round-trip to the provider; the Settings screen and the
// voice worker both ask, so verdicts are held for a while.
const TTL_MS = 10 * 60 * 1000;
const cache = new Map<string, { at: number; value: AppHealth }>();
// Last verdict per user+app, kept past the TTL so a transition is logged once.
const lastVerdict = new Map<string, boolean>();

export async function appHealth(
  userId: string,
  appId: string,
  vaultId: string,
  credentialId: string,
): Promise<AppHealth> {
  const key = `${userId}:${appId}`;
  const hit = cache.get(key);
  if (hit && Date.now() - hit.at < TTL_MS) return hit.value;

  let value: AppHealth;
  try {
    const v = await anthropic.beta.vaults.credentials.mcpOAuthValidate(credentialId, { vault_id: vaultId });
    if (v.refresh?.status === "failed") {
      value = { healthy: false, needsReconnect: true, detail: "refresh token rejected" };
    } else if (v.status === "invalid") {
      const detail = v.mcp_probe ? `${v.mcp_probe.method} failed` : "credential invalid";
      value = { healthy: false, needsReconnect: true, detail };
    } else if (v.status === "valid") {
      value = { healthy: true, needsReconnect: false, detail: "ok" };
    } else {
      // "unknown" (or a connect_error on refresh) is a probe that could not
      // decide, not a dead credential; never prompt a reconnect on a maybe.
      value = { healthy: true, needsReconnect: false, detail: "unverified" };
    }
  } catch (err) {
    console.warn(`[health] validation call failed for ${key}:`, err instanceof Error ? err.message : err);
    value = { healthy: true, needsReconnect: false, detail: "unverified" };
  }
  cache.set(key, { at: Date.now(), value });

  const prev = lastVerdict.get(key);
  if (prev !== value.needsReconnect) {
    lastVerdict.set(key, value.needsReconnect);
    if (value.needsReconnect) {
      console.warn(`[health] ${appId} needs reconnect for ${userId}: ${value.detail}`);
    } else if (prev !== undefined) {
      console.log(`[health] ${appId} healthy again for ${userId}`);
    }
    // First sight of a healthy connection is not an event; going bad, or
    // recovering, is.
    if (value.needsReconnect || prev !== undefined) {
      appendTrace(userId, [
        { type: "app_connection", app: appId, needs_reconnect: value.needsReconnect, detail: value.detail },
      ]);
    }
  }
  return value;
}

/** Drop the cached verdict after a (re)connect so the next look reflects the new credential. */
export function invalidateAppHealth(userId: string, appId: string): void {
  cache.delete(`${userId}:${appId}`);
}
