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
        return DesignSystem.colors.vibrantTeal
      case .secondary:
        return DesignSystem.colors.surface
      case .destructive:
        return DesignSystem.colors.dangerRed
      }
    }

    var foregroundColor: Color {
      switch self {
      case .primary:
        return DesignSystem.colors.deepNavy
      case .secondary:
        return .white
      case .destructive:
        return .white
      }
    }

    var borderColor: Color {
      switch self {
      case .primary:
        return DesignSystem.colors.border
      case .secondary:
        return DesignSystem.colors.border
      case .destructive:
        return DesignSystem.colors.dangerRed
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
        .overlay(
          RoundedRectangle(cornerRadius: 30)
            .stroke(style.borderColor, lineWidth: 1)
        )
        .cornerRadius(30)
    }
    .disabled(isDisabled)
    .opacity(isDisabled ? 0.6 : 1.0)
  }
}
