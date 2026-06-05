#!/usr/bin/env python3
"""
extract_voice_logs.py — Extract VisionClaw voice interaction logs.

These are the Gemini-side logs (voice transcripts, session lifecycle)
captured by RemoteLogger on iOS/Android, stored by the Node.js server.

Data source: ~/.openclaw/visionclaw-logs/visionclaw-YYYY-MM-DD.jsonl

This script complements extract_glass_sessions.py which extracts OpenClaw
tool-call logs. Together they give the full picture:
  - Voice logs: ALL interactions (voice:user, voice:ai, session lifecycle)
  - OpenClaw logs: Only tool-use interactions (browser, web_search, etc.)

Usage: python3 extract_voice_logs.py [output-dir]
"""

import json
import os
import sys
from pathlib import Path
from collections import Counter
from datetime import datetime

VOICE_LOGS_DIR = Path.home() / ".openclaw" / "visionclaw-logs"
OUTPUT_DIR = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("/tmp/visionclaw-data")
OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

if not VOICE_LOGS_DIR.exists():
    print(f"No voice logs found at {VOICE_LOGS_DIR}")
    print("Make sure the VisionClaw signaling server (node index.js) is running")
    print("and that RemoteLogger is enabled in the iOS/Android app.")
    sys.exit(1)

# Find all log files
log_files = sorted(VOICE_LOGS_DIR.glob("visionclaw-*.jsonl"))
print(f"Found {len(log_files)} daily log files in {VOICE_LOGS_DIR}")

# Parse all entries
all_entries = []
for f in log_files:
    date = f.stem.replace("visionclaw-", "")
    with open(f) as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
                entry["_date"] = date
                all_entries.append(entry)
            except json.JSONDecodeError:
                continue

print(f"Total log entries: {len(all_entries)}")

# Classify by event type
event_counts = Counter()
for e in all_entries:
    data = e.get("data", {})
    event = data.get("event", e.get("type", "unknown"))
    event_counts[event] += 1

print(f"\nEvent type breakdown:")
for event, count in event_counts.most_common():
    print(f"  {event:20s}: {count}")

# Extract voice interactions
voice_user = [e for e in all_entries if e.get("data", {}).get("event") == "voice:user"]
voice_ai = [e for e in all_entries if e.get("data", {}).get("event") == "voice:ai"]
tool_calls = [e for e in all_entries if e.get("data", {}).get("event") == "voice:tool_call"]
tool_results = [e for e in all_entries if e.get("data", {}).get("event") == "voice:tool_result"]
session_starts = [e for e in all_entries if e.get("data", {}).get("event") == "session:start"]
session_ends = [e for e in all_entries if e.get("data", {}).get("event") == "session:end"]

print(f"\nVoice interactions:")
print(f"  User utterances:  {len(voice_user)}")
print(f"  AI responses:     {len(voice_ai)}")
print(f"  Tool calls:       {len(tool_calls)}")
print(f"  Tool results:     {len(tool_results)}")
print(f"  Session starts:   {len(session_starts)}")
print(f"  Session ends:     {len(session_ends)}")

# Platform breakdown
ios_entries = [e for e in all_entries if e.get("session") == "ios-client"]
android_entries = [e for e in all_entries if e.get("session") == "android-client"]
print(f"\nPlatform breakdown:")
print(f"  iOS:     {len(ios_entries)}")
print(f"  Android: {len(android_entries)}")

# Per-day breakdown
day_counts = Counter(e["_date"] for e in voice_user)
active_days = sorted(day_counts.keys())
print(f"\nActive days: {len(active_days)}")
for day in active_days:
    print(f"  {day}: {day_counts[day]} user utterances")

# Save structured output
output_path = OUTPUT_DIR / "voice-logs-all.jsonl"
with open(output_path, "w") as f:
    for e in all_entries:
        f.write(json.dumps(e) + "\n")

# Save voice interactions only
voice_path = OUTPUT_DIR / "voice-interactions.jsonl"
with open(voice_path, "w") as f:
    for e in voice_user + voice_ai:
        f.write(json.dumps(e) + "\n")

print(f"\nOutput:")
print(f"  All logs:          {output_path}")
print(f"  Voice interactions: {voice_path}")

# Print sample user utterances
if voice_user:
    print(f"\nSample user utterances:")
    for e in voice_user[:10]:
        text = e.get("data", {}).get("text", "")[:100]
        ts = e.get("ts", "")[:19]
        platform = e.get("session", "?")
        print(f"  [{ts}] ({platform}) {text}")
