import CoreImage
import QuartzCore
import UIKit
import WebRTC

struct WebRTCSenderStats {
  let totalFrames: Int64
  let totalDroppedFrames: Int64
  let windowFramesPerSecond: Double
  let windowDroppedFrames: Int64
  let lastEnqueueDurationMs: Double?
  let sourceLabel: String
  let width: Int
  let height: Int
}

enum VideoFrameBufferFactory {
  static let pixelFormat = kCVPixelFormatType_32BGRA

  private static let ciContext = CIContext()

  static func currentTimestampNs() -> Int64 {
    Int64(CACurrentMediaTime() * 1_000_000_000)
  }

  static func makeBufferPool(
    width: Int,
    height: Int,
    pixelFormat: OSType = pixelFormat
  ) -> CVPixelBufferPool? {
    let attributes: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
      kCVPixelBufferWidthKey as String: width,
      kCVPixelBufferHeightKey as String: height,
      kCVPixelBufferCGImageCompatibilityKey as String: true,
      kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
      kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
    ]

    var pool: CVPixelBufferPool?
    let status = CVPixelBufferPoolCreate(
      kCFAllocatorDefault,
      nil,
      attributes as CFDictionary,
      &pool
    )
    guard status == kCVReturnSuccess else { return nil }
    return pool
  }

  static func makePixelBuffer(
    from image: UIImage,
    using pool: CVPixelBufferPool? = nil,
    pixelFormat: OSType = pixelFormat
  ) -> CVPixelBuffer? {
    guard let cgImage = image.cgImage else { return nil }

    let width = cgImage.width
    let height = cgImage.height
    var pixelBuffer: CVPixelBuffer?
    let status: CVReturn

    if let pool {
      status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
    } else {
      let attrs: [String: Any] = [
        kCVPixelBufferCGImageCompatibilityKey as String: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
      ]
      status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        pixelFormat,
        attrs as CFDictionary,
        &pixelBuffer
      )
    }

    guard status == kCVReturnSuccess, let buffer = pixelBuffer else { return nil }

    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

    guard
      let context = CGContext(
        data: CVPixelBufferGetBaseAddress(buffer),
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
          | CGBitmapInfo.byteOrder32Little.rawValue
      )
    else {
      return nil
    }

    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
    return buffer
  }

  static func copyPixelBuffer(
    _ source: CVPixelBuffer,
    using pool: CVPixelBufferPool? = nil,
    pixelFormat: OSType = pixelFormat
  ) -> CVPixelBuffer? {
    let width = CVPixelBufferGetWidth(source)
    let height = CVPixelBufferGetHeight(source)
    var destination: CVPixelBuffer?
    let status: CVReturn

    if let pool {
      status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &destination)
    } else {
      let attrs: [String: Any] = [
        kCVPixelBufferCGImageCompatibilityKey as String: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
      ]
      status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        pixelFormat,
        attrs as CFDictionary,
        &destination
      )
    }

    guard status == kCVReturnSuccess, let destination else { return nil }
    ciContext.render(CIImage(cvPixelBuffer: source), to: destination)
    return destination
  }
}

/// Bridges UIImage or CVPixelBuffer frames into WebRTC's video pipeline.
class CustomVideoCapturer: RTCVideoCapturer {
  private var frameCount: Int64 = 0
  private var droppedFrameCount: Int64 = 0
  private var statsWindowStart = CACurrentMediaTime()
  private var statsWindowFrames: Int64 = 0
  private var statsWindowDroppedBaseline: Int64 = 0
  private var pixelBufferPool: CVPixelBufferPool?
  private var poolSize: CGSize = .zero
  var onStatsSample: ((WebRTCSenderStats) -> Void)?

