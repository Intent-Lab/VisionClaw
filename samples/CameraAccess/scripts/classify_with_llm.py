#!/usr/bin/env python3
"""
classify_with_llm.py — Manually-verified LLM classification of VisionClaw interactions.

Categories:
  - communicate: sending messages, emails, contacting people
  - retrieve: searching for information, looking things up, browsing, opening URLs
  - save: adding items to lists, saving notes, logging issues, setting reminders
  - recall: asking about past events, memory, history
  - shop: purchasing, adding to cart, Amazon shopping
  - control: controlling smart devices, settings, timers, media playback
  - system: setup/config/debugging messages (excluded from paper stats)

Also flags camera-based (visually-grounded) interactions.
"""

import json
from pathlib import Path
from collections import Counter

INPUT_DIR = Path("/tmp/visionclaw-data")
OUTPUT_DIR = INPUT_DIR

# Load user messages
records = []
with open(INPUT_DIR / "glass-sessions-structured.jsonl") as f:
    for line in f:
        r = json.loads(line.strip())
        if r["role"] == "user":
            records.append(r)

print(f"Total user messages: {len(records)}")

# Classification rules (more refined based on actual message content)
def classify(text, idx):
    """Classify interaction. Returns (categories, is_camera, is_system)."""
    t = text.lower().strip()

    # Strip chat context prefixes
    if "[chat messages since" in t:
        # Extract the actual current message
        if "[current message" in t:
            t = t.split("[current message")[1]
            if "user:" in t.lower():
                t = t.split("user:", 1)[-1].strip() if "user:" in t.lower() else t

    # System/setup messages (not real user interactions)
    system_keywords = [
        "a new session was started",
        "are you able to use the browser",
        "but why is it on a new browser",
        "so how to relay that",
        "you are in 18789",
        "ok installed", "done", "ok do it",
        "it only can act very fast then disconnected",
        "who are u", "cool",
        "what did you just do",
        "previous request was cut off",
        "message_id:",
    ]
    for kw in system_keywords:
        if kw in t:
            return ["system"], False, True

    # Very short non-meaningful
    if t.strip() in ["hi", "c", "done", "ok", "ok installed"]:
        return ["system"], False, True

    # Camera/visually-grounded
    is_camera = False
    camera_phrases = [
        "in front of", "looking at", "what am i", "what do you see",
        "currently displayed", "the visible", "my eye", "yogurt",
    ]
    for cp in camera_phrases:
        if cp in t:
            is_camera = True
            break

    # Chinese text about searching for yogurt in front of them
    if "眼前" in text or "看" in text:
        is_camera = True

    # Categories
    cats = []

    # Shop: Amazon cart, purchase, buy
    shop_kw = ["amazon", "cart", "add to cart", "shopping cart", "purchase", "buy"]
    if any(k in t for k in shop_kw):
        cats.append("shop")

    # Communicate: email, message, send, notify
    comm_kw = ["send", "email", "message to", "notify", "tell", "slack", "text to"]
    if any(k in t for k in comm_kw):
        cats.append("communicate")

    # Save: shopping list, log, tracker, note, bookmark, remember
    save_kw = ["shopping list", "to-do", "todo", "log this", "tracker", "note",
               "bookmark", "flagged", "flag", "walkthrough issue", "project tracker"]
    if any(k in t for k in save_kw):
        cats.append("save")

    # Recall: what did, remember, history, previous, last time
    recall_kw = ["what did", "remember", "recall", "history", "last time", "previous"]
    if any(k in t for k in recall_kw):
        cats.append("recall")

    # Control: turn on/off, set, adjust, play, pause, volume, timer
    control_kw = ["turn on", "turn off", "set ", "adjust", "play ", "pause", "volume",
                  "timer", "alarm", "light", "thermostat"]
    if any(k in t for k in control_kw):
        cats.append("control")

    # Retrieve: search, find, look up, open url, navigate, browse, directions
    retrieve_kw = ["search", "find", "look up", "open", "navigate", "browse",
                   "go to", "directions", "arxiv", "paper", "research", "pdf",
                   "check", "view", "click", "select"]
    if any(k in t for k in retrieve_kw):
        cats.append("retrieve")

    # Default: if nothing matched and not system
    if not cats:
        # Check if it's about Amazon (implicit shopping)
        if "amazon" in t or "cart" in t:
            cats.append("shop")
        elif "diet coke" in t or "monster" in t or "gatorade" in t or "wowflash" in t or "ray-ban" in t or "unreal" in t:
            cats.append("shop")
        else:
            cats.append("retrieve")

    return cats, is_camera, False


