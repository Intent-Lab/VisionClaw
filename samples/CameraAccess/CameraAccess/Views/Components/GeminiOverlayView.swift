import SwiftUI

struct GeminiStatusBar: View {
  @ObservedObject var geminiVM: GeminiSessionViewModel

  var body: some View {
    HStack(spacing: 8) {
      // Dedicated glasses-session connection pill
      StatusPill(color: geminiStatusColor, text: geminiStatusText)

      StatusPill(color: audioRouteColor, text: geminiVM.audioRouteStatus.displayText)

      if geminiVM.isNamedRoutingActive {
        StatusPill(color: harnessStatusColor, text: harnessStatusText)
      } else {
        StatusPill(color: openClawStatusColor, text: openClawStatusText)
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
    case .ready: return "Glasses Session"
    case .connecting, .settingUp: return "Session…"
    case .error: return "Session Error"
    case .disconnected: return "Session Off"
    }
  }

  private var audioRouteColor: Color {
    if geminiVM.audioRouteStatus.isGlassesDuplex {
      return .green
    }
    if !geminiVM.audioRouteStatus.inputNames.isEmpty
        || !geminiVM.audioRouteStatus.outputNames.isEmpty {
      return .yellow
    }
    return .gray
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

  private var harnessStatusColor: Color {
    switch geminiVM.harnessRoutingState {
    case .active: return .green
    case .recognized, .routing: return .yellow
    case .confirmationRequired, .fallback: return .orange
    case .unavailable: return .red
    case .idle: return .gray
    }
  }

  private var harnessStatusText: String {
    let text = geminiVM.harnessRoutingState.displayText
    return text.isEmpty ? "Vision" : text
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
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(text)
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

struct HarnessRoutingStatusView: View {
  let state: NamedHarnessRoutingState

  var body: some View {
    if state != .idle {
      HStack(spacing: 8) {
        Image(systemName: iconName)
          .foregroundColor(iconColor)
        VStack(alignment: .leading, spacing: 2) {
          Text(state.displayText)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.white)
          if let detail {
            Text(detail)
              .font(.system(size: 11))
              .foregroundColor(.white.opacity(0.75))
              .lineLimit(2)
          }
        }
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 8)
      .background(Color.black.opacity(0.65))
      .cornerRadius(16)
      .accessibilityElement(children: .combine)
    }
  }

  private var detail: String? {
    switch state {
    case .confirmationRequired(_, let message),
         .unavailable(_, let message):
      return message
    case .fallback(_, _, let reason):
      return reason
    case .idle, .recognized, .routing, .active:
      return nil
    }
  }

  private var iconName: String {
    switch state {
    case .active: return "checkmark.circle.fill"
    case .recognized, .routing: return "arrow.triangle.branch"
    case .confirmationRequired: return "checkmark.shield.fill"
    case .fallback: return "arrow.uturn.right.circle.fill"
    case .unavailable: return "exclamationmark.triangle.fill"
    case .idle: return "circle"
    }
  }

  private var iconColor: Color {
    switch state {
    case .active: return .green
    case .recognized, .routing: return .yellow
    case .confirmationRequired, .fallback: return .orange
    case .unavailable: return .red
    case .idle: return .gray
    }
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
