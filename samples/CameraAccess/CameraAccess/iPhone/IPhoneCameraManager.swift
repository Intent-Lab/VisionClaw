import AVFoundation
import UIKit

private struct SendablePixelBuffer: @unchecked Sendable {
  let pixelBuffer: CVPixelBuffer
}

class IPhoneCameraManager: NSObject, @unchecked Sendable {
  private let captureSession = AVCaptureSession()
  private let videoOutput = AVCaptureVideoDataOutput()
  private let movieOutput = AVCaptureMovieFileOutput()
  private let sessionQueue = DispatchQueue(label: "iphone-camera-session")
  private let analysisQueue = DispatchQueue(label: "iphone-camera-analysis", qos: .userInitiated)
  private let context = CIContext()
  private var isRunning = false
  private var isConfigured = false
  private var isAudioInputConfigured = false
  private var recordingCompletion: ((URL?) -> Void)?
  private var currentRecordingURL: URL?
  private var lastAnalysisEmissionAt: CFTimeInterval = 0
  private var isAnalysisConversionInFlight = false
  private var sampleFrameCount: Int64 = 0
  private var analysisFrameCount: Int64 = 0
  private var statsWindowStart = CACurrentMediaTime()
  private var hasDeliveredFirstPreviewFrame = false

  var onFrameCaptured: ((UIImage) -> Void)?
  var onSampleBufferCaptured: ((CMSampleBuffer) -> Void)?
  var onFirstPreviewFrame: (() -> Void)?
  var analysisFrameInterval: CFTimeInterval = 0.2
  var analysisMaxDimension: CGFloat = 720
  var previewSession: AVCaptureSession { captureSession }

  func start() {
    guard !isRunning else { return }
    sessionQueue.async { [weak self] in
      NSLog("[iPhoneCamera] start() requested")
      self?.sampleFrameCount = 0
      self?.analysisFrameCount = 0
      self?.statsWindowStart = CACurrentMediaTime()
      self?.lastAnalysisEmissionAt = 0
      self?.isAnalysisConversionInFlight = false
      self?.hasDeliveredFirstPreviewFrame = false
      self?.configureSession()
      self?.captureSession.startRunning()
      self?.isRunning = true
      let sessionRunning = self?.captureSession.isRunning == true
      Task {
        await WorkerTelemetry.shared.record(
          "iphone_camera_start",
          source: "ios_app",
          stage: "camera",
          payload: ["session_running": sessionRunning]
        )
      }
      NSLog("[iPhoneCamera] captureSession.startRunning() complete (isRunning=%@, sessionRunning=%@)",
            self?.isRunning == true ? "true" : "false",
            self?.captureSession.isRunning == true ? "true" : "false")
    }
  }

  func startRecording(sessionID: String) {
    sessionQueue.async { [weak self] in
      guard let self else { return }
      self.configureSession()

      NSLog(
        "[iPhoneCamera] startRecording requested (sessionConfigured=%@, sessionRunning=%@, alreadyRecording=%@)",
        self.isConfigured ? "true" : "false",
        self.captureSession.isRunning ? "true" : "false",
        self.movieOutput.isRecording ? "true" : "false")

      if let attributes = try? FileManager.default.attributesOfFileSystem(forPath: FileManager.default.temporaryDirectory.path),
         let freeSize = attributes[.systemFreeSize] as? NSNumber {
        NSLog("[iPhoneCamera] Free disk space before recording: %@ bytes", freeSize)
      }

      guard self.captureSession.isRunning else {
        NSLog("[iPhoneCamera] Cannot start recording because capture session is not running")
        return
      }
      guard !self.movieOutput.isRecording else {
        NSLog("[iPhoneCamera] Ignoring startRecording because movie output is already recording")
        return
      }

      let fileURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("sop_\(sessionID)")
        .appendingPathExtension("mp4")
      try? FileManager.default.removeItem(at: fileURL)
      self.currentRecordingURL = fileURL

      self.movieOutput.startRecording(to: fileURL, recordingDelegate: self)
      Task {
        await WorkerTelemetry.shared.record(
          "iphone_recording_start",
          source: "ios_app",
          stage: "recording",
          sessionID: sessionID,
          payload: [
            "file_extension": fileURL.pathExtension,
            "disk_free_checked": true
          ]
        )
      }
      NSLog("[iPhoneCamera] Started recording SOP video: %@", fileURL.path)
    }
  }

