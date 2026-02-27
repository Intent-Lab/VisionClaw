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

  private var audioOnlyIcon: String {
    switch geminiVM.sessionMode {
    case .meeting: return "note.text"
    case .golf:    return "flag.fill"
    case .normal:  return "headphones.circle.fill"
    }
  }
  private var audioOnlyIconColor: Color {
    switch geminiVM.sessionMode {
    case .meeting: return .orange.opacity(0.8)
    case .golf:    return .green.opacity(0.8)
    case .normal:  return .white.opacity(0.6)
    }
  }
  private var audioOnlyTitle: String {
    switch geminiVM.sessionMode {
    case .meeting: return "Meeting Mode"
    case .golf:    return "Golf Mode"
    case .normal:  return "Audio Only"
    }
  }
  private var audioOnlyTitleColor: Color {
    switch geminiVM.sessionMode {
    case .meeting: return .orange
    case .golf:    return .green
    case .normal:  return .white
    }
  }
  private var audioOnlySubtitle: String {
    switch geminiVM.sessionMode {
    case .meeting: return "Taking notes — AI will not respond to commands"
    case .golf:    return "Golf caddie active — tracking your round"
    case .normal:  return "No camera active — no LED"
    }
  }

  var body: some View {
    ZStack {
      // Black background for letterboxing/pillarboxing
      Color.black
        .edgesIgnoringSafeArea(.all)

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
      } else if viewModel.streamingMode == .iPhone && viewModel.currentVideoFrame == nil && !viewModel.hasReceivedFirstFrame && viewModel.streamingStatus == .streaming {
        // Audio-only mode: no camera feed
        VStack(spacing: 16) {
          Image(systemName: audioOnlyIcon)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 80, height: 80)
            .foregroundColor(audioOnlyIconColor)
          Text(audioOnlyTitle)
            .font(.system(size: 24, weight: .semibold))
            .foregroundColor(audioOnlyTitleColor)
          Text(audioOnlySubtitle)
            .font(.system(size: 14))
            .foregroundColor(.white.opacity(0.5))
        }
      } else {
        ProgressView()
          .scaleEffect(1.5)
          .foregroundColor(.white)
      }

      // Gemini status overlay (top) + speaking indicator
      if geminiVM.isGeminiActive {
        if geminiVM.sessionMode == .meeting {
          // Meeting mode: full-screen transcript overlay
          MeetingOverlay(geminiVM: geminiVM)
        } else if geminiVM.sessionMode == .golf {
          // Golf mode: green overlay with scorecard HUD
          GolfOverlay(geminiVM: geminiVM)
        } else {
          // Normal AI mode: status bar + transcript + speaking indicator
          VStack {
            HStack(spacing: 8) {
              GeminiStatusBar(geminiVM: geminiVM)
            }
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
          .padding(.all, 24)
        }
      }

      // WebRTC status overlay (top)
      if webrtcVM.isActive {
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
        title: viewModel.currentVideoFrame == nil ? "Stop audio" : "Stop streaming",
        style: .destructive,
        isDisabled: false
      ) {
        Task {
          if viewModel.currentVideoFrame == nil {
            viewModel.stopAudioOnlySession()
          } else {
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

      // Meeting Mode button (disabled when WebRTC is active — audio conflict)
      MeetingModeButton(geminiVM: geminiVM)
        .opacity(webrtcVM.isActive ? 0.4 : 1.0)
        .disabled(webrtcVM.isActive)

      // Golf Mode button (disabled when WebRTC is active — audio conflict)
      GolfModeButton(geminiVM: geminiVM)
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
