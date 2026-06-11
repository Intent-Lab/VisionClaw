import AVFoundation
import SwiftUI
import UIKit

struct CaptureView: View {
  @Environment(\.dismiss) private var dismiss
  @ObservedObject var viewModel: StreamSessionViewModel
  @ObservedObject private var geminiAssistant: GeminiSessionViewModel
  let sop: SOPTemplate
  @State private var highlightedChecklistItemID: UUID?
  @State private var isFinishingSOP: Bool = false
  @State private var finishButtonPulse: Bool = false

  init(viewModel: StreamSessionViewModel, sop: SOPTemplate) {
    self.viewModel = viewModel
    self.sop = sop
    self._geminiAssistant = ObservedObject(wrappedValue: viewModel.geminiAssistant)
  }

  var body: some View {
    GeometryReader { geometry in
      ZStack {
        DesignSystem.colors.deepNavy
          .ignoresSafeArea()

        if viewModel.streamingMode == .iPhone, let previewSession = viewModel.iPhonePreviewSession {
          IPhoneCameraPreviewSurface(session: previewSession)
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .ignoresSafeArea()

          if !viewModel.hasReceivedFirstFrame {
            ProgressView()
              .progressViewStyle(.circular)
              .tint(DesignSystem.colors.vibrantTeal)
          }
        } else if let frame = viewModel.currentVideoFrame, viewModel.hasReceivedFirstFrame {
          Image(uiImage: frame)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .ignoresSafeArea()
        } else {
          ProgressView()
            .progressViewStyle(.circular)
            .tint(DesignSystem.colors.vibrantTeal)
        }

        if viewModel.streamingMode == .iPhone,
           viewModel.webrtcViewModel.incomingRemoteVideoEnabled,
           viewModel.webrtcViewModel.hasRemoteVideo {
          VStack {
            HStack {
              Spacer()
              RTCVideoView(videoTrack: viewModel.webrtcViewModel.remoteVideoTrack)
                .frame(width: 116, height: 156)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                  RoundedRectangle(cornerRadius: 12)
                    .stroke(DesignSystem.colors.white.opacity(0.8), lineWidth: 1)
                )
                .padding(.top, 12)
                .padding(.trailing, 12)
            }
            Spacer()
          }
        }

        VStack(spacing: 10) {
          topControls
          .padding(.top, 12)
          .padding(.horizontal, 12)

          Spacer()

          VStack(spacing: 10) {
            if shouldShowAiConversationPanel {
              aiConversationPanel
            }
            activeStepOverlay
            bottomBar
          }
          .padding(12)
        }
      }
    }
    .navigationTitle(sop.name)
    .navigationBarTitleDisplayMode(.inline)
    .toolbarColorScheme(.dark, for: .navigationBar)
    .task {
      await viewModel.beginLiveCapture(for: sop)
    }
    .onChange(of: viewModel.shouldDismissCapture) { _, shouldDismiss in
      guard shouldDismiss else { return }
      viewModel.clearCaptureDismissFlag()
      dismiss()
    }
    .onDisappear {
      viewModel.stopHoldToTalk()
      if viewModel.isSopAuditRunning {
        viewModel.userTappedEndAndShip()
      }
    }
  }

  private var topControls: some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .top, spacing: 10) {
        topStatusCluster
        Spacer(minLength: 10)
        callBackOfficeButton
      }

      topControlsCompact
    }
  }

  private var topStatusCluster: some View {
    VStack(alignment: .leading, spacing: 8) {
      captureStatusBadge
      cameraSelector
      if !viewModel.dossierPipelineStatusMessage.isEmpty || viewModel.isDossierUploading {
        pipelineStatusBadge
      }
      if viewModel.webrtcViewModel.isActive ||
          !viewModel.helpStatusMessage.isEmpty ||
          !viewModel.geminiInstructionSyncStatus.isEmpty ||
          !viewModel.aiGuideStatusMessage.isEmpty {
        supportStatusBar
      }
    }
    .frame(maxWidth: 270, alignment: .leading)
  }

  private var topControlsCompact: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .top, spacing: 10) {
        captureStatusBadge
        Spacer(minLength: 8)
        callBackOfficeButton
      }
      cameraSelector
      if !viewModel.dossierPipelineStatusMessage.isEmpty || viewModel.isDossierUploading {
        pipelineStatusBadge
      }
      if viewModel.webrtcViewModel.isActive ||
          !viewModel.helpStatusMessage.isEmpty ||
          !viewModel.geminiInstructionSyncStatus.isEmpty ||
          !viewModel.aiGuideStatusMessage.isEmpty {
        supportStatusBar
      }
    }
  }

  private var bottomBar: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 12) {
        aiGuideButton
        checkStepButton
        finishSOPButton
      }

      VStack(spacing: 10) {
        HStack(spacing: 10) {
          aiGuideButton
          checkStepButton
        }
        finishSOPButton
      }
    }
  }

  private var finishSOPButton: some View {
    Button {
      animateFinishSOPPress()
      viewModel.userTappedEndAndShip()
    } label: {
      HStack(spacing: 8) {
        if isFinishingSOP {
          Image(systemName: "checkmark.circle.fill")
            .transition(.scale.combined(with: .opacity))
        }
        Text(isFinishingSOP ? "FINISHING..." : "FINISH SOP")
      }
    }
    .brutalistDangerButton()
    .scaleEffect(finishButtonPulse ? 1.04 : 1.0)
    .opacity(isFinishingSOP ? 0.92 : 1.0)
    .animation(.spring(response: 0.25, dampingFraction: 0.65), value: finishButtonPulse)
    .animation(.easeInOut(duration: 0.2), value: isFinishingSOP)
    .disabled(isFinishingSOP)
  }

  private var aiGuideButton: some View {
    let active = geminiAssistant.isGeminiActive
    let starting = viewModel.isAiGuideStarting
    return Button {
      Task {
        await viewModel.toggleGeminiAssistant()
      }
    } label: {
      HStack(spacing: 8) {
        if starting {
          ProgressView()
            .progressViewStyle(.circular)
            .tint(DesignSystem.colors.deepNavy)
            .scaleEffect(0.75)
        } else {
          Image(systemName: active ? "waveform.circle.fill" : "sparkles")
            .font(.system(size: 15, weight: .bold))
        }
        Text(viewModel.aiGuideButtonTitle)
          .lineLimit(1)
          .minimumScaleFactor(0.72)
      }
      .font(DesignSystem.fonts.mono(size: 13, weight: .semibold))
      .foregroundColor(active || starting ? DesignSystem.colors.deepNavy : DesignSystem.colors.white)
      .padding(.horizontal, 12)
      .frame(maxWidth: .infinity)
      .frame(height: 48)
      .background(active || starting ? DesignSystem.colors.vibrantTeal : DesignSystem.colors.deepNavy)
      .overlay(
        RoundedRectangle(cornerRadius: 8)
          .stroke(DesignSystem.colors.white.opacity(0.9), lineWidth: 1)
      )
      .clipShape(RoundedRectangle(cornerRadius: 8))
    }
    .buttonStyle(.plain)
    .disabled(!viewModel.canToggleAiGuide)
    .opacity(viewModel.canToggleAiGuide ? 1 : 0.66)
  }

  private var checkStepButton: some View {
    Button {
      viewModel.requestGuidedStepValidation(trigger: "tap")
    } label: {
      HStack(spacing: 6) {
        if viewModel.isStepValidationRunning {
          ProgressView()
            .progressViewStyle(.circular)
            .tint(DesignSystem.colors.white)
            .scaleEffect(0.7)
        } else {
          Image(systemName: "checkmark.seal")
            .font(.system(size: 14, weight: .bold))
        }
        Text(viewModel.isStepValidationRunning ? "CHECKING" : "CHECK STEP")
          .lineLimit(1)
          .minimumScaleFactor(0.68)
      }
      .font(DesignSystem.fonts.mono(size: 12, weight: .semibold))
      .foregroundColor(DesignSystem.colors.white)
      .padding(.horizontal, 10)
      .frame(width: 118, height: 48)
      .background(DesignSystem.colors.deepNavy.opacity(0.9))
      .overlay(
        RoundedRectangle(cornerRadius: 8)
          .stroke(DesignSystem.colors.vibrantTeal.opacity(0.82), lineWidth: 1)
      )
      .clipShape(RoundedRectangle(cornerRadius: 8))
    }
    .buttonStyle(.plain)
    .disabled(!viewModel.canRequestStepValidation)
    .opacity(viewModel.canRequestStepValidation ? 1 : 0.62)
  }

  private var cameraSelector: some View {
    HStack(spacing: 8) {
      cameraModeButton(
        title: "iPhone",
        systemName: "iphone",
        mode: .iPhone,
        enabled: true
      )
      cameraModeButton(
        title: viewModel.hasActiveDevice ? "Glasses" : "No Glasses",
        systemName: "eyeglasses",
        mode: .glasses,
        enabled: viewModel.hasActiveDevice
      )
    }
    .frame(maxWidth: 230)
  }

  private func cameraModeButton(
    title: String,
    systemName: String,
    mode: StreamingMode,
    enabled: Bool
  ) -> some View {
    let selected = viewModel.preferredCaptureMode == mode
    return Button {
      viewModel.selectCaptureModeFromUI(mode)
    } label: {
      HStack(spacing: 5) {
        Image(systemName: systemName)
          .font(.system(size: 10, weight: .bold))
        Text(title)
          .font(DesignSystem.fonts.mono(size: 10, weight: .semibold))
          .lineLimit(1)
          .minimumScaleFactor(0.72)
      }
      .foregroundColor(selected ? DesignSystem.colors.deepNavy : DesignSystem.colors.white)
      .padding(.horizontal, 8)
      .frame(maxWidth: .infinity)
      .frame(height: 32)
      .background(selected ? DesignSystem.colors.vibrantTeal : DesignSystem.colors.deepNavy.opacity(0.72))
      .overlay(
        RoundedRectangle(cornerRadius: 8)
          .stroke(selected ? DesignSystem.colors.white.opacity(0.9) : DesignSystem.colors.vibrantTeal.opacity(0.65), lineWidth: 1)
      )
      .clipShape(RoundedRectangle(cornerRadius: 8))
    }
    .buttonStyle(.plain)
    .disabled(!enabled || !viewModel.canSwitchCaptureMode)
    .opacity((enabled && viewModel.canSwitchCaptureMode) ? 1 : 0.5)
  }

  private var captureStatusBadge: some View {
    HStack(spacing: 8) {
      Image(systemName: "record.circle")
        .font(.system(size: 13, weight: .semibold))
        .foregroundColor(DesignSystem.colors.vibrantTeal)
      Text("EXECUTING")
        .font(DesignSystem.fonts.mono(size: 12, weight: .semibold))
        .foregroundColor(DesignSystem.colors.white)
      Text(viewModel.progressText)
        .font(DesignSystem.fonts.mono(size: 12, weight: .semibold))
        .foregroundColor(DesignSystem.colors.vibrantTeal)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .background(DesignSystem.colors.deepNavy.opacity(0.72))
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .stroke(DesignSystem.colors.vibrantTeal.opacity(0.55), lineWidth: 1)
    )
    .clipShape(RoundedRectangle(cornerRadius: 8))
  }

  private var callBackOfficeButton: some View {
    Button {
      viewModel.requestSupervisorHelp()
    } label: {
      HStack(spacing: 8) {
        Image(systemName: "phone.fill")
          .font(.system(size: 15, weight: .bold))
        Text(viewModel.backOfficeCallButtonTitle)
          .font(DesignSystem.fonts.mono(size: 12, weight: .semibold))
          .lineLimit(1)
          .minimumScaleFactor(0.72)
      }
      .foregroundColor(DesignSystem.colors.deepNavy)
      .padding(.horizontal, 12)
      .frame(height: 44)
      .background(DesignSystem.colors.vibrantTeal)
      .overlay(
        RoundedRectangle(cornerRadius: 8)
          .stroke(DesignSystem.colors.white.opacity(0.92), lineWidth: 1)
      )
      .clipShape(RoundedRectangle(cornerRadius: 8))
      .shadow(color: DesignSystem.colors.vibrantTeal.opacity(0.32), radius: 16, x: 0, y: 6)
    }
    .buttonStyle(.plain)
    .disabled(!viewModel.canTapBackOfficeCall)
    .opacity(viewModel.canTapBackOfficeCall ? 1 : 0.72)
  }

  private var activeStepOverlay: some View {
    let step = currentStep
    let isHighlighted = step.map { highlightedChecklistItemID == $0.id } ?? false

    return VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .center, spacing: 8) {
        Text("STEP \(currentStepNumber)/\(max(viewModel.checklistItems.count, 1))")
          .font(DesignSystem.fonts.mono(size: 12, weight: .semibold))
          .foregroundColor(DesignSystem.colors.vibrantTeal)

        Spacer(minLength: 8)

        if let step, step.allowManualComplete || step.isChecked {
          Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.76)) {
              viewModel.toggleChecklistItem(itemID: step.id, viaVoice: false)
            }
            animateChecklistSelection(step.id)
          } label: {
            HStack(spacing: 6) {
              Image(systemName: step.isChecked ? "arrow.uturn.backward" : "checkmark")
                .font(.system(size: 11, weight: .bold))
              Text(step.isChecked ? "REOPEN" : "DONE")
                .font(DesignSystem.fonts.mono(size: 11, weight: .semibold))
            }
            .foregroundColor(step.isChecked ? DesignSystem.colors.white : DesignSystem.colors.deepNavy)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(step.isChecked ? DesignSystem.colors.deepNavy.opacity(0.88) : DesignSystem.colors.vibrantTeal)
            .clipShape(RoundedRectangle(cornerRadius: 8))
          }
          .buttonStyle(.plain)
        }
      }

      if let step {
        Text(step.name)
          .font(DesignSystem.fonts.body(size: 20, weight: .semibold))
          .foregroundColor(DesignSystem.colors.white)
          .lineLimit(2)
          .minimumScaleFactor(0.75)

        HStack(spacing: 8) {
          if !step.duration.isEmpty {
            stepTag(step.duration.uppercased(), color: DesignSystem.colors.blueGrey)
          }
          stepTag(step.validation.uppercased(), color: DesignSystem.colors.vibrantTeal)
          if step.critical {
            stepTag("CRITICAL", color: .red)
          }
          if !step.allowManualComplete && !step.isChecked {
            stepTag("VISION", color: .orange)
          }
        }
      } else {
        Text("All steps complete")
          .font(DesignSystem.fonts.body(size: 20, weight: .semibold))
          .foregroundColor(DesignSystem.colors.white)
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(DesignSystem.colors.deepNavy.opacity(0.78))
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .stroke(DesignSystem.colors.vibrantTeal.opacity(isHighlighted ? 0.95 : 0.5), lineWidth: 1)
    )
    .clipShape(RoundedRectangle(cornerRadius: 8))
  }

  private func stepTag(_ title: String, color: Color) -> some View {
    Text(title)
      .font(DesignSystem.fonts.mono(size: 10, weight: .semibold))
      .foregroundColor(color)
      .lineLimit(1)
      .padding(.horizontal, 7)
      .padding(.vertical, 4)
      .background(color.opacity(0.14))
      .clipShape(RoundedRectangle(cornerRadius: 6))
  }

  private var currentStep: ChecklistItemState? {
    viewModel.checklistItems.first(where: { !$0.isChecked }) ?? viewModel.checklistItems.last
  }

  private var currentStepNumber: Int {
    guard let step = currentStep,
          let index = viewModel.checklistItems.firstIndex(where: { $0.id == step.id })
    else { return 0 }
    return index + 1
  }

  private var pipelineStatusBadge: some View {
    let accentColor: Color = {
      switch viewModel.dossierPipelineStatusKind {
      case .info:
        return DesignSystem.colors.blueGrey
      case .active:
        return DesignSystem.colors.vibrantTeal
      case .success:
        return DesignSystem.colors.deepGreen
      case .error:
        return .red
      }
    }()

    let statusIconName: String = {
      switch viewModel.dossierPipelineStatusKind {
      case .info:
        return "info.circle.fill"
      case .active:
        return "dot.radiowaves.left.and.right"
      case .success:
        return "checkmark.seal.fill"
      case .error:
        return "exclamationmark.triangle.fill"
      }
    }()

    return HStack(spacing: 8) {
      if viewModel.isDossierUploading {
        ProgressView()
          .tint(accentColor)
          .scaleEffect(0.8)
      } else {
        Image(systemName: statusIconName)
          .foregroundColor(accentColor)
          .font(.system(size: 12, weight: .semibold))
      }

      HStack(spacing: 6) {
        if !viewModel.dossierPipelineStatusTimestamp.isEmpty {
          Text("[\(viewModel.dossierPipelineStatusTimestamp)]")
            .font(DesignSystem.fonts.mono(size: 10, weight: .semibold))
            .foregroundColor(accentColor)
            .lineLimit(1)
        }

        Text(viewModel.dossierPipelineStatusMessage)
          .font(DesignSystem.fonts.mono(size: 12, weight: .semibold))
          .foregroundColor(DesignSystem.colors.white)
          .lineLimit(2)
      }

      Spacer(minLength: 0)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .background(DesignSystem.colors.deepNavy.opacity(0.78))
    .background(accentColor.opacity(0.12))
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .stroke(accentColor.opacity(0.9), lineWidth: 1)
    )
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .transition(.move(edge: .top).combined(with: .opacity))
    .animation(.easeInOut(duration: 0.2), value: viewModel.dossierPipelineStatusMessage)
    .animation(.easeInOut(duration: 0.2), value: viewModel.isDossierUploading)
    .animation(.easeInOut(duration: 0.2), value: viewModel.dossierPipelineStatusKind)
    .animation(.easeInOut(duration: 0.2), value: viewModel.dossierPipelineStatusTimestamp)
  }

  private var supportStatusBar: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        if viewModel.webrtcViewModel.isActive {
          WebRTCStatusBar(webrtcVM: viewModel.webrtcViewModel)
        } else {
          Text("SUPPORT")
            .font(DesignSystem.fonts.mono(size: 12, weight: .semibold))
            .foregroundColor(DesignSystem.colors.vibrantTeal)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(DesignSystem.colors.deepNavy.opacity(0.6))
            .overlay(
              RoundedRectangle(cornerRadius: 16)
                .stroke(DesignSystem.colors.vibrantTeal.opacity(0.8), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }

        Spacer(minLength: 0)

        if viewModel.streamingMode == .iPhone,
           viewModel.webrtcViewModel.isActive {
          Button(
            viewModel.webrtcViewModel.incomingRemoteVideoEnabled
              ? "HIDE SUP VIDEO"
              : "SHOW SUP VIDEO"
          ) {
            viewModel.webrtcViewModel.setIncomingRemoteVideoEnabled(
              !viewModel.webrtcViewModel.incomingRemoteVideoEnabled
            )
          }
          .font(DesignSystem.fonts.mono(size: 11, weight: .semibold))
          .foregroundColor(DesignSystem.colors.white)
          .padding(.horizontal, 10)
          .padding(.vertical, 8)
          .background(DesignSystem.colors.deepNavy.opacity(0.82))
          .overlay(
            RoundedRectangle(cornerRadius: 8)
              .stroke(DesignSystem.colors.white.opacity(0.8), lineWidth: 1)
          )
          .clipShape(RoundedRectangle(cornerRadius: 8))
        }

        Text(viewModel.backOfficeCallButtonTitle)
          .font(DesignSystem.fonts.mono(size: 11, weight: .semibold))
          .foregroundColor(DesignSystem.colors.vibrantTeal)
          .padding(.horizontal, 10)
          .padding(.vertical, 7)
          .background(DesignSystem.colors.deepNavy.opacity(0.65))
          .overlay(
            RoundedRectangle(cornerRadius: 8)
              .stroke(DesignSystem.colors.vibrantTeal.opacity(0.6), lineWidth: 1)
          )
          .clipShape(RoundedRectangle(cornerRadius: 8))
      }

      if !viewModel.helpStatusMessage.isEmpty {
        Text(viewModel.helpStatusMessage)
          .font(DesignSystem.fonts.body(size: 12))
          .foregroundColor(DesignSystem.colors.white)
          .multilineTextAlignment(.leading)
      }

      if !viewModel.aiGuideStatusMessage.isEmpty {
        Text(viewModel.aiGuideStatusMessage)
          .font(DesignSystem.fonts.body(size: 12))
          .foregroundColor(DesignSystem.colors.white)
          .multilineTextAlignment(.leading)
      }

      if !viewModel.geminiInstructionSyncStatus.isEmpty {
        Text(viewModel.geminiInstructionSyncStatus)
          .font(DesignSystem.fonts.mono(size: 11, weight: .semibold))
          .foregroundColor(DesignSystem.colors.blueGrey)
          .multilineTextAlignment(.leading)
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .background(DesignSystem.colors.deepNavy.opacity(0.78))
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .stroke(DesignSystem.colors.vibrantTeal.opacity(0.8), lineWidth: 1)
    )
    .clipShape(RoundedRectangle(cornerRadius: 8))
  }

  private var shouldShowAiConversationPanel: Bool {
    geminiAssistant.isGeminiActive ||
      viewModel.isAiGuideStarting ||
      !geminiAssistant.userTranscript.isEmpty ||
      !geminiAssistant.aiTranscript.isEmpty ||
      !(geminiAssistant.errorMessage ?? "").isEmpty
  }

  private var aiConversationPanel: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Image(systemName: geminiAssistant.isModelSpeaking ? "speaker.wave.2.fill" : "waveform.circle.fill")
          .font(.system(size: 13, weight: .semibold))
          .foregroundColor(aiConversationColor)

        Text(aiConversationTitle)
          .font(DesignSystem.fonts.mono(size: 11, weight: .semibold))
          .foregroundColor(DesignSystem.colors.white)

        Spacer(minLength: 6)

        Text(aiConnectionLabel)
          .font(DesignSystem.fonts.mono(size: 10, weight: .semibold))
          .foregroundColor(aiConversationColor)
      }

      if !geminiAssistant.userTranscript.isEmpty {
        Text("You: \(geminiAssistant.userTranscript)")
          .font(DesignSystem.fonts.body(size: 12, weight: .medium))
          .foregroundColor(DesignSystem.colors.white.opacity(0.78))
          .lineLimit(2)
      }

      if !geminiAssistant.aiTranscript.isEmpty {
        Text("AI: \(geminiAssistant.aiTranscript)")
          .font(DesignSystem.fonts.body(size: 13, weight: .semibold))
          .foregroundColor(DesignSystem.colors.white)
          .lineLimit(3)
      }

      if let error = geminiAssistant.errorMessage, !error.isEmpty {
        Text(error)
          .font(DesignSystem.fonts.body(size: 12, weight: .medium))
          .foregroundColor(.white)
          .lineLimit(3)
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(DesignSystem.colors.deepNavy.opacity(0.82))
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .stroke(aiConversationColor.opacity(0.75), lineWidth: 1)
    )
    .clipShape(RoundedRectangle(cornerRadius: 8))
  }

  private var aiConversationTitle: String {
    if geminiAssistant.isModelSpeaking {
      return "AI speaking"
    }
    if viewModel.isAiGuideStarting {
      return "Starting AI guide"
    }
    if geminiAssistant.isGeminiActive && geminiAssistant.isAudioReady {
      return "AI listening"
    }
    if geminiAssistant.isGeminiActive {
      return "AI connecting"
    }
    return "AI guide"
  }

  private var aiConnectionLabel: String {
    switch geminiAssistant.connectionState {
    case .ready:
      return "READY"
    case .connecting:
      return "CONNECTING"
    case .settingUp:
      return "SETTING UP"
    case .error:
      return "ERROR"
    case .disconnected:
      return "OFF"
    }
  }

  private var aiConversationColor: Color {
    switch geminiAssistant.connectionState {
    case .ready:
      return DesignSystem.colors.vibrantTeal
    case .connecting, .settingUp:
      return .orange
    case .error:
      return .red
    case .disconnected:
      return DesignSystem.colors.blueGrey
    }
  }

  private func animateChecklistSelection(_ itemID: UUID) {
    withAnimation(.easeInOut(duration: 0.18)) {
      highlightedChecklistItemID = itemID
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
      withAnimation(.easeOut(duration: 0.22)) {
        if highlightedChecklistItemID == itemID {
          highlightedChecklistItemID = nil
        }
      }
    }
  }

  private func animateFinishSOPPress() {
    guard !isFinishingSOP else { return }

    withAnimation(.spring(response: 0.24, dampingFraction: 0.7)) {
      isFinishingSOP = true
      finishButtonPulse = true
    }

    Task { @MainActor in
      try? await Task.sleep(nanoseconds: 450_000_000)
      withAnimation(.easeOut(duration: 0.2)) {
        finishButtonPulse = false
      }

      try? await Task.sleep(nanoseconds: 700_000_000)
      withAnimation(.easeInOut(duration: 0.2)) {
        isFinishingSOP = false
      }
    }
  }
}
