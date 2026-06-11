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

  init(wearables: WearablesInterface, wearablesVM: WearablesViewModel) {
    self.wearables = wearables
    self.wearablesViewModel = wearablesVM
    self._viewModel = StateObject(wrappedValue: StreamSessionViewModel(wearables: wearables))
  }

  var body: some View {
    NavigationStack {
      HomeView(viewModel: viewModel, wearablesViewModel: wearablesViewModel)
        .background(DesignSystem.colors.adminBackground.ignoresSafeArea())
    }
    .overlay(alignment: .bottom) {
      if viewModel.showShipSuccessToast {
        Text("Execution recorded")
          .font(DesignSystem.fonts.mono(size: 13, weight: .semibold))
          .foregroundColor(DesignSystem.colors.white)
          .padding(.horizontal, 16)
          .padding(.vertical, 12)
          .background(DesignSystem.colors.deepGreen)
          .overlay(Rectangle().stroke(DesignSystem.colors.white, lineWidth: 1))
          .padding(.bottom, 20)
          .transition(.move(edge: .bottom).combined(with: .opacity))
      }
    }
    .animation(.easeInOut(duration: 0.2), value: viewModel.showShipSuccessToast)
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
}
