# MARK 7 — F.R.I.D.A.Y. System Architecture & Handover Document

**Version:** Mark 7 | **Date:** 2026-03-07 | **Author:** Ethan Sia + Claude
**Purpose:** Complete LLM-readable handover document for any successor agent or human to fully understand, operate, and extend the F.R.I.D.A.Y. system.

> **Convention established at Mark 7:** All future Mark upgrades will be recorded as updates to this document and pushed to both VPS (`/root/.openclaw/workspace-chief/`) and GitHub (`ethan-lab-openclaw/workspace-chief`).

---

## 1. SYSTEM IDENTITY

**F.R.I.D.A.Y.** (Friday Responsive Intelligence & Deferral Anticipation Yield) is a steward intelligence system for **Ethan Sia**, Senior Assistant Director at Singapore's National Robotics Programme (NRP).

**Three work streams:**
1. **BAU** — Programme management, project reviews, QBRs, milestones
2. **Standards** — ASTM F45/F48, ISO, Enterprise SG, NWI submissions
3. **EAI Center** — Embodied AI Center planning, center director liaison, A*STAR/NTU/NUS coordination

**Design philosophy:**
- **Steward, not assistant** — maintains continuity of intent even when Ethan forgets
- **Invisible Orchestra** — one unified voice; sub-agents never surface to Ethan
- **Quiet Butler** — silence means everything is on track; max 3 interrupts/day
- **Anticipation over reaction** — pre-meeting prep, deadline escalation, context linking
- **Importance over urgency** — strategic alignment scoring; urgent-but-unaligned gets deprioritized

---

## 2. ARCHITECTURE OVERVIEW

```
                        Telegram (@FridayClawedBot)
                              ↕
                     ┌────────────────┐
                     │  CHIEF AGENT   │  (MiniMax M2.5 / Sonnet 4.6)
                     │  Commander     │
                     └───────┬────────┘
                             │
              ┌──────────────┼──────────────┐
              ↓              ↓              ↓
         ┌─────────┐   ┌─────────┐   ┌──────────┐
         │POSTMAN  │   │KANBAN   │   │SCRIBE    │
         │(email)  │   │(Trello) │   │(writing) │
         └─────────┘   └─────────┘   └──────────┘
              ↓              ↓              ↓
         ┌─────────┐   ┌─────────┐
         │FORGE    │   │DISPATCH │
         │(code)   │   │(routing)│
         └─────────┘   └─────────┘
                             │
              ┌──────────────┼──────────────┐
              ↓              ↓              ↓
        ┌──────────┐  ┌──────────┐  ┌──────────┐
        │  Gmail   │  │ Calendar │  │ Fireflies│
        │  (gog)   │  │  (gog)   │  │   (API)  │
        └──────────┘  └──────────┘  └──────────┘
              ↓              ↓              ↓
        ┌──────────────────────────────────────┐
        │          8 MEMORY FILES              │
        │   (JSON state, ~/.openclaw/          │
        │    workspace-chief/memory/)          │
        └──────────────────────────────────────┘
```

### Commander Pipeline (5 functions)

| Phase | Purpose | LLM? |
|-------|---------|------|
| **MONITOR** | Capture raw signals from crons, heartbeat, messages | No |
| **ANALYSIS** | Score signals, classify work streams, detect blockers | Mostly deterministic |
| **PLANNING** | Decision packaging, anticipation, conflict resolution | LLM for composition |
| **EXECUTION** | Dispatch to specialist agents, authorization gate | No |
| **MEMORY** | Persist state, track commitments, update entities | No |

---

## 3. AGENTS

### 3.1 Chief (Commander)
- **Role:** Orchestrator. Routes signals, composes briefs, manages memory. The only agent that talks to Ethan.
- **Primary model:** MiniMax M2.5 ($0.30/$1.20 per 1M tokens) — for Telegram routing, heartbeat
- **Heavy work model:** Sonnet 4.6 ($3/$15) — for cron jobs requiring multi-step reasoning
- **Fallback:** DeepSeek V3 ($0.28/$0.42) — free tier, 128K context
- **Heartbeat:** Every 2h, 08:00-22:00 SGT
- **Subagent authority:** Can spawn postman, kanban, scribe, forge, dispatch
- **Workspace:** `~/.openclaw/workspace-chief/`
- **SOUL.md:** 14,356 chars, 255 lines — personality, decision logic, forbidden modifications

