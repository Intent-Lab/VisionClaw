import AVFoundation
import Foundation
import LiveKit
import SwiftUI

/// The entire voice+vision client, post-migration: join a LiveKit room, publish
/// mic and camera, subscribe to the agent's audio. Everything the direct
/// connection hand-rolled -- echo cancellation, interruption, turn-taking,
/// reconnection -- lives in WebRTC and the server-side agent now. What remains
/// on the phone is a room ticket and two track toggles.
@MainActor
final class LiveKitSession: NSObject, ObservableObject {
  enum State: Equatable {
    case disconnected
    case connecting
    case connected
    case failed(String)
  }

  /// What the agent is doing right now, surfaced so a dead worker is visible
  /// instead of an empty room that politely ignores you. Driven by agent
  /// presence in the room plus the standard `lk.agent.state` attribute the
  /// agents framework publishes (listening / thinking / speaking).
  enum AgentStatus: Equatable {
    case none        // no active call
    case waiting     // call is up, agent hasn't joined the room
    case starting    // agent joined, model session still initializing
    case listening
    case thinking
    case speaking
    case left        // agent was here and disconnected mid-call
  }

  @Published private(set) var state: State = .disconnected
  @Published private(set) var agentStatus: AgentStatus = .none

  /// True when this call's video comes from the glasses (DAT bridge) instead
  /// of the phone camera. Decided at start() from the persisted capture source.
  @Published private(set) var usingGlassesSource = false

  /// Live caption from the transcription text streams (agent and user speech).
  struct Caption: Equatable {
    let text: String
    let isAgent: Bool
  }

  @Published private(set) var caption: Caption?
  private var captionClearTask: Task<Void, Never>?

  /// A typed card from the agent's show_card tool (vc.ui topic). One card at a
  /// time; the same uuid replaces content in place; dismissal sticks until the
  /// agent publishes again.
  struct UICard: Equatable {
    struct Fact: Equatable {
      let label: String
      let value: String
    }

    struct Item: Equatable {
      let glyph: String?
      let title: String
      let subtitle: String?
      let trailing: String?
    }

    let uuid: String
    let type: String
    let title: String?
    let value: String?
    let body: String?
    let facts: [Fact]
    let items: [Item]
    let imageURL: String?
    let fallbackText: String
  }

  @Published private(set) var card: UICard?

  func dismissCard() {
    card = nil
  }
  @Published private(set) var localVideoTrack: LocalVideoTrack?
  /// Camera-only preview while no call is active. The camera IS this app;
  /// hanging up stops the listening, not the seeing.
  @Published private(set) var previewTrack: LocalVideoTrack?

  let room = Room()

  override init() {
    super.init()
    room.add(delegate: self)
  }

  var isActive: Bool { state == .connected || state == .connecting }

  func refreshAgentStatus() {
    guard state == .connected else {
      agentStatus = .none
      return
    }
    guard let agent = room.remoteParticipants.values.first(where: { $0.isAgent }) else {
      if agentStatus != .left { agentStatus = .waiting }
      return
    }
    switch agent.agentState {
    case .idle, .initializing: agentStatus = .starting
    case .listening: agentStatus = .listening
    case .thinking: agentStatus = .thinking
    case .speaking: agentStatus = .speaking
    }
  }

  // MARK: - Freeze (pin a frame for the model to refer to)

  /// While set, the screen shows this frame and the published video is muted:
  /// the model receives no newer frames, so the pinned one stays the most
  /// recent thing it has seen -- "this" means the frame the user pinned.
  @Published private(set) var frozenFrame: UIImage?

  private let frameGrabber = LatestFrameGrabber()
  private var grabberTrack: LocalVideoTrack?

  private func attachGrabber(to track: LocalVideoTrack?) {
    if let old = grabberTrack { old.remove(videoRenderer: frameGrabber) }
    grabberTrack = track
    if let track { track.add(videoRenderer: frameGrabber) }
  }

  func toggleFreeze() async {
    if frozenFrame != nil {
      await unfreeze()
    } else {
      await freeze()
    }
  }

