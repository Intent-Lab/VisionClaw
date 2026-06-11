import AVFoundation
import Foundation
import UIKit

enum WorkerAudioRouteOwner: String, Sendable {
  case aiGuide = "ai_guide"
  case backOfficeWebRTC = "back_office_webrtc"
  case holdToTalk = "hold_to_talk"
  case viewer = "viewer"
}

struct WorkerAudioRouteLease: Equatable, Sendable {
  let owner: WorkerAudioRouteOwner
  let token: UUID
  let generation: UInt64

  var payload: [String: Any] {
    [
      "owner": owner.rawValue,
      "token": token.uuidString,
      "generation": generation
    ]
  }
}

struct WorkerAudioRouteSnapshot {
  let lease: WorkerAudioRouteLease
  let owner: WorkerAudioRouteOwner
  let mode: StreamingMode
  let reason: String
  let category: String
  let audioMode: String
  let inputs: [String]
  let outputs: [String]
  let preferredInput: String?
  let usesHandsFreeRoute: Bool
  let fallbackMessage: String?
  let sampleRate: Double
  let ioBufferDuration: Double

  var payload: [String: Any] {
    [
      "owner": owner.rawValue,
      "token": lease.token.uuidString,
      "generation": lease.generation,
      "mode": mode == .iPhone ? "iphone" : "glasses",
      "reason": reason,
      "category": category,
      "audio_mode": audioMode,
      "inputs": inputs,
      "outputs": outputs,
      "preferred_input": preferredInput ?? NSNull(),
      "uses_hands_free_route": usesHandsFreeRoute,
      "fallback_message": fallbackMessage ?? NSNull(),
      "sample_rate": sampleRate,
      "io_buffer_duration": ioBufferDuration
    ]
  }
}

final class WorkerAudioRouteCoordinator: @unchecked Sendable {
  static let shared = WorkerAudioRouteCoordinator()

  private let stateQueue = DispatchQueue(label: "worker.audio.route.state")
  private let deactivationQueue = DispatchQueue(
    label: "worker.audio.route.deactivation",
    qos: .userInitiated
  )
  private var activeLease: WorkerAudioRouteLease?
  private var routeGeneration: UInt64 = 0

  @discardableResult
  func acquire(
    owner: WorkerAudioRouteOwner,
    mode: StreamingMode,
    reason: String,
    forceSpeaker: Bool = false,
    preferredSampleRate: Double? = nil,
    preferredIOBufferDuration: TimeInterval = 0.02
  ) throws -> WorkerAudioRouteSnapshot {
    let lease = stateQueue.sync { () -> WorkerAudioRouteLease in
      routeGeneration &+= 1
      let lease = WorkerAudioRouteLease(
        owner: owner,
        token: UUID(),
        generation: routeGeneration
      )
      activeLease = lease
      return lease
    }

    let session = AVAudioSession.sharedInstance()
    do {
      var options: AVAudioSession.CategoryOptions = [.allowBluetoothHFP]
      let audioMode: AVAudioSession.Mode

      switch mode {
      case .iPhone:
        audioMode = .voiceChat
        options.formUnion([.defaultToSpeaker, .duckOthers])
      case .glasses:
        audioMode = forceSpeaker ? .voiceChat : .videoChat
        if forceSpeaker {
          options.formUnion([.defaultToSpeaker])
        }
      }

      try session.setCategory(.playAndRecord, mode: audioMode, options: options)
      if let preferredSampleRate {
        try session.setPreferredSampleRate(preferredSampleRate)
      }
      try session.setPreferredIOBufferDuration(preferredIOBufferDuration)
      try session.setActive(true, options: .notifyOthersOnDeactivation)

      var preferredInputName: String?
      if let input = preferredBluetoothHandsFreeInput(session) {
        try session.setPreferredInput(input)
        preferredInputName = "\(input.portType.rawValue):\(input.portName)"
        try session.setActive(true, options: .notifyOthersOnDeactivation)
      }

      let routeBeforeOverride = session.currentRoute
      let hasHandsFree = hasBluetoothHandsFreeRoute(routeBeforeOverride)
      let fallbackMessage: String?

      if mode == .iPhone || forceSpeaker {
        try session.overrideOutputAudioPort(.speaker)
        fallbackMessage = mode == .glasses
          ? "Glasses audio route unavailable. Using phone speaker."
          : nil
      } else if hasHandsFree {
        try session.overrideOutputAudioPort(.none)
        fallbackMessage = nil
      } else {
        try session.overrideOutputAudioPort(.speaker)
        fallbackMessage = "Meta audio route unavailable. Using phone audio until Bluetooth HFP connects."
      }

      let snapshot = WorkerAudioRouteSnapshot(
        lease: lease,
        owner: owner,
        mode: mode,
        reason: reason,
        category: session.category.rawValue,
        audioMode: session.mode.rawValue,
        inputs: describePorts(session.currentRoute.inputs),
        outputs: describePorts(session.currentRoute.outputs),
        preferredInput: preferredInputName,
        usesHandsFreeRoute: hasBluetoothHandsFreeRoute(session.currentRoute),
        fallbackMessage: fallbackMessage,
        sampleRate: session.sampleRate,
        ioBufferDuration: session.ioBufferDuration
      )
      log(snapshot)
      Task {
        await WorkerTelemetry.shared.record(
          "audio_route_acquired",
          source: "ios_audio",
          stage: owner.rawValue,
          payload: snapshot.payload
        )
      }
      return snapshot
    } catch {
      stateQueue.sync {
        if activeLease?.token == lease.token {
          activeLease = nil
        }
      }
      throw error
    }
  }

