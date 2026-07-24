import AppIntents

struct OpenGlassesSessionIntent: AppIntent {
  static let title: LocalizedStringResource = "Open Glasses Session"
  static let description = IntentDescription(
    "Opens VisionClaw in the foreground so you can connect your glasses and start a session."
  )
  static let openAppWhenRun = true

  func perform() async throws -> some IntentResult {
    GlassesSessionShortcutRequestStore.record()
    return .result()
  }
}

struct VisionClawAppShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: OpenGlassesSessionIntent(),
      phrases: [
        "Open glasses session with \(.applicationName)",
        "Start glasses session in \(.applicationName)",
      ],
      shortTitle: "Open Glasses Session",
      systemImageName: "eyeglasses"
    )
  }
}
