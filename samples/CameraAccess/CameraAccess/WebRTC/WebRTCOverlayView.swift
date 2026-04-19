import SwiftUI

struct WebRTCStatusBar: View {
  @ObservedObject var webrtcVM: WebRTCSessionViewModel

  var body: some View {
    HStack(spacing: 8) {
      StatusPill(color: statusColor, text: statusText)

      if !webrtcVM.roomCode.isEmpty {
        RoomCodePill(code: webrtcVM.roomCode)
      }

      if webrtcVM.connectionState == .connected {
        StatusPill(
          color: webrtcVM.isMuted ? .red : .green,
          text: webrtcVM.isMuted ? "Muted" : "Mic On"
        )
      }

      if webrtcVM.isCollaborativeMode {
        CollaborativeBadge()
      }
    }
  }

  private var statusColor: Color {
    switch webrtcVM.connectionState {
    case .connected: return .green
    case .connecting, .waitingForPeer: return .yellow
    case .backgrounded: return .orange
    case .error: return .red
    case .disconnected: return .gray
    }
  }

  private var statusText: String {
    switch webrtcVM.connectionState {
    case .connected: return "Live"
    case .connecting: return "Connecting..."
    case .waitingForPeer: return "Waiting..."
    case .backgrounded: return "Paused"
    case .error: return "Error"
    case .disconnected: return "Off"
    }
  }
}

struct CollaborativeBadge: View {
  var body: some View {
    HStack(spacing: 4) {
      Image(systemName: "person.2.fill")
        .font(.system(size: 10, weight: .bold))
        .foregroundColor(.cyan)
      Text("Collab")
        .font(.system(size: 11, weight: .semibold))
        .foregroundColor(.white)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 5)
    .background(Color.cyan.opacity(0.3))
    .cornerRadius(12)
  }
}

struct RoomCodePill: View {
  let code: String
  @State private var showCopied: Bool = false

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: showCopied ? "checkmark" : "doc.on.doc")
        .font(.system(size: 10))
        .foregroundColor(showCopied ? .green : .white)
      Text(showCopied ? "Copied" : code)
        .font(.system(size: 14, weight: .bold, design: .monospaced))
        .foregroundColor(.white)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .background(Color.black.opacity(0.6))
    .cornerRadius(16)
    .onTapGesture {
      UIPasteboard.general.string = code
      showCopied = true
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
        showCopied = false
      }
    }
  }
}
