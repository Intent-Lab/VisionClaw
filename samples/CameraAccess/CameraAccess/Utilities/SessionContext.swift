import Foundation
import UIKit

struct SavedPhoto {
  let image: UIImage
  let description: String
  let timestamp: Date
  let pose: SpatialPose?

  init(image: UIImage, description: String, pose: SpatialPose? = nil) {
    self.image = image
    self.description = description
    self.timestamp = Date()
    self.pose = pose
  }
}

struct SessionNote: Codable, Identifiable {
  let id: UUID
  let timestamp: Date
  let text: String
  let category: String
  let pose: SpatialPose?

  init(text: String, category: String = "general", pose: SpatialPose? = nil) {
    self.id = UUID()
    self.timestamp = Date()
    self.text = text
    self.category = category
    self.pose = pose
  }
}

@MainActor
class SessionContext: ObservableObject {
  @Published var workerName: String
  @Published var jobId: String
  @Published var jobDescription: String
  @Published var siteAddress: String
  @Published var notes: [SessionNote] = []
  @Published var photosSaved: Int = 0
  var savedPhotos: [SavedPhoto] = []
  var coordinates: (lat: Double, lon: Double)?
  var reverseGeocodedAddress: String?
  let sessionStartTime: Date
  weak var spatialService: SpatialLocalizationService?

  init() {
    let settings = SettingsManager.shared
    self.workerName = settings.workerName
    self.jobId = settings.defaultJobId
    self.jobDescription = settings.defaultJobDescription
    self.siteAddress = settings.defaultSiteAddress
    self.sessionStartTime = Date()
  }

  func addNote(_ text: String, category: String = "general") {
    let pose = spatialService?.currentPose
    let note = SessionNote(text: text, category: category, pose: pose)
    notes.append(note)
    NSLog("[SessionContext] Note #%d saved (%@) [%@]: %@",
          notes.count, category, pose?.source.displayName ?? "no-pose", String(text.prefix(80)))
  }

  func addPhoto(image: UIImage, description: String) {
    let pose = spatialService?.currentPose
    savedPhotos.append(SavedPhoto(image: image, description: description, pose: pose))
    photosSaved += 1
    NSLog("[SessionContext] Photo #%d saved [%@]: %@",
          photosSaved, pose?.source.displayName ?? "no-pose", description)
  }

  func contextString() -> String {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short

    var parts: [String] = ["[CURRENT JOB CONTEXT]"]
    parts.append("Session started: \(formatter.string(from: sessionStartTime))")

    if !workerName.isEmpty { parts.append("Worker: \(workerName)") }
    if !jobId.isEmpty { parts.append("Job ID: \(jobId)") }
    if !jobDescription.isEmpty { parts.append("Job: \(jobDescription)") }
    if !siteAddress.isEmpty { parts.append("Site: \(siteAddress)") }
    if let coords = coordinates {
      var locationStr = "GPS: \(String(format: "%.5f", coords.lat)), \(String(format: "%.5f", coords.lon))"
      if let address = reverseGeocodedAddress { locationStr += " (\(address))" }
      parts.append(locationStr)
    }
    if photosSaved > 0 { parts.append("Photos saved this session: \(photosSaved)") }
    if !notes.isEmpty {
      parts.append("\nSession notes so far (\(notes.count) total):")
      for note in notes.suffix(20) {
        let time = formatter.string(from: note.timestamp)
        parts.append("- [\(note.category)] \(time): \(note.text)")
      }
    }
    return parts.joined(separator: "\n")
  }

  func notesSummary() -> String {
    if notes.isEmpty { return "No notes recorded yet this session." }
    let formatter = DateFormatter()
    formatter.timeStyle = .short
    var lines = ["\(notes.count) note(s) recorded:"]
    for note in notes {
      lines.append("- [\(note.category)] \(formatter.string(from: note.timestamp)): \(note.text)")
    }
    return lines.joined(separator: "\n")
  }
}
