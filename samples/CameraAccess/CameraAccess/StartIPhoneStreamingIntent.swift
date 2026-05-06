import AppIntents

struct StartIPhoneStreamingIntent: AppIntent {
  static var title: LocalizedStringResource = "Start on iPhone"
  static var description = IntentDescription("Open VisionClaw and start iPhone streaming.")
  static var openAppWhenRun = true

  @Parameter(title: "Start AI Session", default: false)
  var startAISession: Bool

  init() {}

  init(startAISession: Bool) {
    self.startAISession = startAISession
  }

  @MainActor
  func enqueueRequest(using coordinator: ShortcutLaunchCoordinator) {
    coordinator.requestStartIPhoneStreaming(startAISession: startAISession)
  }

  func perform() async throws -> some IntentResult {
    await MainActor.run {
      enqueueRequest(using: .shared)
    }
    return .result()
  }
}

struct VisionClawAppShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: StartIPhoneStreamingIntent(),
      phrases: [
        "Start on iPhone in \(.applicationName)",
        "Start iPhone streaming in \(.applicationName)",
        "Open iPhone camera in \(.applicationName)"
      ],
      shortTitle: "Start on iPhone",
      systemImageName: "iphone"
    )
  }
}
