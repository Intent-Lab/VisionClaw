# VisionClaw Gateway (hosted action agent, beta)

Run VisionClaw's action agent in the cloud so users don't have to install and
host a local agent on their own machine. The gateway speaks the exact protocol
the iOS/Android apps already use (OpenAI-compatible `/v1/chat/completions` +
the WebSocket event channel), and drives
[Anthropic Managed Agents](https://platform.claude.com/docs/en/managed-agents/overview)
behind it: one durable session per user, a mounted long-term memory store, a
per-user credential vault, and a hosted sandbox for tool execution (web search,
files, bash) — no sandbox infrastructure to operate.

```
iOS / Android app  (unchanged)
  ├── POST /v1/chat/completions ─┐
  └── ws:// events ◄─────────┐   │
                             │   ▼
                        this gateway
                             │
                             ▼
              Anthropic Managed Agents (beta)
                1 shared agent config + environment
                1 session + memory store + vault per user
```

## Quick start

```bash
cd gateway
npm install
cp .env.example .env        # set ANTHROPIC_API_KEY and GATEWAY_TOKENS
npm run provision           # creates the shared environment + agent (once)
npm run dev                 # gateway on :8788
```

`GATEWAY_TOKENS` maps client tokens to user ids, e.g.
`GATEWAY_TOKENS="s3cret-a:alice,s3cret-b:bob"`. Each user's session, memory
store, and vault are provisioned lazily on first request (or eagerly via
`npm run provision -- alice bob`).

**App setup** (Settings → Agent): host = `http://<gateway-host>`, port = `8788`,
gateway token = the user's token. Local self-hosted mode keeps working — this
is an alternative backend, not a replacement.

## Endpoints

| Route | Purpose |
|---|---|
| `GET /v1/chat/completions` | reachability probe (the app's connection check) |
| `POST /v1/chat/completions` | one agent turn. Sends only the newest user message — the managed session owns durable history (server-side compaction included). With `"stream": true`, responds with OpenAI-style SSE chunks generated live from the agent's output |
| `POST /context` | queue voice-session context (`{"context": "..."}`); it attaches to the user's next turn as a system-level event (the API rejects standalone system messages) |
| `GET /tasks?limit=N` | recent delegated tasks + results, for the app's Recent Tasks view |
| `GET /apps` | connectable apps and whether this user has linked each one |
| `GET /connect/:app?token=…` | starts the OAuth flow (open in an in-app auth sheet); the callback stores an `mcp_oauth` credential in the user's vault |
| `ws://host:port` | event channel; same protocol-v3 handshake as the local gateway. Late task results arrive as `heartbeat` events, scheduled-task summaries as `cron` events |

## Two-speed turns

`POST /v1/chat/completions` waits up to `QUICK_ANSWER_TIMEOUT_MS` (default 30s).
If the agent is still working, the call returns an acknowledgement immediately
and the final result is pushed over the WebSocket when it lands — the voice
layer never blocks on a long task. The same budget applies to streaming
requests: past it, the stream closes with an acknowledgement chunk and the
final text arrives as a proactive event.

## Connecting apps

Extensions are MCP servers declared once on the shared agent config, with
per-user OAuth credentials in that user's vault (Anthropic refreshes the
tokens). Adding one means a new entry in `src/apps.ts` — the connect routes,
the vault write, and the `/apps` listing are generic. Entries are offered only
when enabled and their MCP URL resolves, so a self-hosted app stays hidden
until it is deployed.

After the OAuth callback the gateway makes one real `tools/call` against the
server before reporting success: a valid grant does not guarantee the server
will serve that account, and "connected" should not claim otherwise.

### Google Calendar

Google's own Calendar MCP server (`calendarmcp.googleapis.com`) is **disabled in
the registry**. It ships under the Google Workspace Developer Preview Program:
with a personal Gmail account `initialize` and `tools/list` succeed but every
`tools/call` returns "The caller does not have permission" — verified with a
direct token call, while the same token works fine against the Calendar REST
API. It needs a Workspace account plus preview enrollment, so it cannot serve
consumer users.

Instead, run [`taylorwilsdon/google_workspace_mcp`](https://github.com/taylorwilsdon/google_workspace_mcp)
(MIT) in external-OAuth mode, where it accepts the bearer token the vault
injects rather than running its own OAuth flow, and calls the Google REST APIs
underneath — which works with consumer accounts:

```bash
docker run -p 8000:8000 \
  -e MCP_ENABLE_OAUTH21=true \
  -e EXTERNAL_OAUTH21_PROVIDER=true \
  -e GOOGLE_OAUTH_CLIENT_ID="<same client id the gateway uses>" \
  -e WORKSPACE_MCP_TOOLS="calendar" \
  workspace-mcp --transport streamable-http --read-only
```

Then point the gateway at it — the app stays hidden until this is set:

```
WORKSPACE_MCP_URL=https://your-workspace-mcp.example.com/mcp/
```

The same deployment also serves Gmail, Tasks, Drive and more: widen
`WORKSPACE_MCP_TOOLS` and add a registry entry with the matching scopes.

To set up the Google side:

1. Create a Google Cloud project; enable **Google Calendar API** and
   **Google Calendar MCP API**.
2. Configure the OAuth consent screen and set publishing status to **In
   production** — in *Testing* status Google expires refresh tokens after 7
   days, which silently breaks stored credentials.
3. Create a Web application OAuth client with redirect URI
   `<PUBLIC_BASE_URL>/connect/gcal-self/callback`; put the id/secret in `.env`.
4. Unverified apps are capped at 100 users and show a warning screen; submit
   for sensitive-scope verification to lift both.

On-device alternative: the iOS app also exposes calendar and reminder tools
backed by EventKit, which need no OAuth at all. Those cover interactive asks;
the connected app is what lets background and scheduled tasks reach the
calendar when the phone is asleep.

### Notion

Notion connects through Notion's hosted MCP server (`https://mcp.notion.com/mcp`),
which speaks the MCP authorization spec (OAuth 2.1). There is nothing to set up in
any console: the gateway discovers the server's OAuth endpoints from its metadata,
registers itself as a client once (dynamic client registration, persisted in the
store under `shared.mcpClients.notion`), and runs a PKCE authorization for each
user. `NOTION_DISABLED=true` hides the app.

What the user sees: Notion's consent screen, where they choose which pages or the
whole workspace the agent may access. Token lifetimes are Notion's: access tokens
about eight hours, refresh tokens 180 days (or 30 days idle), rotated on every
refresh; Anthropic refreshes them from the stored vault credential.

The same `mcp-oauth21` app kind works for any remote MCP server that implements
the authorization spec: add an entry in `apps.ts` with its `mcpUrl` and a
`clientName`, and the discovery, registration, and consent flow are shared.
Servers that publish metadata but do not offer dynamic client registration take
the same entry plus `clientIdEnv`/`clientSecretEnv` for a client you registered
in their console (Slack below).

### Slack

Slack connects through Slack's hosted MCP server (`https://mcp.slack.com/mcp`):
standard OAuth 2.1 metadata and PKCE, but no dynamic client registration, so it
must be backed by a Slack app you create:

1. https://api.slack.com/apps -> Create New App -> From scratch, in the workspace
   the study will use.
2. OAuth & Permissions -> Redirect URLs -> add
   `https://api.visionagents.app/connect/slack/callback` and save.
3. OAuth & Permissions -> User Token Scopes -> add every scope in `SLACK_SCOPES`
   (`apps.ts`): search:read.public, search:read.private, chat:write, channels:read,
   channels:history, groups:history, im:history, users:read, files:write,
   canvases:read, canvases:write. Trim the constant and the app in step if the
   study needs less.
4. Leave Token Rotation OFF (OAuth & Permissions -> Advanced token security).
   Rotated tokens expire after 12 hours; without rotation, user tokens do not
   expire, so the vault credential is stored without a refresh block.
5. Basic Information -> App Credentials -> copy Client ID and Client Secret, then
   `fly secrets set SLACK_CLIENT_ID=... SLACK_CLIENT_SECRET=... -a visionclaw-gateway`.
   The app is hidden from `/apps` until both are set; `SLACK_DISABLED=true` hides it
   again without a deploy.

Constraint from Slack: only internal apps and directory-published apps may use the
MCP server. An internal app works for members of the workspace it was created in,
so every participant who should get Slack must belong to that workspace (a study
workspace you invite them to is the simplest arrangement).

What the user sees: Slack's consent screen for the requested user scopes; every
tool call then acts as that user, under their own permissions.

## Google sign-in and accounts

Besides static `GATEWAY_TOKENS`, people can register themselves with a Google
account. The app opens `GET /auth/google?nonce=<32 hex>` in the browser, the
consent screen asks for identity plus the calendar scopes of `gcal-self`, and
the callback upserts an account, stores the calendar credential in that
user's vault (so signing in also connects the calendar), mints a bearer token,
and parks it under the nonce. The app collects it once with
`POST /auth/exchange {nonce}` (`404 not_ready` until the callback has run,
`410 expired` after use or 10 minutes). Tokens are stored as sha256 hashes,
five live per account; the raw token exists only on the device.

Account ids are `u_<16 hex of sha256(google sub)>`, never the email. Only
`approved` accounts resolve on authenticated routes; `pending` and `revoked`
ones get 401 everywhere except `GET /me` (`{userId,email,status}`), which the
app uses to show a waiting state.

Env:

- `REGISTRATION_OPEN=false` refuses new accounts (existing ones keep working).
- `AUTO_APPROVE_DOMAINS=colorado.edu,example.org` approves new accounts from
  those email domains; everyone else waits in `pending`.
- `AUTO_APPROVE_ALL=true` approves every new account.

Admin (service token only): `GET /admin/accounts`,
`POST /admin/accounts/:userId {status}`, `GET /admin/settings`. The dashboard's
Users tab wraps these: approve, revoke, jump to a user's trace. `/users` (and
so `trace:export --all`) includes approved accounts, and `--all` also writes
`participants.csv` with a stable `p01..pNN` pseudonym per account in sign-up
order.

One-time Google Console step: add
`https://api.visionagents.app/auth/google/callback` as an authorized redirect
URI on the calendar OAuth client (`GOOGLE_CLIENT_ID`). Sign-in reuses that
client, so no new project or verification is involved; the unverified-app cap
of 100 users applies to sign-in as it does to calendar.

## Exporting the interaction trace

The voice worker records every call as text-only events (utterances, tool
actions, cards, parked results) at `POST /trace`; `GET /trace` reads them back
and `/dashboard` shows them live. For study analysis, export per user:

```bash
npm run trace:export -- <userId> [--since 2026-08-18T00:00:00Z] [--out dir]
npm run trace:export -- --all                       # every user in GATEWAY_TOKENS
npm run trace:export -- fixture --from-file test-fixtures/trace-sample.json
```

Needs `GATEWAY_SERVICE_TOKEN` (and optionally `GATEWAY_URL`) in the environment
or `.env`; `--all` enumerates users through the service-token-only `/users`
endpoint. Each user gets `events.csv` (one row per event, session index
attached), `sessions.csv` (per-call duration, engine, turn and action counts)
and `summary.md` (totals, per-tool counts, turn statistics, and every error,
deferral or parked result). `--all` adds an aggregate `summary.md`.

`GET /trace` with no cursor returns the newest 1000 events; with `since` it
returns the oldest 1000 at or after the cursor, and the export pages forward
from the epoch, so long histories export completely.

## Notes and roadmap

- Managed Agents is an Anthropic **beta**; quotas apply (notably scheduled
  deployments are capped per organization).
- Memory is a per-user mounted store of small text files, versioned and
  redactable server-side.
- Roadmap: more connectable apps (Gmail, Notion, Linear), scheduled reminders
  via deployments, tool-permission prompts surfaced as spoken confirmations,
  Android parity for the backend switcher and local tools.
