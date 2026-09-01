import { createHash, createHmac, randomBytes, timingSafeEqual } from "node:crypto";
import type { Express, Request, Response } from "express";
import { anthropic } from "./cma.js";
import {
  activeApps,
  appAvailable,
  appCredentials,
  getApp,
  type ConnectableApp,
  type McpOAuth21App,
  type StaticOAuthApp,
} from "./apps.js";
import { loadStore, saveStore, type McpClientRegistration } from "./store.js";
import { ensureUser } from "./provision.js";
import { notifyUser } from "./notify.js";
import { appHealth, invalidateAppHealth } from "./health.js";

/**
 * One-tap app connection: /connect/:app redirects to the provider, the callback
 * exchanges the code and writes an mcp_oauth credential into the user's vault.
 * Anthropic refreshes the token from there on, so this runs once per user per app.
 */

const STATE_TTL_MS = 10 * 60 * 1000;

function stateSecret(): string {
  return process.env.STATE_SECRET ?? "dev-only-insecure-state-secret";
}

interface StatePayload {
  userId: string;
  appId: string;
  /** Custom URL scheme to bounce back to when the flow finishes (in-app auth sheet). */
  scheme?: string;
  ts: number;
  nonce: string;
}

function signState(userId: string, appId: string, scheme?: string): string {
  const payload: StatePayload = {
    userId,
    appId,
    scheme,
    ts: Date.now(),
    nonce: randomBytes(8).toString("hex"),
  };
  const body = Buffer.from(JSON.stringify(payload)).toString("base64url");
  const mac = createHmac("sha256", stateSecret()).update(body).digest("hex").slice(0, 32);
  return `${body}.${mac}`;
}

function verifyState(state: string): StatePayload | null {
  const [body, mac] = state.split(".");
  if (!body || !mac) return null;
  const expected = createHmac("sha256", stateSecret()).update(body).digest("hex").slice(0, 32);
  const a = Buffer.from(mac);
  const b = Buffer.from(expected);
  if (a.length !== b.length || !timingSafeEqual(a, b)) return null;
  try {
    const payload = JSON.parse(Buffer.from(body, "base64url").toString("utf8")) as StatePayload;
    if (Date.now() - payload.ts > STATE_TTL_MS) return null;
    return payload;
  } catch {
    return null;
  }
}

/** Public origin of this gateway, as the provider must see it in redirect URIs. */
export function baseUrl(req: Request): string {
  return process.env.PUBLIC_BASE_URL ?? `${req.protocol}://${req.get("host")}`;
}

function redirectUri(req: Request, appId: string): string {
  return `${baseUrl(req)}/connect/${appId}/callback`;
}

export function page(title: string, body: string): string {
  return `<!doctype html><meta name="viewport" content="width=device-width,initial-scale=1">
<style>body{font:17px -apple-system,system-ui,sans-serif;margin:0;display:grid;place-items:center;height:100vh;text-align:center;padding:24px;color:#111}
h1{font-size:20px;margin:0 0 8px}p{color:#666;margin:0;max-width:28em}</style>
<h1>${title}</h1><p>${body}</p>`;
}

export interface OAuthTokens {
  access_token: string;
  refresh_token?: string;
  expires_in?: number;
  scope?: string;
}

/** Authorization-code exchange; null when the provider rejects it (already logged). */
export async function exchangeAuthCode(
  tokenUrl: string,
  args: { code: string; clientId: string; clientSecret: string; redirectUri: string },
): Promise<OAuthTokens | null> {
  const tokenRes = await fetch(tokenUrl, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      code: args.code,
      client_id: args.clientId,
      client_secret: args.clientSecret,
      redirect_uri: args.redirectUri,
      grant_type: "authorization_code",
    }),
  });
  if (!tokenRes.ok) {
    console.error("[connect] token exchange failed:", tokenRes.status, await tokenRes.text());
    return null;
  }
  return (await tokenRes.json()) as OAuthTokens;
}

/** How Anthropic should refresh a stored grant: the token endpoint plus the
 * client authentication the provider registered us with. */
export interface RefreshConfig {
  clientId: string;
  tokenEndpoint: string;
  auth: { type: "none" } | { type: "client_secret_post" | "client_secret_basic"; client_secret: string };
  /** RFC 8707 resource indicator, required by MCP servers on refresh too. */
  resource?: string;
  scope?: string;
}

