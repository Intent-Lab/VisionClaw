/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// CircleButton.swift
//
// Reusable circular button component used in streaming controls and UI actions.
//

import SwiftUI

struct CircleButton: View {
  let icon: String
  let text: String?
  /// VoiceOver name for the icon-only variant. Without it the button is read
  /// as its SF Symbol, so callers that pass `text: nil` must pass a label.
  var label: String? = nil
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      if let text {
        VStack(spacing: 2) {
          Image(systemName: icon)
            .font(.system(size: 14))
          Text(text)
            .font(.system(size: 10, weight: .medium))
        }
      } else {
        Image(systemName: icon)
          .font(.system(size: 16))
      }
    }
    .foregroundColor(.black)
    .frame(width: 56, height: 56)
    .background(.white)
    .clipShape(Circle())
    .a11yLabel(label ?? text)
  }
}
