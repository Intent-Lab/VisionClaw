import Foundation

enum ShortcutLaunchAction: Equatable {
  case startIPhoneStreaming(startAISession: Bool)
}

struct ShortcutLaunchRequest: Equatable, Identifiable {
  let id: UUID
  let action: ShortcutLaunchAction
}

@MainActor
final class ShortcutLaunchCoordinator: ObservableObject {
  static let shared = ShortcutLaunchCoordinator()

  @Published private(set) var pendingRequest: ShortcutLaunchRequest?

  func requestStartIPhoneStreaming(startAISession: Bool) {
    pendingRequest = ShortcutLaunchRequest(
      id: UUID(),
      action: .startIPhoneStreaming(startAISession: startAISession)
    )
  }

  func consumePendingRequest() -> ShortcutLaunchRequest? {
    let request = pendingRequest
    pendingRequest = nil
    return request
  }
}
