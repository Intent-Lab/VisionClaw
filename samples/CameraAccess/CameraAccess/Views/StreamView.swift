/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// StreamView.swift
//
// Main UI for video streaming from Meta wearable devices using the DAT SDK.
// This view demonstrates the complete streaming API: video streaming with real-time display, photo capture,
// and error handling. Extended with Gemini Live AI assistant and WebRTC live streaming integration.
//

import MWDATCore
import SwiftUI

struct StreamView: View {
  @ObservedObject var viewModel: StreamSessionViewModel
  @ObservedObject var wearablesVM: WearablesViewModel

  var body: some View {
    ZStack {
      // Black background for letterboxing/pillarboxing
      Color.black
        .edgesIgnoringSafeArea(.all)

      // Single local feed only (pure SOP capture interface)
      if let videoFrame = viewModel.currentVideoFrame, viewModel.hasReceivedFirstFrame {
        GeometryReader { geometry in
          Image(uiImage: videoFrame)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .edgesIgnoringSafeArea(.all)
      } else {
        ProgressView()
          .scaleEffect(1.5)
          .foregroundColor(.white)
      }

      // SOP status + single action control
      VStack {
        if viewModel.isSopAuditRunning {
          Text(String(format: "%.1fs", viewModel.sopAuditSecondsRemaining))
            .font(.system(size: 56, weight: .bold, design: .rounded))
            .foregroundColor(.white)
            .padding(.top, 40)

          Text("Uploading at 2 FPS")
            .font(.system(size: 16, weight: .semibold))
            .foregroundColor(.white.opacity(0.9))
        }

        Spacer()

        if !viewModel.sopAuditStatusMessage.isEmpty {
          Text(viewModel.sopAuditStatusMessage)
            .font(.system(size: 16, weight: .semibold))
            .foregroundColor(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Color.black.opacity(0.55))
            .cornerRadius(12)
            .padding(.bottom, 12)
        }

        VStack(spacing: 10) {
          CustomButton(
            title: viewModel.isSopAuditRunning ? "AUDIT RUNNING..." : "INITIATE WALLET AUDIT",
            style: .primary,
            isDisabled: viewModel.isSopAuditRunning
          ) {
            viewModel.startSopAudit()
          }

          CustomButton(
            title: "TOGGLE AI COPILOT",
            style: .secondary,
            isDisabled: false
          ) {
            Task {
              await viewModel.toggleGeminiAssistant()
            }
          }
        }
      }
      .padding(.all, 24)
    }
    .overlay(alignment: .top) {
      GeminiAssistantOverlay(geminiVM: viewModel.geminiAssistant) {
        Task {
          await viewModel.toggleGeminiAssistant()
        }
      }
    }
    .onDisappear {
      Task {
        if viewModel.streamingStatus != .stopped {
          await viewModel.stopSession()
        }
      }
    }
    // Show captured photos from DAT SDK in a preview sheet
    .sheet(isPresented: $viewModel.showPhotoPreview) {
      if let photo = viewModel.capturedPhoto {
        PhotoPreviewView(
          photo: photo,
          onDismiss: {
            viewModel.dismissPhotoPreview()
          }
        )
      }
    }
  }
}
