# Deployment

This document covers deploying the WebRTC signaling server in
[`samples/CameraAccess/server/`](samples/CameraAccess/server/) to Fly.io.
The mobile clients themselves are distributed via Xcode / Android Studio
and don't have a server-side deploy step.

## Required environment variables

The server refuses to start unless the following are set:

| Variable             | Required | Purpose                                                                |
| -------------------- | -------- | ---------------------------------------------------------------------- |
| `EXPRESSTURN_USER`   | yes      | TURN credential username (per-tenant; do not share across deployments) |
| `EXPRESSTURN_PASS`   | yes      | TURN credential password                                               |
| `EXPRESSTURN_SERVER` | no       | TURN hostname; defaults to `free.expressturn.com`                      |
| `ALLOWED_ORIGINS`    | no       | Comma-separated CORS allowlist for `/api/turn` (e.g. `https://your-app.example.com`). Empty = no cross-origin reads. `*` allowed for local dev only. |
| `PORT`               | no       | Port to bind; defaults to `8080`. Fly.io's `internal_port` is set in `fly.toml`. |

## First-time Fly.io setup

```bash
cd samples/CameraAccess/server

# Sign in and create the app (only once per app name)
flyctl auth login
flyctl apps create visionclaw-signaling   # name must match fly.toml

# Set secrets BEFORE the first deploy. The server will refuse to boot
# without TURN credentials, and missing ALLOWED_ORIGINS means
# cross-origin browsers can't read /api/turn.
flyctl secrets set \
  EXPRESSTURN_USER='your-turn-username' \
  EXPRESSTURN_PASS='your-turn-password' \
  ALLOWED_ORIGINS='https://your-app.example.com'

# Deploy
flyctl deploy
```

## Routine deploys

```bash
cd samples/CameraAccess/server
flyctl deploy
```

To rotate TURN credentials without downtime:

```bash
flyctl secrets set EXPRESSTURN_USER=... EXPRESSTURN_PASS=...
# Fly automatically rolls the machines after a secrets change.
```

## Client URL configuration

The mobile clients connect to the signaling server via WebSocket. After
deploy, Fly serves on `https://visionclaw-signaling.fly.dev`. Use the
`wss://` scheme (not `ws://`) — `force_https = true` in `fly.toml`
redirects HTTP, but WebSocket clients should connect to the secure
endpoint directly.

- iOS: `WebRTC/WebRTCConfig.swift`
- Android: `webrtc/WebRTCConfig.kt`
- Browser viewer: served from the same Fly app at
  `https://visionclaw-signaling.fly.dev/`

## Verifying a deploy

```bash
# Health check via the TURN credential endpoint. Without ALLOWED_ORIGINS
# matching, browsers won't get CORS headers, but a curl with no Origin
# header always succeeds.
curl -i https://visionclaw-signaling.fly.dev/api/turn

# Confirm CORS allowlist is enforced (should NOT include
# Access-Control-Allow-Origin):
curl -i -H "Origin: https://attacker.example" https://visionclaw-signaling.fly.dev/api/turn

# Confirm rate limiting kicks in around 30 req/min:
for i in $(seq 1 35); do
  curl -s -o /dev/null -w '%{http_code}\n' https://visionclaw-signaling.fly.dev/api/turn
done
# Expect: 200 x 30, then 429s.
```

## Known gaps (follow-ups)

- The Gemini API key is still passed in the WebSocket query string from
  the mobile clients. A backend exchange that mints short-lived keys
  per session is the real fix; until then, treat the API key as
  log-leakable and rotate aggressively.
- The signaling server is single-instance; the rate limiter is
  in-process. If you scale to multiple machines, replace it with a
  shared store (e.g. Redis) before relying on the limits for security.
