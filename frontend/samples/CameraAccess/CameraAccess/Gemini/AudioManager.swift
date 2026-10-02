import AVFoundation
import Foundation
import UIKit

class AudioManager {
  var onAudioCaptured: ((Data) -> Void)?

  private let audioEngine = AVAudioEngine()
  private let playerNode = AVAudioPlayerNode()
  private var isCapturing = false
  private var wasCapturingBeforeInterruption = false
  private var useIPhoneMode = false

  private let outputFormat: AVAudioFormat

  // Accumulate resampled PCM into ~100ms chunks before sending
  private let sendQueue = DispatchQueue(label: "audio.accumulator")
  private var accumulatedData = Data()
  private let minSendBytes = 3200  // 100ms at 16kHz mono Int16 = 1600 frames * 2 bytes

  // Notification observers for background resilience
  private var interruptionObserver: NSObjectProtocol?
  private var routeChangeObserver: NSObjectProtocol?
  private var mediaServicesResetObserver: NSObjectProtocol?
  private var foregroundObserver: NSObjectProtocol?

  init() {
    self.outputFormat = AVAudioFormat(
      commonFormat: .pcmFormatInt16,
      sampleRate: GeminiConfig.outputAudioSampleRate,
      channels: GeminiConfig.audioChannels,
      interleaved: true
    )!
  }

  func setupAudioSession(useIPhoneMode: Bool = false) throws {
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
        options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers]
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

    setupInterruptionHandling()
    setupAppLifecycleObservers()
  }

  func startCapture() throws {
    guard !isCapturing else { return }

    audioEngine.attach(playerNode)
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

      // Accumulate into ~100ms chunks before sending to Gemini
      self.sendQueue.async {
        self.accumulatedData.append(pcmData)
        if self.accumulatedData.count >= self.minSendBytes {
          let chunk = self.accumulatedData
          self.accumulatedData = Data()
          if tapCount <= 3 {
            NSLog("[Audio] Sending chunk: %d bytes (~%dms)",
                  chunk.count, chunk.count / 32)  // 16kHz * 2 bytes = 32 bytes/ms
          }
          self.onAudioCaptured?(chunk)
        }
      }
    }

    try audioEngine.start()
    playerNode.play()
    isCapturing = true
  }

  func playAudio(data: Data) {
    guard isCapturing, !data.isEmpty else { return }

    let playerFormat = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: GeminiConfig.outputAudioSampleRate,
      channels: GeminiConfig.audioChannels,
      interleaved: false
    )!

    let frameCount = UInt32(data.count) / (GeminiConfig.audioBitsPerSample / 8 * GeminiConfig.audioChannels)
    guard frameCount > 0 else { return }

    guard let buffer = AVAudioPCMBuffer(pcmFormat: playerFormat, frameCapacity: frameCount) else { return }
    buffer.frameLength = frameCount

    guard let floatData = buffer.floatChannelData else { return }
    data.withUnsafeBytes { rawBuffer in
      guard let int16Ptr = rawBuffer.bindMemory(to: Int16.self).baseAddress else { return }
      for i in 0..<Int(frameCount) {
        floatData[0][i] = Float(int16Ptr[i]) / Float(Int16.max)
      }
    }

    playerNode.scheduleBuffer(buffer)
    if !playerNode.isPlaying {
      playerNode.play()
    }
  }

  func stopPlayback() {
    playerNode.stop()
    playerNode.play()
  }

  func stopCapture() {
    guard isCapturing else { return }
    audioEngine.inputNode.removeTap(onBus: 0)
    playerNode.stop()
    audioEngine.stop()
    audioEngine.detach(playerNode)
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
    case .oldDeviceUnavailable:
      NSLog("[Audio] Audio device removed")
      if isCapturing {
        attemptAudioReset()
      }
    case .categoryChange, .override, .wakeFromSleep, .routeConfigurationChange:
      NSLog("[Audio] Audio route change: %d", reason.rawValue)
    default:
      break
    }
  }

  private func resumeAudioAfterInterruption() {
    NSLog("[Audio] Resuming audio after interruption")
    let audioSession = AVAudioSession.sharedInstance()
    do {
      try audioSession.setActive(true)
      try audioEngine.start()
      NSLog("[Audio] Audio resumed successfully")
    } catch {
      NSLog("[Audio] Failed to resume audio: %@", error.localizedDescription)
      attemptAudioReset()
    }
  }

  private func attemptAudioReset() {
    NSLog("[Audio] Attempting audio reset")
    let wasCapturing = isCapturing

    if audioEngine.isRunning {
      audioEngine.stop()
    }
    audioEngine.inputNode.removeTap(onBus: 0)
    isCapturing = false

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
