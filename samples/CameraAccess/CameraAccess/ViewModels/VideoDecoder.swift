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

    var result = try decodeOnce(sampleBuffer)

    // Backgrounding invalidates the session (kVTInvalidSessionErr, -12903).
    // Previously decode() just threw, so the session stayed dead for the rest
    // of the call: locking the phone killed the decoder and unlocking never
    // brought it back, which is why the view stayed frozen on the frame from
    // the moment of lock. Rebuild and retry the frame instead.
    if result == kVTInvalidSessionErr || result == kVTVideoDecoderMalfunctionErr {
      NSLog("[VideoDecoder] session invalid (%d), rebuilding", result)
      try recreateDecompressionSession(formatDescription: formatDescription)
      result = try decodeOnce(sampleBuffer)
    }

    guard result == noErr else {
      throw DecoderError.decodingFailed(result)
    }
  }

  private func decodeOnce(_ sampleBuffer: CMSampleBuffer) throws -> OSStatus {
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
    if result == noErr {
      VTDecompressionSessionWaitForAsynchronousFrames(session)
    }
    return result
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

    // Hardware decode runs in a shared out-of-process service, which iOS tears
    // down when the app backgrounds -- that is the -12903 storm on a locked
    // screen. Software decode stays inside this process and keeps working with
    // the screen off, and at 504x896 and 2fps the cost is negligible. Fall back
    // to the default decoder if software is unavailable for this format, so a
    // foreground stream never breaks over this preference.
    let softwareSpec: [CFString: Any] = [
      kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: false,
    ]

    var session: VTDecompressionSession?
    var usedSoftware = true
    var status = VTDecompressionSessionCreate(
      allocator: kCFAllocatorDefault,
      formatDescription: formatDescription,
      decoderSpecification: softwareSpec as CFDictionary,
      imageBufferAttributes: attrs as CFDictionary,
      outputCallback: &outputCallback,
      decompressionSessionOut: &session
    )

    if status != noErr || session == nil {
      usedSoftware = false
      status = VTDecompressionSessionCreate(
        allocator: kCFAllocatorDefault,
        formatDescription: formatDescription,
        decoderSpecification: nil,
        imageBufferAttributes: attrs as CFDictionary,
        outputCallback: &outputCallback,
        decompressionSessionOut: &session
      )
    }

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
    NSLog("[VideoDecoder] Created %@ decompression session for codec: %@",
          usedSoftware ? "software" : "hardware", subTypeStr)
  }
}