### 3.2 Postman (Email Specialist)
- **Role:** Email composition, reply drafting, thread analysis
- **Model:** Sonnet 4.6 primary
- **Activation:** On-demand (spawned by Chief)

### 3.3 Kanban (Task Management)
- **Role:** Trello board operations, card management, progress tracking
- **Model:** MiniMax M2.5 primary
- **Activation:** On-demand (spawned by Chief)

### 3.4 Scribe (Documentation)
- **Role:** Meeting minutes, document generation, report writing
- **Model:** Sonnet 4.6 primary
- **Activation:** On-demand (spawned by Chief)

### 3.5 Forge (Engineering)
- **Role:** Code changes, config modifications, system upgrades
- **Model:** Sonnet 4.6 primary
- **Activation:** On-demand (Ethan's coding sessions)
- **Special authority:** ONLY agent allowed to modify code, config, and system files
- **Dual mode:** Sub-agent (Chief spawns) or direct (Ethan works with Forge)

### 3.6 Dispatch (Routing)
- **Role:** Multi-channel message routing, notification delivery
- **Model:** MiniMax M2.5 primary
- **Activation:** On-demand (spawned by Chief)

### Config Guardrail
- Chief is **PROHIBITED** from modifying any code, config, or system files
- Only Forge can execute config changes, with Ethan's explicit approval
- Workflow: Chief proposes → Ethan approves → Forge executes → Ethan confirms

---

## 4. INFRASTRUCTURE

### 4.1 Hosting
- **VPS:** 89.167.121.237 (production — always-on, crons, Telegram bot)
- **Mac:** Development/testing environment; manual syncing to VPS via SCP
- **Gateway:** OpenClaw gateway on port 18789 (loopback), systemd service `openclaw-gateway.service`

### 4.2 External Services
| Service | Access Method | Account |
|---------|--------------|---------|
| Gmail | `gog` CLI (OAuth) | ethan.nrpo@gmail.com |
| Google Calendar | `gog` CLI (OAuth) | ethan.nrpo@gmail.com |
| Trello | REST API (API key + token) | env vars |
| Fireflies.ai | GraphQL API (Bearer token) | env var `FIREFLIES_API_KEY` |
| Telegram | Bot API (@FridayClawedBot) | openclaw.json channels config |
| MiniMax | anthropic-messages API | env var `MINIMAX_API_KEY` |
| Anthropic | Direct API | env var `ANTHROPIC_API_KEY` |
| DeepSeek | openai-responses API | env var `DEEPSEEK_API_KEY` |

### 4.3 Key Environment Variables
Stored in `~/.openclaw/openclaw.json` under `env` section:
- `FIREFLIES_API_KEY`, `TRELLO_API_KEY`, `TRELLO_TOKEN`
- `MINIMAX_API_KEY`, `ANTHROPIC_API_KEY`, `DEEPSEEK_API_KEY`
- `GITHUB_TOKEN`
- `GOG_KEYRING_PASSWORD` (VPS gateway service env)

Scripts auto-resolve credentials from `openclaw.json` via `_load_openclaw_env()` helper — works in both cron (gateway sets vars) and manual SSH contexts.

### 4.4 Telegram Configuration
- **Bot:** @FridayClawedBot
- **Chat ID:** 8292410866 (Ethan Sia)
- **DM Policy:** allowlist (only Ethan)
- **Custom commands:** `/brief`, `/email`, `/trello`, `/cost`, `/today`, `/weekly`, `/memory`, `/systemcheck`, `/why {DEC-ID}`, `/ack {DS-ID}`, `/drift`

---

## 5. CRON JOBS (8 total)

| # | Job | Schedule (SGT) | Model | Timeout | Purpose |
|---|-----|----------------|-------|---------|---------|
| 1 | **Morning Brief** | Tue-Fri 09:00 | Sonnet 4.6 | 300s | Calendar, Trello, decision digest, anticipation, weather |
| 2 | **Email Intake** | Mon-Fri 09:30 | Sonnet 4.6 | 480s | Gmail triage, VIP scoring, decision creation, waiting model |
| 3 | **Fireflies Check** | Mon-Fri 18:00 | Sonnet 4.6 | 480s | Transcript processing, action items, VIP reply tracking |
| 4 | **Evening Micro-Brief** | Mon-Fri 18:30 | Sonnet 4.6 | 360s | Delta analysis vs morning (skip if Friday review ran) |
| 5 | **Friday Weekly Review** | Fri 17:00 | Sonnet 4.6 | 900s | Full sweep: wins, blockers, commitments, inverse queries, drift |
| 6 | **Monday Weekly Brief** | Mon 08:30 | MiniMax | 900s | Week ahead: strategic context, attention allocation, cost burn |
| 7 | **Memory Maintenance** | Sun 03:00 | MiniMax | 300s | Re-embed, decay, evict, audit, expire stale follow-ups |
| 8 | **Cost Report** | Mon 09:00 | MiniMax | 120s | **DISABLED** — folded into Monday Weekly Brief |

### Cron Pipeline Steps (Fireflies example — most complex)
```
M2-A: fireflies_poll.py --json --classify     → Poll + classify transcripts
M2-B: waiting_updater.py --source fireflies   → Auto-populate waiting model
M2-C: ledger.py ingest --source meeting       → Detect decisions from action items
M2-D: reply_tracker.py --update --days 3      → VIP reply tracking (EE-002)
M2-E: fireflies_poll.py --save-metadata       → Store action items for EE-003
```

### Heartbeat (Chief only)
- **Frequency:** Every 2h, 08:00-22:00 SGT, MiniMax M2.5
- **5 checks per cycle:**
  1. Pre-meeting context assembly (2h lookahead)
  2. Deadline escalation (≤3d → interrupt, ≤1w → store)
  3. System health (silent unless critical)
  4. Learning signal processing (deterministic weight update)
  5. Interrupt budget reset (after midnight SGT)

---

## 6. MEMORY FILES (8 JSON state files)

All in `~/.openclaw/workspace-chief/memory/`:

### 6.1 strategic_state.json
**Purpose:** Strategic lens for all signal evaluation
- Quarterly objectives with key results, due dates, status
- Work stream health: `on_track | at_risk | behind | stalled`
- `weeksSinceLastActivity` per work stream (attention drift detection)
- Commitment tracker: decision → commitment → evidence → fulfilled/broken
- Attention allocation: planned vs actual per work stream per week

### 6.2 waiting_model.json
**Purpose:** Two living lists tracking what's blocked
- **waitingOnOthers:** Items delegated or dependent on external parties
- **waitingOnMe:** Items Ethan needs to action
- Each entry: `item, person, organization, sinceDate, source, sourceRef, blockerType, relatedObjective, status, lastContactDate, followUpDates[]`
- **Blocker taxonomy:** external (→ follow-up), dependency (→ unblock upstream), delegated (→ check in), capacity (→ re-evaluate), deprioritized (→ skip unless >15d)

### 6.3 decision_ledger.json
**Purpose:** Full decision lifecycle engine
- **Lifecycle:** DETECTED → PENDING → PROPOSED → DECIDED → COMMITTED → CLOSED
- **Fields per decision:** title, workStream, source, sourceRef, confidence, reversibility, deferralCost, authorityLevel, deadline, options[], recommendation, impactAssessment
- **Drift signals:** 5 rules auto-evaluated:
  1. `REPEATED_DEFERRAL` — deferred ≥2 times
  2. `STALE_PENDING` — pending >7 days
  3. `FOLLOWUP_INERTIA` — follow-up generated but not presented >48h
  4. `AUTHORITY_DEADLINE_RISK` — external authority + deadline <7d
  5. `DEPENDENCY_BLOCKAGE` — blocks other work >24h
- **Follow-ups:** Auto-generated from resolved decisions with confidence scoring, acceptance rate tracking, per-type analysis
- **Priority computation:** P1-P8 at render time from deadline proximity + costOfDeferral + authorityLevel

### 6.4 follow_ups.json
**Purpose:** Action items generated from decision resolution
- **Status flow:** generated → accepted/rejected/edited → completed
- **Thresholds:** min 0.6 confidence to present; max 5 per decision; max 8/day
- **Expiry:** Auto-clear after 14 days

### 6.5 interrupt_log.json
**Purpose:** Rate limiting and dedup for Telegram interrupts
- **Schema (v2):** `today: { date, interruptsSent, lastInterruptAt, itemsSent[] }`
- `itemsSent[]` entries: `{ type, ref, summary, sentAt, source }`
- **Rules:** Max 3/day, 30min cooldown, P0/P1 bypass budget

### 6.6 brief_log.json
**Purpose:** Track what was already communicated to prevent repetition
- `todaysBrief: { morningBrief: { sentAt, itemsCovered[] }, eveningBrief: { sentAt, itemsCovered[] } }`
- `recentBriefs[]` — last 7 days (rotated weekly)
- `decisionsPresented[]` — decision IDs shown in digest

### 6.7 vip_registry.json
**Purpose:** VIP sender classification for interrupt scoring
- **Tier 1 (+50 score):** NRP leadership — `matchPatterns: ["nrp.sg"]`
- **Tier 2 (+20):** ASTM, Enterprise SG, A*STAR, NTU, NUS — domain patterns
- `dynamicElevations[]` — from contact intelligence momentum analysis

### 6.8 email_processed.json
**Purpose:** Dedup — processed email thread IDs
- `processedThreads[]`: `{ id, subject, realSender, processedAt, workStream, urgency, actionRequired, action, score, tier }`
- Prevents re-scanning same email threads

### 6.9 last_processed_fireflies.json
**Purpose:** Dedup — processed Fireflies transcript IDs + metadata
- `processedIds[]` — transcript IDs already processed
- `lastChecked` — timestamp of last poll
- `transcriptMetadata{}` — per-transcript action items, waitingModelIds (added Mark 6)

### 6.10 vip_reply_tracking.json
**Purpose:** Track whether Ethan replied to VIP interrupt emails (EE-002)
- `trackedInterrupts[]`: `{ threadId, subject, senderEmail, senderName, interruptedAt, score, vipTier, status, replyDetectedAt, matchMethod }`
- **Status:** `unreplied | replied | expired | calendar_addressed`
- **Match methods:** `recipient_and_subject | recipient_match | subject_match`

---

## 7. SCRIPTS INVENTORY (13 Python scripts)

### 7.1 Commander Pipeline (`skills/commander-pipeline/scripts/`)

| Script | Purpose | CLI |
|--------|---------|-----|
| `inverse_query.py` | Detect absence signals — what didn't happen that should have. Hardcoded checks (stale blockers, dormant work streams, VIP silence) + expected-event pattern evaluator (7 rules). | `--check daily\|weekly`, `--test` |
| `reply_tracker.py` | Poll sent emails via `gog`, match against VIP interrupts to detect replies. Writes `vip_reply_tracking.json`. | `--update [--days N]`, `--status`, `--test` |
| `waiting_updater.py` | Auto-populate waiting model from Fireflies/email signals. | `--source fireflies\|email --candidates '<JSON>'`, `--list`, `--resolve <id>`, `--test` |
| `brief_validator.py` | Post-LLM gate — validates brief includes all INTERRUPT emails and absence signals. | `--brief '<text>' --scored '<JSON>' --signals '<JSON>'`, `--test` |

### 7.2 Decision Ledger (`skills/decision-ledger/scripts/`)

| Script | Purpose | CLI |
|--------|---------|-----|
| `ledger.py` | Full decision engine — CRUD, digest, drift, follow-ups, audit. Zero-LLM for digest/drift/ack. LLM only for `/why`. | `create\|update\|resolve\|commit\|defer\|cancel\|close\|query\|ingest\|audit\|digest\|drift\|why\|ack`, `generate-followups\|followup-respond\|followup-complete\|followup-query\|followup-summary\|followup-expire\|followup-calibrate` |
| `digest_fmt.py` | Convert ledger digest JSON to Telegram Markdown V2. | Stdin pipe: `ledger.py digest --format json \| digest_fmt.py` |

### 7.3 Service Scripts

| Script | Location | Purpose | CLI |
|--------|----------|---------|-----|
| `fireflies_poll.py` | `skills/fireflies/scripts/` | Poll Fireflies GraphQL API, dedup, classify, save metadata | `--json [--hours N] [--classify]`, `--mark-processed ID...`, `--save-metadata ID --metadata '<JSON>'`, `--test` |
| `email_scorer.py` | `skills/gog/scripts/` | Deterministic email priority scoring (4 tiers) | `--emails '<JSON>'` or stdin |
| `healthcheck.py` | `skills/system-check/scripts/` | Gateway/channel/service diagnostics | `--json`, `--text` |
| `extract_cost.py` | `skills/openclaw-cost-guard/scripts/` | Token/cost from session JSONL, budget enforcement | `--today\|--last-days N\|--top-sessions N`, `--brief`, `--budget-usd N` |
| `learning.py` | `skills/learning-signals/scripts/` | Behavioral learning: signals, weights, decay, metrics | `record\|compute\|update-weights\|decay\|evict\|metrics\|status\|why\|report` |
| `msg_split.py` | `skills/telegram-styling-guide/scripts/` | Split long messages at paragraph boundaries (4096 char Telegram limit) | Stdin, `--max-chars N`, `--test` |
| `contacts.py` | `skills/contact-intelligence/scripts/` | Contact profiling, trending, momentum, absence detection | `build-profiles\|trending\|elevate\|absence\|momentum\|full` |

---

## 8. EXPECTED-EVENT PATTERN ENGINE

**Config:** `memory/expected_events.json` (7 declarative rules)
**Evaluator:** `inverse_query.py` → `evaluate_expected_events()`
**Dispatch:** `_EVALUATORS` dict maps `check` name → Python evaluator function

| Rule | Name | Trigger | Expected Event | Window | Severity |
|------|------|---------|---------------|--------|----------|
| EE-001 | decision_followup_after_resolve | Decision DECIDED | Follow-up or commitment created | 48h | high |
| EE-002 | vip_reply_after_interrupt | VIP INTERRUPT email (score ≥40) | Reply sent or calendar event | 24h | high |
| EE-003 | meeting_actions_after_transcript | Fireflies action items ≥1 | Action items addressed | 72h | medium |
| EE-004 | commitment_progress_check | Decision COMMITTED | Progress evidence | 7d | medium |
| EE-005 | deadline_prep_window | Key result due within 14d | Preparation activity | 14d | high |
| EE-006 | blocker_escalation_cadence | Active blocker >5d | Follow-up attempt | 5d | medium |
| EE-007 | weekly_strategic_health_update | Health not assessed in 7d | Reassessment | 7d | low |

**Data flow:**
- `reply_tracker.py --update` → writes `vip_reply_tracking.json` → EE-002 evaluator reads it
- `fireflies_poll.py --save-metadata` → writes `transcriptMetadata` in `last_processed_fireflies.json` → EE-003 evaluator reads it
- Both evaluators are pure Python reading JSON — no CLI calls at evaluation time

**Self-tests:** 23 total (17 from Mark 5 + 6 from Mark 6)

---

## 9. INTERRUPTION SCORING

Deterministic scoring applied to all incoming signals:

### Score Components
| Signal | Points |
|--------|--------|
| VIP Tier 1 sender | +50 |
| VIP Tier 2 sender | +20 |
| Deadline ≤3 days | +30 |
| Deadline ≤1 week | +15 |
| Contains "urgent"/"asap" | +15 |
| Action required by Ethan | +10 |
| Advances quarterly objective | +25 |
| Threatens quarterly objective | +35 |
| Unblocks cascading work | +20 |
| Broken commitment detected | +30 |
| Urgent but strategically neutral | -10 |

### Tier Classification
| Score | Tier | Action |
|-------|------|--------|
| ≥40 | INTERRUPT | Send via Telegram immediately (subject to budget/cooldown) |
| 10-39 | DIGEST | Include in next morning brief |
| <10 | SILENT | Store in memory only |

### Pipeline Guards
- Max 3 interrupts/day (P0/P1 bypass)
- 30min cooldown between interrupts
- Dedup against `brief_log.json` and `interrupt_log.json`
- Readiness gate: context must be complete before surfacing

---

## 10. PRIORITY MATRIX

Used for decision arbitration and brief ordering:

| Priority | Label | Example |
|----------|-------|---------|
| P0 | System Critical | Gateway down, auth failure |
| P1 | Overdue Deadline | Past-due deliverable |
| P2 | Imminent Deadline | Due within 3 days |
| P3 | VIP + Urgent | VIP sender with time pressure |
| P4 | Active Blocker | Waiting >5 days, cascading |
| P5 | VIP + Normal | VIP sender, routine matter |
| P6 | Approaching Deadline | Due within 1-2 weeks |
| P7 | Routine | Standard work items |
| P8 | FYI | Information only |

**Tiebreakers:** Ethan's explicit request > deadline proximity > dependency impact > work stream priority > attention cost

---

## 11. SKILLS CATALOG (17 total)

| # | Skill | Purpose | Has Scripts? |
|---|-------|---------|-------------|
| 1 | Commander Pipeline | 5-function pipeline procedures, blocker detection, anticipation engine | Yes (4) |
| 2 | Decision Ledger | Decision lifecycle engine, drift detection, follow-ups | Yes (2) |
| 3 | Stewardship | Governance framework, priority matrix, interrupt pipeline rules | No |
| 4 | gog | Google Workspace CLI (Gmail, Calendar, Drive, Contacts) | Yes (1) |
| 5 | gog-calendar | Cross-calendar agenda queries, keyword search | No |
| 6 | Fireflies | Meeting transcript polling and processing | Yes (1) |
| 7 | Briefing | Daily briefing structure (calendar + Trello + weather) | No |
| 8 | Trello | Board/list/card management via REST API | No |
| 9 | Contact Intelligence | Contact profiling, trending, momentum, absence detection | Yes (1) |
| 10 | System Check | Gateway/channel/service diagnostics | Yes (1) |
| 11 | OpenClaw Cost Guard | Token/cost tracking, budget enforcement | Yes (1) |
| 12 | Learning Signals | Behavioral learning engine (EMA weights, decay, metrics) | Yes (1) |
| 13 | Telegram Styler | Telegram Markdown V2 formatting rules | Yes (1) |
| 14 | WhatsApp Styler | WhatsApp formatting rules (disabled) | No |
| 15 | Memory Tools | File-based persistent memory v2 (markdown + YAML frontmatter) | No |
| 16 | RAG Search | Semantic search via ChromaDB (Gmail, memories, Fireflies) | No |
| 17 | Task Decomposer | Complex request decomposition, skill gap analysis | No |

---

## 12. MARK UPGRADE HISTORY

| Mark | Date | Scope |
|------|------|-------|
| Mark 1 | 2026-02-27 | Base system: 6 agents, Telegram, crons, SOUL.md, memory files |
| Mark 2 | 2026-02-27 | Commander pipeline: waiting_updater, email_scorer, brief_validator, inverse_query (hardcoded checks) |
| Mark 3 | 2026-03-05 | Learning signals engine: behavioral learning, EMA weights, decay/evict |
| Mark 4 | 2026-03-06 | Contact intelligence: profiling, trending, momentum, dynamic VIP elevation |
| Mark 5 | 2026-03-07 | Cost of Delay formula in decision digest + expected-event pattern engine (7 rules, 5 evaluators, 17 tests) |
| Mark 6 | 2026-03-07 | Wire up EE-002 (VIP reply tracking) + EE-003 (meeting action items). reply_tracker.py, fireflies --save-metadata, 2 new evaluators, 23 tests total |
| **Mark 7** | **2026-03-07** | **This document — full system architecture handover** |

---

## 13. DEPLOYMENT & OPERATIONS

### File Sync Protocol
```bash
# Mac → VPS deployment
scp <file> root@89.167.121.237:/root/.openclaw/workspace-chief/<path>

# VPS test
ssh root@89.167.121.237 'python3 /root/.openclaw/workspace-chief/skills/<script> --test'

# Gateway restart (after config changes)
ssh root@89.167.121.237 'systemctl restart openclaw-gateway'
```

### Testing Checklist
```bash
# Self-tests (run on both local and VPS)
python3 ~/.openclaw/workspace-chief/skills/commander-pipeline/scripts/inverse_query.py --test    # 23 tests
python3 ~/.openclaw/workspace-chief/skills/commander-pipeline/scripts/reply_tracker.py --test    # 8 tests
python3 ~/.openclaw/workspace-chief/skills/commander-pipeline/scripts/waiting_updater.py --test  # tests
python3 ~/.openclaw/workspace-chief/skills/commander-pipeline/scripts/brief_validator.py --test  # tests
python3 ~/.openclaw/workspace-chief/skills/decision-ledger/scripts/ledger.py digest --format json # smoke test

# Live checks
python3 ~/.openclaw/workspace-chief/skills/commander-pipeline/scripts/inverse_query.py --check daily
python3 ~/.openclaw/workspace-chief/skills/commander-pipeline/scripts/inverse_query.py --check weekly
python3 ~/.openclaw/workspace-chief/skills/commander-pipeline/scripts/reply_tracker.py --status

# System health
python3 ~/.openclaw/workspace-chief/skills/system-check/scripts/healthcheck.py --json
```

### Critical Files (never modify without Forge)
- `~/.openclaw/openclaw.json` — gateway config (invalid keys crash gateway)
- `~/.openclaw/workspace-chief/SOUL.md` — agent identity (must stay <20K chars)
- `~/.openclaw/cron/jobs.json` — cron schedules (gateway mutates `state.nextRunAtMs` — use atomic Python read-modify-write, not Edit tool)

### Known Constraints
- `openclaw.json` keys: `subagents.allowAny` and `subagents.allow` are **INVALID** — use `subagents.allowAgents`
- `channels.{name}` does NOT support `enabled` key — use `plugins.entries.{name}.enabled`
- `jobs.json` editing: gateway actively modifies state between read/write — use Python `json.load/json.dump` via Bash
- gog OAuth on Mac may expire — VPS has fresh tokens via `GOG_KEYRING_PASSWORD` in gateway service
- MiniMax cannot handle complex multi-step cron prompts (>5min timeout) — use per-job Sonnet override

### Cost Management
- **Weekly budget:** $20
- **Pricing (per 1M tokens):** MiniMax $0.30/$1.20 | Sonnet $3/$15 | Opus $5/$25 | DeepSeek $0.28/$0.42
- **Strategy:** Chief on MiniMax for routing; Sonnet for heavy crons via per-job override; DeepSeek as ultimate fallback
- **Monitoring:** `extract_cost.py --last-days 7 --brief --budget-usd 20`

---

## 14. EXTENDING THE SYSTEM

### Adding a new Expected-Event Rule
1. Add rule to `memory/expected_events.json` with unique ID (EE-NNN)
2. Write evaluator function in `inverse_query.py`: `eval_<check_name>(rule, **data_sources) -> list[dict]`
3. Register in `_EVALUATORS` dict
4. Add data source loading in `evaluate_expected_events()` if needed
5. Add self-tests
6. Deploy to VPS, run `--test`

### Adding a new Script
1. Create in appropriate skill directory under `skills/<skill-name>/scripts/`
2. Include docstring with usage, `--test` flag for self-tests
3. Add `_load_openclaw_env()` if script needs env vars
4. Wire into cron prompt if it should run automatically
5. Deploy to VPS

### Adding a new Cron Job
1. Use `openclaw cron add` or atomic Python edit of `jobs.json`
2. Set model override if job requires complex reasoning (Sonnet 4.6)
3. Set appropriate timeout (300s default, 480-900s for complex jobs)
4. Follow Quiet Butler rules: SILENT if nothing actionable
5. Deploy `jobs.json` to VPS

### Adding a new Memory File
1. Create JSON file in `memory/` with `version` field
2. Document schema in this Mark 7 document
3. Add to `.gitignore` in workspace-chief repo (memory files contain personal data)
4. Ensure scripts handle `FileNotFoundError` gracefully

---

## 15. DOCUMENT MAINTENANCE

> **Convention (established Mark 7):** Every successive Mark upgrade will be recorded as an update to this document and pushed to:
> 1. **VPS:** `/root/.openclaw/workspace-chief/MARK-7-SYSTEM-ARCHITECTURE.md`
> 2. **GitHub:** `ethan-lab-openclaw/workspace-chief` repository
>
> This ensures any LLM or human can access the latest system state from a single canonical document on GitHub, without needing local file access.

---

*End of Mark 7 System Architecture Document*
