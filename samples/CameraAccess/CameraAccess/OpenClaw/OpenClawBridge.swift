import Foundation

/// What remains of the pre-LiveKit task bridge: the gateway JSON error parser
/// shared by the Settings screens and the room-ticket fetch. Task delegation
/// itself moved server-side -- the agent worker calls the gateway directly.
enum OpenClawBridge {
  static func errorMessage(from data: Data) -> String? {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    if let err = json["error"] as? [String: Any], let message = err["message"] as? String {
      return message
    }
    if let message = json["error"] as? String {
      return message
    }
    return nil
  }
}