  func release(
    lease: WorkerAudioRouteLease,
    afterAudioGraphStops: @escaping () async -> Void = {}
  ) async {
    let didRelease = stateQueue.sync { () -> Bool in
      guard activeLease?.token == lease.token else { return false }
      activeLease = nil
      return true
    }

    guard didRelease else {
      let currentLease = stateQueue.sync { activeLease }
      print("[Audio] Stale release ignored; newer session active")
      var payload: [String: Any] = [
        "release_owner": lease.owner.rawValue,
        "release_token": lease.token.uuidString,
        "release_generation": lease.generation
      ]
      if let currentLease {
        payload["current_owner"] = currentLease.owner.rawValue
        payload["current_token"] = currentLease.token.uuidString
        payload["current_generation"] = currentLease.generation
      } else {
        payload["current_owner"] = NSNull()
        payload["current_token"] = NSNull()
        payload["current_generation"] = NSNull()
      }
      await WorkerTelemetry.shared.record(
        "audio_route_stale_release_ignored",
        source: "ios_audio",
        stage: lease.owner.rawValue,
        payload: payload
      )
      return
    }

    NSLog("[WorkerAudio] released owner=%@ token=%@", lease.owner.rawValue, lease.token.uuidString)
    await WorkerTelemetry.shared.record(
      "audio_route_released",
      source: "ios_audio",
      stage: lease.owner.rawValue,
      payload: lease.payload
    )

    await afterAudioGraphStops()
    await Task.yield()

    let currentState = stateQueue.sync { () -> (lease: WorkerAudioRouteLease?, generation: UInt64) in
      (activeLease, routeGeneration)
    }
    let currentLease = currentState.lease
    let currentGeneration = currentState.generation
    let shouldDeactivate = currentLease == nil && currentGeneration == lease.generation

    guard shouldDeactivate else {
      var payload: [String: Any] = [
        "owner": lease.owner.rawValue,
        "token": lease.token.uuidString,
        "release_generation": lease.generation,
        "current_generation": currentGeneration
      ]
      payload["current_owner"] = currentLease?.owner.rawValue ?? NSNull()
      payload["current_token"] = currentLease?.token.uuidString ?? NSNull()
      NSLog(
        "[WorkerAudio] skip deactivate owner=%@ token=%@ generation=%llu currentOwner=%@ currentGeneration=%llu",
        lease.owner.rawValue,
        lease.token.uuidString,
        lease.generation,
        currentLease?.owner.rawValue ?? "none",
        currentGeneration
      )
      await WorkerTelemetry.shared.record(
        "audio_route_deactivation_skipped",
        source: "ios_audio",
        stage: lease.owner.rawValue,
        payload: payload
      )
      return
    }

    let result = await deactivateSharedAudioSession()
    switch result {
    case .success:
      NSLog("[WorkerAudio] deactivated owner=%@ token=%@", lease.owner.rawValue, lease.token.uuidString)
      await WorkerTelemetry.shared.record(
        "audio_route_deactivated",
        source: "ios_audio",
        stage: lease.owner.rawValue,
        payload: lease.payload
      )
    case .failure(let error):
      NSLog("[WorkerAudio] deactivate failed owner=%@ token=%@ error=%@",
            lease.owner.rawValue, lease.token.uuidString, error.localizedDescription)
      await WorkerTelemetry.shared.record(
        "audio_route_deactivate_failed",
        source: "ios_audio",
        stage: lease.owner.rawValue,
        payload: [
          "owner": lease.owner.rawValue,
          "token": lease.token.uuidString,
          "generation": lease.generation,
          "error": error.localizedDescription
        ]
      )
    }
  }

