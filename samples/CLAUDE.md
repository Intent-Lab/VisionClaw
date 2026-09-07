# CLAUDE.md

## iOS and Android stay in sync

This folder holds two clients of the same VisionClaw app:

- iOS: `CameraAccess/` (Swift / SwiftUI)
- Android: `CameraAccessAndroid/` (Kotlin / Jetpack Compose)

Rule: every behavioral or user-facing change to one client must be mirrored in
the other in the same change set. Do not ship a feature, fix, or UX tweak on one
side and leave the other behind. If a change is genuinely one-platform-only
(platform plumbing, an OS API with no counterpart), say so explicitly and note
why in the commit or the reply, rather than silently skipping it.

Platform idioms may differ (SF Symbols vs Material icons, AVAudioSession vs
Android audio, SwiftUI gestures vs Compose pointer input). The behavior and the
UX must match; the implementation follows each platform's conventions.

### Parallel file map

Same data flow on both sides: client -> LiveKit SFU -> agent worker + gateway.

| Concern | iOS (`CameraAccess/CameraAccess/`) | Android (`CameraAccessAndroid/app/src/main/.../cameraaccess/`) |
| --- | --- | --- |
| Capture source model (glasses/phone) | `Settings/SettingsManager.swift` | `settings/SettingsManager.kt` |
| Settings screen | `Settings/SettingsView.swift` | `ui/SettingsScreen.kt` |
| Call / home screen | `OpenClaw/LiveKitStreamView.swift` | `ui/LiveKitStreamScreen.kt` |
| Source-swap driver | `Views/StreamSessionView.swift` (`onChange`) | `ui/CameraAccessScaffold.kt` (`LaunchedEffect`) |
| LiveKit session | `OpenClaw/LiveKitSession.swift` | `livekit/LiveKitSessionViewModel.kt`, `livekit/GlassesVideoCapturer.kt` |
| Glasses (DAT) stream VM | `ViewModels/StreamSessionViewModel.swift` | `stream/StreamViewModel.kt`, `wearables/WearablesViewModel.kt` |
| Study engagement nudges | `OpenClaw/NudgeScheduler.swift` | not yet ported (Android has only the foreground-service notification) |

Keep this map current when files move or new parallel features land.
