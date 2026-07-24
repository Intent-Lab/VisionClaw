import Foundation

enum GlassesSessionShortcutDestination {
  static let scheme = "visionclaw"
  static let host = "glasses-session"

  static let url = URL(string: "\(scheme)://\(host)")!
}

enum GlassesSessionShortcutRequestStore {
  private static let pendingRequestKey =
    "visionclaw.pendingGlassesSessionShortcut"

  static func record(in defaults: UserDefaults = .standard) {
    defaults.set(true, forKey: pendingRequestKey)
  }

  static func consume(from defaults: UserDefaults = .standard) -> Bool {
    guard defaults.bool(forKey: pendingRequestKey) else { return false }
    defaults.removeObject(forKey: pendingRequestKey)
    return true
  }
}
