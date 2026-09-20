/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// Accessibility.swift
//
// Shared helpers for the app's accessibility layer.
//
// The call screen expresses session state as on-screen text ("Connecting",
// "Reconnecting to glasses", "Not connected") and as icon-only controls, none
// of which VoiceOver announces on its own when they change. `A11y.announce`
// posts the state changes assistive technology needs to hear; the label
// modifier names icon-only controls that would otherwise be read as their
// SF Symbol.
//

import Foundation
import SwiftUI
import UIKit

enum A11y {
  /// Announces a status change. Use `assertive` for states that should
  /// interrupt -- a dropped connection -- and leave it off for routine
  /// updates so they queue behind whatever VoiceOver is already speaking.
  static func announce(_ message: String, assertive: Bool = false) {
    guard !message.isEmpty else { return }
    if #available(iOS 17.0, *) {
      var announcement = AttributedString(message)
      announcement.accessibilitySpeechAnnouncementPriority = assertive ? .high : .default
      AccessibilityNotification.Announcement(announcement).post()
    } else {
      UIAccessibility.post(notification: .announcement, argument: message)
    }
  }
}

/// Applies an accessibility label only when one is supplied, so a component
/// that draws a visible `Text` keeps its implicit label while its icon-only
/// variant can still name itself.
struct OptionalAccessibilityLabel: ViewModifier {
  private let label: String?

  init(_ label: String?) {
    self.label = label
  }

  func body(content: Content) -> some View {
    if let label, !label.isEmpty {
      content.accessibilityLabel(Text(label))
    } else {
      content
    }
  }
}

extension View {
  func a11yLabel(_ label: String?) -> some View {
    modifier(OptionalAccessibilityLabel(label))
  }
}
