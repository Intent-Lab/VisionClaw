import SwiftUI

/// History of tasks delegated to the cloud action agent, fetched from the
/// gateway's /tasks endpoint. Cloud backend only.
struct RecentTasksView: View {
  @State private var tasks: [TaskEntry] = []
  @State private var isLoading = true
  @State private var errorMessage: String?

  struct TaskEntry: Identifiable {
    let id: String
    let timestamp: Date?
    let prompt: String
    let result: String
  }

  var body: some View {
    Group {
      if isLoading {
        ProgressView("Loading...")
      } else if let error = errorMessage {
        VStack(spacing: 12) {
          Text("Could not load history")
            .font(.headline)
          Text(error)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding()
      } else if tasks.isEmpty {
        Text("No recent tasks")
          .foregroundStyle(.secondary)
          .padding()
      } else {
        List(tasks) { task in
          VStack(alignment: .leading, spacing: 6) {
            if let ts = task.timestamp {
              Text(ts, style: .relative)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Text(task.prompt)
              .font(.subheadline.weight(.medium))
              .lineLimit(2)
            if !task.result.isEmpty {
              Text(task.result)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            }
          }
          .padding(.vertical, 4)
        }
        .refreshable { await load() }
      }
    }
    .navigationTitle("Recent Tasks")
    .task { await load() }
  }

  private func load() async {
    guard GeminiConfig.agentBackend == .cloud, GeminiConfig.isAgentConfigured else {
      errorMessage = "Cloud backend not configured"
      isLoading = false
      return
    }

    guard let url = URL(string: "\(GeminiConfig.agentBaseURL)/tasks?limit=20") else {
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
            let items = json["tasks"] as? [[String: Any]] else {
        errorMessage = "Unexpected response"
        isLoading = false
        return
      }

      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      tasks = items.map { item in
        TaskEntry(
          id: item["id"] as? String ?? UUID().uuidString,
          timestamp: (item["ts"] as? String).flatMap { formatter.date(from: $0) },
          prompt: item["prompt"] as? String ?? "",
          result: item["result"] as? String ?? ""
        )
      }
      errorMessage = nil
      isLoading = false
    } catch {
      errorMessage = error.localizedDescription
      isLoading = false
    }
  }
}
