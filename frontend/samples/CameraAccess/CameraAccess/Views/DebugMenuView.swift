/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// DebugMenuView.swift
//
// Debug-only overlay that provides access to mock device functionality during development.
// This view demonstrates how to integrate mock devices for testing DAT SDK features
// without requiring physical Meta wearable devices.
//

#if canImport(MWDATMockDevice)

import SwiftUI

struct DebugMenuView: View {
  @ObservedObject var debugMenuViewModel: DebugMenuViewModel

  var body: some View {
    HStack {
      Spacer()
      VStack {
        Spacer()
        Button(action: {
          debugMenuViewModel.showDebugMenu = true
        }) {
          Image(systemName: "ladybug.fill")
            .foregroundColor(.white)
            .padding()
            .background(.secondary)
            .clipShape(Circle())
            .shadow(radius: 4)
        }.accessibilityIdentifier("debug_menu_button")
        Spacer()
      }
      .padding(.trailing)
    }
  }
}

#endif
