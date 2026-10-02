# Changes from upstream VisionClaw — Jarvis fork

This fork replaces the **OpenClaw** integration with a typed HTTP client to a
self-hosted **Jarvis Memory API** (`/Users/yskim/Desktop/develop/jarvis_project`).

## What changed

| File | Change |
|------|--------|
| `Secrets.kt.example` | Added `jarvisApiBase`, `jarvisApiKey`. Original OpenClaw fields kept (legacy, unused at runtime). |
| `settings/SettingsManager.kt` | Added `jarvisApiBase` / `jarvisApiKey` getters/setters. New `DEFAULT_SYSTEM_PROMPT` (Korean) instructing Gemini about the 8 Jarvis tools. |
| `gemini/GeminiConfig.kt` | Added `jarvisApiBase`, `jarvisApiKey`, `isJarvisConfigured` accessors. |
| `openclaw/OpenClawBridge.kt` | **Full replacement.** Class name unchanged (wiring-compatible). Now a typed HTTP client for Jarvis API with `dispatch(toolName, args)`. Legacy `delegateTask` kept as a fallback routed to `search_memory`. |
| `openclaw/ToolCallRouter.kt` | **Full replacement.** Routes by `call.name` to `bridge.dispatch(...)` instead of single `delegateTask(task)`. |
| `openclaw/ToolCallModels.kt` | **Full replacement.** Data classes kept identical. `ToolDeclarations.allDeclarationsJSON()` now returns **8 typed function declarations** instead of one `execute` tool. |

**Wiring untouched** in `GeminiSessionViewModel.kt` and `GeminiLiveService.kt` —
they still reference `OpenClawBridge`, `ToolCallRouter`, `ToolDeclarations` by
name, but internally those classes now talk to Jarvis.

## The 8 Gemini tools (1:1 with Jarvis API endpoints)

| Tool | HTTP |
|------|------|
| `save_person`           | `POST /people` |
| `search_people`         | `POST /people/search` |
| `save_meeting`          | `POST /meetings` |
| `search_meetings`       | `POST /meetings/search` |
| `save_memory`           | `POST /memory/save` |
| `search_memory`         | `POST /memory/search` |
| `save_need`             | `POST /needs` |
| `get_proposal_context`  | `GET  /people/{id}/context` |

## Run

1. Bring up Jarvis API:
   ```bash
   cd /Users/yskim/Desktop/develop/jarvis_project
   docker compose up -d
   .venv/bin/uvicorn app.main:app --host 0.0.0.0 --port 8000
   ```
   (Note `--host 0.0.0.0` so your phone on the same Wi-Fi can reach it.)

2. Find your Mac's Bonjour name:
   ```bash
   scutil --get LocalHostName
   # → e.g. yskim-mbp  →  use http://yskim-mbp.local:8000
   ```

3. In `samples/CameraAccessAndroid/app/src/main/java/.../cameraaccess/`:
   ```bash
   cp Secrets.kt.example Secrets.kt
   ```
   Edit `Secrets.kt`:
   ```kotlin
   const val geminiAPIKey = "AIza..."                        // from aistudio.google.com/apikey
   const val jarvisApiBase = "http://yskim-mbp.local:8000"  // your Mac
   const val jarvisApiKey  = "dev-secret-change-me"         // must match jarvis_project/.env
   ```

4. Open `samples/CameraAccessAndroid/` in Android Studio, Gradle Sync, Run.

## What still uses OpenClaw fields

Nothing at runtime — but the Settings UI screen and `SettingsManager` still
expose `openClawHost`/`openClawPort`/etc. so the existing Settings screen
keeps compiling. Safe to ignore or strip later.

## To-do (next milestones)

- [ ] Settings UI section for Jarvis (host / api key inputs) — replace OpenClaw
      section in `SettingsView`
- [ ] Rename `OpenClawBridge` → `JarvisBridge` and `openclaw/` → `jarvis/` once
      stable (one-time refactor)
- [ ] Wire **face recognition**: when phone-side ML Kit / TFLite identifies a
      face, attach `face_embedding` to subsequent tool calls, so
      `search_people` can use vector match instead of text
- [ ] **needs auto-extraction**: at meeting end, send transcript to Gemini
      Flash with a structured-output prompt, then call `save_need` for each
      extracted item
