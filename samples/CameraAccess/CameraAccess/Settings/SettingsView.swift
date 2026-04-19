import SwiftUI

struct SettingsView: View {
  @Environment(\.dismiss) private var dismiss
  private let settings = SettingsManager.shared

  @State private var geminiAPIKey: String = ""
  @State private var openClawHost: String = ""
  @State private var openClawPort: String = ""
  @State private var openClawHookToken: String = ""
  @State private var openClawGatewayToken: String = ""
  @State private var geminiSystemPrompt: String = ""
  @State private var webrtcSignalingURL: String = ""
  @State private var speakerOutputEnabled: Bool = false
  @State private var videoStreamingEnabled: Bool = true
  @State private var proactiveNotificationsEnabled: Bool = true
  @State private var inspectionInterval: String = "10"
  @State private var inspectionAutoStart: Bool = false
  @State private var safetyMonitorInterval: String = "15"
  @State private var safetyMonitorAutoStart: Bool = false
  @State private var multisetEnabled: Bool = true
  @State private var multisetClientId: String = ""
  @State private var multisetClientSecret: String = ""
  @State private var multisetMapCode: String = ""
  @State private var workerName: String = ""
  @State private var defaultJobId: String = ""
  @State private var defaultJobDescription: String = ""
  @State private var defaultSiteAddress: String = ""
  @State private var showResetConfirmation = false