  private func deactivateSharedAudioSession() async -> Result<Void, Error> {
    await withCheckedContinuation { (continuation: CheckedContinuation<Result<Void, Error>, Never>) in
      deactivationQueue.async {
        do {
          try AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
          )
          continuation.resume(returning: .success(()))
        } catch {
          continuation.resume(returning: .failure(error))
        }
      }
    }
  }

  private func preferredBluetoothHandsFreeInput(_ session: AVAudioSession) -> AVAudioSessionPortDescription? {
    session.availableInputs?.first {
      $0.portType == .bluetoothHFP || $0.portType == .bluetoothLE
    }
  }

  private func hasBluetoothHandsFreeRoute(_ route: AVAudioSessionRouteDescription) -> Bool {
    route.inputs.contains {
      $0.portType == .bluetoothHFP || $0.portType == .bluetoothLE
    } || route.outputs.contains {
      $0.portType == .bluetoothHFP || $0.portType == .bluetoothLE
    }
  }

  private func describePorts(_ ports: [AVAudioSessionPortDescription]) -> [String] {
    ports.map { "\($0.portType.rawValue):\($0.portName)" }
  }

  private func log(_ snapshot: WorkerAudioRouteSnapshot) {
    NSLog(
      "[WorkerAudio] owner=%@ mode=%@ reason=%@ inputs=%@ outputs=%@ fallback=%@",
      snapshot.owner.rawValue,
      snapshot.mode == .iPhone ? "iphone" : "glasses",
      snapshot.reason,
      snapshot.inputs.joined(separator: ","),
      snapshot.outputs.joined(separator: ","),
      snapshot.fallbackMessage ?? "none"
    )
  }
}

final class AudioManager: @unchecked Sendable {
  var onAudioCaptured: ((Data) -> Void)?

  // Keep the engine container permanent for the process lifetime. Teardown only
  // stops and detaches child nodes; it never nils or replaces this engine.
  private let audioEngine = AVAudioEngine()
  private let audioLifecycleQueue = DispatchQueue(
    label: "gemini.audio.lifecycle",
    qos: .userInitiated
  )
  private let audioLifecycleQueueKey = DispatchSpecificKey<Void>()
  private let playerNode = AVAudioPlayerNode()
  private var isCapturing = false
  private var isInputTapInstalled = false
  private var isPlayerNodeAttached = false
  private var wasCapturingBeforeInterruption = false
  private var useIPhoneMode = false
  private var audioRouteLease: WorkerAudioRouteLease?
  private var audioGraphGeneration: UInt64 = 0

  private let outputFormat: AVAudioFormat

