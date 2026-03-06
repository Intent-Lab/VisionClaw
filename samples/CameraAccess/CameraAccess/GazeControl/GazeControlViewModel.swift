import Foundation
import SwiftUI

enum GazeMode: String {
  case calibrating
  case tracking
  case dragging
}

@MainActor
class GazeControlViewModel: ObservableObject {
  @Published var isActive = false
  @Published var mode: GazeMode = .calibrating
  @Published var calibrationCount = 0  // 0-4 markers detected
  @Published var gazeScreenPoint: CGPoint?  // Current estimated screen position
  @Published var isDragging = false
  @Published var errorMessage: String?

  let cursorBridge = CursorControlBridge()

  private let markerDetector = MarkerDetectionService()
  private let homography = HomographyService()
  private var lastSendTime: Date = .distantPast
  private var smoothedPoint: CGPoint?
  private var dragStartPoint: CGPoint?

  // Progressive calibration: accumulate markers seen across frames
  private var accumulatedMarkers: [String: CGPoint] = [:]

  // MARK: - Session Control

  func startSession() async {
    isActive = true
    mode = .calibrating
    calibrationCount = 0
    gazeScreenPoint = nil
    smoothedPoint = nil
    accumulatedMarkers = [:]
    homography.reset()

    await cursorBridge.checkConnection()

    if cursorBridge.connectionState != .connected {
      errorMessage = "Cannot reach cursor server at \(GazeConfig.cursorServerBaseURL)"
      isActive = false
      return
    }

    NSLog("[GazeControl] Session started, awaiting calibration")
  }

  func stopSession() {
    if isDragging, let pt = smoothedPoint {
      cursorBridge.mouseUp(at: pt)
      isDragging = false
    }
    isActive = false
    mode = .calibrating
    calibrationCount = 0
    gazeScreenPoint = nil
    smoothedPoint = nil
    accumulatedMarkers = [:]
    homography.reset()
    NSLog("[GazeControl] Session stopped")
  }

  // MARK: - Frame Processing

  func processFrame(_ image: UIImage) {
    guard isActive else { return }

    // Throttle frame processing
    let now = Date()
    guard now.timeIntervalSince(lastSendTime) >= GazeConfig.gazeUpdateInterval else { return }
    lastSendTime = now

    let result = markerDetector.detectMarkers(in: image)

    // Progressive calibration: accumulate markers seen across multiple frames
    // (camera FOV is too narrow to see all 4 corners at once)
    for (id, marker) in result.markers {
      accumulatedMarkers[id] = marker.center
    }

    calibrationCount = accumulatedMarkers.count

    if accumulatedMarkers.count == 4 {
      // All 4 markers have been seen (possibly across different frames)
      updateCalibration(accumulatedMarkers)
      updateGazePoint(image: image)
    } else if mode != .calibrating {
      // Already calibrated — keep tracking with last known homography
      if homography.isCalibrated {
        updateGazePoint(image: image)
      }
    }
  }

  // MARK: - Drag Mode

  func toggleDrag() {
    guard mode == .tracking || mode == .dragging else { return }

    if isDragging {
      // Release drag
      if let pt = smoothedPoint {
        cursorBridge.mouseUp(at: pt)
      }
      isDragging = false
      mode = .tracking
      NSLog("[GazeControl] Drag released")
    } else {
      // Start drag
      if let pt = smoothedPoint {
        cursorBridge.mouseDown(at: pt)
        dragStartPoint = pt
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

  private func updateCalibration(_ centers: [String: CGPoint]) {
    guard let screenSize = cursorBridge.remoteScreenSize else {
      NSLog("[GazeControl] No screen size from server yet")
      return
    }

    if homography.calibrate(markerCenters: centers, screenSize: screenSize) {
      if mode == .calibrating {
        mode = .tracking
        NSLog("[GazeControl] Calibrated for %.0fx%.0f screen", screenSize.width, screenSize.height)
      }
    }
  }

  private func updateGazePoint(image: UIImage) {
    guard homography.isCalibrated else { return }

    // The "gaze point" is the center of the camera frame
    // In normalized image coordinates (0..1, origin top-left):
    // center = (0.5, 0.5)
    let frameCenter = CGPoint(x: 0.5, y: 0.5)

    guard let screenPoint = homography.mapPoint(frameCenter) else { return }

    // Clamp to screen bounds
    let screenSize = cursorBridge.remoteScreenSize ?? CGSize(width: 1920, height: 1080)
    let clampedX = max(0, min(screenSize.width, screenPoint.x))
    let clampedY = max(0, min(screenSize.height, screenPoint.y))
    let clamped = CGPoint(x: clampedX, y: clampedY)

    // Exponential moving average for smoothing
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

    // Send to Mac
    guard let point = smoothedPoint else { return }

    if isDragging {
      cursorBridge.mouseDragTo(point)
    } else {
      cursorBridge.moveCursor(to: point)
    }
  }
}
