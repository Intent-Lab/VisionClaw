# VisionClaw Glasses Broker

The broker is the Mac-side boundary for VisionClaw's named glasses session.
It lets a paired iPhone invoke the fixed `Eva` OpenClaw harness and use a
scoped, fork-only Codex task bridge without placing either backend credential
on the phone.

## Current status

- Secure same-Wi-Fi transport: implemented.
- Persistent OpenClaw Gateway v4 connection: implemented.
- Scoped Codex app-server bridge: implemented.
- One-time QR pairing and TLS public-key pinning contract: implemented.
- Authenticated remote relay: not yet implemented.

Do not port-forward this service. Remote use will go through an outbound,
end-to-end authenticated relay in a later milestone.

## Run locally

Requirements:

- Node.js 22 or newer.
- OpenClaw 2026.7.1 with its local Gateway running.
- The ChatGPT macOS app, which supplies the supported Codex app-server binary.
- `qrencode` for a scannable terminal QR. If it is absent, `pair` prints the
  one-time pairing link instead.

Before starting the broker, verify that the local Gateway is healthy and that
the dedicated agent ID is exactly `glasses`:

```sh
openclaw gateway status
openclaw agents list
```

If `glasses` is absent, create it with OpenClaw's guided setup, then verify the
list again:

```sh
openclaw agents add glasses
openclaw agents list
```

The Gateway must use token authentication. The broker reads that credential
from the Mac's existing OpenClaw configuration and connects over loopback; do
not copy it into VisionClaw and do not expose the Gateway on the LAN.

From this directory:

```sh
npm test
npm start -- --lan
```

Keep the broker running. In a second terminal:

```sh
npm run status
npm run pair
```

`npm run pair` prints the private Mac endpoint, broker suffix, and TLS SHA-256
fingerprint before the QR. Scan the QR with the iPhone Camera and open
VisionClaw. Confirm that all three values exactly match the values on the
iPhone, then tap **Pair**.
A pairing offer lasts two minutes and is single-use. Only one offer can be
active at once, and it cannot replace an existing phone pairing without an
explicit Forget first.

To inspect or revoke phones from the Mac:

```sh
npm run pairings
npm run revoke -- vcp_PAIRING_REFERENCE
```

These administrative calls use a dedicated loopback listener and a stable
random credential kept in the broker's private state, even while the phone
endpoint is bound to Wi-Fi. The credential is sent only by the local CLI and
is never written to the runtime record, Bonjour, or command output. The list
exposes only a derived pairing reference, a terminal-safe device name,
timestamps, and active/revoked status. It never prints the phone's pairing
identity, key, thumbprint, or scopes. Revocation takes effect immediately and
remains in force after restart.

Without `--lan`, the broker binds to loopback for a Mac-only smoke test and
does not advertise Bonjour.

## Security boundary

- Bonjour advertises only a public broker identifier, protocol version, and
  TLS availability. Discovery is never treated as identity.
- Pairing pins the broker's P-256 TLS public key. The broker accepts only a
  P-256 phone signing key and stores its thumbprint with the pairing.
- Every protected request carries a fresh device signature and a one-shot,
  route-bound capability.
- The lightweight `POST /v1/session/status` preflight uses a fresh device
  signature but no capability. A successful response contains only the public
  broker ID, `ready: true`, and broker version.
- Pairings, replay records, operation receipts, and Codex confirmations persist
  in a private SQLite database under `~/.visionclaw-broker`.
- OpenClaw agent IDs, Codex methods, sandbox policy, and available routes are
  selected by the broker. The phone cannot provide a model, agent, shell
  command, filesystem path, URL, or raw RPC method.
- Eva requests acknowledge immediately, then publish a bounded completion for
  the phone to speak when it is ready.
- If the broker process restarts during an Eva request, its persisted
  nonterminal receipt becomes an explicit failure so the phone stops polling
  and can retry with a new request identifier.
- Codex continuation always rechecks the source revision, forks the task, and
  starts a constrained turn on the fork. Approval requests are declined and
  must be handled in Codex Desktop.

The broker reads the existing OpenClaw Gateway credential locally and starts a
dedicated Codex app-server child with a strict environment allowlist. Neither
credential is serialized into pairing data, Bonjour, logs, model context, or
phone responses. OpenClaw output is scrubbed before persistence and again
before response; returned Codex task metadata receives the same final boundary
scrub. This recognizes quoted and nested JSON secret fields and removes exact
credentials loaded locally. The exact user-approved Codex continuation
instruction and its hash are intentionally persisted as confirmation state so
the broker can verify the action across restarts.