  func freeze() async {
    guard frozenFrame == nil, let image = frameGrabber.latestImage() else { return }
    frozenFrame = image
    if state == .connected {
      if let pub = room.localParticipant.localVideoTracks.first {
        try? await pub.mute()
      }
    }
  }

  func unfreeze() async {
    guard frozenFrame != nil else { return }
    frozenFrame = nil
    if state == .connected {
      if let pub = room.localParticipant.localVideoTracks.first {
        try? await pub.unmute()
      }
    }
  }

  // MARK: - Zoom

  /// Optical-then-digital zoom applied at the sensor through whichever camera
  /// track is live (call or preview), so what you pinch into is what the model
  /// sees. Capped at 8x: past that the wide lens is upscaling, not resolving.
  @Published private(set) var zoomFactor: CGFloat = 1
  private var zoomAtGestureStart: CGFloat = 1

  private var activeCaptureDevice: AVCaptureDevice? {
    let track = localVideoTrack ?? previewTrack
    return (track?.capturer as? CameraCapturer)?.device
  }

  func beginZoomGesture() {
    zoomAtGestureStart = zoomFactor
  }

  func updateZoom(scale: CGFloat) {
    guard let device = activeCaptureDevice else { return }
    let ceiling = min(device.activeFormat.videoMaxZoomFactor, 8)
    let target = min(max(zoomAtGestureStart * scale, 1), ceiling)
    do {
      try device.lockForConfiguration()
      device.videoZoomFactor = target
      device.unlockForConfiguration()
      zoomFactor = target
    } catch {
      NSLog("[LiveKit] zoom failed: %@", error.localizedDescription)
    }
  }

  /// Hardware zoom resets whenever the camera changes hands (preview <-> call).
  private func resetZoom() {
    zoomFactor = 1
    zoomAtGestureStart = 1
  }

  /// Local, unpublished camera so the screen shows the world before and
  /// between calls. Handed off to the room on connect (one owner at a time).
  func startPreview() async {
    guard state == .disconnected || isFailed, previewTrack == nil else { return }
    let track: LocalVideoTrack
    if SettingsManager.shared.captureSource == .glasses {
      // Glasses preview is a buffer track fed by pushGlassesFrame; there is
      // no capture device to open.
      track = LocalVideoTrack.createBufferTrack(name: "glasses-preview", source: .camera)
      glassesCapturerBox.capturer = track.capturer as? BufferCapturer
    } else {
      track = LocalVideoTrack.createCameraTrack(
        options: CameraCaptureOptions(position: .back))
      glassesCapturerBox.capturer = nil
    }
    do {
      try await track.start()
      previewTrack = track
      attachGrabber(to: track)
    } catch {
      NSLog("[LiveKit] preview camera unavailable: %@", error.localizedDescription)
    }
  }

  /// Holds the live glasses BufferCapturer outside actor isolation: frames
  /// arrive at 24fps from the DAT decoder's context, and a per-frame hop to
  /// the main actor would be pure overhead. BufferCapturer.capture is
  /// thread-safe; a stale capturer after track teardown drops frames harmlessly.
  private final class GlassesCapturerBox: @unchecked Sendable {
    var capturer: BufferCapturer?
    var sawFrame = false
  }

  /// Flips on the first glasses frame; the call screen shows its waiting
  /// placeholder until then.
  @Published private(set) var hasGlassesFrame = false

  private let glassesCapturerBox = GlassesCapturerBox()

  /// Glasses frames from the DAT decoder land here and flow into whichever
  /// buffer track is live (call or preview). Freeze works unchanged: muting
  /// the publication stops delivery to the room while the grabber holds the
  /// pinned frame.
  nonisolated func pushGlassesFrame(_ pixelBuffer: CVPixelBuffer) {
    glassesCapturerBox.capturer?.capture(pixelBuffer)
    if !glassesCapturerBox.sawFrame {
      glassesCapturerBox.sawFrame = true
      Task { @MainActor in self.hasGlassesFrame = true }
    }
  }

  private func stopPreview() async {
    if let track = previewTrack {
      previewTrack = nil
      try? await track.stop()
    }
  }

