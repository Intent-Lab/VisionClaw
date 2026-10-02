import SwiftUI
import WebRTC

/// FaceTime-style Picture-in-Picture video layout for bidirectional WebRTC streaming.
/// Shows local camera (glasses/iPhone) and remote camera (browser expert) simultaneously.
/// Tap the PiP to swap which feed is main vs. small.
struct PiPVideoView: View {
  let localFrame: UIImage?
  let remoteVideoTrack: RTCVideoTrack?
  let hasRemoteVideo: Bool

  @State private var isSwapped: Bool = false

  private let pipWidth: CGFloat = 120
  private let pipHeight: CGFloat = 160
  private let pipCornerRadius: CGFloat = 12
  private let pipPadding: CGFloat = 16

  var body: some View {
    GeometryReader { geometry in
      ZStack {
        // Main video (full screen)
        mainVideoView
          .frame(width: geometry.size.width, height: geometry.size.height)
          .clipped()

        // PiP video (small, top-right corner)
        VStack {
          HStack {
            Spacer()
            pipVideoView
              .frame(width: pipWidth, height: pipHeight)
              .clipShape(RoundedRectangle(cornerRadius: pipCornerRadius))
              .overlay(
                RoundedRectangle(cornerRadius: pipCornerRadius)
                  .stroke(Color.white.opacity(0.3), lineWidth: 1)
              )
              .shadow(color: Color.black.opacity(0.5), radius: 8, x: 0, y: 4)
              .onTapGesture {
                withAnimation(.easeInOut(duration: 0.3)) {
                  isSwapped.toggle()
                }
              }
              .padding(.top, pipPadding + geometry.safeAreaInsets.top)
              .padding(.trailing, pipPadding)
          }
          Spacer()
        }
      }
    }
    .edgesIgnoringSafeArea(.all)
  }

  // Default: main = local (glasses/iPhone), pip = remote (browser expert)
  // Swapped: main = remote, pip = local

  @ViewBuilder
  private var mainVideoView: some View {
    if isSwapped {
      if hasRemoteVideo {
        RTCVideoView(videoTrack: remoteVideoTrack)
      } else {
        remotePlaceholder
      }
    } else {
      if let frame = localFrame {
        Image(uiImage: frame)
          .resizable()
          .aspectRatio(contentMode: .fill)
      } else {
        Color.black
      }
    }
  }

  @ViewBuilder
  private var pipVideoView: some View {
    if isSwapped {
      if let frame = localFrame {
        Image(uiImage: frame)
          .resizable()
          .aspectRatio(contentMode: .fill)
      } else {
        Color.black
      }
    } else {
      if hasRemoteVideo {
        RTCVideoView(videoTrack: remoteVideoTrack)
      } else {
        remotePlaceholder
      }
    }
  }

  private var remotePlaceholder: some View {
    ZStack {
      Color(white: 0.15)
      VStack(spacing: 8) {
        Image(systemName: "person.crop.circle")
          .font(.system(size: 32))
          .foregroundColor(.white.opacity(0.4))
        Text("No video")
          .font(.system(size: 11))
          .foregroundColor(.white.opacity(0.4))
      }
    }
  }
}