export interface CredentialTarget {
  id: string;
  displayName: string;
  mcpUrl: string;
  /** Scopes the grant was expected to carry; missing ones are logged. */
  scopes?: string[];
}

/**
 * Put an OAuth grant into the user's vault as the credential for one MCP
 * server (replacing any existing one for that URL), so Anthropic refreshes it
 * from here on. Shared by the per-app connect flow and Google sign-in, which
 * connects the calendar in the same consent.
 */
export async function storeMcpCredential(
  userId: string,
  target: CredentialTarget,
  tokens: OAuthTokens,
  refresh: RefreshConfig,
): Promise<{ vaultId: string }> {
  const granted = (tokens.scope ?? "").split(" ").filter(Boolean);
  const missing = (target.scopes ?? []).filter((s) => !granted.includes(s));
  console.log(`[connect] ${target.id} granted scopes:`, granted.join(" ") || "(none reported)");
  if (missing.length > 0) {
    console.warn(`[connect] ${target.id} MISSING scopes:`, missing.join(" "));
  }

  const { vaultId } = await ensureUser(userId);

  // One credential per MCP server URL: replace any existing one.
  for await (const cred of anthropic.beta.vaults.credentials.list(vaultId)) {
    const url = (cred as { auth?: { mcp_server_url?: string } }).auth?.mcp_server_url;
    if (url === target.mcpUrl) {
      await anthropic.beta.vaults.credentials.delete(cred.id, { vault_id: vaultId });
    }
  }

  await anthropic.beta.vaults.credentials.create(vaultId, {
    display_name: `${target.displayName} (${userId})`,
    auth: {
      type: "mcp_oauth",
      mcp_server_url: target.mcpUrl,
      access_token: tokens.access_token,
      expires_at: tokens.expires_in
        ? new Date(Date.now() + tokens.expires_in * 1000).toISOString()
        : undefined,
      // Without refresh, access dies with the first token expiry.
      refresh: tokens.refresh_token
        ? {
            refresh_token: tokens.refresh_token,
            client_id: refresh.clientId,
            token_endpoint: refresh.tokenEndpoint,
            token_endpoint_auth: refresh.auth,
            resource: refresh.resource,
            scope: refresh.scope,
          }
        : undefined,
    },
  });

  if (!tokens.refresh_token) {
    console.warn(
      `[connect] ${target.id} returned no refresh_token for ${userId};` +
        " access will expire. Check access_type=offline and prompt=consent.",
    );
  }
  invalidateAppHealth(userId, target.id);
  return { vaultId };
}

/** Refresh config for a statically registered (Google-style) client. */
export function staticRefresh(
  appDef: StaticOAuthApp,
  creds: { clientId: string; clientSecret: string },
): RefreshConfig {
  return {
    clientId: creds.clientId,
    tokenEndpoint: appDef.tokenUrl,
    auth: { type: "client_secret_post", client_secret: creds.clientSecret },
  };
}

// ---------- OAuth 2.1 remote MCP servers (discovery + dynamic registration + PKCE) ----------

interface AuthServerMetadata {
  authorization_endpoint: string;
  token_endpoint: string;
  registration_endpoint?: string;
  code_challenge_methods_supported?: string[];
  scopes_supported?: string[];
  token_endpoint_auth_methods_supported?: string[];
}

// Notion fronts its MCP with Cloudflare, which bans some non-browser
// User-Agents (Python's default 403s); an explicit identity is safest.
const GATEWAY_UA = "VisionClaw-gateway/1.0 (+https://api.visionagents.app)";
const META_TTL_MS = 60 * 60 * 1000;
const metadataCache = new Map<string, { at: number; meta: AuthServerMetadata }>();

async function fetchJson<T>(url: string): Promise<T | null> {
  try {
    const r = await fetch(url, { headers: { Accept: "application/json", "User-Agent": GATEWAY_UA } });
    if (!r.ok) return null;
    return (await r.json()) as T;
  } catch {
    return null;
  }
}

/** Well-known URL for a path-bearing resource/issuer (RFC 9728 / RFC 8414 insertion rule). */
function wellKnown(base: string, suffix: string): string {
  const u = new URL(base);
  const path = u.pathname.replace(/\/$/, "");
  return `${u.origin}/.well-known/${suffix}${path}`;
}

/**
 * MCP authorization discovery: the protected resource names its authorization
 * server, whose metadata names the endpoints. Servers that skip the first
 * document are handled by asking the MCP origin directly.
 */
