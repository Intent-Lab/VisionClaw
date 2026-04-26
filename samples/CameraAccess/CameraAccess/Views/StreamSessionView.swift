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
  @ObservedObject private var shortcutLaunchCoordinator: ShortcutLaunchCoordinator
  @StateObject private var viewModel: StreamSessionViewModel
  @StateObject private var geminiVM = GeminiSessionViewModel()
  @StateObject private var webrtcVM = WebRTCSessionViewModel()

  init(
    wearables: WearablesInterface,
    wearablesVM: WearablesViewModel,
    shortcutLaunchCoordinator: ShortcutLaunchCoordinator
  ) {
    self.wearables = wearables
    self.wearablesViewModel = wearablesVM
    self.shortcutLaunchCoordinator = shortcutLaunchCoordinator
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
      await handlePendingShortcutRequestIfNeeded()
    }
    .onChange(of: viewModel.streamingMode) { _, newMode in
      geminiVM.streamingMode = newMode
    }
    .task(id: shortcutLaunchCoordinator.pendingRequest?.id) {
      await handlePendingShortcutRequestIfNeeded()
    }
    .onAppear {
      UIApplication.shared.isIdleTimerDisabled = true
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

  private func handlePendingShortcutRequestIfNeeded() async {
    guard let request = shortcutLaunchCoordinator.consumePendingRequest() else { return }

    wearablesViewModel.skipToIPhoneMode = true

    switch request.action {
    case .startIPhoneStreaming(let startAISession):
      if viewModel.streamingMode != .iPhone && geminiVM.isGeminiActive {
        geminiVM.stopSession()
      }

      if viewModel.streamingMode != .iPhone && viewModel.isStreaming {
        await viewModel.stopSession()
      }

      if !viewModel.isStreaming || viewModel.streamingMode != .iPhone {
        await viewModel.handleStartIPhone()
      }

      guard startAISession, viewModel.streamingMode == .iPhone, viewModel.isStreaming else { return }
      await geminiVM.startSession()
    }
  }
}
