import AppIntents
import Combine

/// Starting and ending a call without looking at the screen: from Siri
/// ("Start VisionClaw"), from a Shortcut, or from the iPhone Action Button
/// (Settings > Action Button > Shortcut). For a blind user, finding the call
/// button on a black video screen is the hardest part of using the app.
///
/// A cold launch already joins the call on its own, so the start intent
/// matters most when the app is open but the call has ended or dropped.
/// Starting is idempotent: it never hangs up a live call, so pressing the
/// Action Button while a call is already up is harmless.

/// Hands intent requests to the view that owns the call. The intents run
/// inside the app process (openAppWhenRun), so an in-process signal is enough.
@MainActor
final class CallCommands {
  static let shared = CallCommands()
  let startRequests = PassthroughSubject<Void, Never>()
  let endRequests = PassthroughSubject<Void, Never>()
}

struct StartCallIntent: AppIntent {
  static let title: LocalizedStringResource = "Start Call"
  static let description = IntentDescription("Opens VisionClaw and starts talking to the assistant.")
  static let openAppWhenRun = true

  @MainActor
  func perform() async throws -> some IntentResult {
    CallCommands.shared.startRequests.send()
    return .result()
  }
}

struct EndCallIntent: AppIntent {
  static let title: LocalizedStringResource = "End Call"
  static let description = IntentDescription("Hangs up the current VisionClaw call.")
  static let openAppWhenRun = true

  @MainActor
  func perform() async throws -> some IntentResult {
    CallCommands.shared.endRequests.send()
    return .result()
  }
}

struct VisionClawShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: StartCallIntent(),
      phrases: [
        "Start \(.applicationName)",
        "Start a call with \(.applicationName)",
        "Talk to \(.applicationName)",
      ],
      shortTitle: "Start Call",
      systemImageName: "phone.fill"
    )
    AppShortcut(
      intent: EndCallIntent(),
      phrases: [
        "End \(.applicationName) call",
        "Hang up \(.applicationName)",
      ],
      shortTitle: "End Call",
      systemImageName: "phone.down.fill"
    )
  }
}