async function discoverAuthServer(app: McpOAuth21App): Promise<AuthServerMetadata> {
  const hit = metadataCache.get(app.id);
  if (hit && Date.now() - hit.at < META_TTL_MS) return hit.meta;

  const origin = new URL(app.mcpUrl).origin;
  const prm =
    (await fetchJson<{ authorization_servers?: string[] }>(wellKnown(app.mcpUrl, "oauth-protected-resource"))) ??
    (await fetchJson<{ authorization_servers?: string[] }>(`${origin}/.well-known/oauth-protected-resource`));
  const authServer = prm?.authorization_servers?.[0] ?? origin;

  const meta =
    (await fetchJson<AuthServerMetadata>(wellKnown(authServer, "oauth-authorization-server"))) ??
    (await fetchJson<AuthServerMetadata>(`${origin}/.well-known/oauth-authorization-server`));
  if (!meta?.authorization_endpoint || !meta.token_endpoint) {
    throw new Error(`${app.id}: no OAuth authorization server metadata at ${authServer}`);
  }
  metadataCache.set(app.id, { at: Date.now(), meta });
  console.log(`[connect] ${app.id} auth server: ${authServer}`);
  return meta;
}

/**
 * Register this gateway as an OAuth client with the server, once. A public
 * client (PKCE, no secret) is preferred; servers that insist on a secret get
 * a confidential registration instead. Stored in the shared store so every
 * user's consent reuses the same client id.
 */
async function ensureMcpClient(
  app: McpOAuth21App,
  meta: AuthServerMetadata,
  redirectUri: string,
): Promise<McpClientRegistration> {
  const store = await loadStore();
  store.shared.mcpClients ??= {};
  const existing = store.shared.mcpClients[app.id];
  if (existing && existing.redirectUri === redirectUri) return existing;
  if (!meta.registration_endpoint) {
    throw new Error(`${app.id}: server does not support dynamic client registration`);
  }

  const register = async (method: "none" | "client_secret_post") => {
    const r = await fetch(meta.registration_endpoint!, {
      method: "POST",
      headers: { "Content-Type": "application/json", Accept: "application/json", "User-Agent": GATEWAY_UA },
      body: JSON.stringify({
        client_name: app.clientName,
        redirect_uris: [redirectUri],
        grant_types: ["authorization_code", "refresh_token"],
        response_types: ["code"],
        token_endpoint_auth_method: method,
      }),
    });
    const text = await r.text();
    if (!r.ok) {
      console.warn(`[connect] ${app.id} registration (${method}) rejected:`, r.status, text.slice(0, 300));
      return null;
    }
    return JSON.parse(text) as {
      client_id: string;
      client_secret?: string;
      token_endpoint_auth_method?: string;
    };
  };

  const reg = (await register("none")) ?? (await register("client_secret_post"));
  if (!reg?.client_id) throw new Error(`${app.id}: dynamic client registration failed`);
  const method = (reg.token_endpoint_auth_method ?? (reg.client_secret ? "client_secret_post" : "none")) as
    McpClientRegistration["tokenEndpointAuthMethod"];
  const registration: McpClientRegistration = {
    clientId: reg.client_id,
    clientSecret: reg.client_secret,
    tokenEndpointAuthMethod: method,
    registeredAt: new Date().toISOString(),
    redirectUri,
  };
  store.shared.mcpClients[app.id] = registration;
  await saveStore();
  console.log(`[connect] ${app.id} registered OAuth client (${method})`);
  return registration;
}

function refreshFor(reg: McpClientRegistration, meta: AuthServerMetadata, app: McpOAuth21App): RefreshConfig {
  return {
    clientId: reg.clientId,
    tokenEndpoint: meta.token_endpoint,
    auth:
      reg.tokenEndpointAuthMethod === "none" || !reg.clientSecret
        ? { type: "none" }
        : { type: reg.tokenEndpointAuthMethod, client_secret: reg.clientSecret },
    resource: app.mcpUrl,
    scope: app.scopes?.join(" "),
  };
}

// PKCE verifiers live only until the callback; keyed by the signed state.
const PKCE_TTL_MS = STATE_TTL_MS;
const pkce = new Map<string, { verifier: string; at: number }>();