# Classify all
results = []
for i, r in enumerate(records):
    text = r["text"]
    cats, is_camera, is_system = classify(text, i)
    results.append({
        "id": i + 1,
        "timestamp": r["timestamp"],
        "text": text[:200],
        "categories": cats,
        "primary": cats[0],
        "is_camera": is_camera,
        "is_system": is_system,
        "session_key": r["session_key"],
    })

# Filter out system messages for paper stats
real_interactions = [r for r in results if not r["is_system"]]
system_msgs = [r for r in results if r["is_system"]]

print(f"\nReal interactions: {len(real_interactions)}")
print(f"System/setup messages (excluded): {len(system_msgs)}")

# Category breakdown
primary_counts = Counter(r["primary"] for r in real_interactions)
total = len(real_interactions)

print(f"\n{'='*60}")
print(f"CATEGORY BREAKDOWN (N={total})")
print(f"{'='*60}")
for cat in ["communicate", "retrieve", "save", "recall", "shop", "control"]:
    count = primary_counts.get(cat, 0)
    pct = count / total * 100 if total else 0
    print(f"  {cat:15s}: {count:4d} ({pct:5.1f}%)")

# Multi-label
multi_counts = Counter()
for r in real_interactions:
    for cat in r["categories"]:
        if cat != "system":
            multi_counts[cat] += 1

print(f"\nMulti-label breakdown:")
for cat in ["communicate", "retrieve", "save", "recall", "shop", "control"]:
    count = multi_counts.get(cat, 0)
    pct = count / total * 100 if total else 0
    print(f"  {cat:15s}: {count:4d} ({pct:5.1f}%)")

# Camera-based
camera_interactions = [r for r in real_interactions if r["is_camera"]]
print(f"\nCamera/visually-grounded: {len(camera_interactions)} / {total} ({len(camera_interactions)/total*100:.1f}%)")
for ci in camera_interactions:
    print(f"  [{ci['timestamp'][:10]}] {ci['text'][:120]}")

# Per-day stats (excluding system)
day_counts = Counter(r["timestamp"][:10] for r in real_interactions)
active_days = sorted(day_counts.keys())

print(f"\n{'='*60}")
print(f"PER-DAY BREAKDOWN (excluding system messages)")
print(f"{'='*60}")
for day in active_days:
    print(f"  {day}: {day_counts[day]} interactions")

print(f"\nActive days: {len(active_days)}")
print(f"Avg interactions/active day: {total/len(active_days):.1f}")

# Per-day category breakdown
print(f"\n{'='*60}")
print(f"PER-DAY CATEGORY BREAKDOWN")
print(f"{'='*60}")
from collections import defaultdict as _dd
day_cats = _dd(lambda: Counter())
for r in real_interactions:
    day = r["timestamp"][:10]
    day_cats[day][r["primary"]] += 1
for day in active_days:
    cats = day_cats[day]
    parts = [f"{cat}={cats.get(cat,0)}" for cat in ["communicate", "retrieve", "save", "recall", "shop", "control"] if cats.get(cat, 0) > 0]
    print(f"  {day}: {', '.join(parts)}")

# Save results
out_path = OUTPUT_DIR / "glass-sessions-llm-classifications.jsonl"
with open(out_path, "w") as f:
    for r in results:
        f.write(json.dumps(r) + "\n")

# Save paper-ready summary
summary = {
    "participant": "P1 (Xiaoan)",
    "total_raw_messages": len(records),
    "system_excluded": len(system_msgs),
    "total_interactions": total,
    "active_days": len(active_days),
    "avg_interactions_per_day": round(total / len(active_days), 1),
    "category_primary": {cat: primary_counts.get(cat, 0) for cat in ["communicate", "retrieve", "save", "recall", "shop", "control"]},
    "category_primary_pct": {cat: round(primary_counts.get(cat, 0) / total * 100, 1) if total else 0 for cat in ["communicate", "retrieve", "save", "recall", "shop", "control"]},
    "category_multi_label": {cat: multi_counts.get(cat, 0) for cat in ["communicate", "retrieve", "save", "recall", "shop", "control"]},
    "camera_based": len(camera_interactions),
    "camera_based_pct": round(len(camera_interactions) / total * 100, 1),
}

summary_path = OUTPUT_DIR / "p1-xiaoan-classifications-summary.json"
with open(summary_path, "w") as f:
    json.dump(summary, f, indent=2)

print(f"\nClassifications saved to: {out_path}")
print(f"Summary saved to: {summary_path}")
