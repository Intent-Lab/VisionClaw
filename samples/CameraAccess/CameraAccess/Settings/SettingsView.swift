import SwiftUI

struct SettingsView: View {
  @Environment(\.dismiss) private var dismiss
  private let settings = SettingsManager.shared

  @State private var geminiAPIKey: String = ""
  @State private var openClawHost: String = ""
  @State private var openClawPort: String = ""
  @State private var openClawHookToken: String = ""
  @State private var openClawGatewayToken: String = ""
  @State private var openClawTunnelURL: String = ""
  @State private var geminiSystemPrompt: String = ""
  @State private var webrtcSignalingURL: String = ""
  @State private var translationTargetLanguage: String = ""
  @State private var translationOutputMode: String = ""
  @State private var golfCourseAPIKey: String = ""
  @State private var golfSevenIronCarry: String = ""
  @State private var discordVisionClawWebhook: String = ""
  @State private var showResetConfirmation = false

  private let translationLanguages = ["English", "Portuguese", "Arabic", "Spanish", "French", "Italian", "German", "Chinese", "Japanese", "Korean", "Russian", "Hindi"]
  private let translationOutputModes = [("both", "Both"), ("text", "Text Only"), ("audio", "Audio Only")]

  var body: some View {
    NavigationView {
      Form {
        Section(header: Text("Gemini API")) {
          SecureSettingsField(label: "API Key", placeholder: "Enter Gemini API key", text: $geminiAPIKey)
        }

        Section(header: Text("System Prompt"), footer: Text("Customize the AI assistant's behavior and personality. Changes take effect on the next Gemini session.")) {
          TextEditor(text: $geminiSystemPrompt)
            .font(.system(.body, design: .monospaced))
            .frame(minHeight: 200)
        }

        Section(header: Text("OpenClaw"), footer: Text("Connect to an OpenClaw gateway running on your Mac for agentic tool-calling.")) {
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

          SecureSettingsField(label: "Hook Token", placeholder: "Hook token", text: $openClawHookToken)
          SecureSettingsField(label: "Gateway Token", placeholder: "Gateway auth token", text: $openClawGatewayToken)

          VStack(alignment: .leading, spacing: 4) {
            Text("Tunnel URL (off-WiFi fallback)")
              .font(.caption)
              .foregroundColor(.secondary)
            TextField("https://xxx.ngrok-free.dev", text: $openClawTunnelURL)
              .autocapitalization(.none)
              .disableAutocorrection(true)
              .keyboardType(.URL)
              .font(.system(.body, design: .monospaced))
          }
        }

        Section(header: Text("Golf"), footer: Text("Free API key at golfcourseapi.com — enables course data, distance to green, and hole info. Your 7-iron carry distance calibrates all club recommendations.")) {
          SecureSettingsField(label: "Golf Course API Key", placeholder: "Enter API key", text: $golfCourseAPIKey)

          VStack(alignment: .leading, spacing: 4) {
            Text("7-Iron Carry Distance (yards)")
              .font(.caption)
              .foregroundColor(.secondary)
            TextField("140", text: $golfSevenIronCarry)
              .keyboardType(.numberPad)
              .font(.system(.body, design: .monospaced))
          }
        }

        Section(header: Text("Translation"), footer: Text("Configure the live translation mode target language and output.")) {
          Picker("Target Language", selection: $translationTargetLanguage) {
            ForEach(translationLanguages, id: \.self) { lang in
              Text(lang).tag(lang)
            }
          }

          Picker("Output Mode", selection: $translationOutputMode) {
            ForEach(translationOutputModes, id: \.0) { mode in
              Text(mode.1).tag(mode.0)
            }
          }
        }

        Section(header: Text("Discord"), footer: Text("Webhook URL for #visionclaw channel. Server Settings > Integrations > Webhooks in Discord.")) {
          SecureSettingsField(label: "Webhook URL", placeholder: "https://discord.com/api/webhooks/...", text: $discordVisionClawWebhook)
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
    }
  }

  private func loadCurrentValues() {
    geminiAPIKey = settings.geminiAPIKey
    geminiSystemPrompt = settings.geminiSystemPrompt
    openClawHost = settings.openClawHost
    openClawPort = String(settings.openClawPort)
    openClawHookToken = settings.openClawHookToken
    openClawGatewayToken = settings.openClawGatewayToken
    openClawTunnelURL = settings.openClawTunnelURL
    webrtcSignalingURL = settings.webrtcSignalingURL
    translationTargetLanguage = settings.translationTargetLanguage
    translationOutputMode = settings.translationOutputMode
    golfCourseAPIKey = settings.golfCourseAPIKey
    golfSevenIronCarry = String(settings.golfSevenIronCarry)
    discordVisionClawWebhook = settings.discordVisionClawWebhook
  }

  private func save() {
    settings.geminiAPIKey = geminiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
    settings.geminiSystemPrompt = geminiSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    settings.openClawHost = openClawHost.trimmingCharacters(in: .whitespacesAndNewlines)
    if let port = Int(openClawPort.trimmingCharacters(in: .whitespacesAndNewlines)) {
      settings.openClawPort = port
    }
    settings.openClawHookToken = openClawHookToken.trimmingCharacters(in: .whitespacesAndNewlines)
    settings.openClawGatewayToken = openClawGatewayToken.trimmingCharacters(in: .whitespacesAndNewlines)
    settings.openClawTunnelURL = openClawTunnelURL.trimmingCharacters(in: .whitespacesAndNewlines)
    settings.webrtcSignalingURL = webrtcSignalingURL.trimmingCharacters(in: .whitespacesAndNewlines)
    settings.translationTargetLanguage = translationTargetLanguage
    settings.translationOutputMode = translationOutputMode
    settings.golfCourseAPIKey = golfCourseAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
    if let carry = Int(golfSevenIronCarry.trimmingCharacters(in: .whitespacesAndNewlines)), carry > 0 {
      settings.golfSevenIronCarry = carry
    }
    settings.discordVisionClawWebhook = discordVisionClawWebhook.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

// MARK: - Secure field with reveal toggle

struct SecureSettingsField: View {
  let label: String
  let placeholder: String
  @Binding var text: String
  @State private var isRevealed = false

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(label)
        .font(.caption)
        .foregroundColor(.secondary)
      HStack {
        if isRevealed {
          TextField(placeholder, text: $text)
            .autocapitalization(.none)
            .disableAutocorrection(true)
            .font(.system(.body, design: .monospaced))
        } else {
          SecureField(placeholder, text: $text)
            .autocapitalization(.none)
            .disableAutocorrection(true)
            .font(.system(.body, design: .monospaced))
        }
        Button(action: { isRevealed.toggle() }) {
          Image(systemName: isRevealed ? "eye.slash.fill" : "eye.fill")
            .foregroundColor(.secondary)
            .font(.system(size: 14))
        }
        .buttonStyle(.plain)
      }
    }
  }
}
