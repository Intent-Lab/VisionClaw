import SwiftUI

/// Reachability of the hosted gateway, resolved by an actual authenticated
/// request. "Configured" and "working" are different things -- a wrong token
/// looks identical to a correct one until something calls the server.
enum GatewayStatus: Equatable {
  case checking
  case ready
  case notConfigured
  case unauthorized
  case unreachable(String)
}

private struct GatewayStatusLabel: View {
  let status: GatewayStatus

  var body: some View {
    switch status {
    case .checking:
      ProgressView()
    case .ready:
      Label("Connected", systemImage: "checkmark.circle.fill")
        .foregroundStyle(.green)
        .labelStyle(.titleAndIcon)
    case .notConfigured:
      Text("Not set up")
        .foregroundStyle(.secondary)
    case .unauthorized:
      Label("Token rejected", systemImage: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
        .labelStyle(.titleAndIcon)
    case .unreachable(let why):
      Label(why, systemImage: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
        .labelStyle(.titleAndIcon)
    }
  }
}

struct SettingsView: View {
  @Environment(\.dismiss) private var dismiss
  private let settings = SettingsManager.shared

  @State private var cloudGatewayURL: String = ""
  @State private var cloudGatewayToken: String = ""
  @State private var accountEmail: String?
  @State private var showResetConfirmation = false
  @State private var gatewayStatus: GatewayStatus = .checking
  // Applies immediately rather than on Save: the root view observes the same
  // key and swaps the capture pipeline live.
  @AppStorage(CaptureSource.defaultsKey) private var captureSourceRaw = CaptureSource.iPhoneCamera.rawValue
  @AppStorage(IntelligenceEngine.defaultsKey) private var intelligenceRaw = IntelligenceEngine.gemini.rawValue
  @AppStorage(SettingsManager.showCaptionsKey) private var showCaptions = true

  var body: some View {
    NavigationView {
      Form {
        Section(header: Text("Camera"), footer: Text(captureSourceRaw == CaptureSource.glasses.rawValue
          ? "Streams from your Meta glasses. Connecting them happens on the main screen."
          : "Uses this phone's camera. The app opens straight into it, with voice ready.")) {
          Picker("Source", selection: $captureSourceRaw) {
            ForEach(CaptureSource.allCases, id: \.rawValue) { source in
              Text(source.label).tag(source.rawValue)
            }
          }
          .pickerStyle(.segmented)
        }

        Section(header: Text("Intelligence"), footer: Text(intelligenceRaw == IntelligenceEngine.openai.rawValue
          ? "OpenAI gpt-realtime. Applies to the next call."
          : "Google Gemini Live. Applies to the next call.")) {
          Picker("Model", selection: $intelligenceRaw) {
            ForEach(IntelligenceEngine.allCases, id: \.rawValue) { engine in
              Text(engine.label).tag(engine.rawValue)
            }
          }
          .pickerStyle(.segmented)
          Toggle("Show captions", isOn: $showCaptions)
        }

        // Cloud gateway is the only backend now.
        if true {
          Section {
            if let accountEmail, !accountEmail.isEmpty {
              HStack {
                Text("Signed in as")
                Spacer()
                Text(accountEmail)
                  .foregroundColor(.secondary)
                  .lineLimit(1)
                  .truncationMode(.middle)
              }
              Button("Sign out", role: .destructive) { signOut() }
            }
            HStack {
              Text("Status")
              Spacer()
              GatewayStatusLabel(status: gatewayStatus)
            }

            NavigationLink("Connected Apps") {
              ConnectedAppsView()
            }

            NavigationLink("Recent Tasks") {
              RecentTasksView()
            }
          }

          // The URL and token ship with working defaults, so most people never
          // need to see them; surfacing them as primary fields made a configured
          // setup look like one awaiting setup.
          Section {
            DisclosureGroup("Gateway settings") {
              VStack(alignment: .leading, spacing: 4) {
                Text("Gateway URL")
                  .font(.caption)
                  .foregroundColor(.secondary)
                TextField("https://gateway.example.com", text: $cloudGatewayURL)
                  .autocapitalization(.none)
                  .disableAutocorrection(true)
                  .keyboardType(.URL)
                  .font(.system(.body, design: .monospaced))
              }

              VStack(alignment: .leading, spacing: 4) {
                Text("Access Token")
                  .font(.caption)
                  .foregroundColor(.secondary)
                TextField("Your gateway access token", text: $cloudGatewayToken)
                  .autocapitalization(.none)
                  .disableAutocorrection(true)
                  .font(.system(.body, design: .monospaced))
              }
            }
          }
        }

        Section {
          Button("Reset to Defaults") {
            showResetConfirmation = true
          }
          .foregroundColor(.red)
        }
      }
      .navigationTitle("Settings")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .navigationBarLeading) {
          Button("Cancel") {
            dismiss()
          }
        }
        ToolbarItem(placement: .navigationBarTrailing) {
          Button("Save") {
            save()
            dismiss()
          }
          .fontWeight(.semibold)
        }
      }
      .alert("Reset Settings", isPresented: $showResetConfirmation) {
        Button("Reset", role: .destructive) {
          settings.resetAll()
          loadCurrentValues()
        }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text("This will reset all settings to the values built into the app.")
      }
      .onAppear {
        loadCurrentValues()
      }
      .task {
        await refreshGatewayStatus()
      }
    }
  }

  /// Ask the gateway for something that needs a valid token. /apps is the
  /// cheapest such route, and distinguishing 401 from a transport failure is
  /// the whole point -- they need opposite fixes.
  private func refreshGatewayStatus() async {
    
    gatewayStatus = .checking
    guard GeminiConfig.isAgentConfigured,
          let url = URL(string: "\(GeminiConfig.agentBaseURL)/apps") else {
      gatewayStatus = .notConfigured
      return
    }

    var request = URLRequest(url: url)
    request.timeoutInterval = 15
    request.setValue("Bearer \(GeminiConfig.agentToken)", forHTTPHeaderField: "Authorization")

    do {
      let (_, response) = try await URLSession.shared.data(for: request)
      let code = (response as? HTTPURLResponse)?.statusCode ?? 0
      switch code {
      case 200: gatewayStatus = .ready
      case 401, 403: gatewayStatus = .unauthorized
      default: gatewayStatus = .unreachable("Server error \(code)")
      }
    } catch {
      gatewayStatus = .unreachable("Unreachable")
    }
  }

  private func loadCurrentValues() {
    cloudGatewayURL = settings.cloudGatewayURL
    cloudGatewayToken = settings.cloudGatewayToken
    accountEmail = settings.accountEmail
  }

  /// Drops the gateway credential; the sign-in gate returns at next launch.
  private func signOut() {
    settings.cloudGatewayToken = ""
    settings.accountEmail = nil
    settings.accountStatus = nil
    cloudGatewayToken = ""
    accountEmail = nil
    gatewayStatus = .notConfigured
  }

  private func save() {
    settings.cloudGatewayURL = cloudGatewayURL.trimmingCharacters(in: .whitespacesAndNewlines)
    settings.cloudGatewayToken = cloudGatewayToken.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
