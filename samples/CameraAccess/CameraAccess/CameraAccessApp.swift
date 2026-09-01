/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// CameraAccessApp.swift
//
// VisionClaw is a vision assistant first: the app opens looking at the world
// through the phone camera with voice already listening. Glasses are a capture
// source chosen in Settings, not a decision the user has to make at launch --
// the connect/registration flow appears only when that source is selected.
//

import Foundation
import MWDATCore
import SwiftUI

#if canImport(MWDATMockDevice)
import MWDATMockDevice
#endif

@main
struct CameraAccessApp: App {
  /// nil when the Wearables SDK could not start (no hardware, e.g. the
  /// simulator). Accessing `Wearables.shared` after a failed `configure()`
  /// traps, so nothing glasses-related may be built in that case. The camera
  /// experience does not depend on it.
  private let wearables: WearablesInterface?

  init() {
    var available: WearablesInterface?
    do {
      try Wearables.configure()
      available = Wearables.shared
    } catch {
      NSLog("[CameraAccess] Wearables SDK unavailable: \(error)")
    }
    self.wearables = available
  }

  var body: some Scene {
    WindowGroup {
      VisionRootView(wearables: wearables)
    }
  }
}

/// Camera-first root. The stream view is always the front door; what varies
/// with the Wearables SDK is only whether the glasses affordances exist.
struct VisionRootView: View {
  let wearables: WearablesInterface?
  /// `-openSettings` presents Settings at launch, so screens can be captured
  /// on a simulator with no GUI to tap through.
  @State private var showSettings = ProcessInfo.processInfo.arguments.contains("-openSettings")
  /// Builds ship without a gateway token (it is per-person identity), so an
  /// install with none configured sees only the access-code gate.
  @State private var needsAccessCode =
    SettingsManager.shared.agentBackend == .cloud && !GeminiConfig.isAgentConfigured

  var body: some View {
    Group {
      if needsAccessCode {
        AccessCodeView(onUnlocked: { needsAccessCode = false })
      } else if let wearables {
        GlassesCapableRootView(wearables: wearables)
      } else {
        StreamSessionView(wearables: nil, wearablesVM: nil)
      }
    }
    .sheet(isPresented: $showSettings) { SettingsView() }
  }
}

/// First-launch gate: verifies the entered code against the gateway before
/// unlocking, because a typo saved silently would surface later as a 401 that
/// looks like a server outage.
struct AccessCodeView: View {
  let onUnlocked: () -> Void
  @State private var code = ""
  @State private var checking = false
  @State private var error: String?
  /// Self-hosters mint their own codes on their own gateway; without a way to
  /// point the app there, the gate reads as a private beta and they email the
  /// author for a code that only their gateway can issue.
  @State private var ownGateway = false
  @State private var gatewayURL = SettingsManager.shared.cloudGatewayURL

  var body: some View {
    VStack(spacing: 12) {
      Spacer()
      Text("VisionClaw")
        .font(.title)
        .fontWeight(.semibold)
      Text("Enter your access code to get started. Each code is a personal identity, so ask whoever shared the app for yours.")
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
      TextField("Access code", text: $code)
        .textFieldStyle(.roundedBorder)
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        .disabled(checking)
        .padding(.top, 20)
      DisclosureGroup("Using your own gateway?", isExpanded: $ownGateway) {
        VStack(spacing: 8) {
          Text("A self-hosted gateway issues its own codes: any entry you set in its GATEWAY_TOKENS works here.")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
          TextField("Gateway URL", text: $gatewayURL)
            .textFieldStyle(.roundedBorder)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .keyboardType(.URL)
            .disabled(checking)
        }
        .padding(.top, 6)
      }
      .font(.subheadline)
      .disabled(checking)
      if let error {
        Text(error)
          .font(.footnote)
          .foregroundStyle(.red)
          .multilineTextAlignment(.center)
      }
      Button(action: submit) {
        if checking {
          ProgressView()
            .frame(maxWidth: .infinity)
        } else {
          Text("Continue")
            .frame(maxWidth: .infinity)
        }
      }
      .buttonStyle(.borderedProminent)
      .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || checking)
      Spacer()
    }
    .padding(.horizontal, 32)
  }

  private func submit() {
    guard !checking else { return }
    error = nil
    if ownGateway {
      var url = gatewayURL.trimmingCharacters(in: .whitespacesAndNewlines)
      while url.hasSuffix("/") { url.removeLast() }
      guard url.hasPrefix("http") else {
        error = "Gateway URL must start with https://"
        return
      }
      SettingsManager.shared.cloudGatewayURL = url
    }
    checking = true
    let token = code.trimmingCharacters(in: .whitespacesAndNewlines)
    SettingsManager.shared.cloudGatewayToken = token
    Task {
      defer { checking = false }
      guard let url = URL(string: "\(SettingsManager.shared.cloudGatewayURL)/apps") else {
        error = "Gateway URL is invalid. Fix it in Settings."
        return
      }
      var request = URLRequest(url: url)
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
      do {
        let (_, response) = try await URLSession.shared.data(for: request)
        switch (response as? HTTPURLResponse)?.statusCode {
        case 200:
          onUnlocked()
        case 401, 403:
          error = "That code was not recognized. Check it and try again."
        default:
          error = "The server had a problem. Try again in a moment."
        }
      } catch {
        self.error = "Could not reach the server. Check your connection and try again."
      }
    }
  }
}

/// The full app when the glasses SDK is present: the same camera-first stream
/// view, plus the registration overlay and mock-device debug menu that only
/// make sense with the SDK available.
private struct GlassesCapableRootView: View {
  let wearables: WearablesInterface
  @StateObject private var viewModel: WearablesViewModel

  #if canImport(MWDATMockDevice)
  // Debug menu for simulating device connections during development
  @StateObject private var debugMenuViewModel = DebugMenuViewModel(mockDeviceKit: MockDeviceKit.shared)
  #endif

  init(wearables: WearablesInterface) {
    self.wearables = wearables
    self._viewModel = StateObject(wrappedValue: WearablesViewModel(wearables: wearables))
  }

  var body: some View {
    StreamSessionView(wearables: wearables, wearablesVM: viewModel)
      // Show error alerts for view model failures
      .alert("Error", isPresented: $viewModel.showError) {
        Button("OK") { viewModel.dismissError() }
      } message: {
        Text(viewModel.errorMessage)
      }
      #if canImport(MWDATMockDevice)
      .sheet(isPresented: $debugMenuViewModel.showDebugMenu) {
        MockDeviceKitView(viewModel: debugMenuViewModel.mockDeviceKitViewModel)
      }
      .overlay {
        DebugMenuView(debugMenuViewModel: debugMenuViewModel)
      }
      #endif

    // Registration view handles the flow for connecting to the glasses via Meta AI
    RegistrationView(viewModel: viewModel)
  }
}
