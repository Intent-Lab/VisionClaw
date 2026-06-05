#!/usr/bin/env python3
"""
analyze_glass_sessions.py — Analyze VisionClaw glass session logs for UIST paper.

Reads from structured JSONL (output of extract_glass_sessions.py).
Produces statistics needed for the paper:
  1. Basic stats: active days, sessions, interactions, avg/day
  2. Category breakdown: communicate, retrieve, save, recall, shop, control
  3. Camera-based usage extraction
  4. Tool call latency: browser vs non-browser
  5. Fine-grained stats

Usage: python3 analyze_glass_sessions.py [input-dir] [output-dir]
"""

import json
import sys
import os
import re
from pathlib import Path
from datetime import datetime, timedelta
from collections import Counter, defaultdict

INPUT_DIR = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("/tmp/visionclaw-data")
OUTPUT_DIR = Path(sys.argv[2]) if len(sys.argv) > 2 else INPUT_DIR

STRUCTURED_FILE = INPUT_DIR / "glass-sessions-structured.jsonl"

# ============================================================
# Load data
# ============================================================
records = []
with open(STRUCTURED_FILE) as f:
    for line in f:
        line = line.strip()
        if line:
            records.append(json.loads(line))

print(f"Loaded {len(records)} records from {STRUCTURED_FILE}")

# ============================================================
# 1. BASIC STATS
# ============================================================
print("\n" + "=" * 60)
print("1. BASIC STATISTICS")
print("=" * 60)

user_msgs = [r for r in records if r["role"] == "user"]
assistant_msgs = [r for r in records if r["role"] == "assistant"]
tool_results = [r for r in records if r["role"] == "toolResult"]

# Active days
active_days = sorted(set(r["timestamp"][:10] for r in user_msgs if r["timestamp"]))
date_range_start = active_days[0] if active_days else "?"
date_range_end = active_days[-1] if active_days else "?"

# Sessions = unique session_key values
session_keys = sorted(set(r["session_key"] for r in records))

# Interactions = user messages (each user turn = 1 interaction)
interactions = len(user_msgs)

# Avg uses per active day
avg_per_day = interactions / len(active_days) if active_days else 0

# Per-day breakdown
day_counts = Counter(r["timestamp"][:10] for r in user_msgs if r["timestamp"])

print(f"Date range:          {date_range_start} to {date_range_end}")
print(f"# Active days:       {len(active_days)}")
print(f"# Sessions:          {len(session_keys)}")
print(f"# Interactions:      {interactions} (user messages)")
print(f"# Assistant msgs:    {len(assistant_msgs)}")
print(f"# Tool calls:        {len(tool_results)}")
print(f"Avg interactions/day:{avg_per_day:.1f}")
print(f"\nPer-day breakdown:")
for day in active_days:
    print(f"  {day}: {day_counts[day]} interactions")

# ============================================================
# 2. CATEGORY CLASSIFICATION
# ============================================================
print("\n" + "=" * 60)
print("2. CATEGORY CLASSIFICATION")
print("=" * 60)

# Keyword-based classification for initial pass
# Categories: communicate, retrieve, save, recall, shop, control
CATEGORY_RULES = {
    "communicate": [
        r"\b(send|email|message|text|slack|whatsapp|telegram|call|reply|forward|dm)\b",
        r"\b(tell|notify|contact|reach out|write to)\b",
    ],
    "retrieve": [
        r"\b(search|find|look up|google|what is|who is|where is|how to|check)\b",
        r"\b(weather|news|price|stock|recipe|directions|info|information)\b",
        r"\b(browse|open|go to|navigate|visit)\b",
    ],
    "save": [
        r"\b(save|add to|note|bookmark|remember this|write down|log|record)\b",
        r"\b(shopping list|todo|reminder|calendar|schedule)\b",
        r"\b(add .* to cart|add .* to list)\b",
    ],
    "recall": [
        r"\b(what did|remind me|recall|memory|remember when|last time)\b",
        r"\b(history|previous|earlier|before)\b",
    ],
    "shop": [
        r"\b(buy|purchase|order|amazon|cart|checkout|shop|price|compare)\b",
        r"\b(add .* to .*cart)\b",
        r"\b(ebay|walmart|target|store)\b",
    ],
    "control": [
        r"\b(turn on|turn off|set|adjust|dim|bright|volume|play|pause|stop|skip)\b",
        r"\b(light|thermostat|smart home|device|bluetooth|wifi)\b",
        r"\b(timer|alarm|mute|unmute)\b",
    ],
}

