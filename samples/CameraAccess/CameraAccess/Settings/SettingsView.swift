import SwiftUI

struct SettingsView: View {
  @Environment(\.dismiss) private var dismiss
  private let settings = SettingsManager.shared

  @State private var workerLoginCode: String = ""
  @State private var workerEmail: String = ""
  @State private var workerAPIBearerToken: String = ""
  @State private var opsBaseURL: String = ""
  @State private var adminBaseURL: String = ""
  @State private var signalBaseURL: String = ""
  @State private var webrtcSignalingURL: String = ""
  @State private var speakerOutputEnabled: Bool = false
  @State private var videoStreamingEnabled: Bool = false
  @State private var proactiveNotificationsEnabled: Bool = true
  @State private var showAdvancedBackend = false
  @State private var showResetConfirmation = false

  var body: some View {
    NavigationView {
      Form {
        Section(header: Text("Worker")) {
          VStack(alignment: .leading, spacing: 4) {
            Text("Worker Email")
              .font(.caption)
              .foregroundColor(.secondary)
            TextField("worker@company.com", text: $workerEmail)
              .autocapitalization(.none)
              .disableAutocorrection(true)
              .keyboardType(.emailAddress)
              .textInputAutocapitalization(.never)
              .font(.system(.body, design: .monospaced))
          }

          VStack(alignment: .leading, spacing: 4) {
            Text("Login Code")
              .font(.caption)
              .foregroundColor(.secondary)
            TextField("PD-0101", text: $workerLoginCode)
              .autocapitalization(.none)
              .disableAutocorrection(true)
              .font(.system(.body, design: .monospaced))
          }
        }

        Section(
          header: Text("AI Guide"),
          footer: Text("Gemini key, model, prompt, checklist brain, and manual context come from Admin AI Settings and the server-minted Live token.")
        ) {
          Label("Server-managed Gemini Live", systemImage: "sparkles")
          Label("Checklist context loads from the assigned patient checklist", systemImage: "checklist")
        }

        Section(header: Text("Audio"), footer: Text("Route audio output to the iPhone speaker instead of glasses. Useful for demos where others need to hear.")) {
          Toggle("Speaker Output", isOn: $speakerOutputEnabled)
        }

        Section(header: Text("Video"), footer: Text("Continuous Gemini video frames are optional. Step checks still use the camera on demand when you say \"I'm done\" or tap Check Step.")) {
          Toggle("Continuous AI Video Frames", isOn: $videoStreamingEnabled)
        }

        Section(header: Text("Notifications"), footer: Text("Receive AI guide status updates spoken through the glasses.")) {
          Toggle("Proactive Guide Updates", isOn: $proactiveNotificationsEnabled)
        }

        Section(header: Text("Advanced")) {
          Toggle("Developer Backend Settings", isOn: $showAdvancedBackend)
          if showAdvancedBackend {
            backendFields
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

  private var backendFields: some View {
    Group {
      VStack(alignment: .leading, spacing: 4) {
        Text("Ops Base URL")
          .font(.caption)
          .foregroundColor(.secondary)
        TextField("https://admin.embarcaderolabs.cloud", text: $opsBaseURL)
          .autocapitalization(.none)
          .disableAutocorrection(true)
          .keyboardType(.URL)
          .font(.system(.body, design: .monospaced))
      }

      VStack(alignment: .leading, spacing: 4) {
        Text("Admin Base URL")
          .font(.caption)
          .foregroundColor(.secondary)
        TextField("https://admin.embarcaderolabs.cloud", text: $adminBaseURL)
          .autocapitalization(.none)
          .disableAutocorrection(true)
          .keyboardType(.URL)
          .font(.system(.body, design: .monospaced))
      }

      VStack(alignment: .leading, spacing: 4) {
        Text("Signal Base URL")
          .font(.caption)
          .foregroundColor(.secondary)
        TextField("https://signal.embarcaderolabs.cloud", text: $signalBaseURL)
          .autocapitalization(.none)
          .disableAutocorrection(true)
          .keyboardType(.URL)
          .font(.system(.body, design: .monospaced))
      }

      VStack(alignment: .leading, spacing: 4) {
        Text("WebRTC Signaling URL")
          .font(.caption)
          .foregroundColor(.secondary)
        TextField("wss://signal.embarcaderolabs.cloud", text: $webrtcSignalingURL)
          .autocapitalization(.none)
          .disableAutocorrection(true)
          .keyboardType(.URL)
          .font(.system(.body, design: .monospaced))
      }

      VStack(alignment: .leading, spacing: 4) {
        Text("Worker API Bearer Token")
          .font(.caption)
          .foregroundColor(.secondary)
        SecureField("Optional fallback token", text: $workerAPIBearerToken)
          .autocapitalization(.none)
          .disableAutocorrection(true)
          .textInputAutocapitalization(.never)
          .font(.system(.body, design: .monospaced))
      }
    }
  }

  private func loadCurrentValues() {
    workerLoginCode = settings.workerLoginCode
    workerEmail = settings.workerEmail
    workerAPIBearerToken = settings.workerAPIBearerToken
    opsBaseURL = settings.opsBaseURL
    adminBaseURL = settings.adminBaseURL
    signalBaseURL = settings.signalBaseURL
    webrtcSignalingURL = settings.webrtcSignalingURL
    speakerOutputEnabled = settings.speakerOutputEnabled
    videoStreamingEnabled = settings.videoStreamingEnabled
    proactiveNotificationsEnabled = settings.proactiveNotificationsEnabled
  }

  private func save() {
    settings.workerLoginCode = workerLoginCode.trimmingCharacters(in: .whitespacesAndNewlines)
    settings.workerEmail = workerEmail.trimmingCharacters(in: .whitespacesAndNewlines)
    settings.workerAPIBearerToken = workerAPIBearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
    settings.opsBaseURL = opsBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    settings.adminBaseURL = adminBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    settings.signalBaseURL = signalBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    settings.webrtcSignalingURL = webrtcSignalingURL.trimmingCharacters(in: .whitespacesAndNewlines)
    settings.speakerOutputEnabled = speakerOutputEnabled
    settings.videoStreamingEnabled = videoStreamingEnabled
    settings.proactiveNotificationsEnabled = proactiveNotificationsEnabled
  }
}
