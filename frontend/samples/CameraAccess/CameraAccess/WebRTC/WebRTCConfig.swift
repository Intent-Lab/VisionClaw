import Foundation
import WebRTC

enum WebRTCConfig {
  static let signalingServerURL = Secrets.webrtcSignalingURL

  static let stunServers = [
    "stun:stun.l.google.com:19302",
    "stun:stun1.l.google.com:19302",
  ]

  static let maxBitrateBps = 2_500_000  // 2.5 Mbps
  static let maxFramerate = 24

  static var isConfigured: Bool {
    return !signalingServerURL.isEmpty
      && signalingServerURL != "ws://YOUR_MAC_IP:8080"
  }

  /// Derive the HTTP base URL from the WebSocket signaling URL.
  static var httpBaseURL: String {
    return signalingServerURL
      .replacingOccurrences(of: "wss://", with: "https://")
      .replacingOccurrences(of: "ws://", with: "http://")
  }

  /// Fetch TURN credentials from the signaling server.
  /// Falls back to STUN-only if the fetch fails.
  static func fetchIceServers() async -> [RTCIceServer] {
    var servers = [RTCIceServer(urlStrings: stunServers)]

    guard let url = URL(string: "\(httpBaseURL)/api/turn") else {
      return servers
    }

    do {
      let (data, _) = try await URLSession.shared.data(from: url)
      if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
        // Handle iceServers array format: { iceServers: [{urls, username, credential}, ...] }
        if let iceServersArray = json["iceServers"] as? [[String: Any]] {
          for entry in iceServersArray {
            guard let urls = entry["urls"] as? [String],
              let username = entry["username"] as? String,
              let credential = entry["credential"] as? String
            else { continue }
            servers.append(
              RTCIceServer(urlStrings: urls, username: username, credential: credential))
          }
          NSLog("[WebRTC] TURN credentials loaded (%d servers)", iceServersArray.count)
        }
        // Handle flat format: { urls, username, credential }
        else if let urls = json["urls"] as? [String],
          let username = json["username"] as? String,
          let credential = json["credential"] as? String
        {
          servers.append(
            RTCIceServer(urlStrings: urls, username: username, credential: credential))
          NSLog("[WebRTC] TURN credentials loaded (%d URLs)", urls.count)
        }
      }
    } catch {
      NSLog("[WebRTC] Failed to fetch TURN credentials: %@", error.localizedDescription)
    }

    return servers
  }
}
