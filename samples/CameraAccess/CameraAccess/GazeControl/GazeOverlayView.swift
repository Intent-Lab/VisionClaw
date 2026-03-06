import SwiftUI

struct GazeStatusBar: View {
  @ObservedObject var gazeVM: GazeControlViewModel

  var body: some View {
    HStack(spacing: 8) {
      StatusPill(color: serverStatusColor, text: serverStatusText)
      StatusPill(color: matchColor, text: matchText)

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

  private var matchColor: Color {
    switch gazeVM.mode {
    case .tracking, .dragging: return .green
    case .noMatch: return .red
    case .connecting: return .gray
    case .calibrating: return .blue
    }
  }

  private var matchText: String {
    if gazeVM.mode == .calibrating {
      return "Cal \(gazeVM.calibrationPointIndex + 1)/\(gazeVM.calibrationTotalPoints)"
    }
    if gazeVM.matchCount > 0 {
      return "\(gazeVM.matchCount)pt"
    }
    if !gazeVM.isCalibrated {
      return "Not Calibrated"
    }
    return "No Match"
  }
}

struct GazeOverlayView: View {
  @ObservedObject var gazeVM: GazeControlViewModel

  var body: some View {
    VStack {
      GazeStatusBar(gazeVM: gazeVM)

      if gazeVM.mode == .calibrating {
        Spacer()
        VStack(spacing: 8) {
          Text("Calibrating: Look at the red dot on screen")
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(.white)
          Text("Point \(gazeVM.calibrationPointIndex + 1) of \(gazeVM.calibrationTotalPoints)")
            .font(.system(size: 12, design: .monospaced))
            .foregroundColor(.white.opacity(0.7))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.7))
        .cornerRadius(12)
        Spacer()
      } else {
        Spacer()

        VStack(spacing: 6) {
          if gazeVM.mode == .noMatch && gazeVM.isCalibrated {
            Text("No anchor match")
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
        .padding(.bottom, 120)
      }
    }
    .padding(.all, 24)
  }
}

struct GazeControlButtons: View {
  @ObservedObject var gazeVM: GazeControlViewModel

  var body: some View {
    if gazeVM.isActive {
      HStack(spacing: 8) {
        if gazeVM.mode == .calibrating {
          CircleButton(icon: "camera.fill", text: "Capture") {
            Task { await gazeVM.captureCalibrationPoint() }
          }
          CircleButton(icon: "xmark", text: "Cancel") {
            Task { await gazeVM.cancelCalibration() }
          }
        } else if gazeVM.mode == .tracking || gazeVM.mode == .dragging || gazeVM.mode == .noMatch {
          CircleButton(icon: "scope", text: "Calibrate") {
            Task { await gazeVM.startCalibration() }
          }

          CircleButton(icon: "hand.tap.fill", text: "Tap") {
            gazeVM.triggerClick()
          }

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
}
