import SwiftUI

struct GeminiStatusBar: View {
  @ObservedObject var geminiVM: GeminiSessionViewModel

  var body: some View {
    HStack(spacing: 8) {
      StatusPill(color: geminiStatusColor, text: geminiStatusText)
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

struct GeminiAssistantOverlay: View {
  @ObservedObject var geminiVM: GeminiSessionViewModel
  let onToggle: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .center, spacing: 10) {
        GeminiStatusBar(geminiVM: geminiVM)
        Spacer(minLength: 0)
        Button(action: onToggle) {
          Text(geminiVM.isGeminiActive ? "STOP AI" : "START AI")
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.68))
            .overlay(
              RoundedRectangle(cornerRadius: 14)
                .stroke(Color.white.opacity(0.2), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
      }

      if !geminiVM.userTranscript.isEmpty || !geminiVM.aiTranscript.isEmpty {
        TranscriptView(userText: geminiVM.userTranscript, aiText: geminiVM.aiTranscript)
      }

      HStack(spacing: 10) {
        if geminiVM.isModelSpeaking {
          SpeakingIndicator()
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.55))
            .cornerRadius(16)
        }
        Spacer(minLength: 0)
      }

      if let errorMessage = geminiVM.errorMessage, !errorMessage.isEmpty {
        Text(errorMessage)
          .font(.system(size: 12, weight: .medium))
          .foregroundColor(.white)
          .padding(.horizontal, 14)
          .padding(.vertical, 10)
          .background(Color.red.opacity(0.28))
          .cornerRadius(12)
      }
    }
    .padding(.horizontal, 16)
    .padding(.top, 18)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
