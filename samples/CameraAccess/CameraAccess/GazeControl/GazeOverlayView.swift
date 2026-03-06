import SwiftUI

struct GazeStatusBar: View {
  @ObservedObject var gazeVM: GazeControlViewModel

  var body: some View {
    HStack(spacing: 8) {
      StatusPill(color: serverStatusColor, text: serverStatusText)
      StatusPill(color: calibrationColor, text: calibrationText)

      if gazeVM.mode == .dragging {
        StatusPill(color: .orange, text: "Dragging")
      }
    }
  }

  private var serverStatusColor: Color {
    switch gazeVM.cursorBridge.connectionState {
    case .connected: return .green
    case .checking: return .yellow
    case .unreachable: return .red
    case .disconnected: return .gray
    }
  }

  private var serverStatusText: String {
    switch gazeVM.cursorBridge.connectionState {
    case .connected: return "Cursor"
    case .checking: return "Cursor..."
    case .unreachable: return "Cursor Off"
    case .disconnected: return "No Cursor"
    }
  }

  private var calibrationColor: Color {
    switch gazeVM.calibrationCount {
    case 4: return .green
    case 1...3: return .yellow
    default: return .gray
    }
  }

  private var calibrationText: String {
    "\(gazeVM.calibrationCount)/4"
  }
}

struct GazeOverlayView: View {
  @ObservedObject var gazeVM: GazeControlViewModel

  var body: some View {
    VStack {
      GazeStatusBar(gazeVM: gazeVM)
      Spacer()

      // Mode and coordinate info
      VStack(spacing: 6) {
        if gazeVM.mode == .calibrating {
          Text("Slowly scan across the screen corners")
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.6))
            .cornerRadius(12)
        }

        if let point = gazeVM.gazeScreenPoint {
          Text("(\(Int(point.x)), \(Int(point.y)))")
            .font(.system(size: 12, design: .monospaced))
            .foregroundColor(.white.opacity(0.7))
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(Color.black.opacity(0.5))
            .cornerRadius(8)
        }
      }
      .padding(.bottom, 80)
    }
    .padding(.all, 24)
  }
}

struct GazeControlButtons: View {
  @ObservedObject var gazeVM: GazeControlViewModel

  var body: some View {
    if gazeVM.isActive && gazeVM.mode != .calibrating {
      HStack(spacing: 8) {
        // Click button
        CircleButton(icon: "hand.tap.fill", text: "Tap") {
          gazeVM.triggerClick()
        }

        // Drag toggle button
        CircleButton(
          icon: gazeVM.isDragging ? "hand.raised.fill" : "hand.draw.fill",
          text: gazeVM.isDragging ? "Drop" : "Grab"
        ) {
          gazeVM.toggleDrag()
        }
      }
    }
  }
}
