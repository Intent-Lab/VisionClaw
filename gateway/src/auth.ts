import { createHash, createHmac, randomBytes, timingSafeEqual } from "node:crypto";
import type { Express, Request, Response } from "express";
import { config } from "./config.js";
import { accounts, loadStore, saveStore, type Account, type AccountStatus } from "./store.js";
import { ensureUser } from "./provision.js";
import { appCredentials, getStaticApp } from "./apps.js";
import { baseUrl, exchangeAuthCode, page, staticRefresh, storeMcpCredential } from "./connect.js";

/**
 * Google sign-in with self-registration.
 *
 * The app generates a nonce, opens /auth/google in the browser, and polls
 * /auth/exchange with that nonce. Google's callback lands here, the account is
 * upserted, a bearer token is minted and parked under the nonce, and the app
 * collects it once. Tokens are stored hashed; the raw token exists only on the
 * device. The same consent carries the calendar scopes, so signing in also
 * connects the calendar through the normal vault credential path.
 *
 * Access control is the account status: only `approved` accounts resolve on
 * authenticated routes. New accounts are approved automatically for allowlisted
 * domains (or globally), otherwise they wait in `pending` for the dashboard.
 */

const NONCE_RE = /^[0-9a-f]{32}$/;
const STATE_TTL_MS = 10 * 60 * 1000;
const PARK_TTL_MS = 10 * 60 * 1000;
const TOKENS_PER_ACCOUNT = 5;
const LAST_SEEN_INTERVAL_MS = 5 * 60 * 1000;
const EXCHANGE_RATE_LIMIT = 60; // requests per IP per minute
const SIGN_IN_APP_ID = "gcal-self";
const USERINFO_URL = "https://openidconnect.googleapis.com/v1/userinfo";

// Per-process fallback keeps unsigned-state attacks out even when no service
// token is configured; the cost is that in-flight sign-ins die on restart.
const stateKey = config.serviceToken ?? randomBytes(32).toString("hex");

const sha256 = (s: string) => createHash("sha256").update(s).digest("hex");

// ---------- signed state ----------

function signState(nonce: string): string {
  const body = Buffer.from(JSON.stringify({ nonce, ts: Date.now() })).toString("base64url");
  const mac = createHmac("sha256", stateKey).update(body).digest("hex").slice(0, 32);
  return `${body}.${mac}`;
}

function verifyState(state: string): { nonce: string } | null {
  const [body, mac] = state.split(".");
  if (!body || !mac) return null;
  const expected = createHmac("sha256", stateKey).update(body).digest("hex").slice(0, 32);
  const a = Buffer.from(mac);
  const b = Buffer.from(expected);
  if (a.length !== b.length || !timingSafeEqual(a, b)) return null;
  try {
    const payload = JSON.parse(Buffer.from(body, "base64url").toString("utf8")) as { nonce: string; ts: number };
    if (!NONCE_RE.test(payload.nonce) || Date.now() - payload.ts > STATE_TTL_MS) return null;
    return { nonce: payload.nonce };
  } catch {
    return null;
  }
}

// ---------- nonce parking (single-use, in memory) ----------

interface Parked {
  token: string;
  userId: string;
  email: string;
  status: AccountStatus;
  at: number;
}

const started = new Map<string, number>();
const parked = new Map<string, Parked>();
const used = new Map<string, number>();

function sweepNonces(): void {
  const now = Date.now();
  for (const [n, t] of started) if (now - t > PARK_TTL_MS) started.delete(n);
  for (const [n, p] of parked) if (now - p.at > PARK_TTL_MS) parked.delete(n);
  for (const [n, t] of used) if (now - t > PARK_TTL_MS) used.delete(n);
}

// ---------- token index (sha256(token) -> userId), kept in sync with the store ----------

const tokenIndex = new Map<string, string>();
let accountsRef: Record<string, Account> = {};

function rebuildTokenIndex(): void {
  tokenIndex.clear();
  for (const [userId, acct] of Object.entries(accountsRef)) {
    for (const h of acct.tokenHashes) tokenIndex.set(h, userId);
  }
}

