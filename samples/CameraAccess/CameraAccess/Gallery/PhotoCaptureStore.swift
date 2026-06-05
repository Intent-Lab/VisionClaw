import Foundation
import UIKit

@MainActor
class PhotoCaptureStore: ObservableObject {
  static let shared = PhotoCaptureStore()

  @Published var photos: [CapturedPhoto] = []

  private var manifestURL: URL {
    CapturedPhoto.capturesDirectory.appendingPathComponent("manifest.json")
  }

  private init() {
    loadManifest()
  }

  // MARK: - Public

  @discardableResult
  func saveFrame(_ image: UIImage, description: String?) -> CapturedPhoto? {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
    let filename = "capture_\(formatter.string(from: Date())).jpg"

    guard let data = image.jpegData(compressionQuality: 0.9) else {
      NSLog("[PhotoCapture] Failed to encode JPEG")
      return nil
    }

    let fileURL = CapturedPhoto.capturesDirectory.appendingPathComponent(filename)
    do {
      try data.write(to: fileURL)
    } catch {
      NSLog("[PhotoCapture] Failed to write file: %@", error.localizedDescription)
      return nil
    }

    let photo = CapturedPhoto(
      id: UUID().uuidString,
      filename: filename,
      timestamp: Date(),
      description: description
    )

    photos.insert(photo, at: 0)
    saveManifest()

    NSLog("[PhotoCapture] Saved: %@ (%d bytes)", filename, data.count)
    return photo
  }

  func deletePhoto(_ photo: CapturedPhoto) {
    try? FileManager.default.removeItem(at: photo.fileURL)
    photos.removeAll { $0.id == photo.id }
    saveManifest()
    NSLog("[PhotoCapture] Deleted: %@", photo.filename)
  }

  func imageForPhoto(_ photo: CapturedPhoto) -> UIImage? {
    UIImage(contentsOfFile: photo.fileURL.path)
  }

  // MARK: - Manifest

  private func loadManifest() {
    guard FileManager.default.fileExists(atPath: manifestURL.path) else { return }
    do {
      let data = try Data(contentsOf: manifestURL)
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      var loaded = try decoder.decode([CapturedPhoto].self, from: data)
      // Filter out photos whose files no longer exist
      loaded = loaded.filter { FileManager.default.fileExists(atPath: $0.fileURL.path) }
      photos = loaded
      NSLog("[PhotoCapture] Loaded %d photos from manifest", photos.count)
    } catch {
      NSLog("[PhotoCapture] Failed to load manifest: %@", error.localizedDescription)
    }
  }

  private func saveManifest() {
    do {
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      encoder.outputFormatting = .prettyPrinted
      let data = try encoder.encode(photos)
      try data.write(to: manifestURL)
    } catch {
      NSLog("[PhotoCapture] Failed to save manifest: %@", error.localizedDescription)
    }
  }
}