function sweepPkce(): void {
  const now = Date.now();
  for (const [k, v] of pkce) if (now - v.at > PKCE_TTL_MS) pkce.delete(k);
}

function pkcePair(): { verifier: string; challenge: string } {
  const verifier = randomBytes(32).toString("base64url");
  const challenge = createHash("sha256").update(verifier).digest("base64url");
  return { verifier, challenge };
}

/** Authorization-code exchange for a dynamically registered client (PKCE + resource indicator). */
async function exchangeMcpAuthCode(
  meta: AuthServerMetadata,
  reg: McpClientRegistration,
  app: McpOAuth21App,
  args: { code: string; verifier: string; redirectUri: string },
): Promise<OAuthTokens | null> {
  const body = new URLSearchParams({
    grant_type: "authorization_code",
    code: args.code,
    redirect_uri: args.redirectUri,
    client_id: reg.clientId,
    code_verifier: args.verifier,
    resource: app.mcpUrl,
  });
  const headers: Record<string, string> = {
    "Content-Type": "application/x-www-form-urlencoded",
    "User-Agent": GATEWAY_UA,
  };
  if (reg.clientSecret && reg.tokenEndpointAuthMethod === "client_secret_post") {
    body.set("client_secret", reg.clientSecret);
  } else if (reg.clientSecret && reg.tokenEndpointAuthMethod === "client_secret_basic") {
    headers.Authorization = `Basic ${Buffer.from(`${reg.clientId}:${reg.clientSecret}`).toString("base64")}`;
  }
  const r = await fetch(meta.token_endpoint, { method: "POST", headers, body });
  if (!r.ok) {
    console.error(`[connect] ${app.id} token exchange failed:`, r.status, await r.text());
    return null;
  }
  return (await r.json()) as OAuthTokens;
}

/**
 * Call one real tool on the MCP server with the user's token. `initialize` and
 * `tools/list` can succeed on servers that then refuse every data call, so the
 * only meaningful health check is an actual `tools/call`.
 */
