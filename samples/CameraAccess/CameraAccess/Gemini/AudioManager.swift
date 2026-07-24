import AVFoundation
import Foundation
import UIKit

struct AudioRouteStatus: Equatable {
  let inputNames: [String]
  let outputNames: [String]
  let hasBluetoothHFPInput: Bool
  let hasBluetoothHFPOutput: Bool

  static let unknown = AudioRouteStatus(
    inputNames: [],
    outputNames: [],
    hasBluetoothHFPInput: false,
    hasBluetoothHFPOutput: false
  )

  var isGlassesDuplex: Bool {
    hasBluetoothHFPInput && hasBluetoothHFPOutput
  }

  var displayText: String {
    if isGlassesDuplex {
      return "Glasses Audio"
    }
    if !inputNames.isEmpty || !outputNames.isEmpty {
      return "Phone Audio"
    }
    return "Audio Route…"
  }

  init(route: AVAudioSessionRouteDescription) {
    inputNames = route.inputs.map(\.portName)
    outputNames = route.outputs.map(\.portName)
    hasBluetoothHFPInput = route.inputs.contains { $0.portType == .bluetoothHFP }
    hasBluetoothHFPOutput = route.outputs.contains { $0.portType == .bluetoothHFP }
  }

  init(
    inputNames: [String],
    outputNames: [String],
    hasBluetoothHFPInput: Bool,
    hasBluetoothHFPOutput: Bool
  ) {
    self.inputNames = inputNames
    self.outputNames = outputNames
    self.hasBluetoothHFPInput = hasBluetoothHFPInput
    self.hasBluetoothHFPOutput = hasBluetoothHFPOutput
  }
}

/// Tracks buffers until AVAudioPlayerNode confirms that they were actually
/// played. Server turn completion is not the same as local speaker drain.
final class PlaybackDrainTracker: @unchecked Sendable {
  struct Ticket: Sendable {
    fileprivate let generation: UInt64
  }

  struct EnqueueResult: Sendable {
    let ticket: Ticket
    let becameActive: Bool
  }

  private let lock = NSLock()
  private var generation: UInt64 = 0
  private var pendingBuffers = 0

  var isActive: Bool {
    lock.lock()
    defer { lock.unlock() }
    return pendingBuffers > 0
  }

  var pendingBufferCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return pendingBuffers
  }

  func enqueue() -> EnqueueResult {
    lock.lock()
    let becameActive = pendingBuffers == 0
    pendingBuffers += 1
    let ticket = Ticket(generation: generation)
    lock.unlock()
    return EnqueueResult(ticket: ticket, becameActive: becameActive)
  }

  func isCurrent(_ ticket: Ticket) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return ticket.generation == generation
  }

  /// Returns true when this completion drained the current generation.
  @discardableResult
  func complete(_ ticket: Ticket) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard ticket.generation == generation, pendingBuffers > 0 else { return false }
    pendingBuffers -= 1
    return pendingBuffers == 0
  }

  func invalidate() {
    lock.lock()
    generation &+= 1
    pendingBuffers = 0
    lock.unlock()
  }
}

struct AudioRouteRecoveryState {
  private var nextGeneration: UInt64 = 0
  private(set) var pendingGeneration: UInt64?

  mutating func schedule(isCapturing: Bool) -> UInt64? {
    guard isCapturing else { return nil }
    nextGeneration &+= 1
    pendingGeneration = nextGeneration
    return nextGeneration
  }

  mutating func cancel() {
    pendingGeneration = nil
  }

  mutating func consume(
    generation: UInt64,
    isCapturing: Bool,
    engineIsRunning: Bool
  ) -> Bool {
    guard pendingGeneration == generation else { return false }
    pendingGeneration = nil
    return isCapturing && !engineIsRunning
  }
}

class AudioManager {
  var onAudioCaptured: ((Data) -> Void)?
  var onRouteChanged: ((AudioRouteStatus) -> Void)?

  private var audioEngine = AVAudioEngine()
  private var playerNode = AVAudioPlayerNode()
  private var isCapturing = false
  private var isInputTapInstalled = false
  private var wasCapturingBeforeInterruption = false
  private var useIPhoneMode = false

  private let outputFormat: AVAudioFormat

