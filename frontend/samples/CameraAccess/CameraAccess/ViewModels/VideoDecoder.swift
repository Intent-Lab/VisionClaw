/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreMedia
import VideoToolbox

enum DecoderError: Error {
  case invalidFormat
  case configurationError(OSStatus)
  case decodingFailed(OSStatus)
}

/// Decodes compressed video frames (H.264/HEVC) into raw pixel buffers
/// using VTDecompressionSession. Used for background frame processing
/// where VideoToolbox GPU rendering is unavailable but decompression still works.
final class VideoDecoder {

  struct DecodedFrame {
    let pixelBuffer: CVPixelBuffer
    let presentationTimeStamp: CMTime
    let duration: CMTime
  }

  private var decompressionSession: VTDecompressionSession?
  private var currentFormatDescription: CMFormatDescription?
  private var onFrameDecoded: ((DecodedFrame) -> Void)?

  init() {}

  deinit {
    invalidateSession()
  }

  func setFrameCallback(_ callback: @escaping (DecodedFrame) -> Void) {
    onFrameDecoded = callback
  }

  func decode(_ sampleBuffer: CMSampleBuffer) throws {
    guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
      throw DecoderError.invalidFormat
    }

    if let currentFormat = currentFormatDescription,
      !CMFormatDescriptionEqual(currentFormat, otherFormatDescription: formatDescription)
    {
      try recreateDecompressionSession(formatDescription: formatDescription)
    } else if decompressionSession == nil {
      try createDecompressionSession(formatDescription: formatDescription)
    }

    guard let session = decompressionSession else {
      throw DecoderError.invalidFormat
    }

    var flagOut = VTDecodeInfoFlags(rawValue: 0)
    let result = VTDecompressionSessionDecodeFrame(
      session,
      sampleBuffer: sampleBuffer,
      flags: [._1xRealTimePlayback],
      frameRefcon: nil,
      infoFlagsOut: &flagOut
    )

    guard result == noErr else {
      throw DecoderError.decodingFailed(result)
    }

    VTDecompressionSessionWaitForAsynchronousFrames(session)
  }

  func invalidateSession() {
    if let session = decompressionSession {
      VTDecompressionSessionInvalidate(session)
      decompressionSession = nil
      currentFormatDescription = nil
    }
  }

  private func recreateDecompressionSession(formatDescription: CMFormatDescription) throws {
    invalidateSession()
    try createDecompressionSession(formatDescription: formatDescription)
  }

  private func createDecompressionSession(formatDescription: CMFormatDescription) throws {
    let attrs: [CFString: Any] = [
      kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
      kCVPixelBufferIOSurfacePropertiesKey: NSDictionary(),
    ]

    var outputCallback = VTDecompressionOutputCallbackRecord()
    outputCallback.decompressionOutputCallback = { refcon, _, status, _, imageBuffer, presentationTimeStamp, duration in
      guard status == noErr, let imageBuffer, let refcon else {
        return
      }

      let decoder = Unmanaged<VideoDecoder>.fromOpaque(refcon).takeUnretainedValue()
      let frame = DecodedFrame(
        pixelBuffer: imageBuffer,
        presentationTimeStamp: presentationTimeStamp,
        duration: duration
      )
      decoder.onFrameDecoded?(frame)
    }
    outputCallback.decompressionOutputRefCon = Unmanaged.passUnretained(self).toOpaque()

    var session: VTDecompressionSession?
    let status = VTDecompressionSessionCreate(
      allocator: kCFAllocatorDefault,
      formatDescription: formatDescription,
      decoderSpecification: nil,
      imageBufferAttributes: attrs as CFDictionary,
      outputCallback: &outputCallback,
      decompressionSessionOut: &session
    )

    guard let session, status == noErr else {
      throw DecoderError.configurationError(status)
    }

    decompressionSession = session
    currentFormatDescription = formatDescription

    let subType = CMFormatDescriptionGetMediaSubType(formatDescription)
    let subTypeStr = String(format: "%c%c%c%c",
                            (subType >> 24) & 0xFF,
                            (subType >> 16) & 0xFF,
                            (subType >> 8) & 0xFF,
                            subType & 0xFF)
    NSLog("[VideoDecoder] Created decompression session for codec: %@", subTypeStr)
  }
}
