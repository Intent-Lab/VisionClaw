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

struct GlassesSessionHandoffPresentationState {
  private(set) var activeRequestID: UUID?

  var isPresented: Bool {
    activeRequestID != nil
  }

  mutating func present(requestID: UUID) {
    activeRequestID = requestID
  }

  @discardableResult
  mutating func dismiss(requestID: UUID) -> Bool {
    guard activeRequestID == requestID else { return false }
    activeRequestID = nil
    return true
  }
}

struct StreamSessionView: View {
  @EnvironmentObject private var brokerConnectionModel:
    GlassesBrokerConnectionModel
  let wearables: WearablesInterface
  @ObservedObject private var wearablesViewModel: WearablesViewModel
  @StateObject private var viewModel: StreamSessionViewModel
  @StateObject private var geminiVM = GeminiSessionViewModel()
  @StateObject private var webrtcVM = WebRTCSessionViewModel()
  @State private var shortcutHandoff =
    GlassesSessionHandoffPresentationState()
  @State private var shortcutDismissalTask: Task<Void, Never>?

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
      geminiVM.configureBrokerConnection(brokerConnectionModel)
      viewModel.geminiSessionVM = geminiVM
      viewModel.webrtcSessionVM = webrtcVM
      geminiVM.streamingMode = viewModel.streamingMode
      geminiVM.mediaCaptureHandler = { [weak viewModel] request in
        guard let viewModel else {
          return .failure("The glasses camera session ended. No media was captured.")
        }
        return await viewModel.handleMediaCaptureRequest(request)
      }
      if let requestID =
        brokerConnectionModel.glassesSessionLaunchRequestID {
        presentShortcutHandoff(requestID: requestID)
      }
    }
    .onChange(of: viewModel.streamingMode) { _, newMode in
      geminiVM.streamingMode = newMode
    }
    .onChange(
      of: brokerConnectionModel.glassesSessionLaunchRequestID
    ) { _, requestID in
      guard let requestID else { return }
      presentShortcutHandoff(requestID: requestID)
    }
    .onAppear {
      UIApplication.shared.isIdleTimerDisabled = true
    }
    .onDisappear {
      UIApplication.shared.isIdleTimerDisabled = false
      shortcutDismissalTask?.cancel()
      shortcutDismissalTask = nil
      geminiVM.mediaCaptureHandler = nil
    }
    .alert("Error", isPresented: $viewModel.showError) {
      Button("OK") {
        viewModel.dismissError()
      }
    } message: {
      Text(viewModel.errorMessage)
    }
    .overlay(alignment: .top) {
      if shortcutHandoff.isPresented {
        HStack(spacing: 10) {
          Image(systemName: "eyeglasses")
          VStack(alignment: .leading, spacing: 2) {
            Text("Glasses session")
              .font(.headline)
            Text(
              viewModel.isStreaming
                ? "Tap Session to talk."
                : "Start streaming, then tap Session to talk."
            )
            .font(.caption)
          }
          Spacer()
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Glasses session shortcut opened")
        .transition(.move(edge: .top).combined(with: .opacity))
      }
    }
  }

  private func presentShortcutHandoff(requestID: UUID) {
    guard brokerConnectionModel.consumeGlassesSessionLaunchRequest(
      requestID
    ) else {
      return
    }

    shortcutDismissalTask?.cancel()
    withAnimation {
      shortcutHandoff.present(requestID: requestID)
    }
    shortcutDismissalTask = Task { @MainActor in
      try? await Task.sleep(nanoseconds: 4_000_000_000)
      guard !Task.isCancelled else { return }
      withAnimation {
        _ = shortcutHandoff.dismiss(requestID: requestID)
      }
    }
  }
}
