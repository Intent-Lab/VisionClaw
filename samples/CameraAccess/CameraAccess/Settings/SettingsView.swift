import SwiftUI

struct SettingsView: View {
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var brokerConnectionModel:
    GlassesBrokerConnectionModel
  private let settings = SettingsManager.shared

  @State private var geminiAPIKey: String = ""
  @State private var openClawHost: String = ""
  @State private var openClawPort: String = ""
  @State private var openClawAgentTarget: String = ""
  @State private var openClawHookToken: String = ""
  @State private var openClawGatewayToken: String = ""
  @State private var geminiSystemPrompt: String = ""
  @State private var webrtcSignalingURL: String = ""
  @State private var speakerOutputEnabled: Bool = false
  @State private var videoStreamingEnabled: Bool = true
  @State private var proactiveNotificationsEnabled: Bool = true
  @State private var showResetConfirmation = false
  @State private var showForgetBrokerConfirmation = false

  var body: some View {
    NavigationView {
      Form {
        Section(header: Text("Gemini API")) {
          VStack(alignment: .leading, spacing: 4) {
            Text("API Key")
              .font(.caption)
              .foregroundColor(.secondary)
            SecureField("Enter Gemini API key", text: $geminiAPIKey)
              .autocapitalization(.none)
              .disableAutocorrection(true)
              .font(.system(.body, design: .monospaced))
          }
        }

        Section(header: Text("System Prompt"), footer: Text("Customize the AI assistant's behavior and personality. Changes take effect on the next Gemini session.")) {
          TextEditor(text: $geminiSystemPrompt)
            .font(.system(.body, design: .monospaced))
            .frame(minHeight: 200)
        }

        Section(
          header: Text("Personal Copilot"),
          footer: Text(
            "On your Mac, start the VisionClaw broker and create a pairing QR. Scan it with the iPhone Camera, then return here. The QR—not the nearby-device name—verifies your Mac."
          )
        ) {
          HStack {
            Label(
              brokerConnectionModel.state.displayText,
              systemImage: brokerConnectionModel.isSecureRoutingReady
                ? "checkmark.shield.fill"
                : "shield.slash"
            )
            Spacer()
            if let name = brokerConnectionModel.pairedBrokerName {
              Text(name)
                .foregroundColor(.secondary)
            }
          }

          if !brokerConnectionModel.nearbyBrokers.isEmpty,
             !brokerConnectionModel.isSecureRoutingReady {
            Label("VisionClaw Mac found nearby", systemImage: "wifi")
              .foregroundColor(.secondary)
          }

          if brokerConnectionModel.isSecureRoutingReady {
            Text("Say Eva for OpenClaw, Codex for task control, or Meta for the native-assistant handoff.")
              .font(.footnote)
              .foregroundColor(.secondary)

          } else {
            Text(
              pairingGuidance
            )
              .font(.footnote)
              .foregroundColor(.secondary)
          }

          if brokerConnectionModel.hasStoredPairing {
            Button("Forget Mac Pairing", role: .destructive) {
              showForgetBrokerConfirmation = true
            }
          }
        }

        Section(
          header: Text("Legacy OpenClaw"),
          footer: Text(
            "Compatibility settings used only when the secure Personal Copilot broker is not paired."
          )
        ) {
          VStack(alignment: .leading, spacing: 4) {
            Text("Host")
              .font(.caption)
              .foregroundColor(.secondary)
            TextField("http://your-mac.local", text: $openClawHost)
              .autocapitalization(.none)
              .disableAutocorrection(true)
              .keyboardType(.URL)
              .font(.system(.body, design: .monospaced))
          }

          VStack(alignment: .leading, spacing: 4) {
            Text("Port")
              .font(.caption)
              .foregroundColor(.secondary)
            TextField("18789", text: $openClawPort)
              .keyboardType(.numberPad)
              .font(.system(.body, design: .monospaced))
          }

          VStack(alignment: .leading, spacing: 4) {
            Text("Agent Target")
              .font(.caption)
              .foregroundColor(.secondary)
            TextField("openclaw", text: $openClawAgentTarget)
              .autocapitalization(.none)
              .disableAutocorrection(true)
              .font(.system(.body, design: .monospaced))
          }

          VStack(alignment: .leading, spacing: 4) {
            Text("Hook Token")
              .font(.caption)
              .foregroundColor(.secondary)
            SecureField("Hook token", text: $openClawHookToken)
              .autocapitalization(.none)
              .disableAutocorrection(true)
              .font(.system(.body, design: .monospaced))
          }

          VStack(alignment: .leading, spacing: 4) {
            Text("Gateway Token")
              .font(.caption)
              .foregroundColor(.secondary)
            SecureField("Gateway auth token", text: $openClawGatewayToken)
              .autocapitalization(.none)
              .disableAutocorrection(true)
              .font(.system(.body, design: .monospaced))
          }
        }

        Section(header: Text("WebRTC")) {
          VStack(alignment: .leading, spacing: 4) {
            Text("Signaling URL")
              .font(.caption)
              .foregroundColor(.secondary)
            TextField("wss://your-server.example.com", text: $webrtcSignalingURL)
              .autocapitalization(.none)
              .disableAutocorrection(true)
              .keyboardType(.URL)
              .font(.system(.body, design: .monospaced))
          }
        }

        Section(header: Text("Audio"), footer: Text("Route audio output to the iPhone speaker instead of glasses. Useful for demos where others need to hear.")) {
          Toggle("Speaker Output", isOn: $speakerOutputEnabled)
        }

        Section(header: Text("Video"), footer: Text("Disable video streaming to save battery. Audio remains active for voice-only interaction.")) {
          Toggle("Video Streaming", isOn: $videoStreamingEnabled)
        }

        Section(header: Text("Notifications"), footer: Text("Receive proactive updates from OpenClaw (heartbeat, scheduled tasks) spoken through the glasses.")) {
          Toggle("Proactive Notifications", isOn: $proactiveNotificationsEnabled)
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
      .confirmationDialog(
        "Forget this Mac?",
        isPresented: $showForgetBrokerConfirmation,
        titleVisibility: .visible
      ) {
        Button("Forget Mac Pairing", role: .destructive) {
          brokerConnectionModel.forgetPairing()
        }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text(
          "VisionClaw will delete the protected Mac record and return to the legacy connection until you pair again."
        )
      }
      .onAppear {
        loadCurrentValues()
        brokerConnectionModel.startDiscovery()
        Task {
          await brokerConnectionModel.refreshReachability()
        }
      }
      .onDisappear {
        brokerConnectionModel.stopDiscovery()
      }
    }
  }

  private func loadCurrentValues() {
    geminiAPIKey = settings.geminiAPIKey
    geminiSystemPrompt = settings.geminiSystemPrompt
    openClawHost = settings.openClawHost
    openClawPort = String(settings.openClawPort)
    openClawAgentTarget = settings.openClawAgentTarget
    openClawHookToken = settings.openClawHookToken
    openClawGatewayToken = settings.openClawGatewayToken
    webrtcSignalingURL = settings.webrtcSignalingURL
    speakerOutputEnabled = settings.speakerOutputEnabled
    videoStreamingEnabled = settings.videoStreamingEnabled
    proactiveNotificationsEnabled = settings.proactiveNotificationsEnabled
  }

  private func save() {
    settings.geminiAPIKey = geminiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
    settings.geminiSystemPrompt = geminiSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    settings.openClawHost = openClawHost.trimmingCharacters(in: .whitespacesAndNewlines)
    if let port = Int(openClawPort.trimmingCharacters(in: .whitespacesAndNewlines)) {
      settings.openClawPort = port
    }
    settings.openClawAgentTarget =
      openClawAgentTarget.trimmingCharacters(in: .whitespacesAndNewlines)
    settings.openClawHookToken = openClawHookToken.trimmingCharacters(in: .whitespacesAndNewlines)
    settings.openClawGatewayToken = openClawGatewayToken.trimmingCharacters(in: .whitespacesAndNewlines)
    settings.webrtcSignalingURL = webrtcSignalingURL.trimmingCharacters(in: .whitespacesAndNewlines)
    settings.speakerOutputEnabled = speakerOutputEnabled
    settings.videoStreamingEnabled = videoStreamingEnabled
    settings.proactiveNotificationsEnabled = proactiveNotificationsEnabled
  }

  private var pairingGuidance: String {
    if case .blockedPairing = brokerConnectionModel.state {
      return
        "The protected pairing is unreadable and all external routing is blocked. Use Forget Mac Pairing before scanning another QR or returning to the legacy connection."
    }
    if brokerConnectionModel.hasStoredPairing {
      return
        "The pairing is saved, but the Mac is not ready. Start the broker. If access was revoked, forget this pairing before scanning a new QR."
    }
    return "Waiting for a secure pairing QR from your Mac."
  }
}
