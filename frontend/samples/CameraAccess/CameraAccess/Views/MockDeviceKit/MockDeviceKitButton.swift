/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// MockDeviceKitButton.swift
//
// Specialized button component for mock device controls in the debug interface.
//

#if canImport(MWDATMockDevice)

import SwiftUI

struct MockDeviceKitButton: View {
  enum Style {
    case primary
    case destructive

    var backgroundColor: Color {
      switch self {
      case .primary:
        return .appPrimary
      case .destructive:
        return .red
      }
    }

    var foregroundColor: Color {
      return .white
    }
  }

  let title: String
  let style: Style
  let expandsHorizontally: Bool
  let disabled: Bool
  let action: () -> Void

  init(_ title: String, style: Style = .primary, expandsHorizontally: Bool = true, disabled: Bool = false, action: @escaping () -> Void) {
    self.title = title
    self.style = style
    self.expandsHorizontally = expandsHorizontally
    self.disabled = disabled
    self.action = action
  }

  var body: some View {
    Button(title) {
      action()
    }
    .padding(.horizontal)
    .frame(maxWidth: expandsHorizontally ? .infinity : nil, minHeight: 44)
    .background(style.backgroundColor)
    .foregroundStyle(style.foregroundColor)
    .clipShape(RoundedRectangle(cornerRadius: 16))
    .opacity(disabled ? 0.6 : 1)
    .disabled(disabled)
  }
}

#endif