  func pushFrame(_ image: UIImage) {
    guard let cgImage = image.cgImage else {
      registerDroppedFrame(reason: "missing-cgimage")
      return
    }

    ensurePixelBufferPool(width: cgImage.width, height: cgImage.height)
    let startedAt = CACurrentMediaTime()
    guard
      let buffer = VideoFrameBufferFactory.makePixelBuffer(from: image, using: pixelBufferPool)
    else {
      registerDroppedFrame(reason: "pixel-buffer-create")
      return
    }

    pushPixelBuffer(
      buffer,
      timeStampNs: VideoFrameBufferFactory.currentTimestampNs(),
      enqueueDurationMs: (CACurrentMediaTime() - startedAt) * 1000,
      sourceLabel: "image-converted"
    )
  }

  func pushPixelBuffer(_ pixelBuffer: CVPixelBuffer, timeStampNs: Int64) {
    pushPixelBuffer(
      pixelBuffer,
      timeStampNs: timeStampNs,
      enqueueDurationMs: nil,
      sourceLabel: "pixel-buffer"
    )
  }

  private func pushPixelBuffer(
    _ pixelBuffer: CVPixelBuffer,
    timeStampNs: Int64,
    enqueueDurationMs: Double?,
    sourceLabel: String
  ) {
    let rtcPixelBuffer = RTCCVPixelBuffer(pixelBuffer: pixelBuffer)
    let rtcFrame = RTCVideoFrame(
      buffer: rtcPixelBuffer,
      rotation: ._0,
      timeStampNs: timeStampNs
    )

    delegate?.capturer(self, didCapture: rtcFrame)

    frameCount += 1
    statsWindowFrames += 1
    logSenderStatsIfNeeded(
      width: CVPixelBufferGetWidth(pixelBuffer),
      height: CVPixelBufferGetHeight(pixelBuffer),
      enqueueDurationMs: enqueueDurationMs,
      sourceLabel: sourceLabel
    )
  }

  private func ensurePixelBufferPool(width: Int, height: Int) {
    let requestedSize = CGSize(width: width, height: height)
    guard pixelBufferPool == nil || poolSize != requestedSize else { return }
    pixelBufferPool = VideoFrameBufferFactory.makeBufferPool(width: width, height: height)
    poolSize = requestedSize
  }

  private func registerDroppedFrame(reason: String) {
    droppedFrameCount += 1
    if droppedFrameCount == 1 || droppedFrameCount % 30 == 0 {
      NSLog(
        "[WebRTC] Sender dropped frame #%lld (%@)",
        droppedFrameCount,
        reason
      )
    }
  }

  private func logSenderStatsIfNeeded(
    width: Int,
    height: Int,
    enqueueDurationMs: Double?,
    sourceLabel: String
  ) {
    guard frameCount == 1 || frameCount % 60 == 0 else { return }

    let now = CACurrentMediaTime()
    let elapsed = max(now - statsWindowStart, 0.001)
    let fps = Double(statsWindowFrames) / elapsed
    let droppedInWindow = droppedFrameCount - statsWindowDroppedBaseline
    let enqueueLabel: String

    if let enqueueDurationMs {
      enqueueLabel = String(format: "%.1fms", enqueueDurationMs)
    } else {
      enqueueLabel = "direct"
    }

    NSLog(
      "[WebRTC] Sender stats frames=%lld dropped=%lld rate=%.1ffps last-enqueue=%@ source=%@ size=%dx%d",
      frameCount,
      droppedFrameCount,
      fps,
      enqueueLabel,
      sourceLabel,
      width,
      height
    )

    onStatsSample?(
      WebRTCSenderStats(
        totalFrames: frameCount,
        totalDroppedFrames: droppedFrameCount,
        windowFramesPerSecond: fps,
        windowDroppedFrames: droppedInWindow,
        lastEnqueueDurationMs: enqueueDurationMs,
        sourceLabel: sourceLabel,
        width: width,
        height: height
      )
    )

    statsWindowStart = now
    statsWindowFrames = 0
    statsWindowDroppedBaseline = droppedFrameCount
  }
}
