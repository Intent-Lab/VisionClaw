/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// StatusText.swift
//
// Reusable UI component for displaying conditional status text throughout the CameraAccess app.
//

import SwiftUI

struct StatusText: View {
  let isActive: Bool
  let activeText: String
  let inactiveText: String
  let activeColor: Color
  let inactiveColor: Color

  init(
    isActive: Bool,
    activeText: String,
    inactiveText: String,
    activeColor: Color = .green,
    inactiveColor: Color = .secondary
  ) {
    self.isActive = isActive
    self.activeText = activeText
    self.inactiveText = inactiveText
    self.activeColor = activeColor
    self.inactiveColor = inactiveColor
  }

  var body: some View {
    Text(isActive ? activeText : inactiveText)
      .foregroundColor(isActive ? activeColor : inactiveColor)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}