def classify_interaction(text):
    """Classify a user message into categories. Can be multi-label."""
    text_lower = text.lower()
    categories = []
    for cat, patterns in CATEGORY_RULES.items():
        for pattern in patterns:
            if re.search(pattern, text_lower):
                categories.append(cat)
                break
    return categories if categories else ["retrieve"]  # default to retrieve

# Classify each user message
classifications = []
for msg in user_msgs:
    text = msg["text"]
    cats = classify_interaction(text)
    classifications.append({
        "timestamp": msg["timestamp"],
        "text": text,
        "categories": cats,
        "primary": cats[0],
        "session_key": msg["session_key"],
    })

# Category counts (primary category)
primary_counts = Counter(c["primary"] for c in classifications)
total = len(classifications)

# Also count multi-label
multi_counts = Counter()
for c in classifications:
    for cat in c["categories"]:
        multi_counts[cat] += 1

print(f"\nPrimary category breakdown (N={total}):")
for cat in ["communicate", "retrieve", "save", "recall", "shop", "control"]:
    count = primary_counts.get(cat, 0)
    pct = count / total * 100 if total else 0
    print(f"  {cat:15s}: {count:4d} ({pct:5.1f}%)")

print(f"\nMulti-label category breakdown (interactions can be in multiple):")
for cat in ["communicate", "retrieve", "save", "recall", "shop", "control"]:
    count = multi_counts.get(cat, 0)
    pct = count / total * 100 if total else 0
    print(f"  {cat:15s}: {count:4d} ({pct:5.1f}%)")

# Save detailed classifications for LLM refinement
classifications_path = OUTPUT_DIR / "glass-sessions-classifications.jsonl"
with open(classifications_path, "w") as f:
    for c in classifications:
        f.write(json.dumps(c) + "\n")
print(f"\nDetailed classifications saved to: {classifications_path}")
print("NOTE: These are keyword-based. Use the LLM prompt below for more accurate classification.")

# ============================================================
# 3. CAMERA-BASED USAGE
# ============================================================
print("\n" + "=" * 60)
print("3. CAMERA-BASED USAGE")
print("=" * 60)

# NOTE: Camera-based usage is hard to detect from OpenClaw logs alone.
# OpenClaw only sees the text commands delegated from Gemini.
# The camera frames flow Gemini Live (not through OpenClaw).
# We flag interactions where the user's request implies visual/camera context,
# but the real camera usage data would need to come from the iOS app logs
# or Gemini session transcripts.
#
# For the paper: ALL glass sessions involve camera (glasses are always streaming
# ~1fps to Gemini). The question is which interactions were *visually-grounded*
# (user asked about what they see) vs *voice-only* (user just spoke a command).

CAMERA_KEYWORDS = [
    r"\b(what am i looking at|what do you see|what is this|describe|read this|scan)\b",
    r"\b(looking at|in front of|see this|show me|camera|photo|picture|image|visual)\b",
    r"\b(label|sign|text on|package|barcode|qr code|screen|display)\b",
    r"\b(identify|recognize|detect|object|scene)\b",
    r"\b(read|translate|what does .* say)\b",
    r"tool_call_image_url",
]

