import SwiftUI

// MARK: - Golf Overlay (full overlay shown during golf session)

struct GolfOverlay: View {
  @ObservedObject var geminiVM: GeminiSessionViewModel

  var body: some View {
    VStack(spacing: 0) {
      // Top bar: golf pill + status + score badge
      HStack(spacing: 8) {
        GolfModePill()
        GeminiStatusBar(geminiVM: geminiVM)
        Spacer()
        if let state = geminiVM.golfState {
          ScoreToParBadge(scoreToPar: state.scoreToPar, thruHole: state.currentHole > 1 ? state.currentHole - 1 : 0)
        }
      }
      .padding(.horizontal, 16)
      .padding(.top, 16)

      Spacer()

      // Transcript + tool status + speaking indicator
      VStack(spacing: 8) {
        if !geminiVM.userTranscript.isEmpty || !geminiVM.aiTranscript.isEmpty {
          TranscriptView(
            userText: geminiVM.userTranscript,
            aiText: geminiVM.aiTranscript
          )
        }

        ToolCallStatusView(status: geminiVM.toolCallStatus)

        if geminiVM.isModelSpeaking {
          HStack(spacing: 8) {
            Image(systemName: "speaker.wave.2.fill")
              .foregroundColor(.white)
              .font(.system(size: 14))
            SpeakingIndicator()
          }
          .padding(.horizontal, 16)
          .padding(.vertical, 8)
          .background(Color.black.opacity(0.5))
          .cornerRadius(20)
        }
      }

      // Bottom HUD: hole info card
      if let state = geminiVM.golfState {
        GolfHoleCard(state: state)
          .padding(.horizontal, 16)
          .padding(.top, 8)
      }

      Spacer(minLength: 0)
    }
    .padding(.bottom, 80)
    .padding(.horizontal, 8)
  }
}

// MARK: - Golf Mode Pill (green pulsing indicator)

struct GolfModePill: View {
  @State private var pulsing = false

  var body: some View {
    HStack(spacing: 6) {
      Circle()
        .fill(Color.green)
        .frame(width: 8, height: 8)
        .scaleEffect(pulsing ? 1.3 : 1.0)
        .animation(
          .easeInOut(duration: 1.0).repeatForever(autoreverses: true),
          value: pulsing
        )
      Image(systemName: "flag.fill")
        .font(.system(size: 10))
        .foregroundColor(.green)
      Text("Golf")
        .font(.system(size: 12, weight: .semibold))
        .foregroundColor(.green)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .background(Color.green.opacity(0.15))
    .cornerRadius(16)
    .overlay(
      RoundedRectangle(cornerRadius: 16)
        .stroke(Color.green.opacity(0.4), lineWidth: 1)
    )
    .onAppear { pulsing = true }
  }
}

// MARK: - Score To Par Badge (top-right corner)

struct ScoreToParBadge: View {
  let scoreToPar: Int
  let thruHole: Int

  private var scoreText: String {
    if scoreToPar == 0 { return "E" }
    return scoreToPar > 0 ? "+\(scoreToPar)" : "\(scoreToPar)"
  }

  private var scoreColor: Color {
    if scoreToPar < 0 { return .red }
    if scoreToPar == 0 { return .white }
    return .yellow
  }

  var body: some View {
    VStack(spacing: 1) {
      Text(scoreText)
        .font(.system(size: 20, weight: .bold, design: .rounded))
        .foregroundColor(scoreColor)
      if thruHole > 0 {
        Text("thru \(thruHole)")
          .font(.system(size: 10, weight: .medium))
          .foregroundColor(.white.opacity(0.6))
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .background(Color.black.opacity(0.7))
    .cornerRadius(12)
  }
}

// MARK: - Golf Hole Card (bottom HUD)

struct GolfHoleCard: View {
  let state: GolfState

  var body: some View {
    HStack(spacing: 0) {
      cardItem(label: "HOLE", value: "\(state.currentHole)")
      divider
      cardItem(label: "PAR", value: state.par > 0 ? "\(state.par)" : "—")
      divider
      cardItem(label: "WIND", value: state.wind.isEmpty ? "—" : state.wind)
      divider
      cardItem(label: "LAST", value: state.lastClub.isEmpty ? "—" : state.lastClub)
    }
    .background(Color.black.opacity(0.75))
    .cornerRadius(14)
    .overlay(
      RoundedRectangle(cornerRadius: 14)
        .stroke(Color.green.opacity(0.3), lineWidth: 1)
    )
  }

  private func cardItem(label: String, value: String) -> some View {
    VStack(spacing: 3) {
      Text(label)
        .font(.system(size: 9, weight: .semibold))
        .foregroundColor(.green.opacity(0.7))
      Text(value)
        .font(.system(size: 16, weight: .bold, design: .rounded))
        .foregroundColor(.white)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 10)
  }

  private var divider: some View {
    Rectangle()
      .fill(Color.white.opacity(0.15))
      .frame(width: 1, height: 30)
  }
}

// MARK: - Golf Mode Button (for controls bar)

struct GolfModeButton: View {
  @ObservedObject var geminiVM: GeminiSessionViewModel

  var body: some View {
    Button(action: {
      Task {
        if geminiVM.isGeminiActive && geminiVM.sessionMode == .golf {
          geminiVM.stopSession()
        } else if !geminiVM.isGeminiActive {
          await geminiVM.startGolfSession()
        }
      }
    }) {
      VStack(spacing: 2) {
        Image(systemName: geminiVM.sessionMode == .golf ? "flag.circle.fill" : "flag.circle")
          .font(.system(size: 14))
        Text("Golf")
          .font(.system(size: 10, weight: .medium))
      }
    }
    .foregroundColor(geminiVM.sessionMode == .golf ? .white : .black)
    .frame(width: 56, height: 56)
    .background(geminiVM.sessionMode == .golf ? Color.green : .white)
    .clipShape(Circle())
    .opacity(geminiVM.isGeminiActive && geminiVM.sessionMode != .golf ? 0.4 : 1.0)
    .disabled(geminiVM.isGeminiActive && geminiVM.sessionMode != .golf)
  }
}