  func stopRecording() async -> URL? {
    await withCheckedContinuation { continuation in
      sessionQueue.async { [weak self] in
        guard let self else {
          continuation.resume(returning: nil)
          return
        }

        NSLog(
          "[iPhoneCamera] stopRecording requested (isRecording=%@, currentRecordingURL=%@)",
          self.movieOutput.isRecording ? "true" : "false",
          self.currentRecordingURL?.path ?? "nil")

        guard self.movieOutput.isRecording else {
          NSLog("[iPhoneCamera] stopRecording returning currentRecordingURL immediately because movieOutput.isRecording=false")
          continuation.resume(returning: self.currentRecordingURL)
          return
        }

        self.recordingCompletion = { url in
          NSLog("[iPhoneCamera] stopRecording completion fired with URL=%@", url?.path ?? "nil")
          continuation.resume(returning: url)
        }
        self.movieOutput.stopRecording()
        NSLog("[iPhoneCamera] movieOutput.stopRecording() called")
      }
    }
  }

  func stop() {
    guard isRunning else { return }
    sessionQueue.async { [weak self] in
      NSLog("[iPhoneCamera] stop() requested")
      self?.captureSession.stopRunning()
      self?.isRunning = false
      Task {
        await WorkerTelemetry.shared.record(
          "iphone_camera_stop",
          source: "ios_app",
          stage: "camera"
        )
      }
      NSLog("[iPhoneCamera] captureSession.stopRunning() complete")
    }
  }

  private func configureSession() {
    guard !isConfigured else { return }

    captureSession.beginConfiguration()
    captureSession.sessionPreset = .iFrame960x540

    // Add back camera input
    guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
          let input = try? AVCaptureDeviceInput(device: camera) else {
      NSLog("[iPhoneCamera] Failed to access back camera")
      captureSession.commitConfiguration()
      return
    }

    if captureSession.canAddInput(input) {
      captureSession.addInput(input)
    }

    if let microphone = AVCaptureDevice.default(for: .audio),
       let audioInput = try? AVCaptureDeviceInput(device: microphone),
       captureSession.canAddInput(audioInput) {
      captureSession.addInput(audioInput)
      isAudioInputConfigured = true
    } else {
      isAudioInputConfigured = false
      NSLog("[iPhoneCamera] Microphone input unavailable for recording")
    }

    // Add video output
    videoOutput.videoSettings = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ]
    videoOutput.setSampleBufferDelegate(self, queue: sessionQueue)
    videoOutput.alwaysDiscardsLateVideoFrames = true

    if captureSession.canAddOutput(videoOutput) {
      captureSession.addOutput(videoOutput)
    }

    // Add movie output for full-session recording.
    if captureSession.canAddOutput(movieOutput) {
      captureSession.addOutput(movieOutput)
    }

    // Force portrait-oriented frames from the sensor
    if let connection = videoOutput.connection(with: .video) {
      if connection.isVideoRotationAngleSupported(90) {
        connection.videoRotationAngle = 90
      }
    }

    if let movieConnection = movieOutput.connection(with: .video) {
      if movieConnection.isVideoRotationAngleSupported(90) {
        movieConnection.videoRotationAngle = 90
      }
    }

    captureSession.commitConfiguration()
    isConfigured = true
    NSLog("[iPhoneCamera] Session configured successfully")
  }

  func waitUntilRunningAndAudioConfigured(timeout: TimeInterval) async -> Bool {
    let deadline = CACurrentMediaTime() + max(0, timeout)
    while !Task.isCancelled {
      let ready = await withCheckedContinuation { continuation in
        sessionQueue.async { [weak self] in
          guard let self else {
            continuation.resume(returning: false)
            return
          }
          continuation.resume(
            returning: self.isConfigured &&
              self.isRunning &&
              self.captureSession.isRunning &&
              self.isAudioInputConfigured
          )
        }
      }
      if ready { return true }
      if CACurrentMediaTime() >= deadline { return false }
      try? await Task.sleep(nanoseconds: 100_000_000)
    }
    return false
  }

  static func requestPermission() async -> Bool {
    let status = AVCaptureDevice.authorizationStatus(for: .video)
    switch status {
    case .authorized:
      return true
    case .notDetermined:
      return await AVCaptureDevice.requestAccess(for: .video)
    default:
      return false
    }
  }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension IPhoneCameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
  func captureOutput(
    _ output: AVCaptureOutput,
    didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    sampleFrameCount += 1
    onSampleBufferCaptured?(sampleBuffer)

    if !hasDeliveredFirstPreviewFrame {
      hasDeliveredFirstPreviewFrame = true
      let onFirstPreviewFrame = onFirstPreviewFrame
      DispatchQueue.main.async {
        onFirstPreviewFrame?()
      }
    }

    logCaptureStatsIfNeeded()

    guard onFrameCaptured != nil else { return }

    let now = CACurrentMediaTime()
    guard now - lastAnalysisEmissionAt >= analysisFrameInterval else { return }
    guard !isAnalysisConversionInFlight else { return }
    lastAnalysisEmissionAt = now
    isAnalysisConversionInFlight = true

    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
      isAnalysisConversionInFlight = false
      return
    }
    analysisFrameCount += 1
    let frameHandler = onFrameCaptured
    let maxDimension = analysisMaxDimension
    let analysisPixelBuffer = SendablePixelBuffer(pixelBuffer: pixelBuffer)
    analysisQueue.async { [weak self] in
      let image = self?.makeUIImage(from: analysisPixelBuffer.pixelBuffer, maxDimension: maxDimension)
      self?.sessionQueue.async { [weak self] in
        self?.isAnalysisConversionInFlight = false
      }
      guard let image else { return }
      frameHandler?(image)
    }
  }
}

