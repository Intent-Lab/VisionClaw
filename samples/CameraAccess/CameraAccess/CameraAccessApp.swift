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

import AuthenticationServices
import Foundation
import MWDATCore
import Security
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
  /// install with none configured sees only the sign-in gate. A signed-in but
  /// not-yet-approved account stays on the gate too: every other endpoint
  /// answers 401 until the study team approves it.
  @State private var needsAccessCode =
    (SettingsManager.shared.agentBackend == .cloud && !GeminiConfig.isAgentConfigured)
    || SettingsManager.shared.accountStatus == "pending"

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
    // Meta AI redirects back here to complete glasses registration. Handle the
    // callback at the ROOT so it fires no matter which screen is showing --
    // including the access-code gate. When it lived only inside the unlocked
    // glasses screen, a callback that arrived while that screen was not mounted
    // was dropped, so the DAT grant never completed and connecting looped back
    // to Meta AI forever.
    .onOpenURL { url in
      NSLog("[CameraAccess] onOpenURL: \(url.absoluteString)")
      guard wearables != nil,
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
        components.queryItems?.contains(where: { $0.name == "metaWearablesAction" }) == true
      else { return }
      Task {
        do {
          _ = try await Wearables.shared.handleUrl(url)
          NSLog("[CameraAccess] handleUrl completed")
        } catch {
          NSLog("[CameraAccess] handleUrl failed: \(error.localizedDescription)")
        }
      }
    }
    .sheet(isPresented: $showSettings) { SettingsView() }
  }
}

/// First-launch gate. The primary path is Google sign-in: the gateway turns
/// the Google identity into this app's credential and connects the calendar
/// in the same consent, and unapproved accounts wait here until the study
/// team enables them. Access codes remain for self-hosted gateways.
struct AccessCodeView: View {
  let onUnlocked: () -> Void
  @Environment(\.scenePhase) private var scenePhase

  private enum Phase: Equatable {
    case signIn
    case waiting
    case pending(email: String)
  }

  @State private var phase: Phase = .signIn
  @State private var busy = false
  @State private var error: String?
  @State private var nonce: String?
  @State private var pollTask: Task<Void, Never>?
  @State private var authSession: ASWebAuthenticationSession?

  // Self-hosters mint their own codes on their own gateway; the fields stay
  // available but no longer read as the front door.
  @State private var showCodePath = false
  @State private var code = ""
  @State private var checking = false
  @State private var ownGateway = false
  @State private var gatewayURL = SettingsManager.shared.cloudGatewayURL

  private static let callbackScheme = "visionclaw"
  private static let presentationAnchor = ConnectedAppsView.AuthPresentationAnchor()

  var body: some View {
    VStack(spacing: 12) {
      Spacer()
      Text("VisionClaw")
        .font(.title)
        .fontWeight(.semibold)

      switch phase {
      case .signIn:
        signInSection
      case .waiting:
        waitingSection
      case .pending(let email):
        pendingSection(email: email)
      }

      if let error {
        Text(error)
          .font(.footnote)
          .foregroundStyle(.red)
          .multilineTextAlignment(.center)
      }
      Spacer()
    }
    .padding(.horizontal, 32)
    .onAppear(perform: restorePendingState)
    .onDisappear { pollTask?.cancel() }
    .onChange(of: scenePhase) { _, newPhase in
      guard newPhase == .active else { return }
      // Coming back from the browser: check right away instead of waiting
      // for the next scheduled tick.
      switch phase {
      case .waiting: if let nonce { startExchangePolling(nonce: nonce) }
      case .pending: Task { await checkAccount() }
      case .signIn: break
      }
    }
  }

  // MARK: - Sections

  private var signInSection: some View {
    VStack(spacing: 12) {
      Text("Sign in to get started. Your Google account becomes your VisionClaw account and connects your calendar in the same step.")
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
      Button(action: startGoogleSignIn) {
        Text("Sign in with Google")
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .padding(.top, 12)

      DisclosureGroup("Have an access code or your own gateway?", isExpanded: $showCodePath) {
        VStack(spacing: 10) {
          TextField("Access code", text: $code)
            .textFieldStyle(.roundedBorder)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .disabled(checking)
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
          .font(.footnote)
          Button(action: submitCode) {
            if checking {
              ProgressView().frame(maxWidth: .infinity)
            } else {
              Text("Continue with code").frame(maxWidth: .infinity)
            }
          }
          .buttonStyle(.bordered)
          .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || checking)
        }
        .padding(.top, 8)
      }
      .font(.subheadline)
      .padding(.top, 4)
    }
  }

  private var waitingSection: some View {
    VStack(spacing: 12) {
      ProgressView()
      Text("Finish signing in with Google in the browser. This screen continues on its own.")
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
      Button("Cancel") { cancelSignIn() }
        .font(.subheadline)
    }
  }

  private func pendingSection(email: String) -> some View {
    VStack(spacing: 12) {
      Text("Awaiting approval")
        .font(.headline)
      Text("Signed in as \(email). This account has not been enabled yet; once the study team approves it, this screen lets you through on its own.")
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
      Button(action: { Task { await checkAccount() } }) {
        if busy {
          ProgressView().frame(maxWidth: .infinity)
        } else {
          Text("Check again").frame(maxWidth: .infinity)
        }
      }
      .buttonStyle(.borderedProminent)
      .disabled(busy)
      Button("Use a different account") { signOutToSignIn() }
        .font(.subheadline)
    }
  }

  // MARK: - Google sign-in

