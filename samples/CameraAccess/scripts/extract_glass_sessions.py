#!/usr/bin/env python3
"""
extract_glass_sessions.py — Extract all VisionClaw glass session logs from OpenClaw.

Produces:
  1. glass-sessions-raw.jsonl         — All raw session data merged
  2. glass-sessions-structured.jsonl  — Clean structured messages (timestamp, role, text, tools, etc.)

Data source: ~/.openclaw/agents/main/sessions/sessions.json
"""

import json
import os
import sys
from pathlib import Path
from datetime import datetime

SESSIONS_DIR = Path.home() / ".openclaw" / "agents" / "main" / "sessions"
SESSIONS_JSON = SESSIONS_DIR / "sessions.json"
OUTPUT_DIR = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("/tmp/visionclaw-data")

OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

if not SESSIONS_JSON.exists():
    print(f"Error: {SESSIONS_JSON} not found", file=sys.stderr)
    sys.exit(1)

with open(SESSIONS_JSON) as f:
    store = json.load(f)

# Find all glass session keys
glass_sessions = {k: v for k, v in store.items() if "glass" in k.lower()}
print(f"Found {len(glass_sessions)} glass sessions")

# Resolve session files: try sessionFile first, then sessionId.jsonl
session_files = []
for key, entry in sorted(glass_sessions.items()):
    sf = entry.get("sessionFile")
    sid = entry.get("sessionId", "")

    if sf and Path(sf).exists():
        session_files.append((key, Path(sf)))
    elif sid:
        candidate = SESSIONS_DIR / f"{sid}.jsonl"
        if candidate.exists():
            session_files.append((key, candidate))

print(f"Found {len(session_files)} session files with data")

# --- Extract raw ---
raw_path = OUTPUT_DIR / "glass-sessions-raw.jsonl"
structured_path = OUTPUT_DIR / "glass-sessions-structured.jsonl"

raw_lines = 0
structured_records = []

with open(raw_path, "w") as raw_out:
    for session_key, fpath in session_files:
        with open(fpath) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                raw_out.write(line + "\n")
                raw_lines += 1

                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    continue

                if obj.get("type") != "message":
                    continue

                msg = obj.get("message", {})
                role = msg.get("role", "")
                timestamp = obj.get("timestamp", "")
                content = msg.get("content", [])

                # Extract text
                texts = []
                tool_calls = []
                tool_results = []
                has_thinking = False
                has_image = False

                for c in content:
                    ct = c.get("type", "")
                    if ct == "text":
                        texts.append(c.get("text", ""))
                    elif ct == "toolCall":
                        tool_calls.append({
                            "id": c.get("id", ""),
                            "name": c.get("name", ""),
                            "input_preview": json.dumps(c.get("input", {}))[:300]
                        })
                    elif ct == "toolResult":
                        result_text = ""
                        for rc in c.get("content", []):
                            if rc.get("type") == "text":
                                result_text = rc.get("text", "")[:500]
                        tool_results.append({
                            "id": c.get("id", ""),
                            "name": c.get("name", ""),
                            "result_preview": result_text
                        })
                    elif ct == "thinking":
                        has_thinking = True
                    elif ct == "image":
                        has_image = True

                # Check for image URLs in text
                full_text = "\n".join(texts)
                has_image_url = "tool_call_image_url" in full_text or "image" in full_text.lower()

                usage = msg.get("usage", {})

                record = {
                    "session_key": session_key,
                    "timestamp": timestamp,
                    "role": role,
                    "text": full_text,
                    "tool_calls": tool_calls if tool_calls else None,
                    "tool_results": tool_results if tool_results else None,
                    "has_thinking": has_thinking,
                    "has_image": has_image,
                    "has_image_ref": has_image_url,
                    "usage": {
                        "input_tokens": usage.get("inputTokens", 0),
                        "output_tokens": usage.get("outputTokens", 0),
                    } if usage else None
                }
                structured_records.append(record)

# Sort by timestamp
structured_records.sort(key=lambda r: r["timestamp"])

with open(structured_path, "w") as f:
    for r in structured_records:
        f.write(json.dumps(r) + "\n")

# --- Stats summary ---
user_msgs = [r for r in structured_records if r["role"] == "user"]
assistant_msgs = [r for r in structured_records if r["role"] == "assistant"]
tool_result_msgs = [r for r in structured_records if r["role"] == "toolResult"]

dates = set()
for r in structured_records:
    if r["timestamp"]:
        dates.add(r["timestamp"][:10])

first_ts = structured_records[0]["timestamp"] if structured_records else "?"
last_ts = structured_records[-1]["timestamp"] if structured_records else "?"

print(f"\n=== Extraction Complete ===")
print(f"Raw:        {raw_path} ({raw_lines} lines)")
print(f"Structured: {structured_path} ({len(structured_records)} records)")
print(f"Date range: {first_ts} -> {last_ts}")
print(f"Unique dates: {len(dates)}")
print(f"Messages: user={len(user_msgs)} assistant={len(assistant_msgs)} toolResult={len(tool_result_msgs)}")
print(f"Sessions: {len(session_files)}")

# Per-day breakdown
from collections import Counter
day_counts = Counter()
for r in user_msgs:
    if r["timestamp"]:
        day_counts[r["timestamp"][:10]] += 1

print(f"\nPer-day user message breakdown:")
for day, count in sorted(day_counts.items()):
    print(f"  {day}: {count} user messages")
