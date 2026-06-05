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
  @ObservedObject var geminiVM: GeminiSessionViewModel
  @ObservedObject var webrtcVM: WebRTCSessionViewModel
  @State private var selectedTab: StreamTab = .camera
  @State private var showGallery = false
  @State private var showCaptureToast = false

  enum StreamTab: String, CaseIterable {
    case camera = "Camera"
    case chat = "Chat"
  }

  var body: some View {
    ZStack {
      // Black background for letterboxing/pillarboxing
      Color.black
        .edgesIgnoringSafeArea(.all)

      TabView(selection: $selectedTab) {
        // --- Camera tab ---
        cameraContent
          .tag(StreamTab.camera)

        // --- Chat tab ---
        ChatTranscriptView(geminiVM: geminiVM)
          .padding(.top, 60)
          .padding(.bottom, 80)
          .tag(StreamTab.chat)
      }
      .tabViewStyle(.page(indexDisplayMode: .never))

      // Top bar
      VStack {
        HStack {
          if geminiVM.isGeminiActive {
            GeminiStatusBar(geminiVM: geminiVM)
          }
          Spacer()
          Button(action: { showGallery = true }) {
            Image(systemName: "photo.on.rectangle")
              .font(.system(size: 16, weight: .medium))
              .foregroundColor(.white)
              .padding(8)
              .background(Color.black.opacity(0.5))
              .clipShape(Circle())
          }
          Picker("", selection: $selectedTab) {
            ForEach(StreamTab.allCases, id: \.self) { tab in
              Text(tab.rawValue).tag(tab)
            }
          }
          .pickerStyle(.segmented)
          .frame(width: 140)
        }
        Spacer()
      }
      .padding(.horizontal, 24)
      .padding(.top, 24)

      // WebRTC status overlay (top)
      if webrtcVM.isActive && selectedTab == .camera {
        VStack {
          WebRTCStatusBar(webrtcVM: webrtcVM)
          Spacer()
        }
        .padding(.all, 24)
      }

      // Bottom controls layer
      VStack {
        Spacer()
        ControlsView(viewModel: viewModel, geminiVM: geminiVM, webrtcVM: webrtcVM)
      }
      .padding(.all, 24)
    }
    // Auto-switch to chat tab when Gemini starts if no video
    .onChange(of: geminiVM.isGeminiActive) { _, active in
      if active && !SettingsManager.shared.videoStreamingEnabled {
        selectedTab = .chat
      }
    }
    .onDisappear {
      Task {
        if viewModel.streamingStatus != .stopped {
          await viewModel.stopSession()
        }
        if geminiVM.isGeminiActive {
          geminiVM.stopSession()
        }
        if webrtcVM.isActive {
          webrtcVM.stopSession()
        }
      }
    }
    // Gallery sheet
    .sheet(isPresented: $showGallery) {
      NavigationStack {
        GalleryView()
      }
    }
    // Capture toast
    .overlay(alignment: .top) {
      if showCaptureToast {
        Text("Photo captured")
          .font(.subheadline.weight(.medium))
          .foregroundColor(.white)
          .padding(.horizontal, 16)
          .padding(.vertical, 8)
          .background(Color.black.opacity(0.7))
          .cornerRadius(20)
          .padding(.top, 80)
          .transition(.move(edge: .top).combined(with: .opacity))
      }
    }
    .onChange(of: geminiVM.lastCapturedPhoto?.id) { _, newId in
      guard newId != nil else { return }
      withAnimation { showCaptureToast = true }
      Task {
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        withAnimation { showCaptureToast = false }
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
    // Gemini error alert
    .alert("AI Assistant", isPresented: Binding(
      get: { geminiVM.errorMessage != nil },
      set: { if !$0 { geminiVM.errorMessage = nil } }
    )) {
      Button("OK") { geminiVM.errorMessage = nil }
    } message: {
      Text(geminiVM.errorMessage ?? "")
    }
    // WebRTC error alert
    .alert("Live Stream", isPresented: Binding(
      get: { webrtcVM.errorMessage != nil },
      set: { if !$0 { webrtcVM.errorMessage = nil } }
    )) {
      Button("OK") { webrtcVM.errorMessage = nil }
    } message: {
      Text(webrtcVM.errorMessage ?? "")
    }
  }

  @ViewBuilder
  private var cameraContent: some View {
    // Video backdrop: PiP when WebRTC connected, otherwise single local feed
    if webrtcVM.isActive && webrtcVM.connectionState == .connected {
      PiPVideoView(
        localFrame: viewModel.currentVideoFrame,
        remoteVideoTrack: webrtcVM.remoteVideoTrack,
        hasRemoteVideo: webrtcVM.hasRemoteVideo
      )
    } else if let videoFrame = viewModel.currentVideoFrame, viewModel.hasReceivedFirstFrame {
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

    // Gemini speaking/transcript overlay on camera
    if geminiVM.isGeminiActive {
      VStack {
        Spacer()
        VStack(spacing: 8) {
          if !geminiVM.userTranscript.isEmpty || !geminiVM.aiTranscript.isEmpty {
            TranscriptView(
              userText: geminiVM.userTranscript,
              aiText: geminiVM.aiTranscript
            )
          }
          ToolCallStatusView(status: geminiVM.toolCallStatus)
          if geminiVM.isModelSpeaking {
            HStack(spacing: 8) {
              Image(systemName: "speaker.wave.2.fill")
                .foregroundColor(.white)
                .font(.system(size: 14))
              SpeakingIndicator()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.5))
            .cornerRadius(20)
          }
        }
        .padding(.bottom, 80)
      }
      .padding(.horizontal, 24)
    }
  }
}

// Extracted controls for clarity
struct ControlsView: View {
  @ObservedObject var viewModel: StreamSessionViewModel
  @ObservedObject var geminiVM: GeminiSessionViewModel
  @ObservedObject var webrtcVM: WebRTCSessionViewModel

  var body: some View {
    // Controls row
    HStack(spacing: 8) {
      CustomButton(
        title: "Stop streaming",
        style: .destructive,
        isDisabled: false
      ) {
        Task {
          await viewModel.stopSession()
        }
      }

      // Photo button (glasses mode only -- DAT SDK capture)
      if viewModel.streamingMode == .glasses {
        CircleButton(icon: "camera.fill", text: nil) {
          viewModel.capturePhoto()
        }
      }

      // Gemini AI button (disabled when WebRTC is active — audio conflict)
      CircleButton(
        icon: geminiVM.isGeminiActive ? "waveform.circle.fill" : "waveform.circle",
        text: "AI"
      ) {
        Task {
          if geminiVM.isGeminiActive {
            geminiVM.stopSession()
          } else {
            await geminiVM.startSession()
          }
        }
      }
      .opacity(webrtcVM.isActive ? 0.4 : 1.0)
      .disabled(webrtcVM.isActive)

      // WebRTC Live Stream button (disabled when Gemini is active — audio conflict)
      CircleButton(
        icon: webrtcVM.isActive
          ? "antenna.radiowaves.left.and.right.circle.fill"
          : "antenna.radiowaves.left.and.right.circle",
        text: "Live"
      ) {
        Task {
          if webrtcVM.isActive {
            webrtcVM.stopSession()
          } else {
            await webrtcVM.startSession()
          }
        }
      }
      .opacity(geminiVM.isGeminiActive ? 0.4 : 1.0)
      .disabled(geminiVM.isGeminiActive)
    }
  }
}