/** Load accounts and build the token index; call once before serving. */
export async function initAuth(): Promise<void> {
  await loadStore();
  accountsRef = await accounts();
  rebuildTokenIndex();
  console.log(`[auth] ${Object.keys(accountsRef).length} account(s), registration ${config.registrationOpen ? "open" : "closed"}`);
}

/** Resolve a dynamic (sign-in) token. Static GATEWAY_TOKENS are not consulted here. */
export function lookupToken(token: string): { userId: string; status: AccountStatus } | null {
  const userId = tokenIndex.get(sha256(token));
  if (!userId) return null;
  const acct = accountsRef[userId];
  return acct ? { userId, status: acct.status } : null;
}

export function approvedAccountIds(): string[] {
  return Object.entries(accountsRef)
    .filter(([, a]) => a.status === "approved")
    .map(([id]) => id);
}

const lastTouch = new Map<string, number>();

/** Record activity, persisted at most once per 5 minutes per account. */
export function touchLastSeen(userId: string): void {
  const now = Date.now();
  if (now - (lastTouch.get(userId) ?? 0) < LAST_SEEN_INTERVAL_MS) return;
  lastTouch.set(userId, now);
  const acct = accountsRef[userId];
  if (!acct) return;
  acct.lastSeenAt = new Date(now).toISOString();
  void saveStore().catch((err) => console.warn("[auth] lastSeen save failed:", err));
}

// ---------- helpers ----------

function userIdForSub(sub: string): string {
  return `u_${sha256(sub).slice(0, 16)}`;
}

function initialStatus(email: string): AccountStatus {
  if (config.autoApproveAll) return "approved";
  const domain = email.split("@")[1]?.toLowerCase() ?? "";
  return domain && config.autoApproveDomains.includes(domain) ? "approved" : "pending";
}

function isServiceCall(req: Request): boolean {
  const bearer = req.header("authorization")?.slice("Bearer ".length).trim();
  return !!config.serviceToken && bearer === config.serviceToken;
}

const exchangeHits = new Map<string, { count: number; windowStart: number }>();

function exchangeRateLimited(ip: string): boolean {
  const now = Date.now();
  const hit = exchangeHits.get(ip);
  if (!hit || now - hit.windowStart > 60_000) {
    exchangeHits.set(ip, { count: 1, windowStart: now });
    return false;
  }
  hit.count++;
  return hit.count > EXCHANGE_RATE_LIMIT;
}

function publicAccount(userId: string, a: Account) {
  return {
    userId,
    email: a.email,
    name: a.name,
    status: a.status,
    createdAt: a.createdAt,
    lastSeenAt: a.lastSeenAt,
  };
}

// ---------- routes ----------

