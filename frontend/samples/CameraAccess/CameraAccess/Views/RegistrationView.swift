/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// RegistrationView.swift
//
// Background view that handles callbacks from the Meta AI mobile app during
// DAT SDK registration and permission flows. This invisible view processes deep links
// that complete the OAuth authorization process initiated by the DAT SDK.
//

import MWDATCore
import SwiftUI

struct RegistrationView: View {
  @ObservedObject var viewModel: WearablesViewModel

  var body: some View {
    EmptyView()
      // Handle callback URLs from the Meta mobile app
      // This is essential for completing DAT SDK registration and permission flows
      .onOpenURL { url in
        guard
          let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
          // Check if this URL is related to DAT SDK workflows (contains metaWearablesAction query param)
          components.queryItems?.contains(where: { $0.name == "metaWearablesAction" }) == true
        else {
          return // URL is not related to DAT SDK - ignore it
        }
        Task {
          do {
            // Pass the callback URL to the DAT SDK for processing
            // This handles registration completion and permission grant responses
            _ = try await Wearables.shared.handleUrl(url)
          } catch let error as RegistrationError {
            viewModel.showError(error.description)
          } catch {
            viewModel.showError("Unknown error: \(error.localizedDescription)")
          }
        }
      }
  }
}
