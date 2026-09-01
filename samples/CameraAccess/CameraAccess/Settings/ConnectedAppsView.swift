import AuthenticationServices
import SwiftUI

/// Connect third-party apps (calendar, etc.) to the cloud agent.
///
/// Tapping Connect opens an in-app auth sheet on the gateway's /connect route;
/// the gateway runs the OAuth dance, stores the credential, and bounces back to
/// visionclaw://connect-callback so the sheet closes on its own.
struct ConnectedAppsView: View {
  @State private var apps: [ConnectableApp] = []
  @State private var isLoading = true
  @State private var errorMessage: String?
  @State private var connectingId: String?
  @State private var noticeMessage: String?

  struct ConnectableApp: Identifiable {
    let id: String
    let displayName: String
    let connected: Bool
    let available: Bool
    /// Connected, but the stored credential no longer works; only reconnecting fixes it.
    let needsReconnect: Bool
  }

  var body: some View {
    Group {
      if isLoading {
        ProgressView("Loading...")
      } else if let error = errorMessage {
        VStack(spacing: 12) {
          Text("Could not load apps").font(.headline)
          Text(error).font(.caption).foregroundStyle(.secondary)
          Button("Try Again") { Task { await load() } }
        }
        .padding()
      } else if apps.isEmpty {
        VStack(spacing: 8) {
          Text("No apps available").foregroundStyle(.secondary)
          Text("The gateway has no connectable apps configured.")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
        }
        .padding()
      } else {
        List {
          if let notice = noticeMessage {
            Section { Text(notice).font(.caption).foregroundStyle(.secondary) }
          }
          Section(footer: Text("Connected apps let the assistant act on your behalf even when your phone is asleep, such as in scheduled updates.")) {
            ForEach(apps) { app in
              HStack {
                VStack(alignment: .leading, spacing: 2) {
                  Text(app.displayName)
                  if !app.available {
                    Text("Not configured on the gateway")
                      .font(.caption)
                      .foregroundStyle(.tertiary)
                  } else if app.connected && app.needsReconnect {
                    Text("Access expired")
                      .font(.caption)
                      .foregroundStyle(.red)
                  }
                }
                Spacer()
                if connectingId == app.id {
                  ProgressView()
                } else if app.connected && app.needsReconnect {
                  Button("Reconnect") { connect(app) }
                    .buttonStyle(.borderless)
                } else if app.connected {
                  Label("Connected", systemImage: "checkmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.green)
                } else {
                  Button("Connect") { connect(app) }
                    .buttonStyle(.borderless)
                    .disabled(!app.available)
                }
              }
            }
          }
        }
        .refreshable { await load() }
      }
    }
    .navigationTitle("Connected Apps")
    .task { await load() }
  }

  // MARK: - Loading

  private func load() async {
    guard GeminiConfig.agentBackend == .cloud, GeminiConfig.isAgentConfigured else {
      errorMessage = "Cloud backend not configured"
      isLoading = false
      return
    }
    guard let url = URL(string: "\(GeminiConfig.agentBaseURL)/apps") else {
      errorMessage = "Invalid gateway URL"
      isLoading = false
      return
    }

    var request = URLRequest(url: url)
    request.setValue("Bearer \(GeminiConfig.agentToken)", forHTTPHeaderField: "Authorization")

    do {
      let (data, response) = try await URLSession.shared.data(for: request)
      guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
        errorMessage = OpenClawBridge.errorMessage(from: data) ?? "Server error"
        isLoading = false
        return
      }
      guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let items = json["apps"] as? [[String: Any]] else {
        errorMessage = "Unexpected response"
        isLoading = false
        return
      }
      apps = items.compactMap { item in
        guard let id = item["id"] as? String, let name = item["displayName"] as? String else { return nil }
        return ConnectableApp(
          id: id,
          displayName: name,
          connected: item["connected"] as? Bool ?? false,
          available: item["available"] as? Bool ?? false,
          needsReconnect: item["needs_reconnect"] as? Bool ?? false)
      }
      errorMessage = nil
      isLoading = false
    } catch {
      errorMessage = error.localizedDescription
      isLoading = false
    }
  }

  // MARK: - Connecting

  private func connect(_ app: ConnectableApp) {
    var components = URLComponents(string: "\(GeminiConfig.agentBaseURL)/connect/\(app.id)")
    components?.queryItems = [
      URLQueryItem(name: "token", value: GeminiConfig.agentToken),
      URLQueryItem(name: "scheme", value: Self.callbackScheme),
    ]
    guard let url = components?.url else { return }

    connectingId = app.id
    noticeMessage = nil

    let session = ASWebAuthenticationSession(
      url: url, callbackURLScheme: Self.callbackScheme
    ) { callbackURL, error in
      connectingId = nil
      if let error {
        // User cancelling the sheet is not an error worth surfacing.
        if (error as? ASWebAuthenticationSessionError)?.code != .canceledLogin {
          noticeMessage = error.localizedDescription
        }
        return
      }
      handleCallback(callbackURL, app: app)
    }
    session.presentationContextProvider = Self.presentationAnchor
    // Force a fresh account chooser rather than silently reusing a session.
    session.prefersEphemeralWebBrowserSession = false
    session.start()
  }

  private func handleCallback(_ url: URL?, app: ConnectableApp) {
    let items = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
    let ok = items.first(where: { $0.name == "ok" })?.value == "1"
    let detail = items.first(where: { $0.name == "detail" })?.value

    // "Signed in" and "actually works" are different outcomes; the gateway
    // verifies with a real tool call before reporting success.
    noticeMessage = ok
      ? nil
      : "\(app.displayName) was linked, but the first request was refused\(detail.map { " (\($0))" } ?? ""). It will start working once access is granted."

    Task { await load() }
  }

  private static let callbackScheme = "visionclaw"

  private static let presentationAnchor = AuthPresentationAnchor()

  final class AuthPresentationAnchor: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
      UIApplication.shared.connectedScenes
        .compactMap { ($0 as? UIWindowScene)?.keyWindow }
        .first ?? ASPresentationAnchor()
    }
  }
}
