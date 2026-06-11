import MWDATCore
import SwiftUI

private enum WorkerHomeSheet: String, Identifiable {
  case history
  case settings

  var id: String { rawValue }
}

struct HomeView: View {
  @Environment(\.scenePhase) private var scenePhase
  @ObservedObject var viewModel: StreamSessionViewModel
  @ObservedObject var wearablesViewModel: WearablesViewModel
  @State private var activeSheet: WorkerHomeSheet?

  var body: some View {
    GeometryReader { geometry in
      ZStack {
        cameraBackdrop

        VStack(alignment: .leading, spacing: 0) {
          header
            .padding(.top, geometry.safeAreaInsets.top + 10)

          Spacer(minLength: 16)

          VStack(alignment: .leading, spacing: 12) {
            sopQueuePanel(maxHeight: min(geometry.size.height * 0.46, 390))
            notices
          }
          .padding(.bottom, geometry.safeAreaInsets.bottom + 12)
        }
        .padding(.horizontal, 16)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(DesignSystem.colors.deepNavy.ignoresSafeArea())
    .toolbar(.hidden, for: .navigationBar)
    .sheet(item: $activeSheet) { sheet in
      switch sheet {
      case .history:
        NavigationStack {
          HistoryView(viewModel: viewModel)
            .background(DesignSystem.colors.adminBackground.ignoresSafeArea())
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
        }
      case .settings:
        SettingsView()
      }
    }
    .fullScreenCover(item: $viewModel.activeCaptureSOP) { sop in
      NavigationStack {
        CaptureView(viewModel: viewModel, sop: sop)
      }
    }
    .task {
      await viewModel.handleWorkerHomeEntered()
    }
    .onChange(of: scenePhase) { _, newPhase in
      guard newPhase == .active else { return }
      Task {
        await viewModel.handleWorkerAppBecameActive()
      }
    }
  }

  @ViewBuilder
  private var cameraBackdrop: some View {
    ZStack {
      if viewModel.streamingMode == .iPhone,
         let previewSession = viewModel.iPhonePreviewSession {
        IPhoneCameraPreviewSurface(session: previewSession)
          .ignoresSafeArea()
      } else if let frame = viewModel.currentVideoFrame {
        Image(uiImage: frame)
          .resizable()
          .aspectRatio(contentMode: .fill)
          .ignoresSafeArea()
      } else {
        VStack(spacing: 12) {
          ProgressView()
            .tint(DesignSystem.colors.vibrantTeal)
          Text("OPENING CAMERA")
            .font(DesignSystem.fonts.mono(size: 12, weight: .semibold))
            .foregroundColor(DesignSystem.colors.blueGrey)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DesignSystem.colors.deepNavy)
      }

      LinearGradient(
        colors: [
          .black.opacity(0.58),
          .black.opacity(0.12),
          .black.opacity(0.72)
        ],
        startPoint: .top,
        endPoint: .bottom
      )
      .ignoresSafeArea()
    }
  }

  private var header: some View {
    HStack(alignment: .top, spacing: 12) {
      VStack(alignment: .leading, spacing: 6) {
        Text("EMBARCADERO")
          .font(DesignSystem.fonts.mono(size: 11, weight: .semibold))
          .foregroundColor(DesignSystem.colors.white)
          .padding(.horizontal, 10)
          .padding(.vertical, 5)
          .background(DesignSystem.colors.brandOrange)
          .clipShape(RoundedRectangle(cornerRadius: 8))

        Text(viewModel.workerDisplayName)
          .font(DesignSystem.fonts.body(size: 28, weight: .semibold))
          .foregroundColor(DesignSystem.colors.white)
          .lineLimit(1)
          .minimumScaleFactor(0.72)

        Text("\(viewModel.activePackageTitle) · \(viewModel.currentPackageProgressText)")
          .font(DesignSystem.fonts.mono(size: 12, weight: .semibold))
          .foregroundColor(DesignSystem.colors.white.opacity(0.76))
          .lineLimit(2)
          .minimumScaleFactor(0.72)
      }

      Spacer(minLength: 12)

      HStack(spacing: 8) {
        iconButton(systemName: "arrow.clockwise") {
          Task { await viewModel.refreshWorkerContext() }
        }
        .disabled(viewModel.isSyncingOperations)
        .opacity(viewModel.isSyncingOperations ? 0.55 : 1)

        iconButton(systemName: "clock.arrow.circlepath") {
          activeSheet = .history
        }

        iconButton(systemName: "slider.horizontal.3") {
          activeSheet = .settings
        }
      }
    }
  }

  private func sopQueuePanel(maxHeight: CGFloat) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 8) {
        Text("PENDING SOPS")
          .font(DesignSystem.fonts.mono(size: 12, weight: .semibold))
          .foregroundColor(DesignSystem.colors.brandOrange)
        Spacer()
        statusPill(title: viewModel.assignmentQueueSummary, color: DesignSystem.colors.brandOrange)
      }

      HStack(spacing: 8) {
        statusPill(title: viewModel.pendingShiftLabel, color: DesignSystem.colors.adminMuted)
        statusPill(title: viewModel.selectedCaptureModeLabel, color: DesignSystem.colors.successGreen)
      }

      cameraSelector

      if viewModel.pendingTaskSOPs.isEmpty {
        VStack(alignment: .leading, spacing: 10) {
          Text("No more SOPs pending")
            .font(DesignSystem.fonts.body(size: 24, weight: .semibold))
            .foregroundColor(DesignSystem.colors.adminInk)

          Text("This package queue is complete. Refresh assignments when the next package is ready.")
            .font(DesignSystem.fonts.body(size: 15, weight: .medium))
            .foregroundColor(DesignSystem.colors.adminMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
      } else {
        ScrollView(showsIndicators: true) {
          VStack(spacing: 8) {
            ForEach(Array(viewModel.pendingTaskSOPs.enumerated()), id: \.element.id) { index, sop in
              sopQueueRow(sop, isNext: index == 0)
            }
          }
        }
        .frame(maxHeight: maxHeight)
      }
    }
    .padding(16)
    .background(DesignSystem.colors.adminSurface.opacity(0.96))
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .stroke(DesignSystem.colors.adminStroke, lineWidth: 1)
    )
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .shadow(color: .black.opacity(0.05), radius: 18, x: 0, y: 10)
  }

