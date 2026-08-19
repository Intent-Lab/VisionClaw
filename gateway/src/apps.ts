/**
 * Connectable app registry.
 *
 * Adding an extension is one entry here. Credentials are stored per user in
 * that user's vault, keyed by the MCP server URL; Anthropic refreshes OAuth
 * tokens and injects them as a bearer on every call to that server.
 *
 * An entry is *active* only when its MCP URL resolves and it is not disabled.
 * Inactive entries are invisible to the agent config, `/apps`, and `/connect`.
 */

export interface ConnectableApp {
  id: string;
  displayName: string;
  /** Fixed MCP server URL. Use `mcpUrlEnv` instead for self-hosted deployments. */
  mcpUrl?: string;
  /** Env var holding the MCP server URL; the app stays hidden until it is set. */
  mcpUrlEnv?: string;
  authorizeUrl: string;
  tokenUrl: string;
  scopes: string[];
  /** Extra params on the authorize URL (Google needs these to issue a refresh token). */
  authorizeParams?: Record<string, string>;
  clientIdEnv: string;
  clientSecretEnv: string;
  /** Kept for reference but never offered; see the note on each entry. */
  disabled?: boolean;
}

const GOOGLE_AUTHORIZE = "https://accounts.google.com/o/oauth2/v2/auth";
const GOOGLE_TOKEN = "https://oauth2.googleapis.com/token";
// offline + consent are required for Google to return a refresh token. Without
// one the vault credential dies at the first expiry.
const GOOGLE_AUTHORIZE_PARAMS = {
  access_type: "offline",
  prompt: "consent",
  include_granted_scopes: "true",
};

export const APPS: Record<string, ConnectableApp> = {
  /**
   * Google's own Calendar MCP server.
   *
   * DISABLED — verified 2026-07: it ships under the Google Workspace Developer
   * Preview Program. With a personal Gmail account `initialize` and
   * `tools/list` succeed, but every `tools/call` returns "The caller does not
   * have permission" (reproduced with a direct token call, so not a client or
   * credential problem; the same token works against the Calendar REST API).
   * Using it needs a Workspace account plus preview enrollment, which rules it
   * out for consumer users. Re-enable if that changes.
   */
  gcal: {
    id: "gcal",
    displayName: "Google Calendar (Google-hosted)",
    mcpUrl: "https://calendarmcp.googleapis.com/mcp/v1",
    authorizeUrl: GOOGLE_AUTHORIZE,
    tokenUrl: GOOGLE_TOKEN,
    scopes: [
      "https://www.googleapis.com/auth/calendar.calendarlist.readonly",
      "https://www.googleapis.com/auth/calendar.events.freebusy",
      "https://www.googleapis.com/auth/calendar.events.readonly",
    ],
    authorizeParams: GOOGLE_AUTHORIZE_PARAMS,
    clientIdEnv: "GOOGLE_CLIENT_ID",
    clientSecretEnv: "GOOGLE_CLIENT_SECRET",
    disabled: true,
  },

  /**
   * Self-hosted Google Workspace MCP (taylorwilsdon/google_workspace_mcp, MIT),
   * run in external-OAuth mode so it accepts the bearer token the vault injects
   * instead of running its own OAuth flow. Works with consumer Gmail because it
   * simply calls the Google REST APIs.
   *
   * Deploy with:
   *   MCP_ENABLE_OAUTH21=true EXTERNAL_OAUTH21_PROVIDER=true \
   *   GOOGLE_OAUTH_CLIENT_ID=<same client id> WORKSPACE_MCP_TOOLS=calendar \
   *   <run> --transport streamable-http --read-only
   * then set WORKSPACE_MCP_URL to its public https URL, ending in /mcp/.
   */
  gcalSelfHosted: {
    id: "gcal-self",
    displayName: "Google Calendar",
    mcpUrlEnv: "WORKSPACE_MCP_URL",
    authorizeUrl: GOOGLE_AUTHORIZE,
    tokenUrl: GOOGLE_TOKEN,
    scopes: [
      // The server validates bearer tokens against Google's userinfo endpoint,
      // so identity scopes are required alongside the data scope.
      "openid",
      "https://www.googleapis.com/auth/userinfo.email",
      // Google Calendar is the source of truth for events, so the agent needs
      // to write as well as read -- scheduled runs have no phone to fall back
      // on. This pair covers event CRUD without granting calendar management.
      "https://www.googleapis.com/auth/calendar.readonly",
      "https://www.googleapis.com/auth/calendar.events",
    ],
    authorizeParams: GOOGLE_AUTHORIZE_PARAMS,
    clientIdEnv: "GOOGLE_CLIENT_ID",
    clientSecretEnv: "GOOGLE_CLIENT_SECRET",
  },

  /**
   * Gmail through a second google_workspace_mcp instance (TOOLS=gmail).
   *
   * Deliberately a SEPARATE OAuth client in a SEPARATE Google Cloud project
   * kept in Testing publishing status: gmail.* are restricted scopes, and the
   * only no-review path is testing mode with named test users (max 100).
   * The calendar client's project must stay In Production -- moving it to
   * Testing would put the 7-day refresh-token expiry on calendar too.
   *
   * Testing-mode costs, by policy: every user must be added as a test user in
   * the console first, and refresh tokens expire every 7 days, so connections
   * die weekly and users reconnect from the app. Fine for a deployment study;
   * a public launch needs full restricted-scope verification (CASA).
   *
   * Separate MCP instance because vault credentials are keyed by MCP URL --
   * on the calendar server's URL this credential would overwrite that one.
   */
  gmail: {
    id: "gmail",
    displayName: "Gmail",
    mcpUrlEnv: "GMAIL_MCP_URL",
    authorizeUrl: GOOGLE_AUTHORIZE,
    tokenUrl: GOOGLE_TOKEN,
    scopes: [
      "openid",
      "https://www.googleapis.com/auth/userinfo.email",
      // Read + send, not gmail.modify: the agent summarizes and sends mail;
      // nothing needs label edits or deletion, so don't ask for them.
      "https://www.googleapis.com/auth/gmail.readonly",
      "https://www.googleapis.com/auth/gmail.send",
    ],
    authorizeParams: GOOGLE_AUTHORIZE_PARAMS,
    clientIdEnv: "GOOGLE_GMAIL_CLIENT_ID",
    clientSecretEnv: "GOOGLE_GMAIL_CLIENT_SECRET",
  },
};

/** MCP URL for an app, or null when a self-hosted app has no URL configured. */
export function mcpUrlFor(app: ConnectableApp): string | null {
  if (app.mcpUrl) return app.mcpUrl;
  if (app.mcpUrlEnv) return process.env[app.mcpUrlEnv] || null;
  return null;
}

/** Apps that are enabled and have a resolvable endpoint. */
export function activeApps(): Array<ConnectableApp & { mcpUrl: string }> {
  return Object.values(APPS).flatMap((app) => {
    if (app.disabled) return [];
    const url = mcpUrlFor(app);
    return url ? [{ ...app, mcpUrl: url }] : [];
  });
}

export function getApp(id: string): (ConnectableApp & { mcpUrl: string }) | undefined {
  return activeApps().find((a) => a.id === id);
}

export function appCredentials(app: ConnectableApp): { clientId: string; clientSecret: string } | null {
  const clientId = process.env[app.clientIdEnv];
  const clientSecret = process.env[app.clientSecretEnv];
  if (!clientId || !clientSecret) return null;
  return { clientId, clientSecret };
}
