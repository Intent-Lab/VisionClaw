import UIKit
import WebRTC

/// Bridges UIImage frames from DAT SDK / iPhone camera into WebRTC's video pipeline.
/// Creates RTCVideoFrame from UIImage and feeds it to RTCVideoSource via the capturer delegate pattern.
class CustomVideoCapturer: RTCVideoCapturer {
  private var frameCount: Int64 = 0

  /// Push a UIImage frame into the WebRTC video track.
  /// Called on each frame from StreamSessionViewModel (24fps glasses, 30fps iPhone).
  func pushFrame(_ image: UIImage) {
    guard let cgImage = image.cgImage else { return }

    let width = cgImage.width
    let height = cgImage.height

    // Create CVPixelBuffer from CGImage
    var pixelBuffer: CVPixelBuffer?
    let attrs: [String: Any] = [
      kCVPixelBufferCGImageCompatibilityKey as String: true,
      kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
      kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
    ]
    let status = CVPixelBufferCreate(
      kCFAllocatorDefault, width, height,
      kCVPixelFormatType_32BGRA, attrs as CFDictionary,
      &pixelBuffer
    )
    guard status == kCVReturnSuccess, let buffer = pixelBuffer else { return }

    CVPixelBufferLockBaseAddress(buffer, [])
    if let context = CGContext(
      data: CVPixelBufferGetBaseAddress(buffer),
      width: width, height: height,
      bitsPerComponent: 8,
      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        | CGBitmapInfo.byteOrder32Little.rawValue
    ) {
      context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])

    // Wrap in WebRTC types and feed to video source
    let rtcPixelBuffer = RTCCVPixelBuffer(pixelBuffer: buffer)
    let timeStampNs = Int64(CACurrentMediaTime() * 1_000_000_000)
    let rtcFrame = RTCVideoFrame(
      buffer: rtcPixelBuffer,
      rotation: ._0,
      timeStampNs: timeStampNs
    )

    self.delegate?.capturer(self, didCapture: rtcFrame)

    frameCount += 1
    if frameCount == 1 || frameCount % 120 == 0 {
      NSLog("[WebRTC] Pushed frame #%lld (%dx%d)", frameCount, width, height)
    }
  }
}
