import Foundation
import WebRTC

struct WebRTCStreamProfile {
  let maxBitrateBps: Int
  let maxFramerate: Int
  let maxWidth: Int
  let maxHeight: Int
}

enum WebRTCConfig {
  static var signalBaseURL: String { GeminiConfig.signalBaseURL }

  static var signalingServerURL: String {
    normalizedWebSocketURL(from: signalBaseURL)
  }

  static let stunServers = [
    "stun:stun.l.google.com:19302",
    "stun:stun1.l.google.com:19302",
  ]

  static let supportModeGlassesProfile = WebRTCStreamProfile(
    maxBitrateBps: 850_000,
    maxFramerate: 12,
    maxWidth: 960,
    maxHeight: 540
  )
  static let supportModeGlassesFallbackProfile = WebRTCStreamProfile(
    maxBitrateBps: 550_000,
    maxFramerate: 10,
    maxWidth: 640,
    maxHeight: 360
  )
  static let supportModePhoneProfile = WebRTCStreamProfile(
    maxBitrateBps: 900_000,
    maxFramerate: 20,
    maxWidth: 960,
    maxHeight: 540
  )
  static let supportModePhoneFallbackProfile = WebRTCStreamProfile(
    maxBitrateBps: 550_000,
    maxFramerate: 15,
    maxWidth: 640,
    maxHeight: 360
  )

  static func supportProfile(for mode: StreamingMode) -> WebRTCStreamProfile {
    switch mode {
    case .iPhone:
      return supportModePhoneProfile
    case .glasses:
      return supportModeGlassesProfile
    }
  }

  static var isConfigured: Bool {
    let trimmed = signalBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    return !trimmed.isEmpty
      && !trimmed.contains("YOUR_")
  }

  /// Derive the HTTP base URL from the WebSocket signaling URL.
  static var httpBaseURL: String {
    normalizedHTTPURL(from: signalBaseURL)
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

  private static func normalizedWebSocketURL(from raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return trimmed }
    if trimmed.hasPrefix("wss://") || trimmed.hasPrefix("ws://") {
      return trimmed
    }
    if trimmed.hasPrefix("https://") {
      return "wss://" + String(trimmed.dropFirst("https://".count))
    }
    if trimmed.hasPrefix("http://") {
      return "ws://" + String(trimmed.dropFirst("http://".count))
    }
    return "wss://\(trimmed)"
  }

  private static func normalizedHTTPURL(from raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return trimmed }
    if trimmed.hasPrefix("https://") || trimmed.hasPrefix("http://") {
      return trimmed
    }
    if trimmed.hasPrefix("wss://") {
      return "https://" + String(trimmed.dropFirst("wss://".count))
    }
    if trimmed.hasPrefix("ws://") {
      return "http://" + String(trimmed.dropFirst("ws://".count))
    }
    return "https://\(trimmed)"
  }
}
