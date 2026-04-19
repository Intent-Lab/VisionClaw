import Foundation

enum WebSearchService {
  static func search(_ query: String) async -> Result<String, Error> {
    guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
          let url = URL(string: "https://api.duckduckgo.com/?q=\(encoded)&format=json&no_html=1&skip_disambig=1") else {
      return .failure(SearchError.invalidQuery)
    }
    NSLog("[WebSearch] Searching: %@", query)
    do {
      let config = URLSessionConfiguration.default
      config.timeoutIntervalForRequest = 10
      let session = URLSession(configuration: config)
      let (data, response) = try await session.data(from: url)
      guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
        return .failure(SearchError.httpError)
      }
      guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return .failure(SearchError.parseError)
      }
      var results: [String] = []
      if let answer = json["Answer"] as? String, !answer.isEmpty { results.append("Answer: \(answer)") }
      if let abstract = json["AbstractText"] as? String, !abstract.isEmpty {
        let source = json["AbstractSource"] as? String ?? ""
        results.append("\(abstract)\(source.isEmpty ? "" : " (Source: \(source))")")
      }
      if let topics = json["RelatedTopics"] as? [[String: Any]] {
        for topic in topics.prefix(5) {
          if let text = topic["Text"] as? String, !text.isEmpty { results.append("- \(text)") }
        }
      }
      if let infobox = json["Infobox"] as? [String: Any], let content = infobox["content"] as? [[String: Any]] {
        var specs: [String] = []
        for item in content.prefix(8) {
          if let label = item["label"] as? String, let value = item["value"] as? String { specs.append("\(label): \(value)") }
        }
        if !specs.isEmpty { results.append("Specifications:\n" + specs.joined(separator: "\n")) }
      }
      if results.isEmpty {
        if let definition = json["Definition"] as? String, !definition.isEmpty { results.append(definition) }
      }
      if results.isEmpty {
        return .success("No detailed results found for '\(query)'. Try a more specific query with model number or manufacturer name.")
      }
      let resultText = results.joined(separator: "\n\n")
      NSLog("[WebSearch] Found %d result sections for: %@", results.count, query)
      return .success(resultText)
    } catch {
      NSLog("[WebSearch] Error: %@", error.localizedDescription)
      return .failure(error)
    }
  }
}

enum SearchError: LocalizedError {
  case invalidQuery, httpError, parseError
  var errorDescription: String? {
    switch self {
    case .invalidQuery: return "Invalid search query"
    case .httpError: return "Search service returned an error"
    case .parseError: return "Could not parse search results"
    }
  }
}