  var body: some View {
    NavigationView {
      Form {
        Section(header: Text("Gemini API")) {
          VStack(alignment: .leading, spacing: 4) {
            Text("API Key")
              .font(.caption)
              .foregroundColor(.secondary)
            TextField("Enter Gemini API key", text: $geminiAPIKey)
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

          VStack(alignment: .leading, spacing: 4) {
            Text("Hook Token")
              .font(.caption)
              .foregroundColor(.secondary)
            TextField("Hook token", text: $openClawHookToken)
              .autocapitalization(.none)
              .disableAutocorrection(true)
              .font(.system(.body, design: .monospaced))
          }

          VStack(alignment: .leading, spacing: 4) {
            Text("Gateway Token")
              .font(.caption)
              .foregroundColor(.secondary)
            TextField("Gateway auth token", text: $openClawGatewayToken)
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

        Section(header: Text("Spatial Positioning (Multiset VPS)"), footer: Text("Sub-5cm indoor localization. Scan your facility with the Multiset Mapper app first, then paste the Map Code below. Leave Map Code blank to stay on GPS-only.")) {
          Toggle("Enable Multiset VPS", isOn: $multisetEnabled)
          VStack(alignment: .leading, spacing: 4) {
            Text("Client ID")
              .font(.caption)
              .foregroundColor(.secondary)
            TextField("UUID from developer.multiset.ai", text: $multisetClientId)
              .autocapitalization(.none)
              .disableAutocorrection(true)
              .font(.system(.body, design: .monospaced))
          }
          VStack(alignment: .leading, spacing: 4) {
            Text("Client Secret")
              .font(.caption)
              .foregroundColor(.secondary)
            SecureField("Secret", text: $multisetClientSecret)
              .font(.system(.body, design: .monospaced))
          }
          VStack(alignment: .leading, spacing: 4) {
            Text("Map Code")
              .font(.caption)
              .foregroundColor(.secondary)
            TextField("Code from scanned map", text: $multisetMapCode)
              .autocapitalization(.none)
              .disableAutocorrection(true)
              .font(.system(.body, design: .monospaced))
          }
        }

        Section(header: Text("Safety Monitor"), footer: Text("Continuously watches for safety hazards, OSHA violations, and dangerous conditions through the camera.")) {
          VStack(alignment: .leading, spacing: 4) {
            Text("Check Interval (seconds)")
              .font(.caption)
              .foregroundColor(.secondary)
            TextField("15", text: $safetyMonitorInterval)
              .keyboardType(.numberPad)
              .font(.system(.body, design: .monospaced))
          }
          Toggle("Auto-Start Safety Monitor", isOn: $safetyMonitorAutoStart)
        }

        Section(header: Text("Inspection"), footer: Text("Proactive inspection mode analyzes the camera feed at regular intervals and speaks up when it spots issues.")) {
          VStack(alignment: .leading, spacing: 4) {
            Text("Inspection Interval (seconds)")
              .font(.caption)
              .foregroundColor(.secondary)
            TextField("10", text: $inspectionInterval)
              .keyboardType(.numberPad)
              .font(.system(.body, design: .monospaced))
          }
          Toggle("Auto-Start Inspection", isOn: $inspectionAutoStart)
        }

        Section(header: Text("Field Worker"), footer: Text("Pre-fill job context for field sessions. This information is injected into the AI system prompt and included in reports.")) {
          VStack(alignment: .leading, spacing: 4) {
            Text("Worker Name")
              .font(.caption)
              .foregroundColor(.secondary)
            TextField("Your name", text: $workerName)
              .autocapitalization(.words)
          }
          VStack(alignment: .leading, spacing: 4) {
            Text("Default Job ID")
              .font(.caption)
              .foregroundColor(.secondary)
            TextField("e.g. WO-2024-001", text: $defaultJobId)
              .autocapitalization(.allCharacters)
              .disableAutocorrection(true)
          }
          VStack(alignment: .leading, spacing: 4) {
            Text("Job Description")
              .font(.caption)
              .foregroundColor(.secondary)
            TextField("e.g. Quarterly HVAC inspection", text: $defaultJobDescription)
          }
          VStack(alignment: .leading, spacing: 4) {
            Text("Site Address")
              .font(.caption)
              .foregroundColor(.secondary)
            TextField("e.g. 123 Main St, Building A", text: $defaultSiteAddress)
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
    webrtcSignalingURL = settings.webrtcSignalingURL
    speakerOutputEnabled = settings.speakerOutputEnabled
    videoStreamingEnabled = settings.videoStreamingEnabled
    proactiveNotificationsEnabled = settings.proactiveNotificationsEnabled
    inspectionInterval = String(settings.inspectionInterval)
    inspectionAutoStart = settings.inspectionAutoStart
    safetyMonitorInterval = String(settings.safetyMonitorInterval)
    safetyMonitorAutoStart = settings.safetyMonitorAutoStart
    workerName = settings.workerName
    defaultJobId = settings.defaultJobId
    defaultJobDescription = settings.defaultJobDescription
    defaultSiteAddress = settings.defaultSiteAddress
    multisetEnabled = settings.multisetEnabled
    multisetClientId = settings.multisetClientId
    multisetClientSecret = settings.multisetClientSecret
    multisetMapCode = settings.multisetMapCode
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
    settings.webrtcSignalingURL = webrtcSignalingURL.trimmingCharacters(in: .whitespacesAndNewlines)
    settings.speakerOutputEnabled = speakerOutputEnabled
    settings.videoStreamingEnabled = videoStreamingEnabled
    settings.proactiveNotificationsEnabled = proactiveNotificationsEnabled
    if let interval = Int(inspectionInterval.trimmingCharacters(in: .whitespacesAndNewlines)), interval > 0 {
      settings.inspectionInterval = interval
    }
    settings.inspectionAutoStart = inspectionAutoStart
    if let interval = Int(safetyMonitorInterval.trimmingCharacters(in: .whitespacesAndNewlines)), interval > 0 {
      settings.safetyMonitorInterval = interval
    }
    settings.safetyMonitorAutoStart = safetyMonitorAutoStart
    settings.workerName = workerName.trimmingCharacters(in: .whitespacesAndNewlines)
    settings.defaultJobId = defaultJobId.trimmingCharacters(in: .whitespacesAndNewlines)
    settings.defaultJobDescription = defaultJobDescription.trimmingCharacters(in: .whitespacesAndNewlines)
    settings.defaultSiteAddress = defaultSiteAddress.trimmingCharacters(in: .whitespacesAndNewlines)
    settings.multisetEnabled = multisetEnabled
    settings.multisetClientId = multisetClientId.trimmingCharacters(in: .whitespacesAndNewlines)
    settings.multisetClientSecret = multisetClientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
    settings.multisetMapCode = multisetMapCode.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
