import LiveKit
import SwiftUI

/// Phone-mode main screen under LiveKit: camera preview, a gear, a call
/// button. The overlays the direct connection accumulated -- status pills,
/// latency meters, mode tags, cut markers -- were instrumentation for problems
/// that now live (solved) inside WebRTC and the agent worker.
struct LiveKitStreamView: View {
  @ObservedObject var session: LiveKitSession
  /// Title + caption shown while a glasses call has no frames yet -- the
  /// app's own voice for glasses-state conditions (never alert dialogs).
  var glassesPlaceholder: (title: String, caption: String)? = nil
  @State private var showSettings = false

  var body: some View {
    ZStack {
      Color.black.edgesIgnoringSafeArea(.all)

      if let track = session.localVideoTrack ?? session.previewTrack {
        SwiftUIVideoView(track, layoutMode: .fill)
          .edgesIgnoringSafeArea(.all)
          .gesture(
            MagnificationGesture()
              .onChanged { scale in session.updateZoom(scale: scale) }
              .onEnded { _ in session.beginZoomGesture() }
          )
          .onLongPressGesture(minimumDuration: 0.4) {
            Task { await session.toggleFreeze() }
          }
          .overlay(alignment: .topLeading) {
            if session.zoomFactor > 1.05 && !session.usingGlassesSource {
              Text(String(format: "%.1fx", session.zoomFactor))
                .font(.system(.footnote, design: .rounded).weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.black.opacity(0.45), in: Capsule())
                .padding(.top, 60)
                .padding(.leading, 16)
            }
          }
      }
      if session.usingGlassesSource && !session.hasGlassesFrame, let ph = glassesPlaceholder {
        VStack(spacing: 8) {
          Text(ph.title)
            .font(.title3.weight(.semibold))
            .foregroundStyle(.white)
          Text(ph.caption)
            .font(.subheadline)
            .foregroundStyle(.white.opacity(0.7))
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 32)
      }

      if case .failed(let why) = session.state {
        VStack(spacing: 12) {
          Text("Not connected").font(.headline).foregroundStyle(.white)
          Text(why)
            .font(.footnote)
            .foregroundStyle(.white.opacity(0.7))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 32)
        }
      } else if session.state == .connecting {
        VStack(spacing: 16) {
          ProgressView().tint(.white)
          Text("Connecting")
            .font(.subheadline)
            .foregroundStyle(.white.opacity(0.7))
        }
      }

      // Pinned frame floats as a card over the still-live view: the user keeps
      // their bearings, and the caption doubles as the release affordance.
      // The model is seeing nothing newer than this frame, so screen and model
      // agree on what "this" means.
      if let frozen = session.frozenFrame {
        Color.black.opacity(0.55)
          .edgesIgnoringSafeArea(.all)
          .onTapGesture { Task { await session.unfreeze() } }
        VStack(spacing: 16) {
          Image(uiImage: frozen)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: 300, maxHeight: 480)
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.9), lineWidth: 2))
            .shadow(radius: 18)
          Text("Tap anywhere to return to live")
            .font(.subheadline)
            .foregroundStyle(.white.opacity(0.85))
        }
        .allowsHitTesting(false)
      }

      // Agent liveness, top and center: a call can connect perfectly and still
      // be an empty room if the worker never dispatches. The pill makes the
      // difference visible -- stuck on "Waiting for agent" means the backend
      // is down, not that the model is ignoring you.
      if session.state == .connected && session.agentStatus != .none {
        VStack {
          AgentStatusPill(status: session.agentStatus)
            .padding(.top, 60)
          Spacer()
        }
        .animation(.easeInOut(duration: 0.2), value: session.agentStatus)
      }

      // Live captions: agent speech plain, user speech dimmed. Interim text
      // updates in place; a finished utterance lingers four seconds.
      if let caption = session.caption {
        VStack {
          Spacer()
          Text(caption.text)
            .font(.subheadline)
            .foregroundStyle(caption.isAgent ? .white : .white.opacity(0.65))
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .truncationMode(.head)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 24)
            .padding(.bottom, 116)
        }
        .allowsHitTesting(false)
        .transition(.opacity)
      }

      VStack {
        HStack {
          Spacer()
          Button { showSettings = true } label: {
            Image(systemName: "gearshape.fill")
              .font(.system(size: 18))
              .foregroundStyle(.white.opacity(0.85))
              .padding(10)
              .background(.black.opacity(0.35), in: Circle())
          }
          .padding(.trailing, 16)
        }
        Spacer()
        ZStack {
          // Shutter front and center: pinning what you see is the primary act.
          FreezeButton(session: session)
          HStack {
            LiveKitCallButton(session: session, compact: true)
              .padding(.leading, 24)
            Spacer()
          }
        }
        .padding(.bottom, 24)
      }
    }
    .sheet(isPresented: $showSettings) { SettingsView() }
    // Haptics are opt-in on iOS; a voice call that connects silently under a
    // pocketed phone gives no confirmation at all. Standard call-app grammar:
    // success on connect, error on failure, shutter-weight impacts for pinning.
    .sensoryFeedback(trigger: session.state) { _, newState in
      switch newState {
      case .connected: return .success
      case .failed: return .error
      default: return nil
      }
    }
    .sensoryFeedback(trigger: session.frozenFrame != nil) { _, pinned in
      pinned ? .impact(weight: .medium) : .impact(weight: .light)
    }
    .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
    .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
  }
}