  func start() async {
    guard state == .disconnected || isFailed else { return }
    guard GeminiConfig.isAgentConfigured else {
      state = .failed("Gateway not configured. Check Settings.")
      return
    }
    state = .connecting
    await stopPreview()

    usingGlassesSource = SettingsManager.shared.captureSource == .glasses

    do {
      let ticket = try await fetchTicket()
      try await room.connect(url: ticket.url, token: ticket.token)
      try await room.localParticipant.setMicrophone(enabled: true)
      // Camera failure (simulator, permission denied) degrades to voice-only
      // rather than killing the call.
      do {
        if usingGlassesSource {
          // Glasses frames arrive via pushGlassesFrame; publish a buffer
          // track with camera source so mute/freeze/agent logic is identical.
          let track = LocalVideoTrack.createBufferTrack(name: "glasses", source: .camera)
          try await track.start()
          _ = try await room.localParticipant.publish(videoTrack: track)
          localVideoTrack = track
          glassesCapturerBox.capturer = track.capturer as? BufferCapturer
        } else {
          // A video-call SDK defaults to the selfie camera; this app is a pair
          // of eyes on the world, so it opens on the back camera.
          try await room.localParticipant.setCamera(
            enabled: true,
            captureOptions: CameraCaptureOptions(position: .back))
          localVideoTrack = room.localParticipant.localVideoTracks
            .compactMap { $0.track as? LocalVideoTrack }
            .first
        }
        attachGrabber(to: localVideoTrack)
      } catch {
        NSLog("[LiveKit] camera unavailable, voice-only: %@", error.localizedDescription)
      }
      registerCaptionHandler()
      registerCardHandler()
      state = .connected
      resetZoom()
      refreshAgentStatus()
    } catch {
      state = .failed(error.localizedDescription)
      agentStatus = .none
      await room.disconnect()
      // Even a failed call leaves the user with eyes.
      await startPreview()
    }
  }

  func stop() async {
    await room.disconnect()
    localVideoTrack = nil
    state = .disconnected
    agentStatus = .none
    resetZoom()
    frozenFrame = nil
    caption = nil
    captionClearTask?.cancel()
    card = nil
    glassesCapturerBox.sawFrame = false
    hasGlassesFrame = false
    await startPreview()
  }

  // MARK: - Captions (transcription text streams)

  /// The agents framework publishes live transcriptions of both sides on the
  /// "lk.transcription" topic; each utterance segment is one stream, growing
  /// chunk by chunk. Registration is per-room and survives reconnects, so a
  /// second register on redial throws -- ignored deliberately.
  private func registerCaptionHandler() {
    Task { [weak self] in
      guard let room = self?.room else { return }
      try? await room.registerTextStreamHandler(for: "lk.transcription") { [weak self] reader, identity in
        let isAgent = identity.stringValue.hasPrefix("agent")
        var text = ""
        for try await chunk in reader {
          text += chunk
          await self?.showCaption(text, isAgent: isAgent)
        }
      }
    }
  }

  private func registerCardHandler() {
    Task { [weak self] in
      guard let room = self?.room else { return }
      try? await room.registerTextStreamHandler(for: "vc.ui") { [weak self] reader, _ in
        let json = try await reader.readAll()
        await self?.handleCardJSON(json)
      }
    }
  }

  private func handleCardJSON(_ json: String) {
    guard let data = json.data(using: .utf8),
          let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let uuid = dict["uuid"] as? String,
          let type = dict["type"] as? String
    else {
      NSLog("[LiveKit] ignoring malformed card payload (%d bytes)", json.count)
      return
    }
    let facts = ((dict["facts"] as? [[String: Any]]) ?? []).compactMap { f -> UICard.Fact? in
      guard let label = f["label"] as? String, let value = f["value"] as? String else { return nil }
      return UICard.Fact(label: label, value: value)
    }
    let items = ((dict["items"] as? [[String: Any]]) ?? []).compactMap { i -> UICard.Item? in
      guard let title = i["title"] as? String else { return nil }
      return UICard.Item(
        glyph: i["glyph"] as? String,
        title: title,
        subtitle: i["subtitle"] as? String,
        trailing: i["trailing"] as? String)
    }
    card = UICard(
      uuid: uuid,
      type: type,
      title: dict["title"] as? String,
      value: dict["value"] as? String,
      body: dict["body"] as? String,
      facts: facts,
      items: items,
      imageURL: dict["image_url"] as? String,
      fallbackText: (dict["fallback_text"] as? String) ?? "")
  }

