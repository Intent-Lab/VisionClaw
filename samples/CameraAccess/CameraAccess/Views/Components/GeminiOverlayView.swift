import SwiftUI

struct GeminiStatusBar: View {
  @ObservedObject var geminiVM: GeminiSessionViewModel

  var body: some View {
    HStack(spacing: 8) {
      // Gemini connection pill
      StatusPill(color: geminiStatusColor, text: geminiStatusText)

      // OpenClaw connection pill
      StatusPill(color: openClawStatusColor, text: openClawStatusText)
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

// MARK: - Meeting Mode Components

struct MeetingOverlay: View {
  @ObservedObject var geminiVM: GeminiSessionViewModel
  private let timeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm"
    return f
  }()

  var body: some View {
    VStack(spacing: 0) {
      // Top bar: meeting pill + status
      HStack(spacing: 8) {
        MeetingModePill()
        GeminiStatusBar(geminiVM: geminiVM)
        Spacer()
      }
      .padding(.horizontal, 16)
      .padding(.top, 16)

      // Live transcript scroll area
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 8) {
            ForEach(geminiVM.meetingLines) { line in
              HStack(alignment: .top, spacing: 8) {
                Text(timeFormatter.string(from: line.time))
                  .font(.system(size: 11, design: .monospaced))
                  .foregroundColor(.white.opacity(0.4))
                  .frame(width: 40, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                  Text(line.speaker)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(line.speaker == "Notes" ? .orange : .cyan)
                  Text(line.text)
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.9))
                }
              }
              .id(line.id)
            }
          }
          .padding(.horizontal, 16)
          .padding(.vertical, 8)
        }
        .onChange(of: geminiVM.meetingLines.count) { _ in
          if let last = geminiVM.meetingLines.last {
            withAnimation {
              proxy.scrollTo(last.id, anchor: .bottom)
            }
          }
        }
      }

      // Bottom hint
      if geminiVM.meetingLines.isEmpty {
        VStack(spacing: 12) {
          Spacer()
          Image(systemName: "mic.fill")
            .font(.system(size: 36))
            .foregroundColor(.orange.opacity(0.5))
          Text("Listening...")
            .font(.system(size: 18, weight: .semibold))
            .foregroundColor(.orange.opacity(0.7))
          Text("Speak naturally. Notes will appear here.")
            .font(.system(size: 14))
            .foregroundColor(.white.opacity(0.4))
          Spacer()
        }
      }

      Spacer(minLength: 0)
    }
    .padding(.bottom, 80)
  }
}

struct MeetingModePill: View {
  @State private var pulsing = false

  var body: some View {
    HStack(spacing: 6) {
      Circle()
        .fill(Color.orange)
        .frame(width: 8, height: 8)
        .scaleEffect(pulsing ? 1.3 : 1.0)
        .animation(
          .easeInOut(duration: 1.0).repeatForever(autoreverses: true),
          value: pulsing
        )
      Image(systemName: "note.text")
        .font(.system(size: 10))
        .foregroundColor(.orange)
      Text("Meeting")
        .font(.system(size: 12, weight: .semibold))
        .foregroundColor(.orange)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .background(Color.orange.opacity(0.15))
    .cornerRadius(16)
    .overlay(
      RoundedRectangle(cornerRadius: 16)
        .stroke(Color.orange.opacity(0.4), lineWidth: 1)
    )
    .onAppear { pulsing = true }
  }
}

struct MeetingModeButton: View {
  @ObservedObject var geminiVM: GeminiSessionViewModel

  private var isMeeting: Bool { geminiVM.sessionMode == .meeting }

  var body: some View {
    Button(action: {
      Task {
        if geminiVM.isGeminiActive && isMeeting {
          geminiVM.stopSession()
        } else if !geminiVM.isGeminiActive {
          await geminiVM.startMeetingSession()
        }
      }
    }) {
      VStack(spacing: 2) {
        Image(systemName: isMeeting ? "note.text.badge.plus" : "note.text")
          .font(.system(size: 14))
        Text("Meet")
          .font(.system(size: 10, weight: .medium))
      }
    }
    .foregroundColor(isMeeting ? .white : .black)
    .frame(width: 56, height: 56)
    .background(isMeeting ? Color.orange : .white)
    .clipShape(Circle())
    // Disable if another session mode is already active
    .opacity(geminiVM.isGeminiActive && !isMeeting ? 0.4 : 1.0)
    .disabled(geminiVM.isGeminiActive && !isMeeting)
  }
}