  // Google recommends 20-40ms realtime input chunks. Forty milliseconds keeps
  // request overhead modest while cutting the previous 100ms input delay.
  private let sendQueue = DispatchQueue(label: "audio.accumulator")
  private var accumulatedData = Data()
  private let minSendBytes = 1280  // 40ms at 16kHz mono Int16
  private let playbackPreparationQueue = DispatchQueue(
    label: "audio.playback.prepare",
    qos: .userInitiated
  )
  private let playbackDrainTracker = PlaybackDrainTracker()

  var isPlaybackActive: Bool {
    playbackDrainTracker.isActive
  }

  // Notification observers for background resilience
  private var interruptionObserver: NSObjectProtocol?
  private var routeChangeObserver: NSObjectProtocol?
  private var mediaServicesResetObserver: NSObjectProtocol?
  private var foregroundObserver: NSObjectProtocol?
  private var routeRecoveryState = AudioRouteRecoveryState()
  private var routeRecoveryWorkItem: DispatchWorkItem?
  private var isResettingAudio = false

  init() {
    self.outputFormat = AVAudioFormat(
      commonFormat: .pcmFormatInt16,
      sampleRate: GeminiConfig.outputAudioSampleRate,
      channels: GeminiConfig.audioChannels,
      interleaved: true
    )!
  }

  func setupAudioSession(useIPhoneMode: Bool = false) throws {
    cancelPendingRouteRecovery()
    removeObservers()
    self.useIPhoneMode = useIPhoneMode
    let session = AVAudioSession.sharedInstance()
    // voiceChat: aggressive echo cancellation (mic + speaker co-located on phone)
    // videoChat: mild AEC (mic on glasses, speaker on glasses)
    // When Speaker Output is ON, speaker is on phone so always use voiceChat AEC
    let forceSpeaker = SettingsManager.shared.speakerOutputEnabled
    if useIPhoneMode || forceSpeaker {
      try session.setCategory(
        .playAndRecord,
        mode: .voiceChat,
        options: [.defaultToSpeaker, .allowBluetoothHFP, .mixWithOthers]
      )
    } else {
      try session.setCategory(
        .playAndRecord,
        mode: .videoChat,
        options: [.allowBluetoothHFP, .mixWithOthers, .defaultToSpeaker]
      )
    }
    try session.setPreferredSampleRate(GeminiConfig.inputAudioSampleRate)
    try session.setPreferredIOBufferDuration(0.064)
    try session.setActive(true)
    if SettingsManager.shared.speakerOutputEnabled {
      try session.overrideOutputAudioPort(.speaker)
      NSLog("[Audio] Speaker output override: ON (iPhone speaker)")
    }
    NSLog("[Audio] Session mode: %@", useIPhoneMode ? "voiceChat (iPhone)" : "videoChat (glasses)")
    publishCurrentRoute()

    setupInterruptionHandling()
    setupAppLifecycleObservers()
  }

