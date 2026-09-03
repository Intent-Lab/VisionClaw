import Foundation
import UserNotifications

/// Study engagement nudges: local notifications that periodically remind the
/// participant to look around and find something to ask VisionClaw about. Local-only
/// (no server) -- scheduled on device, so they fire even when the app is closed
/// or the phone is locked. Tapping one opens the app (registered glasses go
/// straight to the call screen).
enum NudgeScheduler {
  // Daytime window and cadence: nudges fire on the hour, every `intervalHours`
  // hours, from `startHour` through `endHour`. Tune these for the study.
  private static let startHour = 10
  private static let endHour = 20
  private static let intervalHours = 2
  private static let idPrefix = "engagement-nudge-"

  // Rotating copy so a day's nudges don't all read the same; assigned to the
  // daytime slots in order.
  private static let messages = [
    "Look around. Anything you're curious about? Tap to ask VisionClaw.",
    "Notice something interesting nearby? Ask VisionClaw about it.",
    "Out and about? See if there's something worth asking VisionClaw.",
    "What's in front of you right now? VisionClaw can take a look.",
    "Wondering about something you can see? Tap to ask VisionClaw.",
    "Take a glance around. Is there anything VisionClaw could help with?",
  ]

  /// Ask for notification permission (once -- the system remembers the decision)
  /// and, if granted, (re)schedule the daytime nudges. Safe to call on every
  /// launch: re-requesting when already decided does not reprompt, and
  /// rescheduling with stable identifiers just refreshes the same slots.
  static func requestAuthorizationAndSchedule() {
    let center = UNUserNotificationCenter.current()
    center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
      guard granted else { return }
      schedule()
    }
  }

  private static func schedule() {
    let center = UNUserNotificationCenter.current()
    // Clear any previously scheduled nudges first, so a changed window or cadence
    // does not leave stale slots behind, then lay down the current schedule.
    center.getPendingNotificationRequests { pending in
      let stale = pending.map(\.identifier).filter { $0.hasPrefix(idPrefix) }
      center.removePendingNotificationRequests(withIdentifiers: stale)

      var slot = 0
      for hour in stride(from: startHour, through: endHour, by: intervalHours) {
        var when = DateComponents()
        when.hour = hour
        when.minute = 0
        let trigger = UNCalendarNotificationTrigger(dateMatching: when, repeats: true)

        let content = UNMutableNotificationContent()
        content.title = "VisionClaw"
        content.body = messages[slot % messages.count]
        content.sound = .default
        // Tag nudge-initiated opens so the study can tell them apart later.
        content.userInfo = ["source": "engagement-nudge"]

        let request = UNNotificationRequest(
          identifier: "\(idPrefix)\(hour)", content: content, trigger: trigger)
        center.add(request)
        slot += 1
      }
    }
  }
}
