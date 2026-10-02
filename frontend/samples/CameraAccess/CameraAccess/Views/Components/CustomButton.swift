/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// CustomButton.swift
//
// Reusable button component used throughout the CameraAccess app for consistent styling.
//

import SwiftUI

struct CustomButton: View {
  let title: String
  let style: ButtonStyle
  let isDisabled: Bool
  let action: () -> Void

  enum ButtonStyle {
    case primary, secondary, destructive

    var backgroundColor: Color {
      switch self {
      case .primary:
        return .appPrimary
      case .secondary:
        return Color(white: 0.25)
      case .destructive:
        return .destructiveBackground
      }
    }

    var foregroundColor: Color {
      switch self {
      case .primary, .secondary:
        return .white
      case .destructive:
        return .destructiveForeground
      }
    }
  }

  var body: some View {
    Button(action: action) {
      Text(title)
        .font(.system(size: 15, weight: .semibold))
        .foregroundColor(style.foregroundColor)
        .frame(maxWidth: .infinity)
        .frame(height: 56)
        .background(style.backgroundColor)
        .cornerRadius(30)
    }
    .disabled(isDisabled)
    .opacity(isDisabled ? 0.6 : 1.0)
  }
}
