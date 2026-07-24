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
// Main entry point for the CameraAccess sample app demonstrating the Meta Wearables DAT SDK.
// This app shows how to connect to wearable devices (like Ray-Ban Meta smart glasses),
// stream live video from their cameras, and capture photos. It provides a complete example
// of DAT SDK integration including device registration, permissions, and media streaming.
//

import Foundation
import MWDATCore
import SwiftUI

#if canImport(MWDATMockDevice)
import MWDATMockDevice
#endif

final class MetaWearablesConfigurationOnceGate {
  private let lock = NSLock()
  private var hasAttemptedConfiguration = false

  @discardableResult
  func configureIfNeeded(
    _ configure: () throws -> Void
  ) rethrows -> Bool {
    lock.lock()
    guard !hasAttemptedConfiguration else {
      lock.unlock()
      return false
    }
    hasAttemptedConfiguration = true
    lock.unlock()

    try configure()
    return true
  }
}

@main
struct CameraAccessApp: App {
  private static let wearablesConfigurationGate =
    MetaWearablesConfigurationOnceGate()

  private let isRunningUnitTests: Bool

  init() {
    #if DEBUG
    let runningUnitTests =
      ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    isRunningUnitTests = runningUnitTests
    guard !runningUnitTests else { return }
    #else
    isRunningUnitTests = false
    #endif

    do {
      try Self.wearablesConfigurationGate.configureIfNeeded {
        try Wearables.configure()
      }
    } catch {
      #if DEBUG
      NSLog("[CameraAccess] Failed to configure Wearables SDK: \(error)")
      #endif
    }
  }

  var body: some Scene {
    WindowGroup {
      if isRunningUnitTests {
        Color.clear
      } else {
        CameraAccessRootView()
      }
    }
  }
}

private struct CameraAccessRootView: View {
  @Environment(\.scenePhase) private var scenePhase
  #if canImport(MWDATMockDevice)
  // Debug menu for simulating device connections during development
  @StateObject private var debugMenuViewModel = DebugMenuViewModel(mockDeviceKit: MockDeviceKit.shared)
  #endif
  private let wearables: WearablesInterface
  @StateObject private var wearablesViewModel: WearablesViewModel
  @StateObject private var brokerConnectionModel:
    GlassesBrokerConnectionModel

  init() {
    let wearables = Wearables.shared
    self.wearables = wearables
    self._wearablesViewModel = StateObject(wrappedValue: WearablesViewModel(wearables: wearables))
    self._brokerConnectionModel = StateObject(
      wrappedValue: GlassesBrokerConnectionModel()
    )
  }

  var body: some View {
    Group {
      // Main app view with access to the shared Wearables SDK instance
      // The Wearables.shared singleton provides the core DAT API
      MainAppView(wearables: wearables, viewModel: wearablesViewModel)
        .environmentObject(brokerConnectionModel)
        .onOpenURL { url in
          Task {
            _ = await brokerConnectionModel.handleDeepLink(url)
          }
        }
        .onAppear {
          consumePendingGlassesSessionShortcut()
        }
        .onChange(of: scenePhase) { _, nextPhase in
          guard nextPhase == .active else { return }
          consumePendingGlassesSessionShortcut()
        }
        .alert(
          "Trust this Mac?",
          isPresented: Binding(
            get: {
              brokerConnectionModel.pendingPairingConfirmation != nil
            },
            set: { _ in }
          ),
          presenting: brokerConnectionModel.pendingPairingConfirmation
        ) { confirmation in
          Button("Pair") {
            Task {
              await brokerConnectionModel.confirmPendingPairing(
                confirmationID: confirmation.id
              )
            }
          }
          Button("Cancel", role: .cancel) {
            brokerConnectionModel.cancelPendingPairing()
          }
        } message: { confirmation in
          Text(
            """
            Private Mac address: \(confirmation.privateMacAddress)
            Broker suffix: \(confirmation.brokerSuffix)
            TLS SHA-256 fingerprint:
            \(confirmation.tlsFingerprintSHA256)

            Pair only if these details match the VisionClaw broker shown on your Mac.
            """
          )
        }
        .sheet(
          item: Binding(
            get: {
              brokerConnectionModel.pendingCodexConfirmation
            },
            set: { _ in }
          )
        ) { confirmation in
          TrustedCodexContinuationConfirmationView(
            confirmation: confirmation,
            brokerConnectionModel: brokerConnectionModel
          )
        }
        .alert(
          "Personal Copilot",
          isPresented: Binding(
            get: {
              brokerConnectionModel.shouldPresentPairingResult
            },
            set: { isPresented in
              if !isPresented {
                brokerConnectionModel.dismissPairingResult()
              }
            }
          )
        ) {
          Button("OK") {
            brokerConnectionModel.dismissPairingResult()
          }
        } message: {
          Text(brokerConnectionModel.pairingResultMessage)
        }
        // Show error alerts for view model failures
        .alert("Error", isPresented: $wearablesViewModel.showError) {
          Button("OK") {
            wearablesViewModel.dismissError()
          }
        } message: {
          Text(wearablesViewModel.errorMessage)
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
      RegistrationView(viewModel: wearablesViewModel)
    }
  }

  private func consumePendingGlassesSessionShortcut() {
    guard GlassesSessionShortcutRequestStore.consume() else { return }
    brokerConnectionModel.requestGlassesSession()
  }
}

private struct TrustedCodexContinuationConfirmationView: View {
  let confirmation: CodexContinuationConfirmation
  @ObservedObject var brokerConnectionModel: GlassesBrokerConnectionModel