  private func showCaption(_ text: String, isAgent: Bool) {
    guard !text.isEmpty, SettingsManager.shared.showCaptions else { return }
    caption = Caption(text: text, isAgent: isAgent)
    captionClearTask?.cancel()
    captionClearTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 4_000_000_000)
      if !Task.isCancelled { self?.caption = nil }
    }
  }

  private var isFailed: Bool {
    if case .failed = state { return true }
    return false
  }

  // MARK: - Room ticket

  private struct Ticket: Decodable {
    let url: String
    let room: String
    let token: String
  }

  /// The gateway holds the LiveKit secret and mints a short-lived per-user
  /// room JWT. The engine choice (which realtime model answers) rides along
  /// and comes back inside the token as participant metadata for the worker.
  private func fetchTicket() async throws -> Ticket {
    guard let url = URL(string: "\(GeminiConfig.agentBaseURL)/livekit-token") else {
      throw URLError(.badURL)
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 20
    request.setValue("Bearer \(GeminiConfig.agentToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: [
      "engine": SettingsManager.shared.intelligenceEngine.rawValue
    ])

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
      if (response as? HTTPURLResponse)?.statusCode == 401 {
        // A revoked (or never-approved) account: drop the credential so the
        // sign-in gate returns at next launch instead of every call failing.
        SettingsManager.shared.cloudGatewayToken = ""
        SettingsManager.shared.accountStatus = nil
      }
      let detail = OpenClawBridge.errorMessage(from: data) ?? "gateway error"
      throw NSError(domain: "LiveKitSession", code: 1, userInfo: [NSLocalizedDescriptionKey: detail])
    }
    return try JSONDecoder().decode(Ticket.self, from: data)
  }
}


// Room events arrive on SDK threads; each handler hops to the main actor and
// re-derives agent status from the room, so ordering races collapse into
// "recompute from current truth".
extension LiveKitSession: RoomDelegate {
  nonisolated func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {
    Task { @MainActor in self.refreshAgentStatus() }
  }

  nonisolated func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
    let agentLeft = participant.isAgent
    Task { @MainActor in
      if agentLeft, self.state == .connected {
        self.agentStatus = .left
      } else {
        self.refreshAgentStatus()
      }
    }
  }

  nonisolated func room(
    _ room: Room, participant: Participant, didUpdateAttributes attributes: [String: String]
  ) {
    guard participant.isAgent else { return }
    Task { @MainActor in self.refreshAgentStatus() }
  }
}

/// Keeps the most recent video frame so a freeze can pin exactly what was on
/// screen. Conversion to UIImage happens only when a pin is taken.
final class LatestFrameGrabber: VideoRenderer {
  private let lock = NSLock()
  private var latestFrame: VideoFrame?

  var isAdaptiveStreamEnabled: Bool { false }
  var adaptiveStreamSize: CGSize { .zero }

  func set(size: CGSize) {}

  func render(frame: VideoFrame) {
    lock.lock()
    latestFrame = frame
    lock.unlock()
  }

  func render(frame: VideoFrame, captureDevice: AVCaptureDevice?, captureOptions: VideoCaptureOptions?) {
    render(frame: frame)
  }

  func latestImage() -> UIImage? {
    lock.lock()
    let frame = latestFrame
    lock.unlock()
    guard let frame, let pixelBuffer = frame.toCVPixelBuffer() else { return nil }
    var ciImage = CIImage(cvPixelBuffer: pixelBuffer)
    // The sensor delivers landscape buffers; renderers apply the frame's
    // rotation tag at display time. Converting raw pixels skips that step, so
    // apply it here or every portrait pin comes out sideways.
    switch frame.rotation {
    case ._90: ciImage = ciImage.oriented(.right)
    case ._180: ciImage = ciImage.oriented(.down)
    case ._270: ciImage = ciImage.oriented(.left)
    default: break
    }
    let context = CIContext()
    guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }
    return UIImage(cgImage: cgImage)
  }
}
