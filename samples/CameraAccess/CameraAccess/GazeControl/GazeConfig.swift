import Foundation
import UIKit

enum GazeConfig {
  // Cursor server (Mac companion)
  static var cursorServerHost: String { SettingsManager.shared.cursorServerHost }
  static var cursorServerPort: Int { SettingsManager.shared.cursorServerPort }

  static var cursorServerBaseURL: String {
    "\(cursorServerHost):\(cursorServerPort)"
  }

  static var isCursorServerConfigured: Bool {
    return cursorServerHost != "http://YOUR_MAC_HOSTNAME.local"
      && !cursorServerHost.isEmpty
  }

  // Frame processing
  static let gazeUpdateInterval: TimeInterval = 1.0 / 10.0  // 10 fps max (server-side matching)
  static let smoothingFactor: Double = 0.3  // Exponential moving average (lower = smoother)

  // JPEG quality for /locate frames (0.0-1.0, lower = smaller payload, faster upload)
  static let locateJpegQuality: CGFloat = 0.5
}