camera_interactions = []
for msg in user_msgs:
    text_lower = msg["text"].lower()
    is_camera = msg.get("has_image", False) or msg.get("has_image_ref", False)
    if not is_camera:
        for pattern in CAMERA_KEYWORDS:
            if re.search(pattern, text_lower):
                is_camera = True
                break
    if is_camera:
        camera_interactions.append(msg)

# Also check: any interaction that includes "image" in the tool input may indicate camera
# Check assistant responses that reference images
for r in records:
    if r["role"] == "assistant" and r.get("tool_calls"):
        for tc in r["tool_calls"]:
            inp = tc.get("input_preview", "").lower()
            if "image" in inp or "photo" in inp or "camera" in inp:
                # Find the preceding user message in same session
                pass  # would need more complex tracking

print(f"Camera/visually-grounded interactions (keyword-detected): {len(camera_interactions)} / {len(user_msgs)} ({len(camera_interactions)/len(user_msgs)*100:.1f}%)")
print(f"NOTE: ALL glass sessions stream camera to Gemini. This counts only interactions")
print(f"      where the user's text request explicitly references visual context.")
print(f"      Actual camera usage is likely much higher (Gemini sees frames continuously).")
print(f"\nCamera-based interaction samples:")
for ci in camera_interactions[:10]:
    print(f"  [{ci['timestamp'][:19]}] {ci['text'][:100]}")

# ============================================================
# 4. TOOL CALL LATENCY
# ============================================================
print("\n" + "=" * 60)
print("4. TOOL CALL LATENCY")
print("=" * 60)

# Use positional matching: assistant with toolCall -> next toolResult in same session
# OpenClaw toolResult messages don't carry tool call IDs, so we match sequentially.

def parse_ts(ts_str):
    """Parse ISO timestamp to datetime."""
    if not ts_str:
        return None
    try:
        ts_str = ts_str.replace("Z", "+00:00")
        return datetime.fromisoformat(ts_str)
    except:
        return None

# Group records by session_key and compute latencies
latencies = []
by_session = defaultdict(list)
for r in records:
    by_session[r["session_key"]].append(r)

for session_key, session_records in by_session.items():
    # Walk through records sequentially, matching toolCall -> toolResult pairs
    i = 0
    while i < len(session_records):
        r = session_records[i]
        if r["role"] == "assistant" and r.get("tool_calls"):
            # This assistant message has tool calls
            for tc in r["tool_calls"]:
                tool_name = tc["name"]
                start_ts = r["timestamp"]
                # Find the next toolResult in sequence
                for j in range(i + 1, len(session_records)):
                    r2 = session_records[j]
                    if r2["role"] == "toolResult":
                        end_ts = r2["timestamp"]
                        start_dt = parse_ts(start_ts)
                        end_dt = parse_ts(end_ts)
                        if start_dt and end_dt:
                            latency_ms = (end_dt - start_dt).total_seconds() * 1000
                            if latency_ms >= 0:  # sanity check
                                latencies.append({
                                    "tool": tool_name,
                                    "latency_ms": latency_ms,
                                    "start": start_ts,
                                    "end": end_ts,
                                    "session_key": session_key,
                                    "is_browser": tool_name == "browser",
                                })
                        # Move past this toolResult for the next tool call
                        i = j
                        break
                    elif r2["role"] == "user":
                        # New user message before result - skip
                        break
        i += 1

# Compute stats
browser_latencies = [l["latency_ms"] for l in latencies if l["is_browser"]]
non_browser_latencies = [l["latency_ms"] for l in latencies if not l["is_browser"]]

