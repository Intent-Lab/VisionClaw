import SwiftUI
import WebRTC

/// SwiftUI wrapper for RTCMTLVideoView (Metal-based WebRTC video renderer).
/// Efficiently renders decoded remote video frames directly on the GPU.
struct RTCVideoView: UIViewRepresentable {
  let videoTrack: RTCVideoTrack?

  func makeUIView(context: Context) -> RTCMTLVideoView {
    let view = RTCMTLVideoView()
    view.videoContentMode = .scaleAspectFill
    view.clipsToBounds = true
    return view
  }

  func updateUIView(_ uiView: RTCMTLVideoView, context: Context) {
    // Remove renderer from previous track
    context.coordinator.currentTrack?.remove(uiView)

    // Attach renderer to new track
    if let track = videoTrack {
      track.add(uiView)
      context.coordinator.currentTrack = track
    } else {
      context.coordinator.currentTrack = nil
    }
  }

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  static func dismantleUIView(_ uiView: RTCMTLVideoView, coordinator: Coordinator) {
    coordinator.currentTrack?.remove(uiView)
    coordinator.currentTrack = nil
  }

  class Coordinator {
    var currentTrack: RTCVideoTrack?
  }
}