/// One glance answers "is anything actually listening to me right now?"
struct AgentStatusPill: View {
  let status: LiveKitSession.AgentStatus

  private var label: String {
    switch status {
    case .waiting: return "Waiting for agent"
    case .starting: return "Agent starting"
    case .listening: return "Listening"
    case .thinking: return "Thinking"
    case .speaking: return "Speaking"
    case .left: return "Agent left the call"
    case .none: return ""
    }
  }

  private var dotColor: Color? {
    switch status {
    case .listening: return .green
    case .thinking: return .yellow
    case .speaking: return .blue
    case .left: return .red
    default: return nil
    }
  }

  var body: some View {
    HStack(spacing: 8) {
      if let dotColor {
        Circle().fill(dotColor).frame(width: 8, height: 8)
      } else {
        ProgressView().controlSize(.small).tint(.white)
      }
      Text(label)
        .font(.system(.footnote, design: .rounded).weight(.semibold))
        .foregroundStyle(.white)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 7)
    .background(.black.opacity(0.45), in: Capsule())
  }
}

/// Same call semantics as before: green to connect, red to hang up.
struct LiveKitCallButton: View {
  @ObservedObject var session: LiveKitSession
  var compact = false

  var body: some View {
    Button {
      Task {
        if session.isActive {
          await session.stop()
        } else {
          await session.start()
        }
      }
    } label: {
      ZStack {
        Circle()
          .fill(session.isActive ? Color.red.opacity(0.9) : Color.green.opacity(0.9))
          .frame(width: compact ? 48 : 64, height: compact ? 48 : 64)
        if session.state == .connecting {
          ProgressView().tint(.white)
        } else {
          Image(systemName: session.isActive ? "phone.down.fill" : "phone.fill")
            .font(.system(size: compact ? 18 : 24, weight: .semibold))
            .foregroundStyle(.white)
        }
      }
    }
    .disabled(session.state == .connecting)
  }
}

/// Camera-app shutter: tap to pin the current frame, tap again to release.
struct FreezeButton: View {
  @ObservedObject var session: LiveKitSession

  var body: some View {
    Button {
      Task { await session.toggleFreeze() }
    } label: {
      ZStack {
        Circle()
          .stroke(session.frozenFrame != nil ? Color.yellow : .white, lineWidth: 4)
          .frame(width: 68, height: 68)
        Circle()
          .fill(session.frozenFrame != nil ? Color.yellow : .white)
          .frame(width: 54, height: 54)
      }
    }
  }
}