def latency_stats(values, label):
    if not values:
        print(f"  {label}: no data")
        return
    values_sorted = sorted(values)
    n = len(values_sorted)
    mean = sum(values_sorted) / n
    median = values_sorted[n // 2]
    p25 = values_sorted[int(n * 0.25)]
    p75 = values_sorted[int(n * 0.75)]
    p95 = values_sorted[int(n * 0.95)]
    mn = values_sorted[0]
    mx = values_sorted[-1]
    print(f"  {label} (n={n}):")
    print(f"    Mean:   {mean:>8.0f} ms ({mean/1000:.1f}s)")
    print(f"    Median: {median:>8.0f} ms ({median/1000:.1f}s)")
    print(f"    P25:    {p25:>8.0f} ms")
    print(f"    P75:    {p75:>8.0f} ms")
    print(f"    P95:    {p95:>8.0f} ms")
    print(f"    Min:    {mn:>8.0f} ms")
    print(f"    Max:    {mx:>8.0f} ms")

print(f"Total tool calls with latency data: {len(latencies)}")
latency_stats(browser_latencies, "Browser tool calls")
latency_stats(non_browser_latencies, "Non-browser tool calls")

# Per-tool breakdown
tool_lat = defaultdict(list)
for l in latencies:
    tool_lat[l["tool"]].append(l["latency_ms"])

print(f"\nPer-tool latency:")
for tool, vals in sorted(tool_lat.items(), key=lambda x: -len(x[1])):
    latency_stats(vals, tool)

# ============================================================
# 5. FINE-GRAINED STATS
# ============================================================
print("\n" + "=" * 60)
print("5. FINE-GRAINED STATISTICS")
print("=" * 60)

# Tool usage breakdown
all_tool_calls = []
for r in records:
    if r["role"] == "assistant" and r.get("tool_calls"):
        for tc in r["tool_calls"]:
            all_tool_calls.append(tc)

tool_counts = Counter(tc["name"] for tc in all_tool_calls)
print(f"\nTool usage breakdown (N={len(all_tool_calls)}):")
for tool, count in tool_counts.most_common():
    pct = count / len(all_tool_calls) * 100
    print(f"  {tool:20s}: {count:4d} ({pct:5.1f}%)")

# Avg tool calls per interaction
sessions_with_tools = defaultdict(int)
for r in records:
    if r["role"] == "assistant" and r.get("tool_calls"):
        sessions_with_tools[r["session_key"]] += len(r["tool_calls"])

tool_calls_per_session = list(sessions_with_tools.values())
if tool_calls_per_session:
    avg_tools = sum(tool_calls_per_session) / len(tool_calls_per_session)
    print(f"\nAvg tool calls per session: {avg_tools:.1f}")

# Avg tool calls per user interaction
tools_per_interaction = len(all_tool_calls) / len(user_msgs) if user_msgs else 0
print(f"Avg tool calls per interaction: {tools_per_interaction:.1f}")

# Session duration stats
session_durations = []
for session_key, session_records in by_session.items():
    timestamps = [parse_ts(r["timestamp"]) for r in session_records if r["timestamp"]]
    timestamps = [t for t in timestamps if t]
    if len(timestamps) >= 2:
        duration = (max(timestamps) - min(timestamps)).total_seconds()
        session_durations.append(duration)

if session_durations:
    avg_dur = sum(session_durations) / len(session_durations)
    med_dur = sorted(session_durations)[len(session_durations) // 2]
    print(f"\nSession duration:")
    print(f"  Avg:    {avg_dur:.0f}s ({avg_dur/60:.1f}min)")
    print(f"  Median: {med_dur:.0f}s ({med_dur/60:.1f}min)")
    print(f"  Min:    {min(session_durations):.0f}s")
    print(f"  Max:    {max(session_durations):.0f}s ({max(session_durations)/60:.1f}min)")

# Token usage
total_input_tokens = 0
total_output_tokens = 0
for r in records:
    if r.get("usage"):
        total_input_tokens += r["usage"].get("input_tokens", 0)
        total_output_tokens += r["usage"].get("output_tokens", 0)

print(f"\nToken usage:")
print(f"  Total input tokens:  {total_input_tokens:>10,}")
print(f"  Total output tokens: {total_output_tokens:>10,}")
print(f"  Total tokens:        {total_input_tokens + total_output_tokens:>10,}")

# ============================================================
# 6. LLM CLASSIFICATION PROMPT
# ============================================================
print("\n" + "=" * 60)
print("6. LLM CLASSIFICATION PROMPT (for more accurate categorization)")
print("=" * 60)

# Generate a prompt that can be fed to Gemini/Claude for accurate classification
llm_input = []
for i, msg in enumerate(user_msgs):
    llm_input.append({"id": i, "text": msg["text"], "timestamp": msg["timestamp"]})

llm_prompt_path = OUTPUT_DIR / "llm-classify-prompt.json"
with open(llm_prompt_path, "w") as f:
    json.dump({
        "instructions": (
            "Classify each user interaction into one or more categories: "
            "communicate, retrieve, save, recall, shop, control. "
            "Definitions:\n"
            "- communicate: sending messages, emails, contacting people\n"
            "- retrieve: searching for information, looking things up, browsing\n"
            "- save: adding items to lists, saving notes, bookmarking, setting reminders\n"
            "- recall: asking about past events, memory, history\n"
            "- shop: purchasing, adding to cart, comparing prices\n"
            "- control: controlling smart devices, settings, timers, media playback\n"
            "Return a JSON array where each element has: id, categories (array of strings), primary (single string)."
        ),
        "interactions": llm_input
    }, f, indent=2)

print(f"LLM classification input saved to: {llm_prompt_path}")
print("Feed this to Gemini/Claude for accurate per-interaction categorization.")

# ============================================================
# 7. SUMMARY TABLE (paper-ready)
# ============================================================
print("\n" + "=" * 60)
print("7. PAPER-READY SUMMARY (P1 - Xiaoan)")
print("=" * 60)

summary = {
    "participant": "P1 (Xiaoan)",
    "date_range": f"{date_range_start} to {date_range_end}",
    "active_days": len(active_days),
    "total_sessions": len(session_keys),
    "total_interactions": interactions,
    "avg_interactions_per_active_day": round(avg_per_day, 1),
    "category_breakdown_primary": {cat: primary_counts.get(cat, 0) for cat in ["communicate", "retrieve", "save", "recall", "shop", "control"]},
    "category_breakdown_pct": {cat: round(primary_counts.get(cat, 0) / total * 100, 1) if total else 0 for cat in ["communicate", "retrieve", "save", "recall", "shop", "control"]},
    "camera_based_interactions": len(camera_interactions),
    "camera_based_pct": round(len(camera_interactions) / len(user_msgs) * 100, 1) if user_msgs else 0,
    "tool_calls_total": len(all_tool_calls),
    "tool_breakdown": dict(tool_counts),
    "latency_browser_median_ms": round(sorted(browser_latencies)[len(browser_latencies)//2]) if browser_latencies else None,
    "latency_browser_mean_ms": round(sum(browser_latencies)/len(browser_latencies)) if browser_latencies else None,
    "latency_non_browser_median_ms": round(sorted(non_browser_latencies)[len(non_browser_latencies)//2]) if non_browser_latencies else None,
    "latency_non_browser_mean_ms": round(sum(non_browser_latencies)/len(non_browser_latencies)) if non_browser_latencies else None,
    "avg_session_duration_sec": round(avg_dur) if session_durations else None,
}

summary_path = OUTPUT_DIR / "p1-xiaoan-summary.json"
with open(summary_path, "w") as f:
    json.dump(summary, f, indent=2)

print(json.dumps(summary, indent=2))
print(f"\nSummary saved to: {summary_path}")

# Save all latency data
latency_path = OUTPUT_DIR / "glass-sessions-latencies.jsonl"
with open(latency_path, "w") as f:
    for l in latencies:
        f.write(json.dumps(l) + "\n")
print(f"Latency data saved to: {latency_path}")
