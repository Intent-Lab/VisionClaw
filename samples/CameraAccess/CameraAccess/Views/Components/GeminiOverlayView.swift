import SwiftUI

struct GeminiStatusBar: View {
  @ObservedObject var geminiVM: GeminiSessionViewModel

  var body: some View {
    HStack(spacing: 8) {
      // Gemini connection pill
      StatusPill(color: geminiStatusColor, text: geminiStatusText)

      // OpenClaw connection pill
      StatusPill(color: openClawStatusColor, text: openClawStatusText)

      if let spatial = geminiVM.spatialService {
        SpatialBadge(spatialService: spatial)
      }

      if geminiVM.isInspectionActive {
        InspectionBadge()
      }
      if geminiVM.isSafetyMonitorActive {
        SafetyBadge()
      }
    }
  }

  private var geminiStatusColor: Color {
    switch geminiVM.connectionState {
    case .ready: return .green
    case .connecting, .settingUp: return .yellow
    case .error: return .red
    case .disconnected: return .gray
    }
  }

  private var geminiStatusText: String {
    switch geminiVM.connectionState {
    case .ready: return "Gemini"
    case .connecting, .settingUp: return "Gemini..."
    case .error: return "Gemini Error"
    case .disconnected: return "Gemini Off"
    }
  }

  private var openClawStatusColor: Color {
    switch geminiVM.openClawConnectionState {
    case .connected: return .green
    case .checking: return .yellow
    case .unreachable: return .red
    case .notConfigured: return .gray
    }
  }

  private var openClawStatusText: String {
    switch geminiVM.openClawConnectionState {
    case .connected: return "OpenClaw"
    case .checking: return "OpenClaw..."
    case .unreachable: return "OpenClaw Off"
    case .notConfigured: return "No OpenClaw"
    }
  }
}

struct StatusPill: View {
  let color: Color
  let text: String

  var body: some View {
    HStack(spacing: 6) {
      Circle()
        .fill(color)
        .frame(width: 8, height: 8)
      Text(text)
        .font(.system(size: 12, weight: .medium))
        .foregroundColor(.white)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .background(Color.black.opacity(0.6))
    .cornerRadius(16)
  }
}

struct TranscriptView: View {
  let userText: String
  let aiText: String

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if !userText.isEmpty {
        Text(userText)
          .font(.system(size: 14))
          .foregroundColor(.white.opacity(0.7))
      }
      if !aiText.isEmpty {
        Text(aiText)
          .font(.system(size: 16, weight: .medium))
          .foregroundColor(.white)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .background(Color.black.opacity(0.6))
    .cornerRadius(12)
  }
}

struct ToolCallStatusView: View {
  let status: ToolCallStatus

  var body: some View {
    if status != .idle {
      HStack(spacing: 8) {
        statusIcon
        Text(status.displayText)
          .font(.system(size: 13, weight: .medium))
          .foregroundColor(.white)
          .lineLimit(1)
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 8)
      .background(statusBackground)
      .cornerRadius(16)
    }
  }

  @ViewBuilder
  private var statusIcon: some View {
    switch status {
    case .executing:
      ProgressView()
        .scaleEffect(0.7)
        .tint(.white)
    case .completed:
      Image(systemName: "checkmark.circle.fill")
        .foregroundColor(.green)
        .font(.system(size: 14))
    case .failed:
      Image(systemName: "exclamationmark.circle.fill")
        .foregroundColor(.red)
        .font(.system(size: 14))
    case .cancelled:
      Image(systemName: "xmark.circle.fill")
        .foregroundColor(.yellow)
        .font(.system(size: 14))
    case .idle:
      EmptyView()
    }
  }

  private var statusBackground: Color {
    switch status {
    case .executing: return Color.black.opacity(0.7)
    case .completed: return Color.black.opacity(0.6)
    case .failed: return Color.red.opacity(0.3)
    case .cancelled: return Color.black.opacity(0.6)
    case .idle: return Color.clear
    }
  }
}

struct InspectionBadge: View {
  @State private var pulsing = false

  var body: some View {
    HStack(spacing: 4) {
      Circle()
        .fill(Color.blue)
        .frame(width: 8, height: 8)
        .scaleEffect(pulsing ? 1.3 : 1.0)
        .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulsing)
      Text("Inspecting")
        .font(.system(size: 11, weight: .semibold))
        .foregroundColor(.white)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 5)
    .background(Color.blue.opacity(0.4))
    .cornerRadius(12)
    .onAppear { pulsing = true }
  }
}

struct SafetyBadge: View {
  @State private var pulsing = false

  var body: some View {
    HStack(spacing: 4) {
      Image(systemName: "shield.checkered")
        .font(.system(size: 10, weight: .bold))
        .foregroundColor(.yellow)
        .scaleEffect(pulsing ? 1.2 : 1.0)
        .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: pulsing)
      Text("Safety")
        .font(.system(size: 11, weight: .semibold))
        .foregroundColor(.white)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 5)
    .background(Color.orange.opacity(0.4))
    .cornerRadius(12)
    .onAppear { pulsing = true }
  }
}

struct SpeakingIndicator: View {
  @State private var animating = false

  var body: some View {
    HStack(spacing: 3) {
      ForEach(0..<4, id: \.self) { index in
        RoundedRectangle(cornerRadius: 1.5)
          .fill(Color.white)
          .frame(width: 3, height: animating ? CGFloat.random(in: 8...20) : 6)
          .animation(
            .easeInOut(duration: 0.3)
              .repeatForever(autoreverses: true)
              .delay(Double(index) * 0.1),
            value: animating
          )
      }
    }
    .onAppear { animating = true }
    .onDisappear { animating = false }
  }
}


struct SpatialBadge: View {
  @ObservedObject var spatialService: SpatialLocalizationService

  var body: some View {
    HStack(spacing: 4) {
      Image(systemName: icon)
        .font(.system(size: 10, weight: .bold))
      Text(label)
        .font(.system(size: 11, weight: .semibold))
    }
    .foregroundColor(.white)
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(color.opacity(0.9))
    .cornerRadius(8)
  }

  private var icon: String {
    switch spatialService.activeSource {
    case .multiset: return "scope"
    case .googleGeo: return "globe"
    case .gps: return "location.fill"
    case .unknown: return "location.slash"
    }
  }

  private var label: String {
    switch spatialService.activeSource {
    case .multiset: return "VPS ±5cm"
    case .googleGeo: return "GEO ±1m"
    case .gps: return "GPS"
    case .unknown: return "Spatial"
    }
  }

  private var color: Color {
    switch spatialService.activeSource {
    case .multiset: return .purple
    case .googleGeo: return .indigo
    case .gps: return .blue
    case .unknown: return .gray
    }
  }
}
