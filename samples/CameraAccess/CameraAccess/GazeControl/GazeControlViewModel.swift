import Foundation
import SwiftUI

enum GazeMode: String {
  case connecting
  case tracking
  case noMatch
  case dragging
}

@MainActor
class GazeControlViewModel: ObservableObject {
  @Published var isActive = false
  @Published var mode: GazeMode = .connecting
  @Published var gazeScreenPoint: CGPoint?
  @Published var isDragging = false
  @Published var errorMessage: String?
  @Published var matchCount: Int = 0
  @Published var confidence: Double = 0.0

  let cursorBridge = CursorControlBridge()

  private var lastSendTime: Date = .distantPast
  private var smoothedPoint: CGPoint?
  private var isLocateInFlight = false

  // MARK: - Session Control

  func startSession() async {
    isActive = true
    mode = .connecting
    gazeScreenPoint = nil
    smoothedPoint = nil
    matchCount = 0
    confidence = 0.0

    await cursorBridge.checkConnection()

    if cursorBridge.connectionState != .connected {
      errorMessage = "Cannot reach cursor server at \(GazeConfig.cursorServerBaseURL)"
      isActive = false
      return
    }

    mode = .tracking
    NSLog("[GazeControl] Session started (server-side matching)")
  }

  func stopSession() {
    if isDragging, let pt = smoothedPoint {
      cursorBridge.mouseUp(at: pt)
      isDragging = false
    }
    isActive = false
    mode = .connecting
    gazeScreenPoint = nil
    smoothedPoint = nil
    isLocateInFlight = false
    matchCount = 0
    confidence = 0.0
    NSLog("[GazeControl] Session stopped")
  }

  // MARK: - Frame Processing

  func processFrame(_ image: UIImage) {
    guard isActive, !isLocateInFlight else { return }

    let now = Date()
    guard now.timeIntervalSince(lastSendTime) >= GazeConfig.gazeUpdateInterval else { return }
    lastSendTime = now

    guard let jpegData = image.jpegData(compressionQuality: GazeConfig.locateJpegQuality) else { return }

    isLocateInFlight = true

    Task {
      let result = await cursorBridge.locateGaze(imageData: jpegData)

      await MainActor.run {
        self.isLocateInFlight = false

        guard let result = result else {
          self.mode = self.isDragging ? .dragging : .noMatch
          return
        }

        self.matchCount = result.matchCount
        self.confidence = result.confidence

        if let point = result.point {
          self.mode = self.isDragging ? .dragging : .tracking
          self.applySmoothedPoint(point)
        } else {
          if !self.isDragging {
            self.mode = .noMatch
          }
        }
      }
    }
  }

  // MARK: - Drag Mode

  func toggleDrag() {
    guard mode == .tracking || mode == .dragging else { return }

    if isDragging {
      if let pt = smoothedPoint {
        cursorBridge.mouseUp(at: pt)
      }
      isDragging = false
      mode = .tracking
      NSLog("[GazeControl] Drag released")
    } else {
      if let pt = smoothedPoint {
        cursorBridge.mouseDown(at: pt)
        isDragging = true
        mode = .dragging
        NSLog("[GazeControl] Drag started at %.0f, %.0f", pt.x, pt.y)
      }
    }
  }

  func triggerClick() {
    guard mode == .tracking, let pt = smoothedPoint else { return }
    cursorBridge.click(at: pt)
    NSLog("[GazeControl] Click at %.0f, %.0f", pt.x, pt.y)
  }

  // MARK: - Internal

  private func applySmoothedPoint(_ raw: CGPoint) {
    let screenSize = cursorBridge.remoteScreenSize ?? CGSize(width: 1920, height: 1080)
    let clamped = CGPoint(
      x: max(0, min(screenSize.width, raw.x)),
      y: max(0, min(screenSize.height, raw.y))
    )

    if let prev = smoothedPoint {
      let alpha = GazeConfig.smoothingFactor
      smoothedPoint = CGPoint(
        x: prev.x + alpha * (clamped.x - prev.x),
        y: prev.y + alpha * (clamped.y - prev.y)
      )
    } else {
      smoothedPoint = clamped
    }

    gazeScreenPoint = smoothedPoint

    guard let point = smoothedPoint else { return }

    if isDragging {
      cursorBridge.mouseDragTo(point)
    } else {
      cursorBridge.moveCursor(to: point)
    }
  }
}
