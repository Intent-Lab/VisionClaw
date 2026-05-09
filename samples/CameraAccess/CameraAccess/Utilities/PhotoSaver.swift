import Photos
import UIKit

enum PhotoSaver {
  static func save(_ image: UIImage) async -> Result<Void, Error> {
    let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
    guard status == .authorized || status == .limited else {
      return .failure(PhotoSaverError.notAuthorized)
    }

    do {
      try await PHPhotoLibrary.shared().performChanges {
        PHAssetChangeRequest.creationRequestForAsset(from: image)
      }
      NSLog("[PhotoSaver] Photo saved to camera roll")
      return .success(())
    } catch {
      NSLog("[PhotoSaver] Failed to save photo: %@", error.localizedDescription)
      return .failure(error)
    }
  }
}

enum PhotoSaverError: LocalizedError {
  case notAuthorized
  case noFrame

  var errorDescription: String? {
    switch self {
    case .notAuthorized:
      return "Photo library access not granted. Please allow access in Settings."
    case .noFrame:
      return "No video frame available to save."
    }
  }
}