  // Accumulate resampled PCM into ~100ms chunks before sending
  private let sendQueue = DispatchQueue(label: "audio.accumulator")
  private var accumulatedData = Data()
  private var accumulatorGeneration: UInt64 = 0
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
    audioLifecycleQueue.setSpecific(key: audioLifecycleQueueKey, value: ())
  }

  func setupAudioSession(useIPhoneMode: Bool = false) throws {
    self.useIPhoneMode = useIPhoneMode
    let forceSpeaker = SettingsManager.shared.speakerOutputEnabled
    let captureMode: StreamingMode = useIPhoneMode ? .iPhone : .glasses
    let snapshot = try WorkerAudioRouteCoordinator.shared.acquire(
      owner: .aiGuide,
      mode: captureMode,
      reason: "gemini_live",
      forceSpeaker: forceSpeaker,
      preferredSampleRate: GeminiConfig.inputAudioSampleRate,
      preferredIOBufferDuration: 0.064
    )
    audioRouteLease = snapshot.lease
    if let fallback = snapshot.fallbackMessage {
      NSLog("[Audio] %@", fallback)
    }

    removeObservers()
    setupInterruptionHandling()
    setupAppLifecycleObservers()
  }

  func startCapture() throws {
    try syncOnAudioLifecycleQueue {
      try startCaptureOnAudioLifecycleQueue()
    }
  }

  private func startCaptureOnAudioLifecycleQueue() throws {
    guard !isCapturing else { return }

    if isInputTapInstalled {
      audioEngine.inputNode.removeTap(onBus: 0)
      isInputTapInstalled = false
    }

    if !isPlayerNodeAttached {
      audioEngine.attach(playerNode)
      isPlayerNodeAttached = true
    }

    let playerFormat = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: GeminiConfig.outputAudioSampleRate,
      channels: GeminiConfig.audioChannels,
      interleaved: false
    )!
    audioEngine.disconnectNodeOutput(playerNode)
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

    audioGraphGeneration &+= 1
    let captureGeneration = audioGraphGeneration
    sendQueue.sync {
      accumulatedData = Data()
      accumulatorGeneration = captureGeneration
    }

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
      let currentTapCount = tapCount
      let rmsValue = self.computeRMS(buffer)
      if currentTapCount % 15 == 0 {
        print("[Audio Monitor] App Mic Level: \(rmsValue)")
      }
      let pcmData: Data

      if let converter {
        let resampleFormat = AVAudioFormat(
          commonFormat: .pcmFormatFloat32,
          sampleRate: GeminiConfig.inputAudioSampleRate,
          channels: GeminiConfig.audioChannels,
          interleaved: false
        )!
        guard let resampled = self.convertBuffer(buffer, using: converter, targetFormat: resampleFormat) else {
          if currentTapCount <= 3 { NSLog("[Audio] Resample failed for tap #%d", currentTapCount) }
          return
        }
        pcmData = self.float32BufferToInt16Data(resampled)
      } else {
        pcmData = self.float32BufferToInt16Data(buffer)
      }

      // Accumulate into ~100ms chunks before sending to Gemini
      self.sendQueue.async {
        guard self.accumulatorGeneration == captureGeneration else { return }
        self.accumulatedData.append(pcmData)
        if self.accumulatedData.count >= self.minSendBytes {
          let chunk = self.accumulatedData
          self.accumulatedData = Data()
          if currentTapCount <= 3 {
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
      tearDownEngineGraphOnAudioLifecycleQueue(flushPendingAudio: false)
      throw error
    }
  }

  func playAudio(data: Data) {
    guard !data.isEmpty else { return }
    audioLifecycleQueue.async { [weak self] in
      self?.playAudioOnAudioLifecycleQueue(data: data)
    }
  }

  private func playAudioOnAudioLifecycleQueue(data: Data) {
    guard isCapturing, isPlayerNodeAttached, audioEngine.isRunning, !data.isEmpty else { return }

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
    audioLifecycleQueue.async { [weak self] in
      self?.stopPlaybackOnAudioLifecycleQueue()
    }
  }

  private func stopPlaybackOnAudioLifecycleQueue() {
    guard isPlayerNodeAttached else { return }
    playerNode.stop()
    if isCapturing, audioEngine.isRunning {
      playerNode.play()
    }
  }

  func stopCapture() async {
    // AVAudioEngine graph teardown runs on a serial lifecycle queue so callers
    // can await the barrier without blocking the MainActor on audio hardware.
    let lease = await withCheckedContinuation { (continuation: CheckedContinuation<WorkerAudioRouteLease?, Never>) in
      audioLifecycleQueue.async { [weak self] in
        guard let self else {
          continuation.resume(returning: nil)
          return
        }

        let lease = self.audioRouteLease
        self.audioRouteLease = nil
        self.tearDownEngineGraphOnAudioLifecycleQueue(flushPendingAudio: true) {
          self.removeObservers()
          continuation.resume(returning: lease)
        }
      }
    }

    if let lease {
      await WorkerAudioRouteCoordinator.shared.release(lease: lease)
    }
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
      self.checkAndResetStoppedEngine()
    }
  }

  private func handleInterruption(type: AVAudioSession.InterruptionType, shouldResume: Bool) {
    switch type {
    case .began:
      NSLog("[Audio] Audio interruption began (e.g. phone call)")
      audioLifecycleQueue.async { [weak self] in
        guard let self else { return }
        self.wasCapturingBeforeInterruption = self.isCapturing
        if self.isCapturing {
          self.audioEngine.pause()
        }
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
      attemptAudioReset()
    case .oldDeviceUnavailable:
      NSLog("[Audio] Audio device removed")
      attemptAudioReset()
    case .categoryChange, .override, .wakeFromSleep, .routeConfigurationChange:
      NSLog("[Audio] Audio route change: %d", reason.rawValue)
    default:
      break
    }
  }

  private func preferredBluetoothHFPInput(_ session: AVAudioSession) -> AVAudioSessionPortDescription? {
    session.availableInputs?.first {
      $0.portType == .bluetoothHFP || $0.portType == .bluetoothLE
    }
  }

  private func hasBluetoothHandsFreeRoute(_ route: AVAudioSessionRouteDescription) -> Bool {
    route.inputs.contains {
      $0.portType == .bluetoothHFP ||
        $0.portType == .bluetoothLE
    } ||
      route.outputs.contains {
        $0.portType == .bluetoothHFP ||
          $0.portType == .bluetoothLE
      }
  }

  private func resumeAudioAfterInterruption() {
    NSLog("[Audio] Resuming audio after interruption")
    audioLifecycleQueue.async { [weak self] in
      guard let self else { return }
      let audioSession = AVAudioSession.sharedInstance()
      do {
        try audioSession.setActive(true)
        if self.isCapturing, !self.audioEngine.isRunning {
          try self.audioEngine.start()
        }
        if self.isCapturing, self.isPlayerNodeAttached, !self.playerNode.isPlaying {
          self.playerNode.play()
        }
        NSLog("[Audio] Audio resumed successfully")
      } catch {
        NSLog("[Audio] Failed to resume audio: %@", error.localizedDescription)
        self.attemptAudioReset()
      }
    }
  }

  private func attemptAudioReset() {
    NSLog("[Audio] Attempting audio reset")
    audioLifecycleQueue.async { [weak self] in
      guard let self else { return }
      let wasCapturing = self.isCapturing
      let useIPhoneMode = self.useIPhoneMode

      self.tearDownEngineGraphOnAudioLifecycleQueue(flushPendingAudio: false) { [weak self] in
        guard let self, wasCapturing else { return }
        DispatchQueue.main.async { [weak self] in
          guard let self else { return }
          do {
            try self.setupAudioSession(useIPhoneMode: useIPhoneMode)
            try self.startCapture()
            NSLog("[Audio] Audio reset successful")
          } catch {
            NSLog("[Audio] Audio reset failed: %@", error.localizedDescription)
          }
        }
      }
    }
  }

  private func tearDownEngineGraphOnAudioLifecycleQueue(flushPendingAudio: Bool, completion: (() -> Void)? = nil) {
    audioGraphGeneration &+= 1
    isCapturing = false

    let inputNode = audioEngine.inputNode
    audioEngine.stop()

    if isInputTapInstalled {
      inputNode.removeTap(onBus: 0)
      isInputTapInstalled = false
    }

    if isPlayerNodeAttached {
      if playerNode.isPlaying {
        playerNode.stop()
      }
      audioEngine.disconnectNodeOutput(playerNode)
      audioEngine.detach(playerNode)
      isPlayerNodeAttached = false
    }

    sendQueue.async {
      defer { completion?() }
      self.accumulatorGeneration = 0
      guard !self.accumulatedData.isEmpty else { return }
      let chunk = self.accumulatedData
      self.accumulatedData = Data()
      if flushPendingAudio {
        self.onAudioCaptured?(chunk)
      }
    }
  }

  private func waitForAudioGraphClean() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      audioLifecycleQueue.async { [weak self] in
        guard let self else {
          continuation.resume()
          return
        }

        self.tearDownEngineGraphOnAudioLifecycleQueue(flushPendingAudio: false) {
          continuation.resume()
        }
      }
    }
  }

  private func checkAndResetStoppedEngine() {
    audioLifecycleQueue.async { [weak self] in
      guard let self else { return }
      if self.isCapturing, !self.audioEngine.isRunning {
        NSLog("[Audio] Audio engine stopped while backgrounded, attempting reset")
        self.attemptAudioReset()
      }
    }
  }

  private func syncOnAudioLifecycleQueue<T>(_ work: () throws -> T) rethrows -> T {
    if DispatchQueue.getSpecific(key: audioLifecycleQueueKey) != nil {
      return try work()
    }
    return try audioLifecycleQueue.sync(execute: work)
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
