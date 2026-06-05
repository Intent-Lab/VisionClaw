import Foundation

struct CapturedPhoto: Identifiable, Codable {
  let id: String
  let filename: String
  let timestamp: Date
  var description: String?

  var fileURL: URL {
    Self.capturesDirectory.appendingPathComponent(filename)
  }

  static var capturesDirectory: URL {
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let dir = docs.appendingPathComponent("Captures", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }
}