extension IPhoneCameraManager: AVCaptureFileOutputRecordingDelegate {
  func fileOutput(
    _ output: AVCaptureFileOutput,
    didStartRecordingTo fileURL: URL,
    from connections: [AVCaptureConnection]
  ) {
    NSLog("[iPhoneCamera] didStartRecordingTo fired for %@", fileURL.path)
  }

  func fileOutput(
    _ output: AVCaptureFileOutput,
    didFinishRecordingTo outputFileURL: URL,
    from connections: [AVCaptureConnection],
    error: Error?
  ) {
    if let error {
      NSLog("[iPhoneCamera] Recording failed: %@", error.localizedDescription)
    } else {
      NSLog("[iPhoneCamera] Recording finished: %@", outputFileURL.path)
    }

    if let attributes = try? FileManager.default.attributesOfItem(atPath: outputFileURL.path),
       let fileSize = attributes[.size] as? NSNumber {
      NSLog("[iPhoneCamera] Recorded file size: %@ bytes", fileSize)
      let stage = error == nil ? "recorded" : "failed"
      let errorMessage = error?.localizedDescription
      let byteCount = fileSize.intValue
      let metricValue = fileSize.doubleValue
      Task {
        await WorkerTelemetry.shared.record(
          "iphone_recording_finish",
          source: "ios_app",
          stage: stage,
          metricValue: metricValue,
          metricUnit: "bytes",
          payload: [
            "bytes": byteCount,
            "error": errorMessage ?? NSNull()
          ]
        )
      }
    } else {
      NSLog("[iPhoneCamera] Could not read recorded file size at %@", outputFileURL.path)
      let errorMessage = error?.localizedDescription
      Task {
        await WorkerTelemetry.shared.record(
          "iphone_recording_finish",
          source: "ios_app",
          stage: "unknown_size",
          payload: ["error": errorMessage ?? NSNull()]
        )
      }
    }

    let completion = recordingCompletion
    recordingCompletion = nil
    currentRecordingURL = outputFileURL
    completion?(error == nil ? outputFileURL : nil)
  }
}

extension IPhoneCameraManager {
  fileprivate func makeUIImage(from pixelBuffer: CVPixelBuffer, maxDimension: CGFloat? = nil) -> UIImage? {
    var ciImage = CIImage(cvPixelBuffer: pixelBuffer)
    let extent = ciImage.extent

    if let maxDimension,
       maxDimension > 0 {
      let largestDimension = max(extent.width, extent.height)
      if largestDimension > maxDimension {
        let scale = maxDimension / largestDimension
        ciImage = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
      }
    }

    guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }
    return UIImage(cgImage: cgImage)
  }

  private func logCaptureStatsIfNeeded() {
    guard sampleFrameCount == 1 || sampleFrameCount % 120 == 0 else { return }

    let now = CACurrentMediaTime()
    let elapsed = max(now - statsWindowStart, 0.001)
    let previewFPS = Double(sampleFrameCount) / elapsed
    let analysisFPS = Double(analysisFrameCount) / elapsed

    NSLog(
      "[iPhoneCamera] Preview stats preview=%.1ffps analysis=%.1ffps recording=%@",
      previewFPS,
      analysisFPS,
      movieOutput.isRecording ? "true" : "false"
    )
    Task {
      await WorkerTelemetry.shared.record(
        "iphone_camera_fps",
        source: "ios_app",
        stage: "camera",
        metricValue: previewFPS,
        metricUnit: "fps",
        payload: [
          "preview_fps": previewFPS,
          "analysis_fps": analysisFPS,
          "recording": movieOutput.isRecording
        ]
      )
    }

    statsWindowStart = now
    sampleFrameCount = 0
    analysisFrameCount = 0
  }
}