  private var cameraSelector: some View {
    HStack(spacing: 8) {
      cameraModeButton(
        title: "iPhone Camera",
        systemName: "iphone",
        mode: .iPhone,
        enabled: true
      )
      cameraModeButton(
        title: viewModel.hasActiveDevice ? "Glasses Camera" : "Glasses Unavailable",
        systemName: "eyeglasses",
        mode: .glasses,
        enabled: viewModel.hasActiveDevice
      )
    }
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
      HStack(spacing: 6) {
        Image(systemName: systemName)
          .font(.system(size: 11, weight: .semibold))
        Text(title)
          .font(DesignSystem.fonts.mono(size: 10, weight: .semibold))
          .lineLimit(1)
          .minimumScaleFactor(0.72)
      }
      .foregroundColor(selected ? DesignSystem.colors.white : DesignSystem.colors.adminInk)
      .padding(.horizontal, 9)
      .frame(maxWidth: .infinity)
      .frame(height: 34)
      .background(selected ? DesignSystem.colors.adminInk : DesignSystem.colors.adminBackground)
      .overlay(
        RoundedRectangle(cornerRadius: 8)
          .stroke(selected ? DesignSystem.colors.successGreen : DesignSystem.colors.adminStroke, lineWidth: 1)
      )
      .clipShape(RoundedRectangle(cornerRadius: 8))
    }
    .buttonStyle(.plain)
    .disabled(!enabled || !viewModel.canSwitchCaptureMode)
    .opacity((enabled && viewModel.canSwitchCaptureMode) ? 1 : 0.5)
  }

  private func sopQueueRow(_ sop: SOPTemplate, isNext: Bool) -> some View {
    Button {
      viewModel.presentCapture(for: sop)
    } label: {
      HStack(spacing: 12) {
        VStack(alignment: .leading, spacing: 6) {
          HStack(spacing: 8) {
            if isNext {
              Text("NEXT")
                .font(DesignSystem.fonts.mono(size: 10, weight: .semibold))
                .foregroundColor(DesignSystem.colors.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(DesignSystem.colors.successGreen)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            Text(sop.packageTitle ?? viewModel.activePackageTitle)
              .font(DesignSystem.fonts.mono(size: 10, weight: .semibold))
              .foregroundColor(DesignSystem.colors.adminMuted)
              .lineLimit(1)
          }

          Text(sop.name)
            .font(DesignSystem.fonts.body(size: 17, weight: .semibold))
            .foregroundColor(DesignSystem.colors.adminInk)
            .lineLimit(2)
            .minimumScaleFactor(0.78)

          Text("\(sop.steps.count) steps · \(sop.validationSummary)")
            .font(DesignSystem.fonts.body(size: 12, weight: .medium))
            .foregroundColor(DesignSystem.colors.adminMuted)
            .lineLimit(1)
        }

        Spacer(minLength: 8)

        HStack(spacing: 6) {
          Image(systemName: "play.fill")
            .font(.system(size: 11, weight: .bold))
          Text("START")
            .font(DesignSystem.fonts.mono(size: 11, weight: .semibold))
        }
        .foregroundColor(DesignSystem.colors.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(DesignSystem.colors.adminInk)
        .clipShape(RoundedRectangle(cornerRadius: 8))
      }
      .padding(12)
      .background(isNext ? DesignSystem.colors.successGreen.opacity(0.08) : DesignSystem.colors.adminBackground)
      .overlay(
        RoundedRectangle(cornerRadius: 8)
          .stroke(isNext ? DesignSystem.colors.successGreen.opacity(0.5) : DesignSystem.colors.adminStroke, lineWidth: 1)
      )
      .clipShape(RoundedRectangle(cornerRadius: 8))
    }
    .buttonStyle(.plain)
    .disabled(viewModel.isSyncingOperations)
  }

  @ViewBuilder
  private var notices: some View {
    if viewModel.isSyncingOperations {
      noticeRow(
        icon: "arrow.triangle.2.circlepath",
        title: "Syncing assignments",
        body: "Loading the current worker queue.",
        color: DesignSystem.colors.brandOrange
      )
    }

    if let warning = viewModel.operationsSyncWarning,
       !warning.isEmpty {
      noticeRow(
        icon: "exclamationmark.triangle.fill",
        title: "Sync warning",
        body: warning,
        color: DesignSystem.colors.adminWarning
      )
    }

    if let error = viewModel.operationsSyncError,
       !error.isEmpty {
      noticeRow(
        icon: "exclamationmark.octagon.fill",
        title: "Assignment issue",
        body: error,
        color: DesignSystem.colors.dangerRed
      )
    }
  }

  private func iconButton(systemName: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: systemName)
        .font(.system(size: 15, weight: .semibold))
        .foregroundColor(DesignSystem.colors.adminInk)
        .frame(width: 40, height: 40)
        .background(DesignSystem.colors.adminSurface)
        .overlay(
          RoundedRectangle(cornerRadius: 8)
            .stroke(DesignSystem.colors.adminStroke, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
    .buttonStyle(.plain)
  }

  private func statusPill(title: String, color: Color) -> some View {
    Text(title.uppercased())
      .font(DesignSystem.fonts.mono(size: 11, weight: .semibold))
      .foregroundColor(color)
      .lineLimit(1)
      .minimumScaleFactor(0.7)
      .padding(.horizontal, 10)
      .padding(.vertical, 7)
      .background(DesignSystem.colors.adminSurface)
      .overlay(
        RoundedRectangle(cornerRadius: 8)
          .stroke(DesignSystem.colors.adminStroke, lineWidth: 1)
      )
      .clipShape(RoundedRectangle(cornerRadius: 8))
  }

  private func assignmentMetric(_ value: String, _ label: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(value.uppercased())
        .font(DesignSystem.fonts.mono(size: 13, weight: .semibold))
        .foregroundColor(DesignSystem.colors.adminInk)
        .lineLimit(1)
        .minimumScaleFactor(0.7)

      Text(label.uppercased())
        .font(DesignSystem.fonts.mono(size: 10, weight: .semibold))
        .foregroundColor(DesignSystem.colors.adminMuted)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .background(DesignSystem.colors.adminBackground)
    .clipShape(RoundedRectangle(cornerRadius: 8))
  }

  private func noticeRow(icon: String, title: String, body: String, color: Color) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: icon)
        .font(.system(size: 14, weight: .semibold))
        .foregroundColor(color)
        .frame(width: 24, height: 24)

      VStack(alignment: .leading, spacing: 4) {
        Text(title.uppercased())
          .font(DesignSystem.fonts.mono(size: 11, weight: .semibold))
          .foregroundColor(color)

        Text(body)
          .font(DesignSystem.fonts.body(size: 13))
          .foregroundColor(DesignSystem.colors.adminMuted)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
    }
    .padding(12)
    .background(DesignSystem.colors.adminSurface)
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .stroke(color.opacity(0.35), lineWidth: 1)
    )
    .clipShape(RoundedRectangle(cornerRadius: 8))
  }
}
