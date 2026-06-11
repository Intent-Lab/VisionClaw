import AVFoundation
import SwiftUI
import UIKit

struct IPhoneCameraPreviewSurface: UIViewRepresentable {
  let session: AVCaptureSession

  func makeUIView(context: Context) -> PreviewContainerView {
    let view = PreviewContainerView()
    view.previewLayer.videoGravity = .resizeAspectFill
    view.previewLayer.session = session
    if let connection = view.previewLayer.connection,
       connection.isVideoRotationAngleSupported(90) {
      connection.videoRotationAngle = 90
    }
    return view
  }

  func updateUIView(_ uiView: PreviewContainerView, context: Context) {
    if uiView.previewLayer.session !== session {
      uiView.previewLayer.session = session
    }
    if let connection = uiView.previewLayer.connection,
       connection.isVideoRotationAngleSupported(90) {
      connection.videoRotationAngle = 90
    }
  }

  static func dismantleUIView(_ uiView: PreviewContainerView, coordinator: ()) {
    uiView.previewLayer.session = nil
  }
}

final class PreviewContainerView: UIView {
  override class var layerClass: AnyClass {
    AVCaptureVideoPreviewLayer.self
  }

  var previewLayer: AVCaptureVideoPreviewLayer {
    layer as! AVCaptureVideoPreviewLayer
  }
}