  @State private var isSubmitting = false

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          Label(
            "This action can continue a Codex task.",
            systemImage: "checkmark.shield"
          )
          .font(.headline)

          VStack(alignment: .leading, spacing: 8) {
            Text("Task title")
              .font(.caption)
              .foregroundStyle(.secondary)
            Text(confirmation.taskTitle)
              .frame(maxWidth: .infinity, alignment: .leading)
              .textSelection(.enabled)
              .accessibilityIdentifier("codex-confirmation-title")
          }

          VStack(alignment: .leading, spacing: 8) {
            Text("Workspace")
              .font(.caption)
              .foregroundStyle(.secondary)
            Text(confirmation.workspace ?? "Not provided")
              .frame(maxWidth: .infinity, alignment: .leading)
              .textSelection(.enabled)
              .accessibilityIdentifier("codex-confirmation-workspace")
          }

          VStack(alignment: .leading, spacing: 8) {
            Text("Opaque reference")
              .font(.caption)
              .foregroundStyle(.secondary)
            Text(confirmation.taskReference)
              .font(.system(.body, design: .monospaced))
              .textSelection(.enabled)
              .accessibilityIdentifier("codex-confirmation-task")
          }

          VStack(alignment: .leading, spacing: 8) {
            Text("Full instruction")
              .font(.caption)
              .foregroundStyle(.secondary)
            Text(confirmation.instruction)
              .frame(maxWidth: .infinity, alignment: .leading)
              .textSelection(.enabled)
              .accessibilityIdentifier("codex-confirmation-instruction")
          }

          Text(
            "Review every field. Gemini cannot press Confirm and never receives the private approval secret."
          )
          .font(.footnote)
          .foregroundStyle(.secondary)
        }
        .padding()
      }
      .navigationTitle("Confirm Codex")
      .navigationBarTitleDisplayMode(.inline)
      .safeAreaInset(edge: .bottom) {
        HStack(spacing: 12) {
          Button("Cancel", role: .cancel) {
            isSubmitting = true
            Task {
              await brokerConnectionModel.cancelPendingCodexContinuation(
                confirmationID: confirmation.id
              )
            }
          }
          .buttonStyle(.bordered)
          .disabled(isSubmitting)

          Button("Confirm") {
            isSubmitting = true
            Task {
              await brokerConnectionModel.confirmPendingCodexContinuation(
                confirmationID: confirmation.id
              )
            }
          }
          .buttonStyle(.borderedProminent)
          .disabled(isSubmitting)
          .accessibilityIdentifier("codex-confirmation-confirm")
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(.regularMaterial)
      }
    }
    .interactiveDismissDisabled()
  }
}
