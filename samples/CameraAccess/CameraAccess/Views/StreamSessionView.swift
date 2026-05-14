/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// StreamSessionView.swift
//
//

import MWDATCore
import SwiftUI
import UIKit

struct StreamSessionView: View {
  let wearables: WearablesInterface
  @ObservedObject private var wearablesViewModel: WearablesViewModel
  @StateObject private var viewModel: StreamSessionViewModel
  @StateObject private var geminiVM = GeminiSessionViewModel()
  @StateObject private var webrtcVM = WebRTCSessionViewModel()
  @State private var hasAttemptedAutoStart = false

  init(wearables: WearablesInterface, wearablesVM: WearablesViewModel) {
    self.wearables = wearables
    self.wearablesViewModel = wearablesVM
    self._viewModel = StateObject(wrappedValue: StreamSessionViewModel(wearables: wearables))
  }

  var body: some View {
    ZStack {
      if viewModel.isStreaming {
        // Full-screen video view with streaming controls
        StreamView(viewModel: viewModel, wearablesVM: wearablesViewModel, geminiVM: geminiVM, webrtcVM: webrtcVM)
      } else {
        // Pre-streaming setup view with permissions and start button
        NonStreamView(viewModel: viewModel, wearablesVM: wearablesViewModel)
      }
    }
    .task {
      viewModel.geminiSessionVM = geminiVM
      viewModel.webrtcSessionVM = webrtcVM
      geminiVM.streamingMode = viewModel.streamingMode
    }
    .onChange(of: viewModel.streamingMode) { newMode in
      geminiVM.streamingMode = newMode
    }
    .onChange(of: viewModel.streamingStatus) { newStatus in
      guard newStatus == .streaming else { return }
      guard SettingsManager.shared.autoStartAssistantEnabled else { return }
      guard !geminiVM.isGeminiActive else { return }
      guard !webrtcVM.isActive else { return }
      Task {
        await geminiVM.startSession()
      }
    }
    .onChange(of: viewModel.hasActiveDevice) { hasDevice in
      guard hasDevice else { return }
      attemptAutoStartIfNeeded()
    }
    .onChange(of: wearablesViewModel.registrationState) { newState in
      guard newState == .registered else { return }
      attemptAutoStartIfNeeded()
    }
    .onAppear {
      UIApplication.shared.isIdleTimerDisabled = true
      attemptAutoStartIfNeeded()
    }
    .onDisappear {
      UIApplication.shared.isIdleTimerDisabled = false
    }
    .alert("Error", isPresented: $viewModel.showError) {
      Button("OK") {
        viewModel.dismissError()
      }
    } message: {
      Text(viewModel.errorMessage)
    }
  }

  private func attemptAutoStartIfNeeded() {
    guard SettingsManager.shared.autoStartAssistantEnabled else { return }
    guard !hasAttemptedAutoStart else { return }
    guard wearablesViewModel.registrationState == .registered || wearablesViewModel.hasMockDevice else { return }
    guard viewModel.hasActiveDevice else { return }
    guard !viewModel.isStreaming else { return }

    hasAttemptedAutoStart = true
    Task {
      await viewModel.handleStartStreaming()
    }
  }
}
