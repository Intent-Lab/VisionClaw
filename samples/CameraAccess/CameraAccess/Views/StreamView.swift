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
// and error handling. Extended with Gemini Live AI assistant integration.
//

import MWDATCore
import SwiftUI

struct StreamView: View {
  @ObservedObject var viewModel: StreamSessionViewModel
  @State private var showSettings = false

  var body: some View {
    ZStack {
      // Black background for letterboxing/pillarboxing
      Color.black
        .edgesIgnoringSafeArea(.all)

      // Settings access. In phone mode this view is the entire app, so
      // without a gear here Settings is unreachable.
      VStack {
        HStack {
          Spacer()
          Button { showSettings = true } label: {
            Image(systemName: "gearshape.fill")
              .font(.system(size: 18))
              .foregroundStyle(.white.opacity(0.85))
              .padding(10)
              .background(.black.opacity(0.35), in: Circle())
          }
          .padding(.trailing, 16)
        }
        Spacer()
      }
      .zIndex(2)
      .sheet(isPresented: $showSettings) { SettingsView() }

      // Video backdrop (glasses frames decoded by the DAT pipeline)
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

      // Bottom controls layer
      VStack {
        Spacer()
        ControlsView(viewModel: viewModel)
      }
      .padding(.all, 24)
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

// Extracted controls for clarity
struct ControlsView: View {
  @ObservedObject var viewModel: StreamSessionViewModel

  var body: some View {
    // Controls row
    HStack(spacing: 8) {
      // Glasses have a stop: they are a remote camera someone may be wearing.
      // The phone camera IS the app -- stopping it just strands the screen on
      // a spinner -- so phone mode has no stop; the AI button is the toggle
      // that means something, and closing the app releases the camera.
      if viewModel.streamingMode == .glasses {
        CustomButton(
          title: "Stop streaming",
          style: .destructive,
          isDisabled: false
        ) {
          Task {
            await viewModel.stopSession()
          }
        }
      }

      // Photo button (glasses mode only -- DAT SDK capture)
      if viewModel.streamingMode == .glasses {
        CircleButton(icon: "camera.fill", text: nil) {
          viewModel.capturePhoto()
        }
      }

    }
  }
}