  func startCapture() throws {
    guard !isCapturing else { return }

    if playerNode.engine == nil {
      audioEngine.attach(playerNode)
    }
    let playerFormat = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: GeminiConfig.outputAudioSampleRate,
      channels: GeminiConfig.audioChannels,
      interleaved: false
    )!
    audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: playerFormat)

    let inputNode = audioEngine.inputNode
    let inputNativeFormat = inputNode.outputFormat(forBus: 0)

    NSLog("[Audio] Native input format: %@ sampleRate=%.0f channels=%d",
          inputNativeFormat.commonFormat == .pcmFormatFloat32 ? "Float32" :
          inputNativeFormat.commonFormat == .pcmFormatInt16 ? "Int16" : "Other",
          inputNativeFormat.sampleRate, inputNativeFormat.channelCount)

    // Always tap in native format (Float32) and convert to Int16 PCM manually.
    // AVAudioEngine taps don't reliably convert between sample formats inline.
    let needsResample = inputNativeFormat.sampleRate != GeminiConfig.inputAudioSampleRate
        || inputNativeFormat.channelCount != GeminiConfig.audioChannels

    NSLog("[Audio] Needs resample: %@", needsResample ? "YES" : "NO")

    sendQueue.async { self.accumulatedData = Data() }

    var converter: AVAudioConverter?
    if needsResample {
      let resampleFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: GeminiConfig.inputAudioSampleRate,
        channels: GeminiConfig.audioChannels,
        interleaved: false
      )!
      converter = AVAudioConverter(from: inputNativeFormat, to: resampleFormat)
    }

    var tapCount = 0
    inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputNativeFormat) { [weak self] buffer, _ in
      guard let self else { return }

      tapCount += 1
      let pcmData: Data

      if let converter {
        let resampleFormat = AVAudioFormat(
          commonFormat: .pcmFormatFloat32,
          sampleRate: GeminiConfig.inputAudioSampleRate,
          channels: GeminiConfig.audioChannels,
          interleaved: false
        )!
        guard let resampled = self.convertBuffer(buffer, using: converter, targetFormat: resampleFormat) else {
          if tapCount <= 3 { NSLog("[Audio] Resample failed for tap #%d", tapCount) }
          return
        }
        pcmData = self.float32BufferToInt16Data(resampled)
      } else {
        pcmData = self.float32BufferToInt16Data(buffer)
      }

      // Emit exact ~40ms chunks even when the audio tap delivers a larger buffer.
      self.sendQueue.async {
        self.accumulatedData.append(pcmData)
        while self.accumulatedData.count >= self.minSendBytes {
          let chunk = Data(self.accumulatedData.prefix(self.minSendBytes))
          self.accumulatedData.removeFirst(self.minSendBytes)
          if tapCount <= 3 {
            NSLog("[Audio] Sending chunk: %d bytes (~%dms)",
                  chunk.count, chunk.count / 32)  // 16kHz * 2 bytes = 32 bytes/ms
          }
          self.onAudioCaptured?(chunk)
        }
      }
    }
    isInputTapInstalled = true

    do {
      try audioEngine.start()
      playerNode.play()
      isCapturing = true
    } catch {
      stopCapture()
      throw error
    }
  }

  func playAudio(data: Data) {
    guard isCapturing, !data.isEmpty else { return }
    let registration = playbackDrainTracker.enqueue()
    if registration.becameActive {
      NSLog("[Audio] Playback started")
    }

    playbackPreparationQueue.async { [weak self] in
      guard let self else { return }
      guard let buffer = Self.makePlaybackBuffer(data: data) else {
        self.finishPlaybackBuffer(registration.ticket)
        return
      }

      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        guard self.isCapturing,
              self.playbackDrainTracker.isCurrent(registration.ticket) else {
          self.finishPlaybackBuffer(registration.ticket)
          return
        }
        self.playerNode.scheduleBuffer(
          buffer,
          completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
          self?.finishPlaybackBuffer(registration.ticket)
        }
        if !self.playerNode.isPlaying {
          self.playerNode.play()
        }
      }
    }
  }

  private static func makePlaybackBuffer(data: Data) -> AVAudioPCMBuffer? {
    let playerFormat = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: GeminiConfig.outputAudioSampleRate,
      channels: GeminiConfig.audioChannels,
      interleaved: false
    )!

    let frameCount = UInt32(data.count) / (GeminiConfig.audioBitsPerSample / 8 * GeminiConfig.audioChannels)
    guard frameCount > 0 else { return nil }

    guard let buffer = AVAudioPCMBuffer(
      pcmFormat: playerFormat,
      frameCapacity: frameCount
    ) else { return nil }
    buffer.frameLength = frameCount

    guard let floatData = buffer.floatChannelData else { return nil }
    data.withUnsafeBytes { rawBuffer in
      guard let int16Ptr = rawBuffer.bindMemory(to: Int16.self).baseAddress else { return }
      for i in 0..<Int(frameCount) {
        floatData[0][i] = Float(int16Ptr[i]) / Float(Int16.max)
      }
    }
    return buffer
  }

  func stopPlayback(reason: String = "unspecified") {
    guard isCapturing else { return }
    NSLog(
      "[Audio] Playback flushed (%@, pending=%d)",
      reason,
      playbackDrainTracker.pendingBufferCount)
    invalidatePreparedPlayback()
    playerNode.stop()
    playerNode.play()
  }

  func stopCapture() {
    cancelPendingRouteRecovery()
    invalidatePreparedPlayback()
    if isInputTapInstalled {
      audioEngine.inputNode.removeTap(onBus: 0)
      isInputTapInstalled = false
    }
    playerNode.stop()
    if audioEngine.isRunning {
      audioEngine.stop()
    }
    if playerNode.engine != nil {
      audioEngine.detach(playerNode)
    }
    isCapturing = false
    // Flush any remaining accumulated audio
    sendQueue.async {
      if !self.accumulatedData.isEmpty {
        let chunk = self.accumulatedData
        self.accumulatedData = Data()
        self.onAudioCaptured?(chunk)
      }
    }
    removeObservers()
  }

  private func finishPlaybackBuffer(_ ticket: PlaybackDrainTracker.Ticket) {
    if playbackDrainTracker.complete(ticket) {
      NSLog("[Audio] Playback fully drained")
    }
  }

  private func invalidatePreparedPlayback() {
    playbackDrainTracker.invalidate()
  }

  // MARK: - Audio Interruption & Route Change Handling

  private func setupInterruptionHandling() {
    interruptionObserver = NotificationCenter.default.addObserver(
      forName: AVAudioSession.interruptionNotification,
      object: AVAudioSession.sharedInstance(),
      queue: .main
    ) { [weak self] notification in
      guard let self,
            let userInfo = notification.userInfo,
            let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: typeValue)
      else { return }

      var shouldResume = false
      if type == .ended,
         let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
        let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
        shouldResume = options.contains(.shouldResume)
      }

      self.handleInterruption(type: type, shouldResume: shouldResume)
    }

    routeChangeObserver = NotificationCenter.default.addObserver(
      forName: AVAudioSession.routeChangeNotification,
      object: AVAudioSession.sharedInstance(),
      queue: .main
    ) { [weak self] notification in
      guard let self,
            let userInfo = notification.userInfo,
            let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
            let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue)
      else { return }

      self.handleRouteChange(reason: reason)
    }

    mediaServicesResetObserver = NotificationCenter.default.addObserver(
      forName: AVAudioSession.mediaServicesWereResetNotification,
      object: AVAudioSession.sharedInstance(),
      queue: .main
    ) { [weak self] _ in
      self?.attemptAudioReset()
    }
  }

  private func setupAppLifecycleObservers() {
    foregroundObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.willEnterForegroundNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      guard let self else { return }
      NSLog("[Audio] App will enter foreground")
      if self.isCapturing && !self.audioEngine.isRunning {
        NSLog("[Audio] Audio engine stopped while backgrounded, attempting reset")
        self.attemptAudioReset()
      }
    }
  }

  private func handleInterruption(type: AVAudioSession.InterruptionType, shouldResume: Bool) {
    switch type {
    case .began:
      NSLog("[Audio] Audio interruption began (e.g. phone call)")
      wasCapturingBeforeInterruption = isCapturing
      if isCapturing {
        audioEngine.pause()
      }
    case .ended:
      NSLog("[Audio] Audio interruption ended (shouldResume=%@)", shouldResume ? "true" : "false")
      if wasCapturingBeforeInterruption {
        resumeAudioAfterInterruption()
      }
    @unknown default:
      break
    }
  }

  private func handleRouteChange(reason: AVAudioSession.RouteChangeReason) {
    switch reason {
    case .newDeviceAvailable:
      NSLog("[Audio] New audio device available")
      cancelPendingRouteRecovery()
    case .oldDeviceUnavailable:
      NSLog("[Audio] Audio device removed")
      scheduleRouteRecoveryIfNeeded()
    case .categoryChange, .override, .wakeFromSleep, .routeConfigurationChange:
      NSLog("[Audio] Audio route change: %d", reason.rawValue)
      if audioEngine.isRunning {
        cancelPendingRouteRecovery()
      }
    default:
      break
    }
    publishCurrentRoute()
  }

  private func publishCurrentRoute() {
    let status = AudioRouteStatus(route: AVAudioSession.sharedInstance().currentRoute)
    NSLog(
      "[Audio] Route input=%@ output=%@ glassesDuplex=%@",
      status.inputNames.joined(separator: ","),
      status.outputNames.joined(separator: ","),
      status.isGlassesDuplex ? "yes" : "no"
    )
    onRouteChanged?(status)
  }

  private func resumeAudioAfterInterruption() {
    NSLog("[Audio] Resuming audio after interruption")
    let audioSession = AVAudioSession.sharedInstance()
    do {
      try audioSession.setActive(true)
      try audioEngine.start()
      if !playerNode.isPlaying {
        playerNode.play()
      }
      NSLog("[Audio] Audio resumed successfully")
    } catch {
      NSLog("[Audio] Failed to resume audio: %@", error.localizedDescription)
      attemptAudioReset()
    }
  }

  private func attemptAudioReset() {
    guard !isResettingAudio else { return }
    isResettingAudio = true
    defer { isResettingAudio = false }
    cancelPendingRouteRecovery()
    NSLog("[Audio] Attempting audio reset")
    let wasCapturing = isCapturing

    invalidatePreparedPlayback()
    playerNode.stop()
    if audioEngine.isRunning {
      audioEngine.stop()
    }
    if isInputTapInstalled {
      audioEngine.inputNode.removeTap(onBus: 0)
      isInputTapInstalled = false
    }
    isCapturing = false
    removeObservers()
    audioEngine = AVAudioEngine()
    playerNode = AVAudioPlayerNode()

    if wasCapturing {
      do {
        try setupAudioSession(useIPhoneMode: useIPhoneMode)
        try startCapture()
        NSLog("[Audio] Audio reset successful")
      } catch {
        NSLog("[Audio] Audio reset failed: %@", error.localizedDescription)
      }
    }
  }

  private func scheduleRouteRecoveryIfNeeded() {
    guard let generation = routeRecoveryState.schedule(
      isCapturing: isCapturing
    ) else { return }
    routeRecoveryWorkItem?.cancel()
    let workItem = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.routeRecoveryWorkItem = nil
      let shouldReset = self.routeRecoveryState.consume(
        generation: generation,
        isCapturing: self.isCapturing,
        engineIsRunning: self.audioEngine.isRunning
      )
      if shouldReset {
        self.attemptAudioReset()
      } else {
        NSLog("[Audio] Route recovered without flushing queued playback")
      }
    }
    routeRecoveryWorkItem = workItem
    DispatchQueue.main.asyncAfter(
      deadline: .now() + 0.6,
      execute: workItem
    )
  }

  private func cancelPendingRouteRecovery() {
    routeRecoveryWorkItem?.cancel()
    routeRecoveryWorkItem = nil
    routeRecoveryState.cancel()
  }

  private func removeObservers() {
    if let observer = interruptionObserver {
      NotificationCenter.default.removeObserver(observer)
      interruptionObserver = nil
    }
    if let observer = routeChangeObserver {
      NotificationCenter.default.removeObserver(observer)
      routeChangeObserver = nil
    }
    if let observer = mediaServicesResetObserver {
      NotificationCenter.default.removeObserver(observer)
      mediaServicesResetObserver = nil
    }
    if let observer = foregroundObserver {
      NotificationCenter.default.removeObserver(observer)
      foregroundObserver = nil
    }
  }

  // MARK: - Private helpers

  private func computeRMS(_ buffer: AVAudioPCMBuffer) -> Float {
    let frameCount = Int(buffer.frameLength)
    guard frameCount > 0, let floatData = buffer.floatChannelData else { return 0 }
    var sumSquares: Float = 0
    for i in 0..<frameCount {
      let s = floatData[0][i]
      sumSquares += s * s
    }
    return sqrt(sumSquares / Float(frameCount))
  }

  private func float32BufferToInt16Data(_ buffer: AVAudioPCMBuffer) -> Data {
    let frameCount = Int(buffer.frameLength)
    guard frameCount > 0, let floatData = buffer.floatChannelData else { return Data() }
    var int16Array = [Int16](repeating: 0, count: frameCount)
    for i in 0..<frameCount {
      let sample = max(-1.0, min(1.0, floatData[0][i]))
      int16Array[i] = Int16(sample * Float(Int16.max))
    }
    return int16Array.withUnsafeBufferPointer { ptr in
      Data(buffer: ptr)
    }
  }

  private func convertBuffer(
    _ inputBuffer: AVAudioPCMBuffer,
    using converter: AVAudioConverter,
    targetFormat: AVAudioFormat
  ) -> AVAudioPCMBuffer? {
    let ratio = targetFormat.sampleRate / inputBuffer.format.sampleRate
    let outputFrameCount = UInt32(Double(inputBuffer.frameLength) * ratio)
    guard outputFrameCount > 0 else { return nil }

    guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCount) else {
      return nil
    }

    var error: NSError?
    var consumed = false
    converter.convert(to: outputBuffer, error: &error) { _, outStatus in
      if consumed {
        outStatus.pointee = .noDataNow
        return nil
      }
      consumed = true
      outStatus.pointee = .haveData
      return inputBuffer
    }

    if error != nil {
      return nil
    }

    return outputBuffer
  }
}