export function registerAuthRoutes(app: Express): void {
  // Step 1: the app opens this in a browser with a fresh nonce.
  app.get("/auth/google", (req: Request, res: Response) => {
    const nonce = String(req.query.nonce ?? "");
    if (!NONCE_RE.test(nonce)) {
      res.status(400).send(page("Bad request", "Open this from the VisionClaw app."));
      return;
    }
    const appDef = getStaticApp(SIGN_IN_APP_ID);
    const creds = appDef ? appCredentials(appDef) : null;
    if (!appDef || !creds) {
      res.status(503).send(page("Not configured", "Google sign-in is not set up on this gateway yet."));
      return;
    }
    sweepNonces();
    started.set(nonce, Date.now());
    const scopes = ["openid", "email", "profile", ...appDef.scopes];
    const params = new URLSearchParams({
      client_id: creds.clientId,
      redirect_uri: `${baseUrl(req)}/auth/google/callback`,
      response_type: "code",
      scope: [...new Set(scopes)].join(" "),
      state: signState(nonce),
      ...(appDef.authorizeParams ?? {}),
    });
    res.redirect(`${appDef.authorizeUrl}?${params.toString()}`);
  });

  // Step 2: Google redirects here. Upsert the account, mint a token, park it.
  app.get("/auth/google/callback", async (req: Request, res: Response) => {
    if (req.query.error) {
      res.status(400).send(page("Sign-in cancelled", "You can close this window and try again from the app."));
      return;
    }
    const verified = verifyState(String(req.query.state ?? ""));
    const code = String(req.query.code ?? "");
    if (!verified || !code) {
      res.status(400).send(page("Could not sign in", "The sign-in link expired. Please try again from the app."));
      return;
    }
    const appDef = getStaticApp(SIGN_IN_APP_ID);
    const creds = appDef ? appCredentials(appDef) : null;
    if (!appDef || !creds) {
      res.status(503).send(page("Not configured", "Google sign-in is not set up on this gateway yet."));
      return;
    }

    try {
      const tokens = await exchangeAuthCode(appDef.tokenUrl, {
        code,
        clientId: creds.clientId,
        clientSecret: creds.clientSecret,
        redirectUri: `${baseUrl(req)}/auth/google/callback`,
      });
      if (!tokens) {
        res.status(502).send(page("Could not sign in", "Google rejected the sign-in. Please try again."));
        return;
      }
      const infoRes = await fetch(USERINFO_URL, { headers: { Authorization: `Bearer ${tokens.access_token}` } });
      if (!infoRes.ok) {
        console.error("[auth] userinfo failed:", infoRes.status, await infoRes.text());
        res.status(502).send(page("Could not sign in", "Google did not return your account details. Please try again."));
        return;
      }
      const info = (await infoRes.json()) as { sub?: string; email?: string; name?: string };
      if (!info.sub || !info.email) {
        res.status(502).send(page("Could not sign in", "Google did not return an email for this account."));
        return;
      }

      const userId = userIdForSub(info.sub);
      const all = await accounts();
      accountsRef = all;
      let acct = all[userId];
      const now = new Date().toISOString();
      if (!acct) {
        if (!config.registrationOpen) {
          res.status(403).send(page("Registration closed", "VisionClaw is not taking new accounts right now."));
          return;
        }
        acct = {
          sub: info.sub,
          email: info.email,
          name: info.name ?? "",
          status: initialStatus(info.email),
          createdAt: now,
          lastSeenAt: now,
          tokenHashes: [],
        };
        all[userId] = acct;
        console.log(`[auth] new account ${userId} (${info.email}) status=${acct.status}`);
      } else {
        acct.email = info.email;
        if (info.name) acct.name = info.name;
        acct.lastSeenAt = now;
      }

      const token = `vc-${randomBytes(16).toString("hex")}`;
      acct.tokenHashes.push(sha256(token));
      if (acct.tokenHashes.length > TOKENS_PER_ACCOUNT) {
        acct.tokenHashes = acct.tokenHashes.slice(-TOKENS_PER_ACCOUNT);
      }
      rebuildTokenIndex();
      await saveStore();

      // The refresh token only exists at this moment, so the calendar
      // credential is stored even for pending accounts: approval later must
      // not require a second sign-in. Revoked accounts get nothing.
      if (acct.status !== "revoked") {
        try {
          await ensureUser(userId);
          await storeMcpCredential(userId, appDef, tokens, staticRefresh(appDef, creds));
        } catch (err) {
          console.error(`[auth] provisioning/calendar failed for ${userId}:`, err);
        }
      }

      sweepNonces();
      started.delete(verified.nonce);
      parked.set(verified.nonce, { token, userId, email: acct.email, status: acct.status, at: Date.now() });

      res.send(
        acct.status === "approved"
          ? page("Signed in", "You can close this window and return to the VisionClaw app.")
          : acct.status === "pending"
            ? page("Almost there", "Your account is awaiting approval. Return to the app; it will let you in once approved.")
            : page("Account disabled", "This account has been revoked. Contact whoever runs this gateway."),
      );
    } catch (err) {
      console.error("[auth] callback failed:", err);
      res.status(502).send(page("Could not sign in", "Something went wrong. Please try again."));
    }
  });

  // Step 3: the app collects the parked token, exactly once.
  app.post("/auth/exchange", (req: Request, res: Response) => {
    if (exchangeRateLimited(req.ip ?? "unknown")) {
      res.status(429).json({ error: { code: "rate_limited", message: "slow down" } });
      return;
    }
    const nonce = String(req.body?.nonce ?? "");
    if (!NONCE_RE.test(nonce)) {
      res.status(400).json({ error: { code: "bad_nonce", message: "nonce must be 32 hex chars" } });
      return;
    }
    sweepNonces();
    const p = parked.get(nonce);
    if (p) {
      parked.delete(nonce);
      used.set(nonce, Date.now());
      res.json({ token: p.token, userId: p.userId, email: p.email, status: p.status });
      return;
    }
    if (used.has(nonce)) {
      res.status(410).json({ error: { code: "expired", message: "this sign-in was already collected" } });
      return;
    }
    const begun = started.get(nonce);
    if (begun !== undefined && Date.now() - begun > PARK_TTL_MS) {
      res.status(410).json({ error: { code: "expired", message: "sign-in expired; start again" } });
      return;
    }
    res.status(404).json({ error: { code: "not_ready", message: "sign-in not completed yet" } });
  });

  // Who am I -- answers for pending and revoked accounts too, so the app can
  // show the waiting state instead of a bare 401.
  app.get("/me", (req: Request, res: Response) => {
    const header = req.header("authorization");
    const token = header?.startsWith("Bearer ") ? header.slice("Bearer ".length).trim() : "";
    if (!token) {
      res.status(401).json({ error: { message: "invalid or missing gateway token" } });
      return;
    }
    if (config.serviceToken && token === config.serviceToken) {
      res.json({ userId: req.header("x-user-id")?.trim() || null, email: null, status: "approved" });
      return;
    }
    const staticUser = config.tokens.get(token);
    if (staticUser) {
      res.json({ userId: staticUser, email: null, status: "approved" });
      return;
    }
    const dyn = lookupToken(token);
    if (!dyn) {
      res.status(401).json({ error: { message: "invalid or missing gateway token" } });
      return;
    }
    const acct = accountsRef[dyn.userId];
    res.json({ userId: dyn.userId, email: acct?.email ?? null, status: dyn.status });
  });

  // ---------- admin (service token only) ----------

  app.get("/admin/accounts", (req: Request, res: Response) => {
    if (!isServiceCall(req)) {
      res.status(401).json({ error: { message: "service token required" } });
      return;
    }
    const list = Object.entries(accountsRef)
      .map(([id, a]) => publicAccount(id, a))
      .sort((a, b) => a.createdAt.localeCompare(b.createdAt));
    res.json({ accounts: list });
  });

  app.post("/admin/accounts/:userId", async (req: Request, res: Response) => {
    if (!isServiceCall(req)) {
      res.status(401).json({ error: { message: "service token required" } });
      return;
    }
    const status = String(req.body?.status ?? "") as AccountStatus;
    if (!["approved", "revoked", "pending"].includes(status)) {
      res.status(400).json({ error: { message: "status must be approved, revoked or pending" } });
      return;
    }
    const userId = String(req.params.userId);
    const acct = accountsRef[userId];
    if (!acct) {
      res.status(404).json({ error: { message: "no such account" } });
      return;
    }
    acct.status = status;
    await saveStore();
    console.log(`[auth] ${userId} (${acct.email}) -> ${status}`);
    res.json({ account: publicAccount(userId, acct) });
  });

  app.get("/admin/settings", (req: Request, res: Response) => {
    if (!isServiceCall(req)) {
      res.status(401).json({ error: { message: "service token required" } });
      return;
    }
    res.json({
      registrationOpen: config.registrationOpen,
      autoApproveDomains: config.autoApproveDomains,
      autoApproveAll: config.autoApproveAll,
    });
  });
}
