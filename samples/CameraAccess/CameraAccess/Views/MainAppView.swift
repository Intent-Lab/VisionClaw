/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// MainAppView.swift
//
// Central navigation hub that displays different views based on DAT SDK registration and device states.
// When unregistered, shows the registration flow. When registered, shows the device selection screen
// for choosing which Meta wearable device to stream from.
//

import MWDATCore
import SwiftUI

struct MainAppView: View {
  let wearables: WearablesInterface
  @ObservedObject private var viewModel: WearablesViewModel
  @ObservedObject private var shortcutLaunchCoordinator: ShortcutLaunchCoordinator

  init(
    wearables: WearablesInterface,
    viewModel: WearablesViewModel,
    shortcutLaunchCoordinator: ShortcutLaunchCoordinator
  ) {
    self.wearables = wearables
    self.viewModel = viewModel
    self.shortcutLaunchCoordinator = shortcutLaunchCoordinator
  }

  var body: some View {
    Group {
      if viewModel.registrationState == .registered || viewModel.hasMockDevice || viewModel.skipToIPhoneMode {
        StreamSessionView(
          wearables: wearables,
          wearablesVM: viewModel,
          shortcutLaunchCoordinator: shortcutLaunchCoordinator
        )
      } else {
        // User not registered - show registration/onboarding flow
        HomeScreenView(viewModel: viewModel)
      }
    }
    .task(id: shortcutLaunchCoordinator.pendingRequest?.id) {
      guard let request = shortcutLaunchCoordinator.pendingRequest else { return }
      if case .startIPhoneStreaming = request.action {
        viewModel.skipToIPhoneMode = true
      }
    }
  }
}
