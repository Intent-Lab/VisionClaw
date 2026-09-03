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
// The app's front door. Phone mode joins a LiveKit room on sight -- camera,
// mic and the assistant all come up together; everything intelligent lives
// server-side. Glasses mode keeps the DAT streaming flow (assistant voice for
// glasses returns when their frames publish into the room as a track).
//

import MWDATCore
import SwiftUI
import UIKit

struct StreamSessionView: View {
  let wearables: WearablesInterface?
  private let wearablesViewModel: WearablesViewModel?
  @StateObject private var viewModel: StreamSessionViewModel
  @StateObject private var liveKit = LiveKitSession()
  @AppStorage(CaptureSource.defaultsKey) private var captureSourceRaw = CaptureSource.iPhoneCamera.rawValue
  @AppStorage(IntelligenceEngine.defaultsKey) private var intelligenceRaw = IntelligenceEngine.gemini.rawValue
  @State private var glassesAutoStarted = false

  private var captureSource: CaptureSource {
    CaptureSource(rawValue: captureSourceRaw) ?? .iPhoneCamera
  }

  private var glassesPlaceholder: (title: String, caption: String) {
    switch viewModel.glassesIssue {
    case .sdkUnavailable:
      return ("Glasses unavailable", "The glasses SDK is not available on this device.")
    case .permissionNeeded:
      return ("Glasses permission needed", "Allow it in the Meta AI app.")
    case .hingesClosed:
      return ("Glasses folded", "Open the hinges to start streaming.")
    case .reconnecting:
      return ("Reconnecting to glasses", "Video will appear when your glasses start streaming.")
    case nil:
      return ("Waiting for glasses video", "Video will appear when your glasses start streaming.")
    }
  }

  init(wearables: WearablesInterface?, wearablesVM: WearablesViewModel?) {
    self.wearables = wearables
    self.wearablesViewModel = wearablesVM
    self._viewModel = StateObject(wrappedValue: StreamSessionViewModel(wearables: wearables))
  }

  var body: some View {
    ZStack {
      if captureSource == .iPhoneCamera {
        LiveKitStreamView(session: liveKit)
      } else if viewModel.isStreaming {
        // Glasses are just another camera: same call screen, same agent, with
        // DAT frames bridged into the room via pushGlassesFrame.
        LiveKitStreamView(session: liveKit, glassesPlaceholder: glassesPlaceholder)
      } else if let wearablesViewModel {
        if wearablesViewModel.registrationState == .registered || wearablesViewModel.hasMockDevice {
          // No start-choice interstitial: registered glasses go straight to
          // the call screen, auto-starting the stream once per entry, then
          // re-attempting on a slow cadence while the glasses are asleep --
          // the placeholder is the only voice for the wait.
          LiveKitStreamView(session: liveKit, glassesPlaceholder: glassesPlaceholder)
            .task {
              guard !glassesAutoStarted else { return }
              glassesAutoStarted = true
              for _ in 0..<4 {
                await viewModel.handleStartStreaming()
                if viewModel.isStreaming { break }
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                if viewModel.isStreaming || captureSource != .glasses { break }
              }
            }
        } else {
          HomeScreenView(viewModel: wearablesViewModel)
        }
      } else {
        Color.black.edgesIgnoringSafeArea(.all)
      }
    }
    .task {
      viewModel.onDecodedFrame = { [weak liveKit] pixelBuffer in
        liveKit?.pushGlassesFrame(pixelBuffer)
      }
      if captureSource == .iPhoneCamera {
        await liveKit.start()
      }
    }
    .onChange(of: viewModel.streamingStatus) { status in
      // Glasses mode: the call rides the DAT stream's lifecycle. Open the room
      // only once frames are actually flowing (.streaming), so the buffer-track
      // publish has a frame to settle its dimensions instead of timing out. A
      // transient .waiting (glasses briefly asleep) keeps the call alive; only
      // a real .stopped ends it. Gating on isStreaming (which is true during
      // .waiting) opened the room before any frame and made the publish race.
      guard captureSource == .glasses else { return }
      Task {
        if status == .streaming {
          await liveKit.start()
        } else if status == .stopped, liveKit.isActive {
          await liveKit.stop()
        }
      }
    }
    .onChange(of: intelligenceRaw) { _ in
      // The brain is chosen at session start (room-token metadata), so a live
      // call redials itself to apply the switch -- the user flips a toggle and
      // three seconds later the other model picks up.
      Task {
        if liveKit.isActive {
          await liveKit.stop()
          await liveKit.start()
        }
      }
    }
    .onChange(of: captureSourceRaw) { newRaw in
      glassesAutoStarted = false
      Task {
        if CaptureSource(rawValue: newRaw) == .iPhoneCamera {
          if viewModel.isStreaming { await viewModel.stopSession() }
          await liveKit.start()
        } else {
          await liveKit.stop()
        }
      }
    }
    .alert("Error", isPresented: $viewModel.showError) {
      Button("OK") { viewModel.dismissError() }
    } message: {
      Text(viewModel.errorMessage)
    }
  }
}