async function probeMcp(
  mcpUrl: string,
  accessToken: string,
  opts: { callTool: boolean } = { callTool: true },
): Promise<{ ok: boolean; detail: string }> {
  const rpc = async (body: object) => {
    const r = await fetch(mcpUrl, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${accessToken}`,
        "Content-Type": "application/json",
        Accept: "application/json, text/event-stream",
      },
      body: JSON.stringify(body),
    });
    return { status: r.status, text: await r.text() };
  };

  try {
    const listed = await rpc({ jsonrpc: "2.0", id: 1, method: "tools/list", params: {} });
    if (listed.status !== 200) return { ok: false, detail: `tools/list HTTP ${listed.status}` };

    const names = [...listed.text.matchAll(/"name"\s*:\s*"([^"]+)"/g)].map((m) => m[1]);
    const probeName =
      names.find((n) => /^list_(calendars|gmail_labels)$/.test(n)) ??
      names.find((n) => /^list_/.test(n)) ??
      names[0];
    if (!probeName) return { ok: false, detail: "server exposed no tools" };
    // Generic servers have no known zero-argument tool to call safely; a
    // successful authenticated tools/list is the best available evidence.
    if (!opts.callTool) return { ok: true, detail: `${names.length} tools listed` };

    const called = await rpc({
      jsonrpc: "2.0",
      id: 2,
      method: "tools/call",
      params: { name: probeName, arguments: {} },
    });
    if (called.status !== 200) return { ok: false, detail: `tools/call HTTP ${called.status}` };
    // JSON-RPC reports tool failures inside a 200 body.
    if (/"isError"\s*:\s*true/.test(called.text)) {
      const msg = called.text.match(/"text"\s*:\s*"([^"]{0,120})"/)?.[1] ?? "tool call rejected";
      return { ok: false, detail: msg };
    }
    return { ok: true, detail: `${probeName} ok` };
  } catch (err) {
    return { ok: false, detail: err instanceof Error ? err.message : "probe failed" };
  }
}

export function registerConnectRoutes(
  app: Express,
  userFromRequest: (req: Request, explicitToken?: string) => string | null,
): void {
  // What's connectable and what this user has already connected.
  app.get("/apps", async (req: Request, res: Response) => {
    const userId = userFromRequest(req);
    if (!userId) {
      res.status(401).json({ error: { message: "invalid or missing gateway token" } });
      return;
    }
    try {
      const { vaultId } = await ensureUser(userId);
      const credentialByUrl = new Map<string, string>();
      for await (const cred of anthropic.beta.vaults.credentials.list(vaultId)) {
        const url = (cred as { auth?: { mcp_server_url?: string } }).auth?.mcp_server_url;
        if (url) credentialByUrl.set(url, cred.id);
      }
      // "Connected" and "working" are different things: a stored credential
      // whose refresh token has expired looks connected and fails every call.
      const apps = await Promise.all(
        activeApps().map(async (a) => {
          const credentialId = credentialByUrl.get(a.mcpUrl);
          const health = credentialId ? await appHealth(userId, a.id, vaultId, credentialId) : null;
          return {
            id: a.id,
            displayName: a.displayName,
            connected: credentialId !== undefined,
            available: appAvailable(a),
            healthy: health ? health.healthy : null,
            needs_reconnect: health ? health.needsReconnect : false,
            detail: health?.detail,
          };
        }),
      );
      res.json({ apps });
    } catch (err) {
      console.error("[apps] listing failed:", err);
      res.status(502).json({ error: { message: "could not list apps" } });
    }
  });

  // Start the flow. Opened in an in-app auth sheet; token in the query so the
  // sheet does not need to set headers.
  app.get("/connect/:appId", (req: Request, res: Response) => {
    const token = String(req.query.token ?? "");
    const userId = userFromRequest(req, token || undefined);
    if (!userId) {
      res.status(401).send(page("Not signed in", "Open this from the VisionClaw app."));
      return;
    }
    const appDef = getApp(String(req.params.appId));
    if (!appDef) {
      res.status(404).send(page("Unknown app", "That integration does not exist."));
      return;
    }
    const scheme = String(req.query.scheme ?? "") || undefined;

    if (appDef.kind === "mcp-oauth21") {
      void (async () => {
        try {
          const meta = await discoverAuthServer(appDef);
          const reg = await ensureMcpClient(appDef, meta, redirectUri(req, appDef.id));
          const { verifier, challenge } = pkcePair();
          const state = signState(userId, appDef.id, scheme);
          sweepPkce();
          pkce.set(state, { verifier, at: Date.now() });
          const params = new URLSearchParams({
            client_id: reg.clientId,
            redirect_uri: redirectUri(req, appDef.id),
            response_type: "code",
            code_challenge: challenge,
            code_challenge_method: "S256",
            state,
            resource: appDef.mcpUrl,
          });
          if (appDef.scopes?.length) params.set("scope", appDef.scopes.join(" "));
          res.redirect(`${meta.authorization_endpoint}?${params.toString()}`);
        } catch (err) {
          console.error(`[connect] ${appDef.id} could not start:`, err);
          res.status(502).send(page("Could not connect", `${appDef.displayName} is not reachable right now. Please try again.`));
        }
      })();
      return;
    }

    const creds = appCredentials(appDef);
    if (!creds) {
      res.status(503).send(page("Not configured", `${appDef.displayName} is not set up on this gateway yet.`));
      return;
    }

    const params = new URLSearchParams({
      client_id: creds.clientId,
      redirect_uri: redirectUri(req, appDef.id),
      response_type: "code",
      scope: appDef.scopes.join(" "),
      state: signState(userId, appDef.id, scheme),
      ...(appDef.authorizeParams ?? {}),
    });
    res.redirect(`${appDef.authorizeUrl}?${params.toString()}`);
  });

  // Provider redirects here: exchange the code, store the credential.
  app.get("/connect/:appId/callback", async (req: Request, res: Response) => {
    const appDef = getApp(String(req.params.appId));
    if (!appDef) {
      res.status(404).send(page("Unknown app", "That integration does not exist."));
      return;
    }
    if (req.query.error) {
      res.status(400).send(page("Connection cancelled", "You can close this window and try again."));
      return;
    }

    const verified = verifyState(String(req.query.state ?? ""));
    const code = String(req.query.code ?? "");
    if (!verified || verified.appId !== appDef.id || !code) {
      res.status(400).send(page("Could not connect", "The sign-in link expired. Please try again from the app."));
      return;
    }

    try {
      let tokens: OAuthTokens | null;
      let refresh: RefreshConfig;
      if (appDef.kind === "mcp-oauth21") {
        const meta = await discoverAuthServer(appDef);
        const reg = await ensureMcpClient(appDef, meta, redirectUri(req, appDef.id));
        const entry = pkce.get(String(req.query.state));
        pkce.delete(String(req.query.state));
        if (!entry) {
          res.status(400).send(page("Could not connect", "The sign-in link expired. Please try again from the app."));
          return;
        }
        tokens = await exchangeMcpAuthCode(meta, reg, appDef, {
          code,
          verifier: entry.verifier,
          redirectUri: redirectUri(req, appDef.id),
        });
        refresh = refreshFor(reg, meta, appDef);
      } else {
        const creds = appCredentials(appDef);
        if (!creds) {
          res.status(503).send(page("Not configured", `${appDef.displayName} is not set up on this gateway yet.`));
          return;
        }
        tokens = await exchangeAuthCode(appDef.tokenUrl, {
          code,
          clientId: creds.clientId,
          clientSecret: creds.clientSecret,
          redirectUri: redirectUri(req, appDef.id),
        });
        refresh = staticRefresh(appDef, creds);
      }
      if (!tokens) {
        res.status(502).send(page("Could not connect", "The provider rejected the sign-in. Please try again."));
        return;
      }

      // DIAG=1: probe the provider directly with the fresh token, so an opaque
      // "permission denied" from the agent can be attributed to the token, the
      // REST API, or the MCP endpoint specifically.
      if (process.env.DIAG === "1" && appDef.kind === "oauth2-static") {
        try {
          const rest = await fetch("https://www.googleapis.com/calendar/v3/users/me/calendarList", {
            headers: { Authorization: `Bearer ${tokens.access_token}` },
          });
          console.log("[diag] calendar REST status:", rest.status, (await rest.text()).slice(0, 300));
          const mcpCall = async (label: string, body: object) => {
            const r = await fetch(appDef.mcpUrl, {
              method: "POST",
              headers: {
                Authorization: `Bearer ${tokens.access_token}`,
                "Content-Type": "application/json",
                Accept: "application/json, text/event-stream",
              },
              body: JSON.stringify(body),
            });
            console.log(`[diag] MCP ${label}:`, r.status, (await r.text()).slice(0, 600));
          };
          await mcpCall("initialize", {
            jsonrpc: "2.0",
            id: 1,
            method: "initialize",
            params: {
              protocolVersion: "2025-06-18",
              capabilities: {},
              clientInfo: { name: "visionclaw-diag", version: "0.1.0" },
            },
          });
          await mcpCall("tools/list", { jsonrpc: "2.0", id: 2, method: "tools/list", params: {} });
          // The operation the agent actually fails on.
          await mcpCall("tools/call list_calendars", {
            jsonrpc: "2.0",
            id: 3,
            method: "tools/call",
            params: { name: "list_calendars", arguments: {} },
          });
        } catch (e) {
          console.warn("[diag] probe failed:", e);
        }
      }

      await storeMcpCredential(verified.userId, appDef, tokens, refresh);

      // Verify the connection actually works before claiming it does: a valid
      // OAuth grant does not guarantee the MCP server will serve this account.
      const health = await probeMcp(appDef.mcpUrl, tokens.access_token, {
        callTool: appDef.kind === "oauth2-static",
      });
      if (health.ok) {
        console.log(`[connect] ${appDef.displayName} connected and working for ${verified.userId}`);
        notifyUser(verified.userId, `${appDef.displayName} is connected.`);
      } else {
        console.warn(`[connect] ${appDef.id} signed in but unusable for ${verified.userId}:`, health.detail);
      }

      // Started from an in-app auth sheet: bounce back so the sheet closes
      // itself and the app can refresh, instead of stranding a web page.
      if (verified.scheme) {
        const back = new URL(`${verified.scheme}://connect-callback`);
        back.searchParams.set("app", appDef.id);
        back.searchParams.set("ok", health.ok ? "1" : "0");
        if (!health.ok) back.searchParams.set("detail", health.detail);
        res.redirect(back.toString());
        return;
      }

      res.send(
        health.ok
          ? page(`${appDef.displayName} connected`, "You can close this window and keep talking.")
          : page(
              "Signed in, but not usable yet",
              `Your account was linked, but ${appDef.displayName} refused the first request (${health.detail}). ` +
                "The credential is saved, so it will start working as soon as access is granted.",
            ),
      );
    } catch (err) {
      console.error("[connect] callback failed:", err);
      res.status(502).send(page("Could not connect", "Something went wrong. Please try again."));
    }
  });
}