  private func restorePendingState() {
    let settings = SettingsManager.shared
    if settings.accountStatus == "pending", let email = settings.accountEmail, !settings.cloudGatewayToken.isEmpty {
      phase = .pending(email: email)
      startPendingPolling()
    }
  }

  private func startGoogleSignIn() {
    error = nil
    var bytes = [UInt8](repeating: 0, count: 16)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
      error = "Could not start sign-in. Try again."
      return
    }
    let fresh = bytes.map { String(format: "%02x", $0) }.joined()
    guard let url = URL(string: "\(SettingsManager.shared.cloudGatewayURL)/auth/google?nonce=\(fresh)") else {
      error = "Gateway URL is invalid. Fix it under your own gateway settings."
      return
    }
    nonce = fresh
    phase = .waiting

    // The browser sheet is only the consent surface; completion is decided by
    // the exchange poll below, which also covers a sheet closed with Done.
    let session = ASWebAuthenticationSession(url: url, callbackURLScheme: Self.callbackScheme) { _, _ in }
    session.presentationContextProvider = Self.presentationAnchor
    session.prefersEphemeralWebBrowserSession = false
    authSession = session
    session.start()
    startExchangePolling(nonce: fresh)
  }

  private enum Exchange {
    case ready(token: String, email: String, status: String)
    case notReady
    case expired
  }

  private func startExchangePolling(nonce: String) {
    pollTask?.cancel()
    pollTask = Task {
      // 10 minutes at 2 s: long enough to read a consent screen, short enough
      // that an abandoned attempt does not poll forever.
      for _ in 0..<300 {
        if Task.isCancelled { return }
        switch await exchange(nonce: nonce) {
        case .ready(let token, let email, let status):
          await finishSignIn(token: token, email: email, status: status)
          return
        case .expired:
          phase = .signIn
          error = "Sign-in expired, try again."
          return
        case .notReady:
          break
        }
        try? await Task.sleep(for: .seconds(2))
      }
      if !Task.isCancelled {
        phase = .signIn
        error = "Sign-in timed out. Try again."
      }
    }
  }

  private func exchange(nonce: String) async -> Exchange {
    guard let url = URL(string: "\(SettingsManager.shared.cloudGatewayURL)/auth/exchange") else { return .expired }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 15
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try? JSONSerialization.data(withJSONObject: ["nonce": nonce])
    guard let (data, response) = try? await URLSession.shared.data(for: request),
          let http = response as? HTTPURLResponse else { return .notReady }
    switch http.statusCode {
    case 200:
      guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let token = body["token"] as? String else { return .notReady }
      return .ready(
        token: token,
        email: body["email"] as? String ?? "",
        status: body["status"] as? String ?? "pending"
      )
    case 410: return .expired
    default: return .notReady
    }
  }

  @MainActor
  private func finishSignIn(token: String, email: String, status: String) async {
    authSession?.cancel()
    authSession = nil
    let settings = SettingsManager.shared
    settings.cloudGatewayToken = token
    settings.accountEmail = email
    settings.accountStatus = status
    await checkAccount()
  }

  /// GET /me: the gateway's word on whether this account may use the service.
  @MainActor
  private func checkAccount() async {
    guard !busy else { return }
    busy = true
    defer { busy = false }
    let settings = SettingsManager.shared
    let token = settings.cloudGatewayToken
    guard !token.isEmpty, let url = URL(string: "\(settings.cloudGatewayURL)/me") else {
      phase = .signIn
      return
    }
    var request = URLRequest(url: url)
    request.timeoutInterval = 15
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    guard let (data, response) = try? await URLSession.shared.data(for: request),
          let http = response as? HTTPURLResponse else {
      error = "Could not reach the server. Check your connection and try again."
      return
    }
    let body = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    let email = body["email"] as? String ?? settings.accountEmail ?? ""
    let status = body["status"] as? String
    switch (http.statusCode, status) {
    case (200, "approved"):
      settings.accountStatus = "approved"
      settings.accountEmail = email
      pollTask?.cancel()
      error = nil
      onUnlocked()
    case (200, "pending"):
      settings.accountStatus = "pending"
      settings.accountEmail = email
      error = nil
      if phase != .pending(email: email) {
        phase = .pending(email: email)
        startPendingPolling()
      }
    case (200, _), (401, _), (403, _):
      // Revoked, or a credential the gateway no longer recognizes.
      settings.cloudGatewayToken = ""
      settings.accountStatus = nil
      pollTask?.cancel()
      phase = .signIn
      error = "This account is not enabled for VisionClaw. Sign in with a different account, or ask the study team."
    default:
      error = "The server had a problem. Try again in a moment."
    }
  }

  private func startPendingPolling() {
    pollTask?.cancel()
    pollTask = Task {
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(15))
        if Task.isCancelled { return }
        await checkAccount()
      }
    }
  }

  private func cancelSignIn() {
    pollTask?.cancel()
    authSession?.cancel()
    authSession = nil
    nonce = nil
    phase = .signIn
  }

  private func signOutToSignIn() {
    pollTask?.cancel()
    let settings = SettingsManager.shared
    settings.cloudGatewayToken = ""
    settings.accountEmail = nil
    settings.accountStatus = nil
    error = nil
    phase = .signIn
  }

  // MARK: - Access code (self-hosted gateways)

  private func submitCode() {
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
          SettingsManager.shared.accountStatus = "approved"
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

    // The Meta AI callback is handled at the app root (see .onOpenURL there) so
    // it works even while the access-code gate is showing.
  }
}
