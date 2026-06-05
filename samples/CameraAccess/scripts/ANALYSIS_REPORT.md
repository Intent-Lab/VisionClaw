# VisionClaw Usage Analysis Report - P1 (Xiaoan)

Generated: 2026-03-26
Data source: `~/.openclaw/agents/main/sessions/sessions.json` (glass sessions)

## 1. Basic Statistics

| Metric | Value |
|--------|-------|
| Date range | 2026-02-06 to 2026-03-24 |
| Active days | 13 (14 raw, 1 excluded as system-only) |
| Total sessions | 79 |
| Total interactions | 133 (155 raw, 22 system/setup excluded) |
| Avg interactions/active day | 10.2 |
| Total tool calls (OpenClaw) | 500 |
| Avg tool calls/interaction | 3.2 |
| Avg session duration | 431s (7.2 min), median 32s |

### Per-day breakdown

| Date | Interactions |
|------|-------------|
| 2026-02-06 | 32 |
| 2026-02-10 | 13 |
| 2026-02-11 | 27 |
| 2026-02-12 | 1 |
| 2026-02-14 | 7 |
| 2026-02-15 | 6 |
| 2026-02-18 | 10 |
| 2026-03-03 | 5 |
| 2026-03-07 | 6 |
| 2026-03-09 | 1 |
| 2026-03-10 | 4 |
| 2026-03-12 | 3 |
| 2026-03-15 | 18 |

## 2. Category Breakdown (Primary)

| Category | Count | % |
|----------|-------|---|
| Shop | 87 | 65.4% |
| Retrieve | 20 | 15.0% |
| Communicate | 13 | 9.8% |
| Save | 13 | 9.8% |
| Recall | 0 | 0.0% |
| Control | 0 | 0.0% |

### Multi-label breakdown (interactions can belong to multiple categories)

| Category | Count | % |
|----------|-------|---|
| Shop | 87 | 65.4% |
| Retrieve | 73 | 54.9% |
| Save | 22 | 16.5% |
| Communicate | 13 | 9.8% |
| Recall | 0 | 0.0% |
| Control | 0 | 0.0% |

**Note:** Classification is keyword-based. Most shopping interactions also involve "retrieve" (searching Amazon). For the paper, Ryo may want to use LLM-based classification for more nuance - the input file `llm-classify-prompt.json` is ready for that.

## 3. Camera-based Usage

- Camera/visually-grounded interactions: **3 / 133 (2.3%)**
- Examples:
  - "Add the visible red Gatorade drink to the user's shopping cart"
  - "Add the item currently displayed on the Amazon tab to the user's Amazon cart"
  - Chinese: searching for yogurt "in front of me" on Amazon

**Important caveat:** These OpenClaw logs only capture the text commands delegated from Gemini. ALL glass sessions stream camera frames (~1fps) to Gemini continuously. The "camera-based" count here only reflects interactions where the user's voice command explicitly referenced what they were seeing. Actual visual grounding is much higher since Gemini has continuous visual context.

## 4. Tool Call Latency

### Browser vs Non-browser

| Metric | Browser (n=439) | Non-browser (n=60) |
|--------|-----------------|-------------------|
| Mean | 515 ms | 348 ms |
| Median | 144 ms | 37 ms |
| P25 | 53 ms | 19 ms |
| P75 | 237 ms | 721 ms |
| P95 | 2,564 ms | 1,811 ms |
| Max | 11,817 ms | 2,288 ms |

### Per-tool breakdown

| Tool | Count | Median (ms) | Mean (ms) |
|------|-------|-------------|-----------|
| browser | 439 | 144 | 515 |
| read | 17 | 19 | 29 |
| write | 11 | 25 | 25 |
| exec | 10 | 75 | 293 |
| memory_search | 8 | 1,202 | 1,252 |
| edit | 6 | 27 | 403 |
| web_search | 6 | 743 | 771 |
| nodes | 2 | 66 | 57 |

**Note:** These are OpenClaw-side tool execution latencies (from tool call initiation to result return). End-to-end latency from user speech to spoken response also includes: Gemini STT, Gemini thinking, iOS->Gemini round-trip, and Gemini TTS - not captured here.

## 5. Tool Usage Breakdown

| Tool | Count | % |
|------|-------|---|
| browser | 440 | 88.0% |
| read | 17 | 3.4% |
| write | 11 | 2.2% |
| exec | 10 | 2.0% |
| memory_search | 8 | 1.6% |
| edit | 6 | 1.2% |
| web_search | 6 | 1.2% |
| nodes | 2 | 0.4% |

## Scripts

- `extract_glass_sessions.py` - Extract raw + structured JSONL from OpenClaw session store
- `analyze_glass_sessions.py` - Compute all stats (basic, latency, categories, camera)
- `classify_with_llm.py` - Refined keyword classification with system message filtering

## Output files (in /tmp/visionclaw-data/)

- `glass-sessions-raw.jsonl` - All raw session data
- `glass-sessions-structured.jsonl` - Clean structured messages
- `glass-sessions-classifications.jsonl` - Per-interaction classifications
- `glass-sessions-llm-classifications.jsonl` - Refined classifications
- `glass-sessions-latencies.jsonl` - Per-tool-call latency data
- `p1-xiaoan-summary.json` - Paper-ready summary JSON
- `p1-xiaoan-classifications-summary.json` - Classification summary JSON
- `llm-classify-prompt.json` - Input for LLM-based classification
