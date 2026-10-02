/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// MediaPickerView.swift
//
// UIKit-SwiftUI bridge component for selecting media from the device photo library.
//

import AVFoundation
import SwiftUI
import UIKit

struct MediaPickerView: UIViewControllerRepresentable {
  enum MediaType {
    case video
    case image
  }

  let mode: MediaType
  let onMediaSelected: (URL, MediaType) -> Void

  func makeUIViewController(context: Context) -> UIImagePickerController {
    let picker = UIImagePickerController()
    picker.delegate = context.coordinator
    picker.sourceType = .photoLibrary
    switch mode {
    case .video:
      picker.mediaTypes = ["public.movie"]
      picker.videoExportPreset = AVAssetExportPresetHEVCHighestQuality
    case .image:
      picker.mediaTypes = ["public.image"]
    }
    picker.allowsEditing = false
    return picker
  }

  func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

  func makeCoordinator() -> Coordinator {
    Coordinator(self)
  }

  final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    let parent: MediaPickerView

    init(_ parent: MediaPickerView) {
      self.parent = parent
    }

    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
      if let mediaType = info[.mediaType] as? String {
        if mediaType == "public.movie", let videoURL = info[.mediaURL] as? URL {
          parent.onMediaSelected(videoURL, .video)
        } else if mediaType == "public.image" {
          let image = info[.editedImage] as? UIImage ?? info[.originalImage] as? UIImage
          if let image, let imageURL = saveImageToTemporaryFile(image: image) {
            parent.onMediaSelected(imageURL, .image)
          }
        }
      }
      picker.dismiss(animated: true)
    }

    private func saveImageToTemporaryFile(image: UIImage) -> URL? {
      let tempDirectory = FileManager.default.temporaryDirectory
      let fileName = UUID().uuidString + ".jpg"
      let fileURL = tempDirectory.appendingPathComponent(fileName)

      guard let imageData = image.jpegData(compressionQuality: 0.8) else {
        return nil
      }

      do {
        try imageData.write(to: fileURL)
        return fileURL
      } catch {
        return nil
      }
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
      picker.dismiss(animated: true)
    }
  }
}
