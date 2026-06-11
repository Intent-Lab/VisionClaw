/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// StreamSessionViewModel.swift
//
// Core view model demonstrating video streaming from Meta wearable devices using the DAT SDK.
// This class showcases the key streaming patterns: device selection, session management,
// video frame handling, photo capture, and error handling.
//

import CoreImage
import CoreMedia
import CoreVideo
import MWDATCamera
import MWDATCore
import AVFoundation
import Combine
import Speech
import SwiftUI
import UIKit
import VideoToolbox

enum StreamingStatus {
  case streaming
  case waiting
  case stopped
}

enum StreamingMode {
  case glasses
  case iPhone
}

enum ChecklistCompletionSource: String, Codable {
  case pending
  case manual
  case voice
  case vision
}

enum SopTerminationStatus: String, Codable {
  case timedOut = "timed_out"
  case allItemsChecked = "all_items_checked"
  case userEnded = "user_ended"
}

enum GuidancePolicy: String {
  case silent
  case confirm
  case nextInstruction = "next_instruction"
  case warning
  case helpPrompt = "help_prompt"

  var instruction: String {
    switch self {
    case .silent:
      return "Stay silent unless the worker asks for help, the step changes, or a safety/compliance issue appears."
    case .confirm:
      return "Briefly confirm the observed evidence, then stay quiet."
    case .nextInstruction:
      return "Give the next step instruction once, then stay quiet while the worker acts."
    case .warning:
      return "Warn the worker only about the specific skipped, out-of-order, or unsafe condition."
    case .helpPrompt:
      return "Ask one short clarifying question or offer help because the evidence is unclear."
    }
  }
}

enum DossierPipelineStatusKind {
  case info
  case active
  case success
  case error
}

struct SOPTemplate: Identifiable, Hashable {
  let id: UUID
  let remoteID: String?
  let name: String
  let steps: [SOPStepTemplate]
  let estimatedDuration: Double
  let shiftID: String?
  let shiftName: String?
  let packageID: String?
  let packageRunID: String?
  let packageTitle: String?
  let packageVersion: Int?
  let sopVersion: Int?
  let sourceType: String
  let sortOrder: Int
  let required: Bool

  var items: [String] {
    steps.map(\.title)
  }

  var validationSummary: String {
    let labels = Array(Set(steps.map { $0.validation.uppercased() })).sorted()
    return labels.isEmpty ? "NO VALIDATION" : labels.joined(separator: " + ")
  }

  init(
    id: UUID = UUID(),
    remoteID: String? = nil,
    name: String,
    steps: [SOPStepTemplate]? = nil,
    items: [String] = [],
    estimatedDuration: Double = 15.0,
    shiftID: String? = nil,
    shiftName: String? = nil,
    packageID: String? = nil,
    packageRunID: String? = nil,
    packageTitle: String? = nil,
    packageVersion: Int? = nil,
    sopVersion: Int? = nil,
    sourceType: String = "standalone",
    sortOrder: Int = 0,
    required: Bool = true
  ) {
    self.id = id
    self.remoteID = remoteID
    self.name = name
    let resolvedSteps = steps ?? items.enumerated().map { index, item in
      SOPStepTemplate(
        id: ChecklistItemState.normalizedItemID(from: item),
        order: index + 1,
        title: item,
        aiPrompt: "Look at the image and confirm whether \"\(item)\" has been completed."
      )
    }
    self.steps = resolvedSteps.sorted { $0.order < $1.order }
    self.estimatedDuration = estimatedDuration
    self.shiftID = shiftID
    self.shiftName = shiftName
    self.packageID = packageID
    self.packageRunID = packageRunID
    self.packageTitle = packageTitle
    self.packageVersion = packageVersion
    self.sopVersion = sopVersion
    self.sourceType = sourceType
    self.sortOrder = sortOrder
    self.required = required
  }
}

private func validRemoteUUID(_ value: String?) -> String? {
  guard let value,
        UUID(uuidString: value) != nil
  else { return nil }
  return value
}

struct SOPStepTemplate: Identifiable, Hashable {
  let id: String
  let order: Int
  let title: String
  let description: String
  let duration: String
  let validation: String
  let critical: Bool
  let aiPrompt: String
  let expectedObjects: [String]
  let preconditions: [String]
  let postconditions: [String]
  let skipRisk: String
  let evidenceRequired: Bool
  let allowManualComplete: Bool

  init(
    id: String,
    order: Int,
    title: String,
    description: String = "",
    duration: String = "30s",
    validation: String = "visual",
    critical: Bool = false,
    aiPrompt: String,
    expectedObjects: [String] = [],
    preconditions: [String] = [],
    postconditions: [String] = [],
    skipRisk: String = "medium",
    evidenceRequired: Bool = true,
    allowManualComplete: Bool = true
  ) {
    self.id = id
    self.order = order
    self.title = title
    self.description = description
    self.duration = duration
    self.validation = validation
    self.critical = critical
    self.aiPrompt = aiPrompt
    self.expectedObjects = expectedObjects
    self.preconditions = preconditions
    self.postconditions = postconditions
    self.skipRisk = skipRisk
    self.evidenceRequired = evidenceRequired
    self.allowManualComplete = allowManualComplete
  }
}

private struct RemoteSOPListResponse: Decodable {
  let version: String?

  private let sops: [RemoteSOP]?
  private let data: [RemoteSOP]?
  private let templates: [RemoteSOP]?
  private let sopTemplates: [RemoteSOP]?

  var allSOPs: [RemoteSOP] {
    sops ?? data ?? templates ?? sopTemplates ?? []
  }

  private enum CodingKeys: String, CodingKey {
    case version
    case sops
    case data
    case templates
    case sopTemplates = "sop_templates"
  }
}

private struct RemoteSOP: Decodable {
  let id: String
  let name: String
  let items: [RemoteSOPItem]
  let estimatedDuration: Double?
  let updatedAt: Date?
  let createdAt: Date?

  private enum CodingKeys: String, CodingKey {
    case id
    case uuid
    case sopID = "sop_id"
    case name
    case title
    case items
    case estimatedDuration = "estimatedDuration"
    case estimatedDurationSnake = "estimated_duration"
    case duration
    case updatedAt = "updatedAt"
    case updatedAtSnake = "updated_at"
    case modifiedAtSnake = "modified_at"
    case createdAt = "createdAt"
    case createdAtSnake = "created_at"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)

    let decodedID = try container.decodeIfPresent(String.self, forKey: .id)
    let decodedUUID = try container.decodeIfPresent(String.self, forKey: .uuid)
    let decodedSopID = try container.decodeIfPresent(String.self, forKey: .sopID)
    id = decodedID ?? decodedUUID ?? decodedSopID ?? UUID().uuidString

    let decodedName = try container.decodeIfPresent(String.self, forKey: .name)
    let decodedTitle = try container.decodeIfPresent(String.self, forKey: .title)
    name = decodedName ?? decodedTitle ?? "Untitled SOP"

    if let decodedItems = try container.decodeIfPresent([RemoteSOPItem].self, forKey: .items) {
      items = decodedItems
    } else if let stringItems = try container.decodeIfPresent([String].self, forKey: .items) {
      items = stringItems.map { RemoteSOPItem(name: $0) }
    } else {
      items = []
    }

    if let estimate = try container.decodeIfPresent(Double.self, forKey: .estimatedDuration) {
      estimatedDuration = estimate
    } else if let estimate = try container.decodeIfPresent(Double.self, forKey: .estimatedDurationSnake) {
      estimatedDuration = estimate
    } else if let estimate = try container.decodeIfPresent(Double.self, forKey: .duration) {
      estimatedDuration = estimate
    } else if let estimateInt = try container.decodeIfPresent(Int.self, forKey: .estimatedDuration) {
      estimatedDuration = Double(estimateInt)
    } else if let estimateInt = try container.decodeIfPresent(Int.self, forKey: .estimatedDurationSnake) {
      estimatedDuration = Double(estimateInt)
    } else if let estimateInt = try container.decodeIfPresent(Int.self, forKey: .duration) {
      estimatedDuration = Double(estimateInt)
    } else {
      estimatedDuration = nil
    }

    let decodedUpdatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
    let decodedUpdatedAtSnake = try container.decodeIfPresent(String.self, forKey: .updatedAtSnake)
    let decodedModifiedAtSnake = try container.decodeIfPresent(String.self, forKey: .modifiedAtSnake)
    let updatedRaw = decodedUpdatedAt ?? decodedUpdatedAtSnake ?? decodedModifiedAtSnake

    let decodedCreatedAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
    let decodedCreatedAtSnake = try container.decodeIfPresent(String.self, forKey: .createdAtSnake)
    let createdRaw = decodedCreatedAt ?? decodedCreatedAtSnake

    updatedAt = Self.parseDate(updatedRaw)
    createdAt = Self.parseDate(createdRaw)
  }

  private static func parseDate(_ raw: String?) -> Date? {
    guard let raw, !raw.isEmpty else { return nil }

    let isoFormatter = ISO8601DateFormatter()
    isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = isoFormatter.date(from: raw) { return date }

    let fallbackISO = ISO8601DateFormatter()
    if let date = fallbackISO.date(from: raw) { return date }

    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return formatter.date(from: raw)
  }
}

private struct RemoteSOPItem: Decodable {
  let name: String

  init(name: String) {
    self.name = name
  }

  private enum CodingKeys: String, CodingKey {
    case name
    case title
    case label
    case item
  }

  init(from decoder: Decoder) throws {
    if let singleValueContainer = try? decoder.singleValueContainer(),
      let raw = try? singleValueContainer.decode(String.self)
    {
      name = raw
      return
    }

    let container = try decoder.container(keyedBy: CodingKeys.self)
    let decodedName = try container.decodeIfPresent(String.self, forKey: .name)
    let decodedTitle = try container.decodeIfPresent(String.self, forKey: .title)
    let decodedLabel = try container.decodeIfPresent(String.self, forKey: .label)
    let decodedItem = try container.decodeIfPresent(String.self, forKey: .item)
    name = decodedName ?? decodedTitle ?? decodedLabel ?? decodedItem ?? "Unknown Item"
  }
}

private final class ConversationAudioRecorder: @unchecked Sendable {
  private enum Source: String {
    case input = "worker_input"
    case output = "gemini_output"
  }

  private struct AudioChunk {
    let data: Data
    let sampleRate: Double
    let source: Source
    let hostTime: CFTimeInterval
  }

  private let queue = DispatchQueue(label: "sop.conversation.audio.recorder", qos: .userInitiated)
  private let sessionID: String?
  private let recordingStartHostTime: CFTimeInterval
  private let outputURL: URL
  private var chunks: [AudioChunk] = []
  private var isFinishing = false
  private var inputAudioChunkCount = 0
  private var outputAudioChunkCount = 0

  init(sessionID: String?, recordingStartHostTime: CFTimeInterval = CACurrentMediaTime()) {
    self.sessionID = sessionID
    self.recordingStartHostTime = recordingStartHostTime
    self.outputURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("sop_\(sessionID ?? UUID().uuidString)_conversation")
      .appendingPathExtension("m4a")
    try? FileManager.default.removeItem(at: outputURL)
  }

  func appendInputAudio(_ data: Data) {
    append(data, sampleRate: GeminiConfig.inputAudioSampleRate, source: .input)
  }

  func appendOutputAudio(_ data: Data) {
    append(data, sampleRate: GeminiConfig.outputAudioSampleRate, source: .output)
  }

  func finishAudioFile() async -> URL? {
    await withCheckedContinuation { continuation in
      queue.async { [weak self] in
        guard let self else {
          continuation.resume(returning: nil)
          return
        }

        self.isFinishing = true
        let chunks = self.chunks
        let inputCount = self.inputAudioChunkCount
        let outputCount = self.outputAudioChunkCount
        guard !chunks.isEmpty else {
          continuation.resume(returning: nil)
          return
        }

        let mixedPCM = Self.renderMixedPCM(
          chunks: chunks,
          recordingStartHostTime: self.recordingStartHostTime
        )
        guard !mixedPCM.isEmpty else {
          continuation.resume(returning: nil)
          return
        }

        Self.writeAACAudio(data: mixedPCM, outputURL: self.outputURL) { url in
          let byteCount = url.flatMap { url -> Int? in
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
              return nil
            }
            return attributes[.size] as? Int
          } ?? 0
          Task {
            await WorkerTelemetry.shared.record(
              "conversation_audio_finish",
              source: "media_upload",
              stage: url == nil ? "failed" : "completed",
              sessionID: self.sessionID,
              metricValue: Double(byteCount),
              metricUnit: "bytes",
              payload: [
                "bytes": byteCount,
                "input_audio_chunks": inputCount,
                "output_audio_chunks": outputCount
              ]
            )
          }
          continuation.resume(returning: url)
        }
      }
    }
  }

  private func append(_ data: Data, sampleRate: Double, source: Source) {
    guard !data.isEmpty else { return }
    let hostTime = CACurrentMediaTime()
    queue.async { [weak self] in
      guard let self, !self.isFinishing else { return }
      switch source {
      case .input:
        self.inputAudioChunkCount += 1
      case .output:
        self.outputAudioChunkCount += 1
      }
      self.chunks.append(
        AudioChunk(
          data: data,
          sampleRate: sampleRate,
          source: source,
          hostTime: hostTime
        )
      )
    }
  }

  private static func renderMixedPCM(
    chunks: [AudioChunk],
    recordingStartHostTime: CFTimeInterval
  ) -> Data {
    let targetSampleRate = GeminiConfig.outputAudioSampleRate
    var renderedChunks: [(startFrame: Int, samples: [Float])] = []
    var totalFrameCount = 0

    for chunk in chunks {
      let samples = resampledFloatSamples(
        from: chunk.data,
        sourceSampleRate: chunk.sampleRate,
        targetSampleRate: targetSampleRate
      )
      guard !samples.isEmpty else { continue }
      let startFrame = max(0, Int((chunk.hostTime - recordingStartHostTime) * targetSampleRate))
      totalFrameCount = max(totalFrameCount, startFrame + samples.count)
      renderedChunks.append((startFrame, samples))
    }

    guard totalFrameCount > 0 else { return Data() }

    var mixed = [Float](repeating: 0, count: totalFrameCount)
    var contributors = [UInt8](repeating: 0, count: totalFrameCount)
    for rendered in renderedChunks {
      for (offset, sample) in rendered.samples.enumerated() {
        let index = rendered.startFrame + offset
        guard index < mixed.count else { continue }
        mixed[index] += sample
        if contributors[index] < UInt8.max {
          contributors[index] += 1
        }
      }
    }

    var int16Samples = [Int16](repeating: 0, count: totalFrameCount)
    for index in mixed.indices {
      let count = contributors[index]
      let normalized = count > 1 ? mixed[index] / Float(count) : mixed[index]
      let clamped = max(-1.0, min(1.0, normalized))
      int16Samples[index] = Int16(clamped * Float(Int16.max))
    }

    return int16Samples.withUnsafeBufferPointer { Data(buffer: $0) }
  }

  private static func resampledFloatSamples(
    from data: Data,
    sourceSampleRate: Double,
    targetSampleRate: Double
  ) -> [Float] {
    let sourceFrameCount = data.count / MemoryLayout<Int16>.size
    guard sourceFrameCount > 0 else { return [] }

    let sourceSamples: [Float] = data.withUnsafeBytes { rawBuffer in
      guard let baseAddress = rawBuffer.bindMemory(to: Int16.self).baseAddress else { return [] }
      return (0..<sourceFrameCount).map { Float(baseAddress[$0]) / Float(Int16.max) }
    }

    guard sourceSampleRate != targetSampleRate else { return sourceSamples }

    let outputFrameCount = max(
      1,
      Int((Double(sourceSamples.count) * targetSampleRate / sourceSampleRate).rounded())
    )
    var output = [Float](repeating: 0, count: outputFrameCount)
    for index in 0..<outputFrameCount {
      let sourcePosition = Double(index) * sourceSampleRate / targetSampleRate
      let lowerIndex = min(Int(sourcePosition), sourceSamples.count - 1)
      let upperIndex = min(lowerIndex + 1, sourceSamples.count - 1)
      let fraction = Float(sourcePosition - Double(lowerIndex))
      output[index] = sourceSamples[lowerIndex] * (1 - fraction) + sourceSamples[upperIndex] * fraction
    }
    return output
  }

  private static func writeAACAudio(
    data: Data,
    outputURL: URL,
    completion: @escaping (URL?) -> Void
  ) {
    try? FileManager.default.removeItem(at: outputURL)
    guard let writer = try? AVAssetWriter(outputURL: outputURL, fileType: .m4a) else {
      completion(nil)
      return
    }

    let audioInput = AVAssetWriterInput(
      mediaType: .audio,
      outputSettings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: GeminiConfig.outputAudioSampleRate,
        AVNumberOfChannelsKey: Int(GeminiConfig.audioChannels),
        AVEncoderBitRateKey: 64_000
      ]
    )
    audioInput.expectsMediaDataInRealTime = false
    guard writer.canAdd(audioInput) else {
      completion(nil)
      return
    }
    writer.add(audioInput)
    guard writer.startWriting() else {
      completion(nil)
      return
    }
    writer.startSession(atSourceTime: .zero)

    guard let formatDescription = makePCMFormatDescription() else {
      completion(nil)
      return
    }

    let bytesPerFrame = MemoryLayout<Int16>.size * Int(GeminiConfig.audioChannels)
    let framesPerChunk = Int(GeminiConfig.outputAudioSampleRate)
    let bytesPerChunk = framesPerChunk * bytesPerFrame
    var byteOffset = 0
    var accumulatedSampleCount = 0
    var appendFailed = false

    while byteOffset < data.count, !appendFailed {
      while !audioInput.isReadyForMoreMediaData {
        Thread.sleep(forTimeInterval: 0.005)
      }
      let byteCount = min(bytesPerChunk, data.count - byteOffset)
      let alignedByteCount = byteCount - (byteCount % bytesPerFrame)
      guard alignedByteCount > 0 else { break }
      let chunkData = data.subdata(in: byteOffset..<(byteOffset + alignedByteCount))
      let presentationTime = CMTime(
        value: CMTimeValue(accumulatedSampleCount),
        timescale: CMTimeScale(GeminiConfig.outputAudioSampleRate)
      )
      guard let sampleBuffer = makeAudioSampleBuffer(
        data: chunkData,
        sampleRate: GeminiConfig.outputAudioSampleRate,
        channels: GeminiConfig.audioChannels,
        formatDescription: formatDescription,
        presentationTime: presentationTime
      ) else {
        appendFailed = true
        break
      }
      appendFailed = !audioInput.append(sampleBuffer)
      byteOffset += alignedByteCount
      accumulatedSampleCount += alignedByteCount / bytesPerFrame
    }

    audioInput.markAsFinished()
    writer.finishWriting {
      completion(!appendFailed && writer.status == .completed ? outputURL : nil)
    }
  }

  private static func makePCMFormatDescription() -> CMAudioFormatDescription? {
    var streamDescription = AudioStreamBasicDescription(
      mSampleRate: GeminiConfig.outputAudioSampleRate,
      mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: AudioFormatFlags(kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked),
      mBytesPerPacket: UInt32(MemoryLayout<Int16>.size) * GeminiConfig.audioChannels,
      mFramesPerPacket: 1,
      mBytesPerFrame: UInt32(MemoryLayout<Int16>.size) * GeminiConfig.audioChannels,
      mChannelsPerFrame: GeminiConfig.audioChannels,
      mBitsPerChannel: UInt32(MemoryLayout<Int16>.size * 8),
      mReserved: 0
    )
    var formatDescription: CMAudioFormatDescription?
    let status = CMAudioFormatDescriptionCreate(
      allocator: kCFAllocatorDefault,
      asbd: &streamDescription,
      layoutSize: 0,
      layout: nil,
      magicCookieSize: 0,
      magicCookie: nil,
      extensions: nil,
      formatDescriptionOut: &formatDescription
    )
    guard status == noErr else { return nil }
    return formatDescription
  }

  private static func makeAudioSampleBuffer(
    data: Data,
    sampleRate: Double,
    channels: UInt32,
    formatDescription: CMAudioFormatDescription,
    presentationTime: CMTime
  ) -> CMSampleBuffer? {
    let bytesPerFrame = Int(MemoryLayout<Int16>.size * Int(channels))
    guard bytesPerFrame > 0 else { return nil }
    let sampleCount = data.count / bytesPerFrame
    guard sampleCount > 0 else { return nil }

    var blockBuffer: CMBlockBuffer?
    var status = CMBlockBufferCreateWithMemoryBlock(
      allocator: kCFAllocatorDefault,
      memoryBlock: nil,
      blockLength: data.count,
      blockAllocator: nil,
      customBlockSource: nil,
      offsetToData: 0,
      dataLength: data.count,
      flags: 0,
      blockBufferOut: &blockBuffer
    )
    guard status == noErr, let blockBuffer else { return nil }

    status = data.withUnsafeBytes { rawBuffer in
      guard let baseAddress = rawBuffer.baseAddress else { return OSStatus(-1) }
      return CMBlockBufferReplaceDataBytes(
        with: baseAddress,
        blockBuffer: blockBuffer,
        offsetIntoDestination: 0,
        dataLength: data.count
      )
    }
    guard status == noErr else { return nil }

    let sampleDuration = CMTime(value: 1, timescale: CMTimeScale(sampleRate))
    var timing = CMSampleTimingInfo(
      duration: sampleDuration,
      presentationTimeStamp: presentationTime,
      decodeTimeStamp: .invalid
    )
    var sampleBuffer: CMSampleBuffer?
    status = CMSampleBufferCreate(
      allocator: kCFAllocatorDefault,
      dataBuffer: blockBuffer,
      dataReady: true,
      makeDataReadyCallback: nil,
      refcon: nil,
      formatDescription: formatDescription,
      sampleCount: sampleCount,
      sampleTimingEntryCount: 1,
      sampleTimingArray: &timing,
      sampleSizeEntryCount: 0,
      sampleSizeArray: nil,
      sampleBufferOut: &sampleBuffer
    )
    guard status == noErr else { return nil }
    return sampleBuffer
  }
}

private enum ConversationAudioMuxer {
  static func mux(videoURL: URL, audioURL: URL, outputURL: URL) async -> URL? {
    await withCheckedContinuation { continuation in
      let videoAsset = AVURLAsset(url: videoURL)
      let audioAsset = AVURLAsset(url: audioURL)
      let composition = AVMutableComposition()

      guard
        let videoTrack = videoAsset.tracks(withMediaType: .video).first,
        let compositionVideoTrack = composition.addMutableTrack(
          withMediaType: .video,
          preferredTrackID: kCMPersistentTrackID_Invalid
        )
      else {
        continuation.resume(returning: nil)
        return
      }

      do {
        try compositionVideoTrack.insertTimeRange(
          CMTimeRange(start: .zero, duration: videoAsset.duration),
          of: videoTrack,
          at: .zero
        )
        compositionVideoTrack.preferredTransform = videoTrack.preferredTransform

        if let audioTrack = audioAsset.tracks(withMediaType: .audio).first,
           let compositionAudioTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
           ) {
          let audioDuration = CMTimeCompare(audioAsset.duration, videoAsset.duration) > 0
            ? videoAsset.duration
            : audioAsset.duration
          if CMTimeCompare(audioDuration, .zero) > 0 {
            try compositionAudioTrack.insertTimeRange(
              CMTimeRange(start: .zero, duration: audioDuration),
              of: audioTrack,
              at: .zero
            )
          }
        }
      } catch {
        NSLog("[SOPRecorder] Failed to build mixed replay composition: %@", error.localizedDescription)
        continuation.resume(returning: nil)
        return
      }

      try? FileManager.default.removeItem(at: outputURL)
      guard let exporter = AVAssetExportSession(
        asset: composition,
        presetName: AVAssetExportPresetPassthrough
      ) else {
        continuation.resume(returning: nil)
        return
      }
      exporter.outputURL = outputURL
      exporter.outputFileType = .mp4
      exporter.shouldOptimizeForNetworkUse = true
      exporter.exportAsynchronously {
        continuation.resume(returning: exporter.status == .completed ? outputURL : nil)
      }
    }
  }
}

private enum SopMediaBackgroundTask {
  static func begin(name: String) async -> UIBackgroundTaskIdentifier {
    await MainActor.run {
      UIApplication.shared.beginBackgroundTask(withName: name) {
        NSLog("[SOPRecorder] Background media finalize task expired")
      }
    }
  }

  static func end(_ identifier: UIBackgroundTaskIdentifier) async {
    guard identifier != .invalid else { return }
    await MainActor.run {
      UIApplication.shared.endBackgroundTask(identifier)
    }
  }
}

private enum SopSessionMediaFinalizer {
  static func finishRecording(
    wasIPhoneRecording: Bool,
    iPhoneCameraManager: IPhoneCameraManager?,
    conversationAudioRecorder: ConversationAudioRecorder?,
    sopVideoRecorder: SopVideoRecorder?
  ) async -> URL? {
    if wasIPhoneRecording {
      let phoneVideoURL = await iPhoneCameraManager?.stopRecording()
      let conversationAudioURL = await conversationAudioRecorder?.finishAudioFile()
      iPhoneCameraManager?.stop()

      guard let phoneVideoURL else {
        return nil
      }

      guard let conversationAudioURL else {
        return phoneVideoURL
      }

      let mixedURL = phoneVideoURL
        .deletingLastPathComponent()
        .appendingPathComponent(phoneVideoURL.deletingPathExtension().lastPathComponent + "_mixed")
        .appendingPathExtension("mp4")
      if let muxedURL = await ConversationAudioMuxer.mux(
        videoURL: phoneVideoURL,
        audioURL: conversationAudioURL,
        outputURL: mixedURL
      ) {
        try? FileManager.default.removeItem(at: phoneVideoURL)
        try? FileManager.default.removeItem(at: conversationAudioURL)
        return muxedURL
      }

      NSLog("[SOPRecorder] iPhone mixed audio mux failed; returning phone recording")
      return phoneVideoURL
    }

    return await sopVideoRecorder?.finishRecording()
  }
}

private final class SopVideoRecorder: @unchecked Sendable {
  private enum AudioTrackKind: String {
    case input = "worker_input"
    case output = "gemini_output"
  }

  private struct PendingAudioChunk {
    let data: Data
    let sampleRate: Double
    let source: AudioTrackKind
    let hostTime: CFTimeInterval
  }

  private let queue = DispatchQueue(label: "sop.video.recorder", qos: .userInitiated)
  private let sessionID: String?
  private var writer: AVAssetWriter?
  private var writerInput: AVAssetWriterInput?
  private var inputAudioInput: AVAssetWriterInput?
  private var outputAudioInput: AVAssetWriterInput?
  private var inputAudioFormatDescription: CMAudioFormatDescription?
  private var outputAudioFormatDescription: CMAudioFormatDescription?
  private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
  private let recordingStartHostTime: CFTimeInterval
  private let conversationRecorder: ConversationAudioRecorder
  private(set) var outputURL: URL?
  private var isFinishing = false
  private var appendedFrameCount = 0
  private var inputAudioChunkCount = 0
  private var outputAudioChunkCount = 0
  private var droppedAudioChunkCount = 0
  private var pendingAudioChunks: [PendingAudioChunk] = []
  private let sourcePixelFormat = VideoFrameBufferFactory.pixelFormat
  private let maxPendingAudioChunks = 160

  init(sessionID: String? = nil) {
    self.sessionID = sessionID
    let startHostTime = CACurrentMediaTime()
    self.recordingStartHostTime = startHostTime
    self.conversationRecorder = ConversationAudioRecorder(
      sessionID: sessionID,
      recordingStartHostTime: startHostTime
    )
    let fileURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("sop_\(sessionID ?? UUID().uuidString)")
      .appendingPathExtension("mp4")
    try? FileManager.default.removeItem(at: fileURL)
    self.outputURL = fileURL
    NSLog("[SOPRecorder] Prepared output path at %@", fileURL.path)
    Task {
      await WorkerTelemetry.shared.record(
        "sop_recorder_start",
        source: "media_upload",
        stage: "prepared",
        sessionID: sessionID,
        payload: ["path_ready": true]
      )
    }
  }

  func appendFrame(_ image: UIImage) {
    queue.async { [weak self] in
      guard let self, !self.isFinishing else { return }
      guard let cgImage = image.cgImage else { return }
      self.configureWriterIfNeeded(width: cgImage.width, height: cgImage.height)

      guard
        let pixelBuffer = VideoFrameBufferFactory.makePixelBuffer(
          from: image,
          using: self.pixelBufferAdaptor?.pixelBufferPool
        )
      else {
        return
      }

      self.appendPixelBufferInternal(pixelBuffer)
    }
  }

  func appendPixelBuffer(_ pixelBuffer: CVPixelBuffer) {
    queue.async { [weak self] in
      guard let self, !self.isFinishing else { return }
      self.configureWriterIfNeeded(
        width: CVPixelBufferGetWidth(pixelBuffer),
        height: CVPixelBufferGetHeight(pixelBuffer)
      )
      self.appendPixelBufferInternal(pixelBuffer)
    }
  }

  func appendInputAudio(_ data: Data) {
    guard !data.isEmpty else { return }
    conversationRecorder.appendInputAudio(data)
    queue.async { [weak self] in
      self?.inputAudioChunkCount += 1
    }
  }

  func appendOutputAudio(_ data: Data) {
    guard !data.isEmpty else { return }
    conversationRecorder.appendOutputAudio(data)
    queue.async { [weak self] in
      self?.outputAudioChunkCount += 1
    }
  }

  func finishRecording() async -> URL? {
    await withCheckedContinuation { continuation in
      queue.async { [weak self] in
        guard let self else {
          continuation.resume(returning: nil)
          return
        }

        NSLog(
          "[SOPRecorder] finishRecording called (frames=%d, inputAudio=%d, outputAudio=%d, droppedAudio=%d, hasWriter=%@, outputURL=%@)",
          self.appendedFrameCount,
          self.inputAudioChunkCount,
          self.outputAudioChunkCount,
          self.droppedAudioChunkCount,
          self.writer == nil ? "no" : "yes",
          self.outputURL?.path ?? "nil")

        guard let writer = self.writer,
              let writerInput = self.writerInput,
              writer.status == .writing else {
          if let writer = self.writer {
            NSLog("[SOPRecorder] finishRecording returning nil because writer status=%d", writer.status.rawValue)
          } else {
            NSLog("[SOPRecorder] finishRecording returning nil because no video frames were recorded")
          }
          Task {
            await WorkerTelemetry.shared.record(
              "sop_recorder_finish",
              source: "media_upload",
              stage: "missing_video",
              sessionID: self.sessionID,
              payload: [
                "frame_count": self.appendedFrameCount,
                "audio_input_chunks": self.inputAudioChunkCount,
                "audio_output_chunks": self.outputAudioChunkCount,
                "dropped_audio_chunks": self.droppedAudioChunkCount,
                "reason": "no_video_frames_recorded"
              ]
            )
          }
          continuation.resume(returning: nil)
          return
        }

        self.isFinishing = true
        writerInput.markAsFinished()
        writer.finishWriting {
          Task {
            let videoURL = self.outputURL
            let audioURL = await self.conversationRecorder.finishAudioFile()
            var finalURL = videoURL
            if writer.status == .completed, let videoURL, let audioURL {
              let mixedURL = videoURL
                .deletingLastPathComponent()
                .appendingPathComponent(videoURL.deletingPathExtension().lastPathComponent + "_mixed")
                .appendingPathExtension("mp4")
              if let muxedURL = await ConversationAudioMuxer.mux(
                videoURL: videoURL,
                audioURL: audioURL,
                outputURL: mixedURL
              ) {
                finalURL = muxedURL
                try? FileManager.default.removeItem(at: videoURL)
                try? FileManager.default.removeItem(at: audioURL)
              } else {
                NSLog("[SOPRecorder] Mixed audio mux failed; returning video-only recording")
              }
            }

            let fileSize = finalURL.flatMap { url -> Int? in
              guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
                return nil
              }
              return attributes[.size] as? Int
            }
            NSLog(
              "[SOPRecorder] finishWriting completed (status=%d, outputURL=%@, bytes=%d)",
              writer.status.rawValue,
              finalURL?.path ?? "nil",
              fileSize ?? 0)
            Task {
              await WorkerTelemetry.shared.record(
                "sop_recorder_finish",
                source: "media_upload",
                stage: writer.status == .completed ? "completed" : "failed",
                sessionID: self.sessionID,
                metricValue: Double(fileSize ?? 0),
                metricUnit: "bytes",
                payload: [
                  "frame_count": self.appendedFrameCount,
                  "file_size": fileSize ?? 0,
                  "audio_input_chunks": self.inputAudioChunkCount,
                  "audio_output_chunks": self.outputAudioChunkCount,
                  "dropped_audio_chunks": self.droppedAudioChunkCount,
                  "writer_status": writer.status.rawValue,
                  "writer_error": writer.error?.localizedDescription ?? NSNull()
                ]
              )
            }
            continuation.resume(returning: writer.status == .completed ? finalURL : nil)
          }
        }
      }
    }
  }

  private func appendPixelBufferInternal(_ pixelBuffer: CVPixelBuffer) {
    guard let writer = writer,
          writer.status == .writing,
          let writerInput = writerInput,
          let adaptor = pixelBufferAdaptor,
          writerInput.isReadyForMoreMediaData else {
      if writer == nil {
        NSLog("[SOPRecorder] Dropping frame because writer was never configured")
      } else if let writer {
        NSLog("[SOPRecorder] Dropping frame because writer is not writable (status=%d)", writer.status.rawValue)
      }
      return
    }

    let elapsed = CACurrentMediaTime() - recordingStartHostTime
    let presentationTime = CMTime(seconds: max(0, elapsed), preferredTimescale: 600)
    let bufferForWriter =
      VideoFrameBufferFactory.copyPixelBuffer(pixelBuffer, using: adaptor.pixelBufferPool)
      ?? pixelBuffer

    let appended = adaptor.append(bufferForWriter, withPresentationTime: presentationTime)
    if appended {
      appendedFrameCount += 1
      if appendedFrameCount == 1 {
        NSLog("[SOPRecorder] First frame appended successfully")
        Task {
          await WorkerTelemetry.shared.record(
            "sop_recorder_first_frame",
            source: "media_upload",
            stage: "recording",
            sessionID: sessionID
          )
        }
      } else if appendedFrameCount % 60 == 0 {
        NSLog("[SOPRecorder] Appended %d frames", appendedFrameCount)
      }
    } else {
      NSLog(
        "[SOPRecorder] Failed appending frame at %.3fs (writer status=%d)",
        elapsed,
        writer.status.rawValue
      )
    }
  }

  private func configureWriterIfNeeded(width: Int, height: Int) {
    guard writer == nil else { return }

    let size = Self.normalizedSize(width: width, height: height)
    guard size.width > 0, size.height > 0 else {
      NSLog("[SOPRecorder] Invalid normalized size: %@", NSCoder.string(for: size))
      return
    }

    let fileURL = outputURL ?? FileManager.default.temporaryDirectory
      .appendingPathComponent("sop_\(sessionID ?? UUID().uuidString)")
      .appendingPathExtension("mp4")

    try? FileManager.default.removeItem(at: fileURL)

    NSLog("[SOPRecorder] Creating writer at %@ with size %@", fileURL.path, NSCoder.string(for: size))

    guard let writer = try? AVAssetWriter(outputURL: fileURL, fileType: .mp4) else {
      NSLog("[SOPRecorder] Failed to create AVAssetWriter")
      return
    }

    let outputSettings: [String: Any] = [
      AVVideoCodecKey: AVVideoCodecType.h264,
      AVVideoWidthKey: Int(size.width),
      AVVideoHeightKey: Int(size.height),
      AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: 2_500_000,
        AVVideoProfileLevelKey: AVVideoProfileLevelH264MainAutoLevel
      ]
    ]

    let input = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
    input.expectsMediaDataInRealTime = true

    let sourceAttributes: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: Int(sourcePixelFormat),
      kCVPixelBufferWidthKey as String: Int(size.width),
      kCVPixelBufferHeightKey as String: Int(size.height),
      kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
    ]

    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: sourceAttributes)

    guard writer.canAdd(input) else {
      NSLog("[SOPRecorder] Writer cannot add AVAssetWriterInput")
      return
    }
    writer.add(input)
    // Conversation audio is mixed into one AAC track during finishRecording(),
    // so the live writer stays focused on video frames.

    guard writer.startWriting() else {
      NSLog("[SOPRecorder] startWriting failed: %@", writer.error?.localizedDescription ?? "unknown")
      return
    }
    writer.startSession(atSourceTime: .zero)
    NSLog("[SOPRecorder] Writer started successfully")

    self.writer = writer
    self.writerInput = input
    self.pixelBufferAdaptor = adaptor
    self.outputURL = fileURL
    drainPendingAudioChunks()
  }

  private func appendAudio(
    _ data: Data,
    sampleRate: Double,
    source: AudioTrackKind
  ) {
    guard !data.isEmpty else { return }
    let hostTime = CACurrentMediaTime()
    queue.async { [weak self] in
      guard let self, !self.isFinishing else { return }
      switch source {
      case .input:
        self.inputAudioChunkCount += 1
      case .output:
        self.outputAudioChunkCount += 1
      }
      let chunk = PendingAudioChunk(
        data: data,
        sampleRate: sampleRate,
        source: source,
        hostTime: hostTime
      )

      guard self.writer?.status == .writing else {
        self.pendingAudioChunks.append(chunk)
        if self.pendingAudioChunks.count > self.maxPendingAudioChunks {
          self.pendingAudioChunks.removeFirst(self.pendingAudioChunks.count - self.maxPendingAudioChunks)
          self.droppedAudioChunkCount += 1
        }
        return
      }

      self.appendAudioChunkInternal(chunk)
    }
  }

  private func drainPendingAudioChunks() {
    guard !pendingAudioChunks.isEmpty else { return }
    let chunks = pendingAudioChunks
    pendingAudioChunks.removeAll()
    for chunk in chunks {
      appendAudioChunkInternal(chunk)
    }
  }

  private func appendAudioChunkInternal(_ chunk: PendingAudioChunk) {
    let audioInput: AVAssetWriterInput?
    let formatDescription: CMAudioFormatDescription?
    switch chunk.source {
    case .input:
      audioInput = inputAudioInput
      formatDescription = inputAudioFormatDescription
    case .output:
      audioInput = outputAudioInput
      formatDescription = outputAudioFormatDescription
    }

    guard let audioInput, let formatDescription else {
      droppedAudioChunkCount += 1
      return
    }
    guard audioInput.isReadyForMoreMediaData else {
      droppedAudioChunkCount += 1
      return
    }
    guard let sampleBuffer = Self.makeAudioSampleBuffer(
      data: chunk.data,
      sampleRate: chunk.sampleRate,
      channels: GeminiConfig.audioChannels,
      formatDescription: formatDescription,
      presentationTime: CMTime(
        seconds: max(0, chunk.hostTime - recordingStartHostTime),
        preferredTimescale: 600
      )
    ) else {
      droppedAudioChunkCount += 1
      return
    }

    if !audioInput.append(sampleBuffer) {
      droppedAudioChunkCount += 1
      NSLog("[SOPRecorder] Failed appending %@ audio chunk", chunk.source.rawValue)
    }
  }

  private func makeAudioInput(sampleRate: Double, channels: UInt32) -> AVAssetWriterInput {
    let outputSettings: [String: Any] = [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVSampleRateKey: sampleRate,
      AVNumberOfChannelsKey: Int(channels),
      AVEncoderBitRateKey: 64_000
    ]
    let input = AVAssetWriterInput(mediaType: .audio, outputSettings: outputSettings)
    input.expectsMediaDataInRealTime = true
    return input
  }

  private static func makePCMFormatDescription(
    sampleRate: Double,
    channels: UInt32
  ) -> CMAudioFormatDescription? {
    var streamDescription = AudioStreamBasicDescription(
      mSampleRate: sampleRate,
      mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: AudioFormatFlags(kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked),
      mBytesPerPacket: UInt32(MemoryLayout<Int16>.size) * channels,
      mFramesPerPacket: 1,
      mBytesPerFrame: UInt32(MemoryLayout<Int16>.size) * channels,
      mChannelsPerFrame: channels,
      mBitsPerChannel: UInt32(MemoryLayout<Int16>.size * 8),
      mReserved: 0
    )
    var formatDescription: CMAudioFormatDescription?
    let status = CMAudioFormatDescriptionCreate(
      allocator: kCFAllocatorDefault,
      asbd: &streamDescription,
      layoutSize: 0,
      layout: nil,
      magicCookieSize: 0,
      magicCookie: nil,
      extensions: nil,
      formatDescriptionOut: &formatDescription
    )
    guard status == noErr else { return nil }
    return formatDescription
  }

  private static func makeAudioSampleBuffer(
    data: Data,
    sampleRate: Double,
    channels: UInt32,
    formatDescription: CMAudioFormatDescription,
    presentationTime: CMTime
  ) -> CMSampleBuffer? {
    let bytesPerFrame = Int(MemoryLayout<Int16>.size * Int(channels))
    guard bytesPerFrame > 0 else { return nil }
    let sampleCount = data.count / bytesPerFrame
    guard sampleCount > 0 else { return nil }

    var blockBuffer: CMBlockBuffer?
    var status = CMBlockBufferCreateWithMemoryBlock(
      allocator: kCFAllocatorDefault,
      memoryBlock: nil,
      blockLength: data.count,
      blockAllocator: nil,
      customBlockSource: nil,
      offsetToData: 0,
      dataLength: data.count,
      flags: 0,
      blockBufferOut: &blockBuffer
    )
    guard status == noErr, let blockBuffer else { return nil }

    status = data.withUnsafeBytes { rawBuffer in
      guard let baseAddress = rawBuffer.baseAddress else { return OSStatus(-1) }
      return CMBlockBufferReplaceDataBytes(
        with: baseAddress,
        blockBuffer: blockBuffer,
        offsetIntoDestination: 0,
        dataLength: data.count
      )
    }
    guard status == noErr else { return nil }

    let sampleDuration = CMTime(value: 1, timescale: CMTimeScale(sampleRate))
    var timing = CMSampleTimingInfo(
      duration: sampleDuration,
      presentationTimeStamp: presentationTime,
      decodeTimeStamp: .invalid
    )
    var sampleBuffer: CMSampleBuffer?
    status = CMSampleBufferCreate(
      allocator: kCFAllocatorDefault,
      dataBuffer: blockBuffer,
      dataReady: true,
      makeDataReadyCallback: nil,
      refcon: nil,
      formatDescription: formatDescription,
      sampleCount: sampleCount,
      sampleTimingEntryCount: 1,
      sampleTimingArray: &timing,
      sampleSizeEntryCount: 0,
      sampleSizeArray: nil,
      sampleBufferOut: &sampleBuffer
    )
    guard status == noErr else { return nil }
    return sampleBuffer
  }

  private static func normalizedSize(width: Int, height: Int) -> CGSize {
    var width = max(2, width)
    var height = max(2, height)
    if width % 2 != 0 { width += 1 }
    if height % 2 != 0 { height += 1 }
    return CGSize(width: width, height: height)
  }
}

struct ChecklistItemState: Identifiable, Codable, Hashable {
  let id: UUID
  let itemID: String
  let name: String
  let description: String
  let duration: String
  let validation: String
  let critical: Bool
  let aiPrompt: String
  let expectedObjects: [String]
  let preconditions: [String]
  let postconditions: [String]
  let skipRisk: String
  let evidenceRequired: Bool
  let allowManualComplete: Bool
  var isChecked: Bool
  var completionSource: ChecklistCompletionSource

  private enum CodingKeys: String, CodingKey {
    case id
    case itemID
    case name
    case description
    case duration
    case validation
    case critical
    case aiPrompt
    case expectedObjects
    case preconditions
    case postconditions
    case skipRisk
    case evidenceRequired
    case allowManualComplete
    case isChecked
    case completionSource
  }

  init(
    id: UUID = UUID(),
    itemID: String? = nil,
    name: String,
    description: String = "",
    duration: String = "30s",
    validation: String = "visual",
    critical: Bool = false,
    aiPrompt: String? = nil,
    expectedObjects: [String] = [],
    preconditions: [String] = [],
    postconditions: [String] = [],
    skipRisk: String = "medium",
    evidenceRequired: Bool = true,
    allowManualComplete: Bool = true,
    isChecked: Bool = false,
    completionSource: ChecklistCompletionSource = .pending
  ) {
    self.id = id
    self.itemID = itemID ?? ChecklistItemState.normalizedItemID(from: name)
    self.name = name
    self.description = description
    self.duration = duration
    self.validation = validation
    self.critical = critical
    self.aiPrompt = aiPrompt ?? "Look at the image and confirm whether \"\(name)\" has been completed."
    self.expectedObjects = expectedObjects
    self.preconditions = preconditions
    self.postconditions = postconditions
    self.skipRisk = skipRisk
    self.evidenceRequired = evidenceRequired
    self.allowManualComplete = allowManualComplete
    self.isChecked = isChecked
    self.completionSource = completionSource
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let name = try container.decode(String.self, forKey: .name)
    self.init(
      id: try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
      itemID: try container.decodeIfPresent(String.self, forKey: .itemID),
      name: name,
      description: try container.decodeIfPresent(String.self, forKey: .description) ?? "",
      duration: try container.decodeIfPresent(String.self, forKey: .duration) ?? "30s",
      validation: try container.decodeIfPresent(String.self, forKey: .validation) ?? "visual",
      critical: try container.decodeIfPresent(Bool.self, forKey: .critical) ?? false,
      aiPrompt: try container.decodeIfPresent(String.self, forKey: .aiPrompt),
      expectedObjects: try container.decodeIfPresent([String].self, forKey: .expectedObjects) ?? [],
      preconditions: try container.decodeIfPresent([String].self, forKey: .preconditions) ?? [],
      postconditions: try container.decodeIfPresent([String].self, forKey: .postconditions) ?? [],
      skipRisk: try container.decodeIfPresent(String.self, forKey: .skipRisk) ?? "medium",
      evidenceRequired: try container.decodeIfPresent(Bool.self, forKey: .evidenceRequired) ?? true,
      allowManualComplete: try container.decodeIfPresent(Bool.self, forKey: .allowManualComplete) ?? true,
      isChecked: try container.decodeIfPresent(Bool.self, forKey: .isChecked) ?? false,
      completionSource: try container.decodeIfPresent(ChecklistCompletionSource.self, forKey: .completionSource) ?? .pending
    )
  }

  static func normalizedItemID(from name: String) -> String {
    let lowered = name.lowercased()
    let filtered = lowered.map { ch in
      ch.isLetter || ch.isNumber ? ch : "_"
    }
    let collapsed = String(filtered)
      .replacingOccurrences(of: "__+", with: "_", options: .regularExpression)
      .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    return collapsed.isEmpty ? UUID().uuidString.lowercased() : collapsed
  }
}

struct SpotterEvidenceDecision: Equatable {
  let shouldAutoComplete: Bool
  let sampleCount: Int
  let positiveCount: Int
  let averagePositiveConfidence: Double
  let threshold: Double
}

struct SpotterEvidenceWindow {
  private struct Sample {
    let matched: Bool
    let confidence: Double
  }

  var maxSamples = 5
  var minPositiveSamples = 3
  private var samplesByStepID: [String: [Sample]] = [:]

  mutating func record(
    stepID: String,
    matched: Bool,
    autoComplete: Bool,
    confidence: Double,
    threshold: Double
  ) -> SpotterEvidenceDecision {
    let positive = matched && autoComplete && confidence >= threshold
    var samples = samplesByStepID[stepID] ?? []
    samples.append(Sample(matched: positive, confidence: confidence))
    if samples.count > maxSamples {
      samples = Array(samples.suffix(maxSamples))
    }
    samplesByStepID[stepID] = samples

    let positives = samples.filter(\.matched)
    let average = positives.isEmpty
      ? 0
      : positives.reduce(0) { $0 + $1.confidence } / Double(positives.count)
    let shouldAutoComplete = positives.count >= minPositiveSamples && average >= threshold

    return SpotterEvidenceDecision(
      shouldAutoComplete: shouldAutoComplete,
      sampleCount: samples.count,
      positiveCount: positives.count,
      averagePositiveConfidence: average,
      threshold: threshold
    )
  }

  mutating func reset(stepID: String) {
    samplesByStepID[stepID] = nil
  }

  mutating func resetAll() {
    samplesByStepID.removeAll()
  }
}

private enum WorkerLiveLogger {
  static func log(
    _ event: String,
    sessionID: String? = nil,
    roomCode: String? = nil,
    assetID: String? = nil,
    assetType: String? = nil,
    bucket: String? = nil,
    path: String? = nil,
    byteSize: Int? = nil,
    retryCount: Int? = nil,
    uploadState: String? = nil,
    error: String? = nil,
    durationMs: Double? = nil,
    metricValue: Double? = nil,
    metricUnit: String? = nil,
    telemetry: WorkerTelemetry? = nil
  ) {
    let payload: [String: Any] = [
      "event": event,
      "sessionId": sessionID ?? NSNull(),
      "roomCode": roomCode ?? NSNull(),
      "assetId": assetID ?? NSNull(),
      "assetType": assetType ?? NSNull(),
      "bucket": bucket ?? NSNull(),
      "path": path ?? NSNull(),
      "byteSize": byteSize ?? NSNull(),
      "retryCount": retryCount ?? NSNull(),
      "uploadState": uploadState ?? NSNull(),
      "error": error ?? NSNull(),
      "durationMs": durationMs ?? NSNull()
    ]

    guard JSONSerialization.isValidJSONObject(payload),
          let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
          let encoded = String(data: data, encoding: .utf8)
    else {
      NSLog("[worker-live] %@", event)
      return
    }

    NSLog("[worker-live] %@", encoded)

    guard let telemetry, let sessionID else { return }
    Task {
      await telemetry.record(
        event,
        source: telemetrySource(for: event),
        stage: telemetryStage(for: event, uploadState: uploadState),
        sessionID: sessionID,
        durationMs: durationMs,
        metricValue: metricValue,
        metricUnit: metricUnit,
        payload: payload
      )
    }
  }

  private static func telemetrySource(for event: String) -> String {
    if event.contains("upload") || event.contains("finalize") || event == "retry_scheduled" {
      return "media_upload"
    }
    if event.contains("heartbeat") {
      return "ios_app"
    }
    return "ios_app"
  }

  private static func telemetryStage(for event: String, uploadState: String?) -> String {
    if event.contains("failure") || uploadState == "failed" {
      return "failed"
    }
    if event.contains("success") || uploadState == "uploaded" {
      return "uploaded"
    }
    if event.contains("target") {
      return "target"
    }
    if event.contains("heartbeat") {
      return "heartbeat"
    }
    if event == "retry_scheduled" {
      return "retry"
    }
    return "point"
  }
}

struct WorkerMediaUploadResult: Equatable, Sendable {
  let assetType: String
  let assetID: String?
  let bucket: String?
  let path: String?
  let byteSize: Int
  let uploadState: String
  let errorMessage: String?

  var succeeded: Bool {
    uploadState == "uploaded"
  }

  var isPending: Bool {
    uploadState == "pending"
  }
}

struct WorkerPreparedMediaUpload: Equatable, Sendable {
  let target: WorkerMediaUploadTarget
  let result: WorkerMediaUploadResult
}

actor WorkerAdminLiveSessionCoordinator {
  typealias Sleeper = @Sendable (UInt64) async -> Void
  typealias FileLoader = @Sendable (URL) async -> Data?
  typealias HeartbeatResponseHandler = @Sendable (WorkerLiveHeartbeatResponse) async -> Void
  typealias HeartbeatFailureHandler = @Sendable (_ sessionID: String, _ message: String) async -> Void

  private let api: WorkerAdminAPI
  private let telemetry: WorkerTelemetry?
  private let heartbeatIntervalNanoseconds: UInt64
  private let sleeper: Sleeper
  private let fileLoader: FileLoader
  private let onHeartbeatResponse: HeartbeatResponseHandler?
  private let onHeartbeatFailure: HeartbeatFailureHandler?

  private var sessionID: String?
  private var roomCode: String?
  private var currentStepIndex: Int = 0
  private var helpRequested: Bool = false
  private var lastFrameBucket: String?
  private var lastFramePath: String?
  private var heartbeatTask: Task<Void, Never>?
  private var queuedFrameData: Data?
  private var frameUploadTask: Task<Void, Never>?

  init(
    api: WorkerAdminAPI,
    sessionID: String? = nil,
    heartbeatIntervalNanoseconds: UInt64 = 7_000_000_000,
    telemetry: WorkerTelemetry? = nil,
    onHeartbeatResponse: HeartbeatResponseHandler? = nil,
    onHeartbeatFailure: HeartbeatFailureHandler? = nil,
    sleeper: @escaping Sleeper = { nanoseconds in
      guard nanoseconds > 0 else { return }
      try? await Task.sleep(nanoseconds: nanoseconds)
    },
    fileLoader: @escaping FileLoader = { url in
      await Task.detached(priority: .utility) {
        try? Data(contentsOf: url)
      }.value
    }
  ) {
    self.api = api
    self.telemetry = telemetry
    self.sessionID = sessionID
    self.heartbeatIntervalNanoseconds = heartbeatIntervalNanoseconds
    self.sleeper = sleeper
    self.fileLoader = fileLoader
    self.onHeartbeatResponse = onHeartbeatResponse
    self.onHeartbeatFailure = onHeartbeatFailure
  }

  func start(
    sessionID: String,
    currentStepIndex: Int,
    helpRequested: Bool,
    roomCode: String? = nil
  ) async {
    self.sessionID = sessionID
    self.currentStepIndex = currentStepIndex
    self.helpRequested = helpRequested
    await telemetry?.configure(
      api: api,
      sessionID: sessionID,
      deviceID: GeminiConfig.deviceID
    )
    await telemetry?.record(
      "session_start",
      source: "ios_app",
      stage: "started",
      sessionID: sessionID,
      payload: [
        "current_step_index": currentStepIndex,
        "help_requested": helpRequested,
        "room_code_present": Self.trimmed(roomCode) != nil
      ]
    )
    if let roomCode = Self.trimmed(roomCode) {
      self.roomCode = roomCode
    }

    if heartbeatTask == nil, heartbeatIntervalNanoseconds > 0 {
      heartbeatTask = Task { [heartbeatIntervalNanoseconds] in
        while !Task.isCancelled {
          await self.sleeper(heartbeatIntervalNanoseconds)
          if Task.isCancelled { break }
          await self.sendHeartbeat()
        }
      }
    }

    await sendHeartbeat()
  }

  func updateRoomCode(_ roomCode: String?, sendImmediateHeartbeat: Bool = true) async {
    guard let roomCode = Self.trimmed(roomCode) else { return }
    self.roomCode = roomCode
    if sendImmediateHeartbeat {
      await sendHeartbeat()
    }
  }

  func updateCurrentStepIndex(_ currentStepIndex: Int, sendImmediateHeartbeat: Bool = false) async {
    self.currentStepIndex = currentStepIndex
    if sendImmediateHeartbeat {
      await sendHeartbeat()
    }
  }

  func updateHelpRequested(_ helpRequested: Bool, sendImmediateHeartbeat: Bool = true) async {
    self.helpRequested = helpRequested
    if sendImmediateHeartbeat {
      await sendHeartbeat()
    }
  }

  func enqueueFrameUpload(data: Data) async {
    queuedFrameData = data
    if let sessionID {
      await telemetry?.record(
        "frame_enqueued",
        source: "media_upload",
        stage: "queued",
        sessionID: sessionID,
        metricValue: Double(data.count),
        metricUnit: "bytes",
        payload: [
          "bytes": data.count,
          "latest_frame_only": true
        ]
      )
    }
    guard frameUploadTask == nil else { return }
    frameUploadTask = Task {
      await self.drainQueuedFrames()
    }
  }

  func uploadVideoRecording(
    from fileURL: URL?,
    source: String = "session-recording"
  ) async -> WorkerMediaUploadResult {
    guard let preparedUpload = await prepareVideoRecordingUpload(source: source) else {
      return videoUploadFailureResult(errorMessage: "Recording upload target could not be prepared.")
    }

    return await uploadPreparedVideoRecording(from: fileURL, preparedUpload: preparedUpload)
  }

  func prepareVideoRecordingUpload(
    source: String = "session-recording"
  ) async -> WorkerPreparedMediaUpload? {
    guard let sessionID else {
      return nil
    }

    let targetStartedAt = CACurrentMediaTime()

    do {
      let target = try await retry(
        sessionID: sessionID,
        roomCode: roomCode,
        assetType: "video",
        byteSize: 0,
        uploadState: "pending"
      ) {
        try await api.requestWorkerMediaUploadTarget(
          sessionID: sessionID,
          assetType: "video",
          filename: "recording.mp4",
          contentType: "video/mp4",
          byteSize: 0,
          source: source
        )
      }

      WorkerLiveLogger.log(
        "video_upload_target",
        sessionID: sessionID,
        roomCode: roomCode,
        assetID: target.assetID,
        assetType: "video",
        bucket: target.bucket,
        path: target.path,
        byteSize: 0,
        uploadState: "pending",
        durationMs: (CACurrentMediaTime() - targetStartedAt) * 1000,
        telemetry: telemetry
      )

      return WorkerPreparedMediaUpload(
        target: target,
        result: WorkerMediaUploadResult(
          assetType: "video",
          assetID: target.assetID,
          bucket: target.bucket,
          path: target.path,
          byteSize: 0,
          uploadState: "pending",
          errorMessage: nil
        )
      )
    } catch {
      WorkerLiveLogger.log(
        "video_upload_target_failure",
        sessionID: sessionID,
        roomCode: roomCode,
        assetType: "video",
        byteSize: 0,
        uploadState: "failed",
        error: error.localizedDescription,
        durationMs: (CACurrentMediaTime() - targetStartedAt) * 1000,
        telemetry: telemetry
      )
      return nil
    }
  }

  func uploadPreparedVideoRecording(
    from fileURL: URL?,
    preparedUpload: WorkerPreparedMediaUpload
  ) async -> WorkerMediaUploadResult {
    guard let sessionID else {
      return videoUploadFailureResult(errorMessage: "Recording upload session is missing.")
    }

    let byteSize: Int
    let data: Data?
    let missingDataError: String

    if let fileURL {
      data = await fileLoader(fileURL)
      if let data {
        byteSize = data.count
        missingDataError = data.isEmpty ? "Recording file is empty." : "Recording file could not be loaded."
      } else {
        byteSize = 0
        missingDataError = "Recording file could not be loaded."
      }
    } else {
      data = nil
      byteSize = 0
      missingDataError = "Recording file was not created because no video frames were recorded."
    }

    guard let data, !data.isEmpty else {
      WorkerLiveLogger.log(
        "recording_missing",
        sessionID: sessionID,
        roomCode: roomCode,
        assetID: preparedUpload.target.assetID,
        assetType: "video",
        bucket: preparedUpload.target.bucket,
        path: preparedUpload.target.path,
        byteSize: byteSize,
        uploadState: "failed",
        error: missingDataError,
        telemetry: telemetry
      )

      return await finalizeFailure(
        logPrefix: "video",
        sessionID: sessionID,
        assetType: "video",
        target: preparedUpload.target,
        byteSize: byteSize,
        errorMessage: missingDataError
      )
    }

    return await uploadPreparedAsset(
      assetType: "video",
      contentType: "video/mp4",
      target: preparedUpload.target,
      data: data,
      byteSize: byteSize,
      missingDataError: missingDataError
    )
  }

  func completeSession(
    pendingVideoUpload: WorkerPreparedMediaUpload?,
    onBeforeMarkEnded: () async -> Void
  ) async -> WorkerMediaUploadResult {
    let result = pendingVideoUpload?.result
      ?? videoUploadFailureResult(errorMessage: "Recording upload target could not be prepared.")

    queuedFrameData = nil
    frameUploadTask?.cancel()
    frameUploadTask = nil
    heartbeatTask?.cancel()
    heartbeatTask = nil

    await onBeforeMarkEnded()
    await telemetry?.record(
      "session_end_requested",
      source: "ios_app",
      stage: result.isPending ? "pending" : result.succeeded ? "uploaded" : "failed",
      sessionID: sessionID,
      payload: [
        "video_upload_state": result.uploadState,
        "video_bytes": result.byteSize,
        "error": result.errorMessage ?? NSNull()
      ]
    )
    await telemetry?.flush()
    return result
  }

  func flushTelemetryAndStop() async {
    await telemetry?.flushAndStop()
  }

  func stop() async {
    queuedFrameData = nil
    frameUploadTask?.cancel()
    frameUploadTask = nil
    heartbeatTask?.cancel()
    heartbeatTask = nil
    if let sessionID {
      await telemetry?.record(
        "session_stop",
        source: "ios_app",
        stage: "stopped",
        sessionID: sessionID
      )
      await telemetry?.flushAndStop()
    }
  }

  private func sendHeartbeat() async {
    guard let sessionID else { return }

    let heartbeat = WorkerLiveHeartbeatRequest(
      sessionID: sessionID,
      webrtcRoomCode: roomCode,
      currentStepIndex: currentStepIndex,
      helpRequested: helpRequested,
      status: "active",
      lastFrameBucket: lastFrameBucket,
      lastFramePath: lastFramePath
    )

    WorkerLiveLogger.log(
      "heartbeat_sent",
      sessionID: sessionID,
      roomCode: roomCode,
      bucket: lastFrameBucket,
      path: lastFramePath,
      uploadState: "active",
      telemetry: telemetry
    )

    do {
      let heartbeatStartedAt = CACurrentMediaTime()
      try await retry(
        sessionID: sessionID,
        roomCode: roomCode,
        assetType: nil,
        bucket: lastFrameBucket,
        path: lastFramePath,
        uploadState: "active"
      ) {
        let response = try await api.sendWorkerLiveHeartbeat(heartbeat)
        await onHeartbeatResponse?(response)
      }

      WorkerLiveLogger.log(
        "heartbeat_result",
        sessionID: sessionID,
        roomCode: roomCode,
        bucket: lastFrameBucket,
        path: lastFramePath,
        uploadState: "active",
        durationMs: (CACurrentMediaTime() - heartbeatStartedAt) * 1000,
        telemetry: telemetry
      )
    } catch {
      let message = error.localizedDescription
      WorkerLiveLogger.log(
        "heartbeat_result",
        sessionID: sessionID,
        roomCode: roomCode,
        bucket: lastFrameBucket,
        path: lastFramePath,
        uploadState: "active",
        error: message,
        telemetry: telemetry
      )
      await onHeartbeatFailure?(sessionID, message)
    }
  }

  private func drainQueuedFrames() async {
    while !Task.isCancelled {
      guard let frameData = queuedFrameData else { break }
      queuedFrameData = nil

      let result = await uploadAsset(
        assetType: "frame",
        filename: "last-frame.jpg",
        contentType: "image/jpeg",
        data: frameData,
        byteSize: frameData.count,
        missingDataError: "Frame JPEG data was empty.",
        source: "live-preview"
      )

      if result.succeeded {
        lastFrameBucket = result.bucket
        lastFramePath = result.path
        if !Task.isCancelled {
          await sendHeartbeat()
        }
      }
    }

    frameUploadTask = nil
    if queuedFrameData != nil, !Task.isCancelled {
      frameUploadTask = Task {
        await self.drainQueuedFrames()
      }
    }
  }

	  private func uploadAsset(
	    assetType: String,
	    filename: String,
	    contentType: String,
    data: Data?,
    byteSize: Int,
    missingDataError: String,
    source: String? = nil
  ) async -> WorkerMediaUploadResult {
    guard let sessionID else {
      return WorkerMediaUploadResult(
        assetType: assetType,
        assetID: nil,
        bucket: nil,
        path: nil,
        byteSize: byteSize,
        uploadState: "failed",
        errorMessage: "Session ID missing."
      )
    }

    let logPrefix = assetType == "frame" ? "frame" : "video"
    let assetUploadStartedAt = CACurrentMediaTime()

    do {
      let targetStartedAt = CACurrentMediaTime()
      let target = try await retry(
        sessionID: sessionID,
        roomCode: roomCode,
        assetType: assetType,
        byteSize: byteSize,
        uploadState: "pending"
      ) {
        try await api.requestWorkerMediaUploadTarget(
          sessionID: sessionID,
          assetType: assetType,
          filename: filename,
          contentType: contentType,
          byteSize: byteSize,
          source: source
        )
      }

      WorkerLiveLogger.log(
        "\(logPrefix)_upload_target",
        sessionID: sessionID,
        roomCode: roomCode,
        assetID: target.assetID,
        assetType: assetType,
        bucket: target.bucket,
        path: target.path,
        byteSize: byteSize,
        uploadState: "pending",
        durationMs: (CACurrentMediaTime() - targetStartedAt) * 1000,
        telemetry: telemetry
      )

      guard let data, !data.isEmpty else {
        WorkerLiveLogger.log(
          "\(logPrefix)_upload_failure",
          sessionID: sessionID,
          roomCode: roomCode,
          assetID: target.assetID,
          assetType: assetType,
          bucket: target.bucket,
          path: target.path,
          byteSize: byteSize,
          uploadState: "failed",
          error: missingDataError,
          durationMs: (CACurrentMediaTime() - assetUploadStartedAt) * 1000,
          telemetry: telemetry
        )
        return await finalizeFailure(
          logPrefix: logPrefix,
          sessionID: sessionID,
          assetType: assetType,
          target: target,
          byteSize: byteSize,
          errorMessage: missingDataError
        )
      }

      do {
        let binaryUploadStartedAt = CACurrentMediaTime()
        try await retry(
          sessionID: sessionID,
          roomCode: roomCode,
          assetID: target.assetID,
          assetType: assetType,
          bucket: target.bucket,
          path: target.path,
          byteSize: byteSize,
          uploadState: "pending"
        ) {
          try await api.uploadBinary(to: target, data: data, contentType: contentType)
        }

        WorkerLiveLogger.log(
          "\(logPrefix)_upload_success",
          sessionID: sessionID,
          roomCode: roomCode,
          assetID: target.assetID,
          assetType: assetType,
          bucket: target.bucket,
          path: target.path,
          byteSize: byteSize,
          uploadState: "pending",
          durationMs: (CACurrentMediaTime() - binaryUploadStartedAt) * 1000,
          metricValue: Double(byteSize),
          metricUnit: "bytes",
          telemetry: telemetry
        )

        do {
          let finalizeStartedAt = CACurrentMediaTime()
          try await retry(
            sessionID: sessionID,
            roomCode: roomCode,
            assetID: target.assetID,
            assetType: assetType,
            bucket: target.bucket,
            path: target.path,
            byteSize: byteSize,
            uploadState: "uploaded"
          ) {
            try await api.finalizeWorkerMediaUpload(
              WorkerMediaFinalizeRequest(
                assetID: target.assetID,
                sessionID: sessionID,
                bucket: target.bucket,
                path: target.path,
                status: "uploaded",
                byteSize: byteSize,
                error: nil
              )
            )
          }

          WorkerLiveLogger.log(
            "\(logPrefix)_finalize_success",
            sessionID: sessionID,
            roomCode: roomCode,
            assetID: target.assetID,
            assetType: assetType,
            bucket: target.bucket,
            path: target.path,
            byteSize: byteSize,
            uploadState: "uploaded",
            durationMs: (CACurrentMediaTime() - finalizeStartedAt) * 1000,
            metricValue: Double(byteSize),
            metricUnit: "bytes",
            telemetry: telemetry
          )

          return WorkerMediaUploadResult(
            assetType: assetType,
            assetID: target.assetID,
            bucket: target.bucket,
            path: target.path,
            byteSize: byteSize,
            uploadState: "uploaded",
            errorMessage: nil
          )
        } catch {
          let finalizeError = "Finalize uploaded failed: \(error.localizedDescription)"
          WorkerLiveLogger.log(
            "\(logPrefix)_finalize_failure",
            sessionID: sessionID,
            roomCode: roomCode,
            assetID: target.assetID,
            assetType: assetType,
            bucket: target.bucket,
            path: target.path,
            byteSize: byteSize,
            uploadState: "uploaded",
            error: finalizeError,
            durationMs: (CACurrentMediaTime() - assetUploadStartedAt) * 1000,
            telemetry: telemetry
          )
          return await finalizeFailure(
            logPrefix: logPrefix,
            sessionID: sessionID,
            assetType: assetType,
            target: target,
            byteSize: byteSize,
            errorMessage: finalizeError
          )
        }
      } catch {
        let uploadError = error.localizedDescription
        WorkerLiveLogger.log(
          "\(logPrefix)_upload_failure",
          sessionID: sessionID,
          roomCode: roomCode,
          assetID: target.assetID,
          assetType: assetType,
          bucket: target.bucket,
          path: target.path,
          byteSize: byteSize,
          uploadState: "failed",
          error: uploadError,
          durationMs: (CACurrentMediaTime() - assetUploadStartedAt) * 1000,
          telemetry: telemetry
        )
        return await finalizeFailure(
          logPrefix: logPrefix,
          sessionID: sessionID,
          assetType: assetType,
          target: target,
          byteSize: byteSize,
          errorMessage: uploadError
        )
      }
    } catch {
      WorkerLiveLogger.log(
        "\(logPrefix)_upload_failure",
        sessionID: sessionID,
        roomCode: roomCode,
        assetType: assetType,
        byteSize: byteSize,
        uploadState: "failed",
        error: error.localizedDescription,
        durationMs: (CACurrentMediaTime() - assetUploadStartedAt) * 1000,
        telemetry: telemetry
      )

      return WorkerMediaUploadResult(
        assetType: assetType,
        assetID: nil,
        bucket: nil,
        path: nil,
        byteSize: byteSize,
        uploadState: "failed",
        errorMessage: error.localizedDescription
      )
	    }
	  }

  private func uploadPreparedAsset(
    assetType: String,
    contentType: String,
    target: WorkerMediaUploadTarget,
    data: Data?,
    byteSize: Int,
    missingDataError: String
  ) async -> WorkerMediaUploadResult {
    guard let sessionID else {
      return WorkerMediaUploadResult(
        assetType: assetType,
        assetID: target.assetID,
        bucket: target.bucket,
        path: target.path,
        byteSize: byteSize,
        uploadState: "failed",
        errorMessage: "Session ID missing."
      )
    }

    let logPrefix = assetType == "frame" ? "frame" : "video"
    let assetUploadStartedAt = CACurrentMediaTime()

    guard let data, !data.isEmpty else {
      WorkerLiveLogger.log(
        "\(logPrefix)_upload_failure",
        sessionID: sessionID,
        roomCode: roomCode,
        assetID: target.assetID,
        assetType: assetType,
        bucket: target.bucket,
        path: target.path,
        byteSize: byteSize,
        uploadState: "failed",
        error: missingDataError,
        durationMs: (CACurrentMediaTime() - assetUploadStartedAt) * 1000,
        telemetry: telemetry
      )
      return await finalizeFailure(
        logPrefix: logPrefix,
        sessionID: sessionID,
        assetType: assetType,
        target: target,
        byteSize: byteSize,
        errorMessage: missingDataError
      )
    }

    do {
      let binaryUploadStartedAt = CACurrentMediaTime()
      try await retry(
        sessionID: sessionID,
        roomCode: roomCode,
        assetID: target.assetID,
        assetType: assetType,
        bucket: target.bucket,
        path: target.path,
        byteSize: byteSize,
        uploadState: "pending"
      ) {
        try await api.uploadBinary(to: target, data: data, contentType: contentType)
      }

      WorkerLiveLogger.log(
        "\(logPrefix)_upload_success",
        sessionID: sessionID,
        roomCode: roomCode,
        assetID: target.assetID,
        assetType: assetType,
        bucket: target.bucket,
        path: target.path,
        byteSize: byteSize,
        uploadState: "pending",
        durationMs: (CACurrentMediaTime() - binaryUploadStartedAt) * 1000,
        metricValue: Double(byteSize),
        metricUnit: "bytes",
        telemetry: telemetry
      )

      do {
        let finalizeStartedAt = CACurrentMediaTime()
        try await retry(
          sessionID: sessionID,
          roomCode: roomCode,
          assetID: target.assetID,
          assetType: assetType,
          bucket: target.bucket,
          path: target.path,
          byteSize: byteSize,
          uploadState: "uploaded"
        ) {
          try await api.finalizeWorkerMediaUpload(
            WorkerMediaFinalizeRequest(
              assetID: target.assetID,
              sessionID: sessionID,
              bucket: target.bucket,
              path: target.path,
              status: "uploaded",
              byteSize: byteSize,
              error: nil
            )
          )
        }

        WorkerLiveLogger.log(
          "\(logPrefix)_finalize_success",
          sessionID: sessionID,
          roomCode: roomCode,
          assetID: target.assetID,
          assetType: assetType,
          bucket: target.bucket,
          path: target.path,
          byteSize: byteSize,
          uploadState: "uploaded",
          durationMs: (CACurrentMediaTime() - finalizeStartedAt) * 1000,
          metricValue: Double(byteSize),
          metricUnit: "bytes",
          telemetry: telemetry
        )

        return WorkerMediaUploadResult(
          assetType: assetType,
          assetID: target.assetID,
          bucket: target.bucket,
          path: target.path,
          byteSize: byteSize,
          uploadState: "uploaded",
          errorMessage: nil
        )
      } catch {
        let finalizeError = "Finalize uploaded failed: \(error.localizedDescription)"
        WorkerLiveLogger.log(
          "\(logPrefix)_finalize_failure",
          sessionID: sessionID,
          roomCode: roomCode,
          assetID: target.assetID,
          assetType: assetType,
          bucket: target.bucket,
          path: target.path,
          byteSize: byteSize,
          uploadState: "uploaded",
          error: finalizeError,
          durationMs: (CACurrentMediaTime() - assetUploadStartedAt) * 1000,
          telemetry: telemetry
        )
        return await finalizeFailure(
          logPrefix: logPrefix,
          sessionID: sessionID,
          assetType: assetType,
          target: target,
          byteSize: byteSize,
          errorMessage: finalizeError
        )
      }
    } catch {
      let uploadError = error.localizedDescription
      WorkerLiveLogger.log(
        "\(logPrefix)_upload_failure",
        sessionID: sessionID,
        roomCode: roomCode,
        assetID: target.assetID,
        assetType: assetType,
        bucket: target.bucket,
        path: target.path,
        byteSize: byteSize,
        uploadState: "failed",
        error: uploadError,
        durationMs: (CACurrentMediaTime() - assetUploadStartedAt) * 1000,
        telemetry: telemetry
      )
      return await finalizeFailure(
        logPrefix: logPrefix,
        sessionID: sessionID,
        assetType: assetType,
        target: target,
        byteSize: byteSize,
        errorMessage: uploadError
      )
    }
  }

  private func videoUploadFailureResult(errorMessage: String) -> WorkerMediaUploadResult {
    WorkerMediaUploadResult(
      assetType: "video",
      assetID: nil,
      bucket: nil,
      path: nil,
      byteSize: 0,
      uploadState: "failed",
      errorMessage: errorMessage
    )
  }

  private func finalizeFailure(
    logPrefix: String,
    sessionID: String,
    assetType: String,
    target: WorkerMediaUploadTarget,
    byteSize: Int,
    errorMessage: String
  ) async -> WorkerMediaUploadResult {
    do {
      try await retry(
        sessionID: sessionID,
        roomCode: roomCode,
        assetID: target.assetID,
        assetType: assetType,
        bucket: target.bucket,
        path: target.path,
        byteSize: byteSize,
        uploadState: "failed"
      ) {
        try await api.finalizeWorkerMediaUpload(
          WorkerMediaFinalizeRequest(
            assetID: target.assetID,
            sessionID: sessionID,
            bucket: target.bucket,
            path: target.path,
            status: "failed",
            byteSize: byteSize,
            error: errorMessage
          )
        )
      }

      WorkerLiveLogger.log(
        "\(logPrefix)_finalize_success",
        sessionID: sessionID,
        roomCode: roomCode,
        assetID: target.assetID,
        assetType: assetType,
        bucket: target.bucket,
        path: target.path,
        byteSize: byteSize,
        uploadState: "failed",
        error: errorMessage,
        telemetry: telemetry
      )
    } catch {
      WorkerLiveLogger.log(
        "\(logPrefix)_finalize_failure",
        sessionID: sessionID,
        roomCode: roomCode,
        assetID: target.assetID,
        assetType: assetType,
        bucket: target.bucket,
        path: target.path,
        byteSize: byteSize,
        uploadState: "failed",
        error: error.localizedDescription,
        telemetry: telemetry
      )
    }

    return WorkerMediaUploadResult(
      assetType: assetType,
      assetID: target.assetID,
      bucket: target.bucket,
      path: target.path,
      byteSize: byteSize,
      uploadState: "failed",
      errorMessage: errorMessage
    )
  }

  private func retry<T>(
    sessionID: String?,
    roomCode: String?,
    assetID: String? = nil,
    assetType: String?,
    bucket: String? = nil,
    path: String? = nil,
    byteSize: Int? = nil,
    uploadState: String? = nil,
    operation: () async throws -> T
  ) async throws -> T {
    let backoffSchedule: [UInt64] = [750_000_000, 1_500_000_000, 3_000_000_000]
    var attempt = 0

    while true {
      do {
        return try await operation()
      } catch {
        guard !Task.isCancelled, attempt < backoffSchedule.count, Self.isTransient(error) else {
          throw error
        }

        let retryCount = attempt + 1
        WorkerLiveLogger.log(
          "retry_scheduled",
          sessionID: sessionID,
          roomCode: roomCode,
          assetID: assetID,
          assetType: assetType,
          bucket: bucket,
          path: path,
          byteSize: byteSize,
          retryCount: retryCount,
          uploadState: uploadState,
          error: error.localizedDescription,
          telemetry: telemetry
        )

        await sleeper(backoffSchedule[attempt])
        attempt += 1
      }
    }
  }

  private static func trimmed(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
          !value.isEmpty
    else {
      return nil
    }
    return value
  }

  private static func isTransient(_ error: Error) -> Bool {
    if error is CancellationError {
      return false
    }

    if let urlError = error as? URLError {
      switch urlError.code {
      case .timedOut,
           .cannotFindHost,
           .cannotConnectToHost,
           .networkConnectionLost,
           .dnsLookupFailed,
           .notConnectedToInternet,
           .resourceUnavailable,
           .dataNotAllowed,
           .callIsActive,
           .internationalRoamingOff:
        return true
      default:
        return false
      }
    }

    if let opsError = error as? OpsAPIError {
      switch opsError {
      case .invalidResponse:
        return true
      case .server(let statusCode, _):
        return [408, 409, 425, 429, 500, 502, 503, 504].contains(statusCode)
      case .notConfigured, .invalidURL, .missingWorkerSession, .missingWorkerBearerToken:
        return false
      }
    }

    return false
  }
}

struct ShippedSessionRecord: Identifiable, Codable {
  let id: UUID
  let timestamp: Date
  let sopName: String
  let status: String

  init(id: UUID = UUID(), timestamp: Date, sopName: String, status: String) {
    self.id = id
    self.timestamp = timestamp
    self.sopName = sopName
    self.status = status
  }

  var timestampText: String {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .medium
    return formatter.string(from: timestamp)
  }
}

private struct PendingWorkerRecording: Codable, Equatable {
  let sessionID: String
  let filePath: String
}

private enum PendingWorkerRecordingStore {
  static func remember(defaultsKey: String, sessionID: String, fileURL: URL) {
    let pending = PendingWorkerRecording(sessionID: sessionID, filePath: fileURL.path)
    guard let encoded = try? JSONEncoder().encode(pending) else { return }
    UserDefaults.standard.set(encoded, forKey: defaultsKey)
  }

  static func clear(defaultsKey: String) {
    UserDefaults.standard.removeObject(forKey: defaultsKey)
  }
}

private struct IPhoneAnalysisFrameEnvelope: @unchecked Sendable {
  let image: UIImage
  let shouldRecordAudit: Bool
  let enqueuedAt: CFTimeInterval
}

private struct SendableStreamPixelBuffer: @unchecked Sendable {
  let pixelBuffer: CVPixelBuffer
}

private struct SendableSampleBuffer: @unchecked Sendable {
  let sampleBuffer: CMSampleBuffer
}

private struct SendableDecodedVideoFrame: @unchecked Sendable {
  let pixelBuffer: CVPixelBuffer
  let presentationTimeStamp: CMTime

  init(_ frame: VideoDecoder.DecodedFrame) {
    pixelBuffer = frame.pixelBuffer
    presentationTimeStamp = frame.presentationTimeStamp
  }
}

private final class StreamPixelBufferImageRenderer: @unchecked Sendable {
  private let context = CIContext(options: [.useSoftwareRenderer: true])

  func makeUIImage(from pixelBuffer: CVPixelBuffer) -> UIImage? {
    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    guard width > 0, height > 0 else { return nil }

    let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
    let rect = CGRect(x: 0, y: 0, width: width, height: height)
    guard let cgImage = context.createCGImage(ciImage, from: rect) else { return nil }
    return UIImage(cgImage: cgImage)
  }
}

private final class GlassesVideoDecodeLane: @unchecked Sendable {
  private let queue = DispatchQueue(
    label: "visionclaw.glasses-video-decode-lane",
    qos: .userInitiated
  )
  private let decoder = VideoDecoder()
  private var onFrameDecoded: (@Sendable (SendableDecodedVideoFrame) -> Void)?

  init() {
    decoder.setFrameCallback { [weak self] frame in
      self?.onFrameDecoded?(SendableDecodedVideoFrame(frame))
    }
  }

  func setFrameCallback(_ callback: @escaping @Sendable (SendableDecodedVideoFrame) -> Void) {
    queue.sync {
      self.onFrameDecoded = callback
    }
  }

  func decode(_ sampleBuffer: CMSampleBuffer, onError: @escaping @Sendable (String) -> Void) {
    let sendableSampleBuffer = SendableSampleBuffer(sampleBuffer: sampleBuffer)
    queue.async {
      do {
        try self.decoder.decode(sendableSampleBuffer.sampleBuffer)
      } catch {
        onError(String(describing: error))
      }
    }
  }

  func invalidateSession() {
    queue.async {
      self.decoder.invalidateSession()
    }
  }
}

private final class IPhoneAnalysisLane: @unchecked Sendable {
  private let queue = DispatchQueue(
    label: "visionclaw.iphone.analysis-lane",
    qos: .userInitiated
  )
  private var pendingFrame: IPhoneAnalysisFrameEnvelope?
  private var isProcessing = false
  private var submittedCount: Int64 = 0
  private var processedCount: Int64 = 0
  private var droppedCount: Int64 = 0

  var onFrameReady: (@Sendable (IPhoneAnalysisFrameEnvelope, @escaping @Sendable () -> Void) -> Void)?

  func submit(_ image: UIImage, shouldRecordAudit: Bool) {
    queue.async {
      self.submittedCount += 1

      if self.pendingFrame != nil {
        self.droppedCount += 1
      }

      self.pendingFrame = IPhoneAnalysisFrameEnvelope(
        image: image,
        shouldRecordAudit: shouldRecordAudit,
        enqueuedAt: CACurrentMediaTime()
      )

      guard !self.isProcessing else { return }
      self.isProcessing = true
      self.drain()
    }
  }

  func reset() {
    queue.async {
      self.pendingFrame = nil
      self.isProcessing = false
      self.submittedCount = 0
      self.processedCount = 0
      self.droppedCount = 0
    }
  }

  private func drain() {
    guard let frame = pendingFrame else {
      isProcessing = false
      return
    }

    pendingFrame = nil
    let completion: @Sendable () -> Void = { [weak self] in
      guard let self else { return }
      self.queue.async {
        self.processedCount += 1
        self.logIfNeeded(lastLatencyMs: (CACurrentMediaTime() - frame.enqueuedAt) * 1000)
        self.drain()
      }
    }

    if let onFrameReady {
      onFrameReady(frame, completion)
    } else {
      completion()
    }
  }

  private func logIfNeeded(lastLatencyMs: Double) {
    guard processedCount == 1 || processedCount % 20 == 0 else { return }
    let queueDepth = pendingFrame == nil ? 0 : 1
    NSLog(
      "[Stream] iPhone analysis lane processed=%lld dropped=%lld queue-depth=%d last-latency=%.1fms",
      processedCount,
      droppedCount,
      queueDepth,
      lastLatencyMs
    )
  }
}

private final class LivePreviewFrameEncoder: @unchecked Sendable {
  private let queue = DispatchQueue(
    label: "visionclaw.live-preview-frame-encoder",
    qos: .utility
  )

  func encode(
    image: UIImage,
    maxDimension: CGFloat,
    compressionQuality: CGFloat
  ) async -> Data? {
    await withCheckedContinuation { continuation in
      queue.async {
        let previewImage = image.resizedForLivePreview(maxDimension: maxDimension)
        continuation.resume(returning: previewImage.jpegData(compressionQuality: compressionQuality))
      }
    }
  }
}

@MainActor
class StreamSessionViewModel: ObservableObject {
  @Published var currentVideoFrame: UIImage?
  @Published var hasReceivedFirstFrame: Bool = false
  @Published var streamingStatus: StreamingStatus = .stopped
  @Published var showError: Bool = false
  @Published var errorMessage: String = ""
  @Published var hasActiveDevice: Bool = false
  @Published var streamingMode: StreamingMode = .glasses
  @Published var selectedResolution: StreamingResolution = .low
  @Published var preferredCaptureMode: StreamingMode = .iPhone
  @Published var isSopAuditRunning: Bool = false
  @Published var sopAuditSecondsRemaining: Double = 15.0
  @Published var sopAuditStatusMessage: String = ""
  @Published var selectedSOP: SOPTemplate?
  @Published var checklistItems: [ChecklistItemState] = []
  @Published var shouldDismissCapture: Bool = false
  @Published var showShipSuccessToast: Bool = false
  @Published var isListeningForVoice: Bool = false
  @Published var isAiGuideStarting: Bool = false
  @Published var isStepValidationRunning: Bool = false
  @Published var aiGuideStatusMessage: String = ""
  @Published var isDossierUploading: Bool = false
  @Published var isSwitchingCaptureMode: Bool = false
  @Published var dossierPipelineStatusMessage: String = ""
  @Published var dossierPipelineStatusKind: DossierPipelineStatusKind = .info
  @Published var dossierPipelineStatusTimestamp: String = ""
  @Published var dossierSpotterHitCount: Int = 0
  @Published var shippedHistory: [ShippedSessionRecord] = []
  @Published var isSyncingOperations: Bool = false
  @Published var operationsSyncError: String?
  @Published var operationsSyncWarning: String?
  @Published var workerProfile: BackendWorker?
  @Published var registeredDevice: BackendDevice?
  @Published var activeShift: BackendShift?
  @Published var assignedPackages: [BackendAssignedPackage] = []
  @Published var activeExecutionSession: BackendExecutionSession?
  @Published var helpRequestNotes: String = ""
  @Published var helpStatusMessage: String = ""
  @Published var isRequestingHelp: Bool = false
  @Published var packageClosureStatusMessage: String = ""
  @Published var isClosingPackage: Bool = false
  @Published var activeCaptureSOP: SOPTemplate?
  @Published var geminiInstructionSyncStatus: String = ""
  @Published private(set) var guidancePolicy: GuidancePolicy = .nextInstruction
  @Published private(set) var guidancePolicyReason: String = "Start the assigned SOP."
  @Published var iPhonePreviewSession: AVCaptureSession?

  @Published var availableSOPs: [SOPTemplate] = []
  @Published private(set) var locallyCompletedPendingTaskKeys: Set<String> = []

  var isStreaming: Bool {
    streamingStatus != .stopped
  }

  var resolutionLabel: String {
    switch selectedResolution {
    case .low: return "360x640"
    case .medium: return "504x896"
    case .high: return "720x1280"
    @unknown default: return "Unknown"
    }
  }

  var progressText: String {
    "\(checklistItems.filter { $0.isChecked }.count)/\(checklistItems.count)"
  }

  var currentAssignedSOP: SOPTemplate? {
    if let selectedSOP, pendingTaskSOPs.contains(selectedSOP) {
      return selectedSOP
    }
    return pendingTaskSOPs.first
  }

  var workerDisplayName: String {
    if isDemoWorkerMode {
      return "Lucas Pereira"
    }
    return workerProfile?.displayName ?? "Unassigned Worker"
  }

  var workerRoleText: String {
    workerProfile?.role?.uppercased() ?? "WORKER"
  }

  var activePackageTitle: String {
    assignedPackages.first?.title
      ?? activeShift?.package?.title
      ?? currentAssignedSOP?.packageTitle
      ?? "No Active Package"
  }

  var pendingTaskSOPs: [SOPTemplate] {
    availableSOPs
      .sorted { $0.sortOrder < $1.sortOrder }
      .filter { !locallyCompletedPendingTaskKeys.contains(pendingTaskKey(for: $0)) }
  }

  var pendingShiftLabel: String {
    activeShift?.shiftName
      ?? currentAssignedSOP?.shiftName
      ?? "MORNING SHIFT"
  }

  var pendingTaskHeaderSummary: String {
    let count = pendingTaskSOPs.count
    if count == 0 {
      return "ALL PENDING TASKS COMPLETE"
    }
    return "\(count) PENDING TASK\(count == 1 ? "" : "S") · \(selectedCaptureModeLabel)"
  }

  var activeAssignedPackageCount: Int {
    assignedPackages.count
  }

  var currentPackageProgressText: String {
    guard let key = currentPackageCompletionKey, !currentPackageRequiredRemoteIDs.isEmpty else {
      return availableSOPs.isEmpty ? "NO PACKAGE QUEUE" : "\(availableSOPs.count) SOPS QUEUED"
    }

    let completedCount = locallyCompletedSopsByPackageKey[key]?.count ?? 0
    return "\(completedCount)/\(currentPackageRequiredRemoteIDs.count) PACKAGE SOPS COMPLETE"
  }

  var currentSessionSyncLabel: String {
    if let activeExecutionSession {
      return "SESSION \(activeExecutionSession.id.prefix(8))"
    }
    if currentSopSessionId != nil {
      return "LOCAL SESSION"
    }
    return "NOT STARTED"
  }

  var canRequestHelp: Bool {
    isSopAuditRunning
  }

  var canTapBackOfficeCall: Bool {
    canRequestHelp && !isRequestingHelp && !hasActiveHelpEscalation
  }

  var backOfficeCallButtonTitle: String {
    if webrtcViewModel.isActive {
      return "LIVE"
    }
    if isRequestingHelp {
      return "CALLING"
    }
    if hasActiveHelpEscalation {
      return "RINGING"
    }
    return "CALL"
  }

  var canCloseCurrentPackage: Bool {
    guard activePackageRunID != nil else { return false }
    guard let key = currentPackageCompletionKey, !currentPackageRequiredRemoteIDs.isEmpty else { return false }
    let completed = locallyCompletedSopsByPackageKey[key] ?? []
    return Set(currentPackageRequiredRemoteIDs).isSubset(of: completed)
  }

  var selectedCaptureModeLabel: String {
    switch preferredCaptureMode {
    case .glasses: return "META CAMERA"
    case .iPhone: return "IPHONE CAMERA"
    }
  }

  var currentAssignmentSubtitle: String {
    guard let sop = currentAssignedSOP else { return "No assignment loaded" }
    let package = sop.packageTitle ?? activePackageTitle
    let stepCount = sop.steps.count
    return "\(package) · \(stepCount) STEP\(stepCount == 1 ? "" : "S")"
  }

  var assignmentQueueSummary: String {
    let count = pendingTaskSOPs.count
    if count == 0 {
      return "Queue clear"
    }
    if count == 1 {
      return "1 assignment ready"
    }
    return "\(count) assignments ready"
  }

  var cameraReadinessLabel: String {
    hasActiveDevice ? "Meta camera ready" : "iPhone camera ready"
  }

  var cameraReadinessDetail: String {
    hasActiveDevice
      ? "Glasses will be used for the next execution."
      : "Using iPhone until glasses are available."
  }

  var aiGuideButtonTitle: String {
    if isAiGuideStarting {
      return "STARTING AI"
    }
    if geminiAssistant.isGeminiActive && geminiAssistant.isAudioReady {
      return "AI LISTENING"
    }
    if geminiAssistant.isGeminiActive {
      return "AI CONNECTING"
    }
    return "RESUME AI"
  }

  var canToggleAiGuide: Bool {
    isSopAuditRunning && !isAiGuideStarting && !hasActiveHelpEscalation
  }

  var canSwitchCaptureMode: Bool {
    !isSwitchingCaptureMode &&
      !isRequestingHelp &&
      !webrtcViewModel.isActive &&
      !isDossierUploading &&
      !isFinalizingAndShipping
  }

  var canRequestStepValidation: Bool {
    isSopAuditRunning && !isStepValidationRunning && !hasActiveHelpEscalation
  }

  // Photo capture properties
  @Published var capturedPhoto: UIImage?
  @Published var showPhotoPreview: Bool = false

  // Operational backend integration
  private let opsAPIClient = OpsAPIClient()
  let geminiAssistant = GeminiSessionViewModel()
  private let geminiLiveSpotter = GeminiLiveSpotter()
  let webrtcViewModel = WebRTCSessionViewModel()
  private var workerAdminSync: WorkerAdminLiveSessionCoordinator?
  private var currentSopSessionId: String?
  private var sopCountdownTask: Task<Void, Never>?
  private var sopVideoRecorder: SopVideoRecorder?
  private let liveFrameProcessingQueue = DispatchQueue(
    label: "stream.live.frame-processing",
    qos: .userInitiated
  )
  private var proofImagesByTargetID: [String: Data] = [:]
  private var spotterEvidenceWindow = SpotterEvidenceWindow()
  private var lastSpotterInferenceTime: Date = .distantPast
  private var currentStepBecameActiveAt: Date = Date()
  private var isSpotterInferenceInFlight = false
  private var isFinalizingAndShipping = false
  private var successToastTask: Task<Void, Never>?
  private var hasLoadedWorkerContext = false
  private var hasEnteredWorkerHome = false
  private var isUsingLocalSessionFallback = false
  private var roomCodeCancellable: AnyCancellable?
  private var connectionStateCancellable: AnyCancellable?
  private var livePressureCancellable: AnyCancellable?
  private var locallyCompletedSopsByPackageKey: [String: Set<String>] = [:]
  private var lastLivePreviewSyncAt: Date = .distantPast
  private var hasActiveHelpEscalation = false
  private struct LiveRoomSyncSnapshot: Equatable {
    let roomCode: String
    let helpRequested: Bool
    let backOfficeConnected: Bool
  }
  private var lastLiveRoomSyncSnapshot: LiveRoomSyncSnapshot?
  private var lastLiveRoomSyncAt: Date = .distantPast
  private let liveRoomRedundantSyncThrottleInterval: TimeInterval = 5
  private var hasReceivedBackOfficeConnectedHandshake = false
  private var hasLoggedRoomCreatedForSession = false
  private var hasLoggedRoomJoinedForSession = false
  private var didAttemptPendingRecordingRecovery = false
  private var shouldResumeAiSupportAfterBackOffice = false
  private var isLiveRoomHandoffInProgress = false
  private var lastWorkerLiveHeartbeatFailureWarningAt: Date = .distantPast

  private var isDemoWorkerMode: Bool {
    let configuredCode = GeminiConfig.workerLoginCode.trimmingCharacters(in: .whitespacesAndNewlines)
    let workerCode = workerProfile?.loginCode?.trimmingCharacters(in: .whitespacesAndNewlines)
    let loginCode = workerCode?.isEmpty == false ? workerCode! : configuredCode
    return loginCode.uppercased() == "EMBC-0001"
  }

  private func pendingTaskKey(for sop: SOPTemplate) -> String {
    [
      sop.shiftID ?? "shift",
      sop.packageRunID ?? sop.packageID ?? "standalone",
      sop.remoteID ?? sop.id.uuidString,
      "\(sop.sortOrder)"
    ].joined(separator: "::")
  }

  // Hold-to-talk speech recognition
  private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
  private let audioEngine = AVAudioEngine()
  private var speechRequest: SFSpeechAudioBufferRecognitionRequest?
  private var speechTask: SFSpeechRecognitionTask?
  private var lastProcessedTranscript: String = ""
  private var lastAiCommandKey: String = ""
  private var lastAiCommandAt: Date = .distantPast

  private var currentPackageCompletionKey: String? {
    if let runID = activePackageRunID {
      return runID
    }
    return currentAssignedSOP?.packageID ?? assignedPackages.first?.id
  }

  private var activePackageRunID: String? {
    currentAssignedSOP?.packageRunID
      ?? assignedPackages.first(where: { $0.id == currentAssignedSOP?.packageID })?.packageRunID
      ?? assignedPackages.first?.packageRunID
  }

  private var currentPackageRequiredRemoteIDs: [String] {
    let packageID = currentAssignedSOP?.packageID ?? assignedPackages.first?.id
    return availableSOPs
      .filter { sop in
        sop.required &&
          sop.packageID == packageID &&
          sop.sourceType == "package"
      }
      .compactMap(\.remoteID)
  }

  private let historyDefaultsKey = "visionclaw.shipped.history.v2"
  private let pendingRecordingDefaultsKey = "visionclaw.pending.worker.recording.v1"
  private static let pipelineTimestampFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "HH:mm:ss"
    return formatter
  }()

  // The core DAT SDK StreamSession - handles all streaming operations
  private var streamSession: StreamSession
  // Listener tokens are used to manage DAT SDK event subscriptions
  private var stateListenerToken: AnyListenerToken?
  private var videoFrameListenerToken: AnyListenerToken?
  private var errorListenerToken: AnyListenerToken?
  private var photoDataListenerToken: AnyListenerToken?
  private let wearables: WearablesInterface
  private let deviceSelector: AutoDeviceSelector
  private var deviceMonitorTask: Task<Void, Never>?
  private var iPhoneCameraManager: IPhoneCameraManager?
  private var conversationAudioRecorder: ConversationAudioRecorder?
  private var holdToTalkAudioLease: WorkerAudioRouteLease?
  private var viewerAudioRouteLease: WorkerAudioRouteLease?
  private let iPhoneAnalysisLane = IPhoneAnalysisLane()
  private let livePreviewFrameEncoder = LivePreviewFrameEncoder()
  private let streamImageRenderer = StreamPixelBufferImageRenderer()
  private let videoDecodeLane = GlassesVideoDecodeLane()

  private var backgroundFrameCount = 0
  private var bgDiagLogged = false
  private var lastGlassesAnalysisFrameQueuedAt: CFTimeInterval = 0

  init(wearables: WearablesInterface) {
    self.wearables = wearables
    // Let the SDK auto-select from available devices
    self.deviceSelector = AutoDeviceSelector(wearables: wearables)
    let config = StreamSessionConfig(
      videoCodec: VideoCodec.raw,
      resolution: StreamingResolution.low,
      frameRate: 24)
    streamSession = StreamSession(streamSessionConfig: config, deviceSelector: deviceSelector)

    // Monitor device availability
    deviceMonitorTask = Task { @MainActor in
      for await device in deviceSelector.activeDeviceStream() {
        self.hasActiveDevice = device != nil
        self.reconcileCaptureModeWithDeviceAvailability(allowTransportSwitch: true)
      }
    }

    setupVideoDecoder()
    attachListeners()
    loadHistoryFromDefaults()
    requestSpeechPermissionsIfNeeded()
    observeWebRTCSession()
    geminiAssistant.onInputCommand = { [weak self] transcript in
      Task { @MainActor [weak self] in
        self?.handleVoiceTranscript(transcript)
      }
    }
    geminiAssistant.onInputAudioChunk = { [weak self] data in
      self?.sopVideoRecorder?.appendInputAudio(data)
      self?.conversationAudioRecorder?.appendInputAudio(data)
    }
    geminiAssistant.onOutputAudioChunk = { [weak self] data in
      self?.sopVideoRecorder?.appendOutputAudio(data)
      self?.conversationAudioRecorder?.appendOutputAudio(data)
    }
    iPhoneAnalysisLane.onFrameReady = { [weak self] frame, completion in
      Task { @MainActor [weak self] in
        guard let self else {
          completion()
          return
        }
        self.handleIPhoneAnalysisFrame(frame)
        completion()
      }
    }
  }

  private func setupVideoDecoder() {
    let imageRenderer = streamImageRenderer
    videoDecodeLane.setFrameCallback { [weak self, imageRenderer] decodedFrame in
      Task { @MainActor [weak self] in
        guard let self else { return }
        let pixelBuffer = decodedFrame.pixelBuffer
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let timeStampNs = decodedFrame.presentationTimeStamp.isValid
          ? Int64(CMTimeGetSeconds(decodedFrame.presentationTimeStamp) * 1_000_000_000)
          : VideoFrameBufferFactory.currentTimestampNs()
        if self.webrtcViewModel.isActive {
          self.webrtcViewModel.realtimeVideoForwarder.enqueuePixelBuffer(
            pixelBuffer,
            timeStampNs: timeStampNs
          )
        }
        let shouldRecordAudit = self.isSopAuditRunning
        if shouldRecordAudit {
          self.sopVideoRecorder?.appendPixelBuffer(pixelBuffer)
        }

        guard self.shouldQueueGlassesAnalysisFrame(now: CACurrentMediaTime()) else { return }
        let sendablePixelBuffer = SendableStreamPixelBuffer(pixelBuffer: pixelBuffer)
        self.liveFrameProcessingQueue.async { [weak self] in
          guard let image = imageRenderer.makeUIImage(from: sendablePixelBuffer.pixelBuffer) else { return }
          Task { @MainActor [weak self] in
            guard let self else { return }
            self.handleAnalysisImageFrame(image, shouldRecordAudit: shouldRecordAudit)
            if self.backgroundFrameCount <= 5 || self.backgroundFrameCount % 120 == 0 {
              NSLog("[Stream] Background frame #%d decoded and forwarded (%dx%d)",
                    self.backgroundFrameCount, width, height)
            }
          }
        }
      }
    }
  }

  /// Recreate the StreamSession with the current selectedResolution.
  /// Only call when not actively streaming.
  func updateResolution(_ resolution: StreamingResolution) {
    guard !isStreaming else { return }
    selectedResolution = resolution
    let config = StreamSessionConfig(
      videoCodec: VideoCodec.raw,
      resolution: resolution,
      frameRate: 24)
    streamSession = StreamSession(streamSessionConfig: config, deviceSelector: deviceSelector)
    attachListeners()
    NSLog("[Stream] Resolution changed to %@", resolutionLabel)
  }

  private func attachListeners() {
    let realtimeVideoForwarder = webrtcViewModel.realtimeVideoForwarder

    // Subscribe to session state changes using the DAT SDK listener pattern
    stateListenerToken = streamSession.statePublisher.listen { [weak self] state in
      Task { @MainActor [weak self] in
        self?.updateStatusFromState(state)
      }
    }

    // Subscribe to video frames from the device camera
    // This callback fires whether the app is in the foreground or background,
    // enabling continuous streaming even when the screen is locked.
    videoFrameListenerToken = streamSession.videoFramePublisher.listen { [weak self] videoFrame in
      Task { @MainActor [weak self] in
        guard let self else { return }
        let shouldForwardToWebRTC = self.webrtcViewModel.isActive
        let shouldRecordAudit = self.isSopAuditRunning

        let isInBackground = UIApplication.shared.applicationState == .background

        if !isInBackground {
          self.backgroundFrameCount = 0
          self.bgDiagLogged = false

          let sampleBuffer = videoFrame.sampleBuffer
          let timeStampNs = Self.rtcTimestampNs(from: sampleBuffer)
          if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            if shouldForwardToWebRTC {
              realtimeVideoForwarder.enqueuePixelBuffer(pixelBuffer, timeStampNs: timeStampNs)
            }
            if shouldRecordAudit {
              self.sopVideoRecorder?.appendPixelBuffer(pixelBuffer)
            }
            guard self.shouldQueueGlassesAnalysisFrame(now: CACurrentMediaTime()) else { return }
            let sendablePixelBuffer = SendableStreamPixelBuffer(pixelBuffer: pixelBuffer)
            let imageRenderer = self.streamImageRenderer
            self.liveFrameProcessingQueue.async { [weak self] in
              guard let image = imageRenderer.makeUIImage(from: sendablePixelBuffer.pixelBuffer) else { return }
              Task { @MainActor [weak self] in
                self?.handleAnalysisImageFrame(image, shouldRecordAudit: shouldRecordAudit)
              }
            }
          } else if CMSampleBufferGetDataBuffer(sampleBuffer) != nil {
            let decodeLane = self.videoDecodeLane
            decodeLane.decode(sampleBuffer) { errorMessage in
              NSLog("[Stream] Foreground decode error: %@", errorMessage)
            }
          } else {
            guard self.shouldQueueGlassesAnalysisFrame(now: CACurrentMediaTime()) else { return }
            self.liveFrameProcessingQueue.async { [weak self] in
              guard let self else { return }
              guard let image = videoFrame.makeUIImage() else { return }
              let timeStampNs = VideoFrameBufferFactory.currentTimestampNs()

              if shouldForwardToWebRTC {
                realtimeVideoForwarder.enqueueImage(image)
              }

              Task { @MainActor [weak self] in
                self?.handleProcessedLiveFrame(
                  image: image,
                  pixelBuffer: nil,
                  timeStampNs: timeStampNs,
                  shouldForwardToWebRTC: false,
                  shouldRecordAudit: shouldRecordAudit
                )
              }
            }
          }
        } else {
          // In background: makeUIImage() uses VideoToolbox GPU rendering which iOS suspends.
          // Instead, use our VideoDecoder (VTDecompressionSession) to decode compressed
          // frames into pixel buffers, then convert via CPU CIContext.
          self.backgroundFrameCount += 1

          let sampleBuffer = videoFrame.sampleBuffer
          let hasCompressedData = CMSampleBufferGetDataBuffer(sampleBuffer) != nil

          if hasCompressedData {
            // Compressed frame (HEVC/H.264) - decode via VTDecompressionSession
            let decodeLane = self.videoDecodeLane
            let frameCount = self.backgroundFrameCount
            decodeLane.decode(sampleBuffer) { errorMessage in
              if frameCount <= 5 || frameCount % 120 == 0 {
                NSLog("[Stream] Background frame #%d decode error: %@",
                      frameCount, errorMessage)
              }
            }
          } else if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            // Raw pixel buffer - convert directly via CPU CIContext
            let timeStampNs = Self.rtcTimestampNs(from: sampleBuffer)
            if shouldForwardToWebRTC {
              realtimeVideoForwarder.enqueuePixelBuffer(pixelBuffer, timeStampNs: timeStampNs)
            }
            if shouldRecordAudit {
              self.sopVideoRecorder?.appendPixelBuffer(pixelBuffer)
            }
            if self.shouldQueueGlassesAnalysisFrame(now: CACurrentMediaTime()) {
              let sendablePixelBuffer = SendableStreamPixelBuffer(pixelBuffer: pixelBuffer)
              let imageRenderer = self.streamImageRenderer
              self.liveFrameProcessingQueue.async { [weak self] in
                guard let image = imageRenderer.makeUIImage(from: sendablePixelBuffer.pixelBuffer) else { return }
                Task { @MainActor [weak self] in
                  self?.handleAnalysisImageFrame(image, shouldRecordAudit: shouldRecordAudit)
                }
              }
            }
            self.videoDecodeLane.invalidateSession()
          }
        }
      }
    }

    // Subscribe to streaming errors
    errorListenerToken = streamSession.errorPublisher.listen { [weak self] error in
      Task { @MainActor [weak self] in
        guard let self else { return }
        // Suppress device-not-found errors when user hasn't started streaming yet
        if self.streamingStatus == .stopped {
          if case .deviceNotConnected = error { return }
          if case .deviceNotFound = error { return }
        }
        let newErrorMessage = formatStreamingError(error)
        if newErrorMessage != self.errorMessage {
          showError(newErrorMessage)
        }
      }
    }

    updateStatusFromState(streamSession.state)

    // Subscribe to photo capture events
    photoDataListenerToken = streamSession.photoDataPublisher.listen { [weak self] photoData in
      Task { @MainActor [weak self] in
        guard let self else { return }
        if let uiImage = UIImage(data: photoData.data) {
          self.capturedPhoto = uiImage
          self.showPhotoPreview = true
        }
      }
    }
  }

  func handleStartStreaming() async {
    let permission = Permission.camera
    do {
      let status = try await wearables.checkPermissionStatus(permission)
      if status == .granted {
        await startSession()
        return
      }
      let requestStatus = try await wearables.requestPermission(permission)
      if requestStatus == .granted {
        await startSession()
        return
      }
      showError("Permission denied")
    } catch {
      showError("Permission error: \(error.description)")
    }
  }

  func startSession() async {
    geminiAssistant.streamingMode = streamingMode
    await streamSession.start()
  }

  private func showError(_ message: String) {
    errorMessage = message
    showError = true
  }

  private func handleProcessedLiveFrame(
    image: UIImage,
    pixelBuffer: CVPixelBuffer?,
    timeStampNs: Int64,
    shouldForwardToWebRTC: Bool,
    shouldRecordAudit: Bool
  ) {
    if shouldForwardToWebRTC {
      if let pixelBuffer {
        webrtcViewModel.pushVideoPixelBuffer(pixelBuffer, timeStampNs: timeStampNs)
      } else {
        webrtcViewModel.pushVideoFrame(image)
      }
    }

    handleAnalysisImageFrame(image, shouldRecordAudit: shouldRecordAudit)

    if shouldRecordAudit {
      if let pixelBuffer {
        sopVideoRecorder?.appendPixelBuffer(pixelBuffer)
      } else {
        sopVideoRecorder?.appendFrame(image)
      }
    }
  }

  private func handleAnalysisImageFrame(_ image: UIImage, shouldRecordAudit: Bool) {
    currentVideoFrame = image
    if !hasReceivedFirstFrame {
      hasReceivedFirstFrame = true
    }

    geminiAssistant.sendVideoFrameIfThrottled(image: image)

    if shouldRecordAudit {
      Task { await syncLivePreviewFrameIfNeeded(image: image) }
    }
  }

  private func shouldQueueGlassesAnalysisFrame(now: CFTimeInterval) -> Bool {
    let interval: CFTimeInterval = webrtcViewModel.isUnderLiveVideoPressure ? 0.2 : 0.1
    if !hasReceivedFirstFrame || now - lastGlassesAnalysisFrameQueuedAt >= interval {
      lastGlassesAnalysisFrameQueuedAt = now
      return true
    }
    return false
  }

  private func enqueueIPhoneAnalysisFrame(_ image: UIImage, shouldRecordAudit: Bool) {
    iPhoneAnalysisLane.submit(image, shouldRecordAudit: shouldRecordAudit)
  }

  private func handleIPhoneAnalysisFrame(_ frame: IPhoneAnalysisFrameEnvelope) {
    handleAnalysisImageFrame(frame.image, shouldRecordAudit: frame.shouldRecordAudit)
  }

  private func resetIPhoneAnalysisLane() {
    iPhoneAnalysisLane.reset()
  }

  private static func rtcTimestampNs(from sampleBuffer: CMSampleBuffer) -> Int64 {
    let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    if presentationTime.isValid {
      return Int64(CMTimeGetSeconds(presentationTime) * 1_000_000_000)
    }
    return VideoFrameBufferFactory.currentTimestampNs()
  }

  func stopSession() async {
    await geminiAssistant.stopSession()
    isAiGuideStarting = false
    isStepValidationRunning = false
    aiGuideStatusMessage = ""
    if isSopAuditRunning {
      await endAndShip(status: .userEnded)
    } else {
      await workerAdminSync?.stop()
      workerAdminSync = nil
      resetLiveRoomSyncSnapshot()
    }

    if webrtcViewModel.isActive {
      webrtcViewModel.stopSession()
    }
    activeCaptureSOP = nil

    if streamingMode == .iPhone {
      stopIPhoneSession()
      return
    }
    await streamSession.stop()
  }

  func toggleGeminiAssistant() async {
    guard canToggleAiGuide else { return }
    if geminiAssistant.isGeminiActive {
      await geminiAssistant.stopSession()
      aiGuideStatusMessage = "AI guide paused."
      sopAuditStatusMessage = aiGuideStatusMessage
      return
    }

    await startGeminiAssistant(
      startingMessage: "Loading checklist guide...",
      listeningMessage: "AI guide listening. Say \"I'm done\" when you want me to check this step."
    )
  }

  @discardableResult
  private func startGeminiAssistant(
    startingMessage: String,
    listeningMessage: String
  ) async -> Bool {
    guard isSopAuditRunning, !isAiGuideStarting, !hasActiveHelpEscalation else { return false }
    geminiAssistant.streamingMode = streamingMode
    geminiAssistant.configureWorkerAdminAPI(
      opsAPIClient,
      sessionID: activeExecutionSession?.id
    )

    isAiGuideStarting = true
    aiGuideStatusMessage = startingMessage
    sopAuditStatusMessage = aiGuideStatusMessage
    await geminiAssistant.startSession(systemInstruction: buildGeminiSessionInstruction())
    isAiGuideStarting = false
    if let errorMessage = geminiAssistant.errorMessage, !errorMessage.isEmpty {
      sopAuditStatusMessage = errorMessage
      aiGuideStatusMessage = errorMessage
      await postExecutionEvent(
        type: "ai_guide_failed",
        payload: [
          "error": errorMessage,
          "capture_mode": selectedCaptureModeLabel.lowercased()
        ]
      )
      return false
    } else if geminiAssistant.isGeminiActive {
      aiGuideStatusMessage = listeningMessage
      sopAuditStatusMessage = aiGuideStatusMessage
      await postExecutionEvent(
        type: "ai_guide_started",
        payload: [
          "capture_mode": selectedCaptureModeLabel.lowercased()
        ]
      )
      return true
    }
    return false
  }

  private func autoStartAiGuideWhenCaptureIsReady() async {
    await ensureAiGuideStarted(reason: "capture_ready")
  }

  private func waitForMediaReadyBeforeAiStart(reason: String) async -> Bool {
    guard streamingMode == .iPhone else { return true }
    guard let camera = iPhoneCameraManager else {
      await recordAiGuideMediaReadyTimeout(reason: reason, cameraReady: false)
      return false
    }

    aiGuideStatusMessage = "Waiting for phone camera and mic..."
    sopAuditStatusMessage = aiGuideStatusMessage

    let timeout: CFTimeInterval = 3.0
    let deadline = CACurrentMediaTime() + timeout
    var cameraReady = false

    while CACurrentMediaTime() < deadline {
      guard isSopAuditRunning, !hasActiveHelpEscalation else { return false }
      let remaining = max(0, deadline - CACurrentMediaTime())
      cameraReady = await camera.waitUntilRunningAndAudioConfigured(
        timeout: min(0.25, remaining)
      )
      if cameraReady && hasReceivedFirstFrame {
        try? await Task.sleep(nanoseconds: 150_000_000)
        return true
      }
      try? await Task.sleep(nanoseconds: 100_000_000)
    }

    await recordAiGuideMediaReadyTimeout(reason: reason, cameraReady: cameraReady)
    return false
  }

  private func recordAiGuideMediaReadyTimeout(reason: String, cameraReady: Bool) async {
    let message = "Phone camera/mic still warming up. Tap Start AI to retry."
    aiGuideStatusMessage = message
    sopAuditStatusMessage = message
    await WorkerTelemetry.shared.record(
      "ai_guide_media_ready_timeout",
      source: "gemini_live",
      stage: "timeout",
      sessionID: currentSopSessionId,
      payload: [
        "reason": reason,
        "camera_ready": cameraReady,
        "has_first_frame": hasReceivedFirstFrame,
        "capture_mode": captureModeEventValue(streamingMode)
      ]
    )
    await postExecutionEvent(
      type: "ai_guide_media_ready_timeout",
      payload: [
        "reason": reason,
        "camera_ready": cameraReady,
        "has_first_frame": hasReceivedFirstFrame,
        "capture_mode": captureModeEventValue(streamingMode)
      ]
    )
  }

  @discardableResult
  private func ensureAiGuideStarted(
    reason: String,
    maxAttempts: Int = 3
  ) async -> Bool {
    guard isSopAuditRunning, !hasActiveHelpEscalation else { return false }
    if geminiAssistant.isGeminiActive {
      return true
    }
    guard !isAiGuideStarting else { return false }
    guard await waitForMediaReadyBeforeAiStart(reason: reason) else { return false }

    aiGuideStatusMessage = "Connecting AI voice..."
    sopAuditStatusMessage = aiGuideStatusMessage

    for attempt in 1...maxAttempts {
      guard isSopAuditRunning, !hasActiveHelpEscalation else { return false }
      await WorkerTelemetry.shared.record(
        "ai_guide_autostart_attempt",
        source: "gemini_live",
        stage: "attempt",
        sessionID: currentSopSessionId,
        payload: [
          "reason": reason,
          "attempt": attempt,
          "max_attempts": maxAttempts,
          "has_first_frame": hasReceivedFirstFrame,
          "capture_mode": captureModeEventValue(streamingMode)
        ]
      )
      await postExecutionEvent(
        type: "ai_guide_autostart_attempt",
        payload: [
          "reason": reason,
          "attempt": attempt,
          "has_first_frame": hasReceivedFirstFrame,
          "capture_mode": captureModeEventValue(streamingMode)
        ]
      )

      let started = await startGeminiAssistant(
        startingMessage: attempt == 1 ? "Connecting AI voice..." : "Retrying AI voice...",
        listeningMessage: "AI guide listening. Say \"I'm done\" or \"next step\" when you finish a step."
      )
      if started {
        await WorkerTelemetry.shared.record(
          "ai_guide_autostart_ready",
          source: "gemini_live",
          stage: "ready",
          sessionID: currentSopSessionId,
          payload: [
            "reason": reason,
            "attempt": attempt,
            "has_first_frame": hasReceivedFirstFrame
          ]
        )
        return true
      }

      guard attempt < maxAttempts else { break }
      try? await Task.sleep(nanoseconds: UInt64(attempt) * 850_000_000)
    }

    await WorkerTelemetry.shared.record(
      "ai_guide_autostart_failed",
      source: "gemini_live",
      stage: "failed",
      sessionID: currentSopSessionId,
      payload: [
        "reason": reason,
        "error": geminiAssistant.errorMessage ?? NSNull()
      ]
    )
    return false
  }

  func beginLiveCapture(for sop: SOPTemplate) async {
    selectedSOP = sop
    activeCaptureSOP = sop
    configureChecklist(for: sop)
    showShipSuccessToast = false
    shouldDismissCapture = false
    sopAuditStatusMessage = "Loading checklist guide..."
    aiGuideStatusMessage = sopAuditStatusMessage
    isAiGuideStarting = false
    isStepValidationRunning = false
    helpStatusMessage = ""

    if !hasLoadedWorkerContext {
      await loadWorkerContextIfNeeded()
    }

    if !isStreaming {
      await startPreferredCamera()
    }

    guard isStreaming else { return }

    await startSopAudit(for: sop)
    if isSopAuditRunning && !geminiAssistant.isGeminiActive {
      await ensureAiGuideStarted(reason: "begin_live_capture")
    }
  }

  func selectCaptureMode(_ mode: StreamingMode) {
    guard mode != .glasses || hasActiveDevice else {
      sopAuditStatusMessage = "Meta camera not connected."
      return
    }
    preferredCaptureMode = mode
    if webrtcViewModel.isActive && webrtcViewModel.isSupportMode {
      do {
        if let routeWarning = try configureWorkerAudioRoute(for: mode, reason: .viewer) {
          helpStatusMessage = routeWarning
        }
      } catch {
        helpStatusMessage = "Audio route update failed: \(error.localizedDescription)"
      }
    }
  }

  func selectCaptureModeFromUI(_ mode: StreamingMode) {
    selectCaptureMode(mode)
    Task { @MainActor [weak self] in
      await self?.switchToPreferredCaptureModeIfNeeded()
    }
  }

  func startCurrentAssignmentFromHome() {
    reconcileCaptureModeWithDeviceAvailability(allowTransportSwitch: false)
    guard let sop = currentAssignedSOP else {
      if operationsSyncError == nil {
        setCriticalOperationsSyncIssue(
          phase: "assignment",
          message: "No active SOP assignment is available for this worker."
        )
      }
      return
    }

    selectedSOP = sop
    activeCaptureSOP = sop
    shouldDismissCapture = false
  }

  func presentCapture(for sop: SOPTemplate) {
    selectedSOP = sop
    activeCaptureSOP = sop
    shouldDismissCapture = false
  }

  func handleWorkerHomeEntered() async {
    if !hasLoadedWorkerContext {
      await loadWorkerContextIfNeeded()
    }
    reconcileCaptureModeWithDeviceAvailability(allowTransportSwitch: false)
    await startHomeCameraPreviewIfNeeded()

    guard !hasEnteredWorkerHome else { return }
    hasEnteredWorkerHome = true
    await resetDemoShiftForHomeIfNeeded(reloadAssignments: false)
  }

  func handleWorkerAppBecameActive() async {
    guard hasEnteredWorkerHome else { return }
    guard !isSopAuditRunning, activeCaptureSOP == nil else { return }
    await resetDemoShiftForHomeIfNeeded(reloadAssignments: true)
    await startHomeCameraPreviewIfNeeded()
  }

  func restoreActiveCaptureIfNeeded() {
    guard activeCaptureSOP == nil else { return }
    guard isSopAuditRunning else { return }
    if let activeSOP = selectedSOP ?? currentAssignedSOP {
      activeCaptureSOP = activeSOP
    }
  }

  func switchToPreferredCaptureModeIfNeeded() async {
    guard canSwitchCaptureMode else { return }

    if preferredCaptureMode == .glasses, !hasActiveDevice {
      sopAuditStatusMessage = "Meta camera not connected."
      return
    }

    if isStreaming && streamingMode == preferredCaptureMode {
      return
    }

    let previousMode = streamingMode
    isSwitchingCaptureMode = true
    defer { isSwitchingCaptureMode = false }

    await stopCurrentCameraTransportOnly()
    await startPreferredCamera()

    if isStreaming, streamingMode == preferredCaptureMode, previousMode != streamingMode {
      geminiAssistant.streamingMode = streamingMode
      if isSopAuditRunning {
        await postExecutionEvent(
          type: "capture_mode_switched",
          payload: [
            "from": captureModeEventValue(previousMode),
            "to": captureModeEventValue(streamingMode),
            "label": selectedCaptureModeLabel
          ]
        )
      }
    }
  }

  func loadWorkerContextIfNeeded() async {
    guard !hasLoadedWorkerContext else { return }
    await refreshWorkerContext()
  }

  func refreshWorkerContext() async {
    guard GeminiConfig.isOpsConfigured else {
      setCriticalOperationsSyncIssue(
        phase: "bootstrap",
        message: "Set the ops-api URL in Settings to load assignments."
      )
      return
    }

    let loginCode = GeminiConfig.workerLoginCode.trimmingCharacters(in: .whitespacesAndNewlines)
    let workerEmail = GeminiConfig.workerEmail.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !loginCode.isEmpty || !workerEmail.isEmpty else {
      setCriticalOperationsSyncIssue(
        phase: "bootstrap",
        message: "Set a worker email or login code in Settings to bootstrap assignments."
      )
      return
    }

    isSyncingOperations = true
    clearOperationsSyncState()
    packageClosureStatusMessage = ""
    defer { isSyncingOperations = false }

    do {
      let payload = try await opsAPIClient.bootstrap(
        loginCode: loginCode.isEmpty ? nil : loginCode,
        email: workerEmail.isEmpty ? nil : workerEmail,
        platform: "ios",
        label: UIDevice.current.name
      )

      workerProfile = payload.worker
      registeredDevice = payload.device
      activeShift = payload.shift
      let canonicalLucasTemplates = lucasDemoQueueTemplates()
      let resolvedQueue = canonicalLucasQueue(from: payload.queue)
      assignedPackages =
        payload.assignedPackages.isEmpty
        ? deriveAssignedPackages(from: resolvedQueue, canonicalTemplates: canonicalLucasTemplates)
        : payload.assignedPackages
      availableSOPs = resolvedQueue.map { hydrateQueueItem($0, canonicalTemplates: canonicalLucasTemplates) }
      if selectedSOP == nil || !pendingTaskSOPs.contains(selectedSOP!) {
        selectedSOP = pendingTaskSOPs.first
      }
      reconcileCaptureModeWithDeviceAvailability(allowTransportSwitch: false)
      hasLoadedWorkerContext = true

      if availableSOPs.isEmpty {
        if isDemoWorkerMode {
          applyLucasDemoWorkerFallback(reason: "No remote SOPs were assigned yet. Using the local Lucas demo queue.")
        } else {
          setCriticalOperationsSyncIssue(
            phase: "bootstrap",
            message: "No SOPs assigned to this worker yet."
          )
        }
      }

      await recoverPendingWorkerRecordingIfNeeded()
    } catch {
      if isDemoWorkerMode {
        applyLucasDemoWorkerFallback(
          reason: "Assignment sync failed: \(error.localizedDescription). Using the local Lucas demo queue."
        )
        hasLoadedWorkerContext = true
      } else {
        setCriticalOperationsSyncIssue(
          phase: "bootstrap",
          message: "Assignment sync failed: \(error.localizedDescription)"
        )
      }
    }
  }

  private func canonicalLucasQueue(from queue: [WorkerQueueItem]) -> [WorkerQueueItem] {
    var seen = Set<String>()
    return queue
      .sorted { lhs, rhs in
        let leftOrder = lhs.sortOrder == 0 ? lucasCanonicalOrder(for: lhs.sopID) : lhs.sortOrder
        let rightOrder = rhs.sortOrder == 0 ? lucasCanonicalOrder(for: rhs.sopID) : rhs.sortOrder
        if leftOrder == rightOrder {
          return lhs.sopTitle < rhs.sopTitle
        }
        return leftOrder < rightOrder
      }
      .filter { item in
        let key = item.sopID.lowercased()
        guard !seen.contains(key) else { return false }
        seen.insert(key)
        return true
      }
  }

  private func hydrateQueueItem(
    _ queueItem: WorkerQueueItem,
    canonicalTemplates: [SOPTemplate]
  ) -> SOPTemplate {
    let canonical = canonicalTemplates.first { template in
      template.name.caseInsensitiveCompare(queueItem.sopTitle) == .orderedSame
    }

    let stepTemplates: [SOPStepTemplate]
    if queueItem.steps.isEmpty {
      stepTemplates = canonical?.steps ?? []
    } else {
      stepTemplates = queueItem.steps.enumerated().map { index, step in
        SOPStepTemplate(
          id: step.id,
          order: step.order == 0 ? index + 1 : step.order,
          title: step.title,
          description: step.description,
          duration: step.duration,
          validation: step.validation,
          critical: step.critical,
          aiPrompt: step.aiPrompt,
          expectedObjects: step.expectedObjects,
          preconditions: step.preconditions,
          postconditions: step.postconditions,
          skipRisk: step.skipRisk,
          evidenceRequired: step.evidenceRequired,
          allowManualComplete: step.allowManualComplete
        )
      }
    }

    let resolvedSortOrder = canonical?.sortOrder ?? (queueItem.sortOrder == 0 ? lucasCanonicalOrder(for: queueItem.sopID) : queueItem.sortOrder)
    let resolvedShiftName = queueItem.shiftName ?? canonical?.shiftName ?? "Morning"
    let resolvedPackageTitle = queueItem.packageTitle ?? canonical?.packageTitle
    let resolvedPackageVersion = queueItem.packageVersion ?? canonical?.packageVersion
    let resolvedSopVersion = queueItem.sopVersion ?? canonical?.sopVersion
    let resolvedSourceType =
      queueItem.packageID == nil && canonical?.packageID != nil
      ? canonical?.sourceType ?? queueItem.sourceType
      : queueItem.sourceType

    return SOPTemplate(
      id: UUID(uuidString: queueItem.sopID) ?? canonical?.id ?? UUID(),
      remoteID: queueItem.sopID,
      name: canonical?.name ?? queueItem.sopTitle,
      steps: stepTemplates,
      estimatedDuration: canonical?.estimatedDuration ?? max(Double(max(stepTemplates.count, 1)) * 18.0, 18.0),
      shiftID: validRemoteUUID(queueItem.shiftAssignmentID),
      shiftName: resolvedShiftName,
      packageID: queueItem.packageID ?? canonical?.packageID,
      packageRunID: queueItem.packageRunID ?? canonical?.packageRunID,
      packageTitle: resolvedPackageTitle,
      packageVersion: resolvedPackageVersion,
      sopVersion: resolvedSopVersion,
      sourceType: resolvedSourceType,
      sortOrder: resolvedSortOrder,
      required: queueItem.required
    )
  }

  private func deriveAssignedPackages(
    from queue: [WorkerQueueItem],
    canonicalTemplates: [SOPTemplate]
  ) -> [BackendAssignedPackage] {
    var resolved: [String: BackendAssignedPackage] = [:]

    for item in queue {
      guard let packageID = item.packageID else { continue }
      let matchingTemplate = canonicalTemplates.first { template in
        template.name.caseInsensitiveCompare(item.sopTitle) == .orderedSame
      }
      resolved[packageID] = BackendAssignedPackage(
        id: packageID,
        title: item.packageTitle ?? matchingTemplate?.packageTitle ?? "Assigned Package",
        description: nil,
        outcome: nil,
        version: item.packageVersion ?? matchingTemplate?.packageVersion,
        shiftName: item.shiftName ?? matchingTemplate?.shiftName ?? "Morning",
        active: item.active ?? true,
        packageRunID: item.packageRunID,
        packageRunStatus: nil,
        packageRunStartedAt: item.startsAt,
        packageRunCompletedAt: item.endsAt
      )
    }

    return resolved.values.sorted { lhs, rhs in
      let leftOrder = lucasCanonicalPackageOrder(for: lhs.title)
      let rightOrder = lucasCanonicalPackageOrder(for: rhs.title)
      if leftOrder == rightOrder {
        return lhs.title < rhs.title
      }
      return leftOrder < rightOrder
    }
  }

  private func lucasCanonicalOrder(for sopID: String) -> Int {
    switch sopID {
    case "22222222-2222-2222-2222-222222222222":
      return 1
    case "a1000001-0000-0000-0000-000000000001":
      return 2
    case "a1000002-0000-0000-0000-000000000002":
      return 3
    case "a1000003-0000-0000-0000-000000000003":
      return 4
    default:
      return 99
    }
  }

  private func lucasCanonicalPackageOrder(for packageTitle: String) -> Int {
    switch packageTitle {
    case "Inbound Cold Chain Audit":
      return 1
    case "QSR Value Meal Order":
      return 2
    default:
      return 99
    }
  }

  private func applyLucasDemoWorkerFallback(reason: String) {
    workerProfile = BackendWorker(
      id: "worker-lucas",
      loginCode: "EMBC-0001",
      displayName: "Lucas Pereira",
      role: "Kitchen Staff",
      status: "active"
    )

    let inboundPackage = BackendAssignedPackage(
      id: "33333333-3333-3333-3333-333333333333",
      title: "Inbound Cold Chain Audit",
      description: "Verify cold-chain compliance for inbound product before storing.",
      outcome: "Cold Chain Verified",
      version: 2,
      shiftName: "Morning",
      active: true,
      packageRunID: nil,
      packageRunStatus: nil,
      packageRunStartedAt: nil,
      packageRunCompletedAt: nil
    )

    let mealPackage = BackendAssignedPackage(
      id: "b2000001-0000-0000-0000-000000000001",
      title: "QSR Value Meal Order",
      description: "Standard meal execution from assembly to drink handoff.",
      outcome: "Order Fulfilled",
      version: 2,
      shiftName: "Morning",
      active: true,
      packageRunID: nil,
      packageRunStatus: nil,
      packageRunStartedAt: nil,
      packageRunCompletedAt: nil
    )

    let shiftPackage = BackendPackage(
      id: inboundPackage.id,
      title: inboundPackage.title,
      description: inboundPackage.description,
      outcome: inboundPackage.outcome,
      version: inboundPackage.version,
      status: "active"
    )

    activeShift = BackendShift(
      id: "shift-lucas-morning",
      packageID: inboundPackage.id,
      shiftName: "Morning",
      startsAt: nil,
      endsAt: nil,
      active: true,
      package: shiftPackage
    )

    assignedPackages = [inboundPackage, mealPackage]
    availableSOPs = lucasDemoQueueTemplates()
    selectedSOP = pendingTaskSOPs.first
    setCriticalOperationsSyncIssue(phase: "bootstrap", message: reason)
  }

  private func lucasDemoQueueTemplates() -> [SOPTemplate] {
    [
      SOPTemplate(
        remoteID: "22222222-2222-2222-2222-222222222222",
        name: "Cold Chain Verification SOP",
        steps: [
          SOPStepTemplate(
            id: "inspect_packaging_seal",
            order: 1,
            title: "Inspect packaging seal",
            description: "Check the inbound package seal before accepting the delivery.",
            duration: "30s",
            validation: "visual",
            critical: true,
            aiPrompt: "Look at the image and confirm whether the operator inspected the package seal before accepting the delivery.",
            expectedObjects: ["seal", "package"],
            allowManualComplete: true
          ),
          SOPStepTemplate(
            id: "record_temperature_log",
            order: 2,
            title: "Record temperature log",
            description: "Read the temperature and confirm it is entered into the log.",
            duration: "30s",
            validation: "visual",
            critical: false,
            aiPrompt: "Look at the image and confirm whether the operator recorded the product temperature in the log.",
            expectedObjects: ["thermometer", "clipboard"],
            allowManualComplete: true
          ),
          SOPStepTemplate(
            id: "verify_lot_number",
            order: 3,
            title: "Verify lot number",
            description: "Confirm the lot number is visible and matches the manifest.",
            duration: "30s",
            validation: "visual",
            critical: false,
            aiPrompt: "Look at the image and confirm whether the operator verified the lot number on the inbound package.",
            expectedObjects: ["label", "lot"],
            allowManualComplete: true
          ),
          SOPStepTemplate(
            id: "sign_off",
            order: 4,
            title: "Sign off",
            description: "Acknowledge the cold-chain verification and release storage.",
            duration: "30s",
            validation: "tap",
            critical: false,
            aiPrompt: "Look at the image and confirm whether the cold-chain verification was signed off.",
            expectedObjects: ["clipboard", "signature"],
            allowManualComplete: true
          ),
        ],
        estimatedDuration: 72,
        shiftID: nil,
        shiftName: "Morning",
        packageID: "33333333-3333-3333-3333-333333333333",
        packageTitle: "Inbound Cold Chain Audit",
        packageVersion: 2,
        sopVersion: 1,
        sourceType: "package",
        sortOrder: 1,
        required: true
      ),
      SOPTemplate(
        remoteID: "a1000001-0000-0000-0000-000000000001",
        name: "Burger Assembly",
        steps: [
          SOPStepTemplate(id: "toast_the_bun", order: 1, title: "Toast the bun", description: "Place bun halves on the grill until golden.", duration: "30s", validation: "visual", critical: false, aiPrompt: "Look at the image and confirm whether the bun has been toasted.", expectedObjects: ["bun"], allowManualComplete: true),
          SOPStepTemplate(id: "place_patty_on_grill", order: 2, title: "Place patty on grill", description: "Place the patty on the grill and season as needed.", duration: "30s", validation: "visual", critical: true, aiPrompt: "Look at the image and confirm whether the patty was placed on the grill.", expectedObjects: ["patty", "grill"], allowManualComplete: true),
          SOPStepTemplate(id: "add_cheese_slice", order: 3, title: "Add cheese slice", description: "Place cheese slice on the patty before removal.", duration: "30s", validation: "visual", critical: false, aiPrompt: "Look at the image and confirm whether a cheese slice was added to the patty.", expectedObjects: ["cheese", "patty"], allowManualComplete: true),
          SOPStepTemplate(id: "apply_condiments", order: 4, title: "Apply condiments", description: "Apply standard condiments to the bottom bun.", duration: "30s", validation: "visual", critical: false, aiPrompt: "Look at the image and confirm whether condiments were applied to the bun.", expectedObjects: ["bun", "condiments"], allowManualComplete: true),
          SOPStepTemplate(id: "stack_ingredients", order: 5, title: "Stack ingredients", description: "Assemble ingredients in the correct order.", duration: "30s", validation: "visual", critical: false, aiPrompt: "Look at the image and confirm whether the burger ingredients were stacked in the correct order.", expectedObjects: ["bun", "patty", "lettuce"], allowManualComplete: true),
          SOPStepTemplate(id: "quality_check", order: 6, title: "Quality check", description: "Confirm finished burger matches the reference build.", duration: "30s", validation: "visual", critical: true, aiPrompt: "Look at the image and confirm whether the finished burger matches the reference build.", expectedObjects: ["burger"], allowManualComplete: true),
        ],
        estimatedDuration: 108,
        shiftID: nil,
        shiftName: "Morning",
        packageID: "b2000001-0000-0000-0000-000000000001",
        packageTitle: "QSR Value Meal Order",
        packageVersion: 2,
        sopVersion: 2,
        sourceType: "package",
        sortOrder: 2,
        required: true
      ),
      SOPTemplate(
        remoteID: "a1000002-0000-0000-0000-000000000002",
        name: "Fries Assembly",
        steps: [
          SOPStepTemplate(id: "load_fry_basket", order: 1, title: "Load fry basket", description: "Fill the basket to the correct portion.", duration: "30s", validation: "visual", critical: false, aiPrompt: "Look at the image and confirm whether the fry basket was loaded to the correct portion.", expectedObjects: ["basket", "fries"], allowManualComplete: true),
          SOPStepTemplate(id: "cook_fries", order: 2, title: "Cook fries", description: "Start the fryer and monitor the timer.", duration: "30s", validation: "visual", critical: false, aiPrompt: "Look at the image and confirm whether the fries are cooking in the fryer.", expectedObjects: ["fryer", "basket"], allowManualComplete: true),
          SOPStepTemplate(id: "drain_and_salt", order: 3, title: "Drain and salt", description: "Drain basket and season fries.", duration: "30s", validation: "visual", critical: false, aiPrompt: "Look at the image and confirm whether the fries were drained and salted.", expectedObjects: ["fries", "salt"], allowManualComplete: true),
          SOPStepTemplate(id: "bag_fries", order: 4, title: "Bag fries", description: "Transfer fries into the correct serving container.", duration: "30s", validation: "visual", critical: false, aiPrompt: "Look at the image and confirm whether the fries were transferred into the serving container.", expectedObjects: ["fries", "container"], allowManualComplete: true),
        ],
        estimatedDuration: 72,
        shiftID: nil,
        shiftName: "Morning",
        packageID: "b2000001-0000-0000-0000-000000000001",
        packageTitle: "QSR Value Meal Order",
        packageVersion: 2,
        sopVersion: 2,
        sourceType: "package",
        sortOrder: 3,
        required: true
      ),
      SOPTemplate(
        remoteID: "a1000003-0000-0000-0000-000000000003",
        name: "Drink Prep",
        steps: [
          SOPStepTemplate(id: "select_cup_size", order: 1, title: "Select cup size", description: "Choose the cup size that matches the ticket.", duration: "30s", validation: "visual", critical: false, aiPrompt: "Look at the image and confirm whether the correct cup size was selected.", expectedObjects: ["cup"], allowManualComplete: true),
          SOPStepTemplate(id: "fill_beverage", order: 2, title: "Fill beverage", description: "Dispense the beverage to the marked fill line.", duration: "30s", validation: "visual", critical: false, aiPrompt: "Look at the image and confirm whether the beverage was filled to the marked line.", expectedObjects: ["cup", "drink"], allowManualComplete: true),
          SOPStepTemplate(id: "add_lid_and_straw", order: 3, title: "Add lid and straw", description: "Seal the cup and attach the straw.", duration: "30s", validation: "visual", critical: false, aiPrompt: "Look at the image and confirm whether the lid and straw were added to the drink.", expectedObjects: ["lid", "straw"], allowManualComplete: true),
          SOPStepTemplate(id: "stage_for_pickup", order: 4, title: "Stage for pickup", description: "Place the drink in the order hand-off zone.", duration: "30s", validation: "visual", critical: false, aiPrompt: "Look at the image and confirm whether the drink was staged for pickup.", expectedObjects: ["cup", "handoff"], allowManualComplete: true),
        ],
        estimatedDuration: 72,
        shiftID: nil,
        shiftName: "Morning",
        packageID: "b2000001-0000-0000-0000-000000000001",
        packageTitle: "QSR Value Meal Order",
        packageVersion: 2,
        sopVersion: 1,
        sourceType: "package",
        sortOrder: 4,
        required: true
      ),
    ]
  }

  func startSopAudit(for sop: SOPTemplate) async {
    guard !isSopAuditRunning else { return }

    let sessionId = await createOrFallbackSessionID(for: sop)
    await workerAdminSync?.stop()
    workerAdminSync = WorkerAdminLiveSessionCoordinator(
      api: opsAPIClient,
      telemetry: WorkerTelemetry.shared,
      onHeartbeatResponse: { [weak self] response in
        Task { @MainActor [weak self] in
          await self?.handleWorkerLiveHeartbeatResponse(response)
        }
      },
      onHeartbeatFailure: { [weak self] sessionID, message in
        Task { @MainActor [weak self] in
          await self?.handleWorkerLiveHeartbeatFailure(sessionID: sessionID, message: message)
        }
      }
    )
    geminiLiveSpotter.configure(api: opsAPIClient)
    currentSopSessionId = sessionId
    activeCaptureSOP = sop
    isSopAuditRunning = true
    sopAuditSecondsRemaining = sop.estimatedDuration
    sopAuditStatusMessage = ""
    aiGuideStatusMessage = ""
    isAiGuideStarting = false
    isStepValidationRunning = false
    proofImagesByTargetID = [:]
    lastLivePreviewSyncAt = .distantPast
    resetLiveRoomSyncSnapshot()
    lastGlassesAnalysisFrameQueuedAt = 0
    hasLoggedRoomCreatedForSession = false
    hasLoggedRoomJoinedForSession = false
    lastWorkerLiveHeartbeatFailureWarningAt = .distantPast
    if streamingMode == .iPhone {
      sopVideoRecorder = nil
      conversationAudioRecorder = ConversationAudioRecorder(sessionID: sessionId)
    } else {
      conversationAudioRecorder = nil
      sopVideoRecorder = SopVideoRecorder(sessionID: sessionId)
      if let fileURL = sopVideoRecorder?.outputURL {
        rememberPendingRecording(sessionID: sessionId, fileURL: fileURL)
      }
    }
    isDossierUploading = false
    dossierSpotterHitCount = 0
    updateDossierPipelineStatus("Recording execution...", kind: .info)
    lastSpotterInferenceTime = .distantPast
    isSpotterInferenceInFlight = false
    isFinalizingAndShipping = false
    lastProcessedTranscript = ""
    helpStatusMessage = ""
    hasActiveHelpEscalation = false
    shouldResumeAiSupportAfterBackOffice = false
    packageClosureStatusMessage = ""
    clearOperationsSyncState()

    if webrtcViewModel.isActive {
      webrtcViewModel.stopSession()
    }

    WorkerLiveLogger.log(
      "session_start",
      sessionID: sessionId,
      roomCode: nil,
      uploadState: "active"
    )
    await workerAdminSync?.start(
      sessionID: sessionId,
      currentStepIndex: nextIncompleteStepIndex(),
      helpRequested: false,
      roomCode: nil
    )

    if streamingMode == .iPhone {
      iPhoneCameraManager?.startRecording(sessionID: sessionId)
      rememberPendingRecording(sessionID: sessionId, fileURL: expectedIPhoneRecordingURL(for: sessionId))
    }

    if isSopAuditRunning && !geminiAssistant.isGeminiActive {
      await ensureAiGuideStarted(reason: "sop_started")
    }

    await ensureObservationLiveRoomSession()

    // No countdown/auto-timeout for long SOP runs.
    sopCountdownTask?.cancel()
    sopCountdownTask = nil
  }

  func startSopAudit() {
    let sop = selectedSOP ?? pendingTaskSOPs.first ?? availableSOPs.first ?? SOPTemplate(name: "Wallet & Thermos", items: ["Wallet", "Thermos"])
    selectedSOP = sop
    configureChecklist(for: sop)
    Task { await startSopAudit(for: sop) }
  }

  func toggleChecklistItem(itemID: UUID, viaVoice: Bool) {
    guard let index = checklistItems.firstIndex(where: { $0.id == itemID }) else { return }
    if !checklistItems[index].allowManualComplete && !checklistItems[index].isChecked && !viaVoice {
      sopAuditStatusMessage = "This step completes through visual AI only."
      return
    }

    checklistItems[index].isChecked.toggle()
    checklistItems[index].completionSource = checklistItems[index].isChecked
      ? (viaVoice ? .voice : .manual)
      : .pending

    let item = checklistItems[index]
    Task {
      await handleChecklistMutation(
        item: item,
        stepIndex: index,
        eventType: item.isChecked ? "step_complete" : "step_reopened"
      )
    }

    if checklistItems.allSatisfy({ $0.isChecked }) {
      Task { await endAndShip(status: .allItemsChecked) }
    }
  }

  func userTappedEndAndShip() {
    Task { await endAndShip(status: .userEnded) }
  }

  func requestSupervisorHelp() {
    Task { await requestSupervisorHelpFlow() }
  }

  func closeCurrentPackage() {
    Task { await closeCurrentPackageFlow() }
  }

  func closeSupervisorRoom() {
    webrtcViewModel.stopSession()
    helpStatusMessage = "Supervisor room closed."
    hasActiveHelpEscalation = false
    shouldResumeAiSupportAfterBackOffice = false
    resetLiveRoomSyncSnapshot()
    Task { @MainActor in
      await workerAdminSync?.updateHelpRequested(false)
      await patchActiveExecutionSession(
        ExecutionSessionPatch(
          helpRequested: false
        )
      )
      await ensureObservationLiveRoomSession()
      if isSopAuditRunning, !geminiAssistant.isGeminiActive {
        await ensureAiGuideStarted(reason: "support_closed")
      }
    }
  }

  func clearCaptureDismissFlag() {
    shouldDismissCapture = false
  }

  private func recordPackageProgressIfNeeded(for sop: SOPTemplate) {
    guard sop.sourceType == "package" else { return }
    guard let completionKey = sop.packageRunID ?? sop.packageID else { return }
    guard let remoteSOPID = sop.remoteID else { return }

    var completed = locallyCompletedSopsByPackageKey[completionKey] ?? []
    completed.insert(remoteSOPID)
    locallyCompletedSopsByPackageKey[completionKey] = completed
  }

  private func markPendingTaskComplete(_ sop: SOPTemplate) {
    locallyCompletedPendingTaskKeys.insert(pendingTaskKey(for: sop))
  }

  private func formatOperationsSyncMessage(phase: String, message: String) -> String {
    "[\(phase)] \(message)"
  }

  private func clearOperationsSyncState(clearWarning: Bool = true) {
    operationsSyncError = nil
    if clearWarning {
      operationsSyncWarning = nil
    }
  }

  private func setCriticalOperationsSyncIssue(phase: String, message: String) {
    operationsSyncError = formatOperationsSyncMessage(phase: phase, message: message)
  }

  private func setOperationsSyncWarning(phase: String, message: String) {
    operationsSyncWarning = formatOperationsSyncMessage(phase: phase, message: message)
  }

  private func resetDemoShiftForHomeIfNeeded(reloadAssignments: Bool) async {
    guard isDemoWorkerMode else { return }
    guard !isSopAuditRunning, activeCaptureSOP == nil else { return }

    locallyCompletedPendingTaskKeys = []
    selectedSOP = nil
    await syncGeminiSessionInstruction()
    shouldDismissCapture = false
    helpStatusMessage = ""
    packageClosureStatusMessage = ""

    if reloadAssignments, hasLoadedWorkerContext {
      await refreshWorkerContext()
    }
  }

  private func launchBackgroundMediaFinalization(
    sessionID: String,
    workerAdminSync: WorkerAdminLiveSessionCoordinator?,
    preparedUpload: WorkerPreparedMediaUpload?,
    wasIPhoneRecording: Bool,
    iPhoneCameraManager: IPhoneCameraManager?,
    conversationAudioRecorder: ConversationAudioRecorder?,
    sopVideoRecorder: SopVideoRecorder?
  ) {
    let pendingDefaultsKey = pendingRecordingDefaultsKey

    Task.detached(priority: .utility) {
      let backgroundTaskID = await SopMediaBackgroundTask.begin(name: "SOP media finalize")
      let recordedVideoURL = await SopSessionMediaFinalizer.finishRecording(
        wasIPhoneRecording: wasIPhoneRecording,
        iPhoneCameraManager: iPhoneCameraManager,
        conversationAudioRecorder: conversationAudioRecorder,
        sopVideoRecorder: sopVideoRecorder
      )

      let result: WorkerMediaUploadResult
      if let workerAdminSync, let preparedUpload {
        result = await workerAdminSync.uploadPreparedVideoRecording(
          from: recordedVideoURL,
          preparedUpload: preparedUpload
        )
      } else {
        result = WorkerMediaUploadResult(
          assetType: "video",
          assetID: preparedUpload?.result.assetID,
          bucket: preparedUpload?.result.bucket,
          path: preparedUpload?.result.path,
          byteSize: 0,
          uploadState: "failed",
          errorMessage: workerAdminSync == nil
            ? "Worker admin sync was unavailable during background media finalize."
            : "Recording upload target could not be prepared."
        )
      }

      if result.succeeded {
        PendingWorkerRecordingStore.clear(defaultsKey: pendingDefaultsKey)
        if let recordedVideoURL {
          try? FileManager.default.removeItem(at: recordedVideoURL)
        }
      } else if let recordedVideoURL {
        PendingWorkerRecordingStore.remember(
          defaultsKey: pendingDefaultsKey,
          sessionID: sessionID,
          fileURL: recordedVideoURL
        )
      }

      WorkerLiveLogger.log(
        "session_media_background_finalize_completed",
        sessionID: sessionID,
        assetID: result.assetID,
        assetType: result.assetType,
        bucket: result.bucket,
        path: result.path,
        byteSize: result.byteSize,
        uploadState: result.uploadState,
        error: result.errorMessage
      )

      await workerAdminSync?.flushTelemetryAndStop()
      await SopMediaBackgroundTask.end(backgroundTaskID)
    }
  }

  func endAndShip(status: SopTerminationStatus, cancelCountdownTask: Bool = true) async {
    guard !isFinalizingAndShipping, isSopAuditRunning, currentSopSessionId != nil else { return }
    isFinalizingAndShipping = true
    stopHoldToTalk()
    let sessionID = currentSopSessionId
    let syncedToBackend = activeExecutionSession != nil
    let completedSOP = selectedSOP
    let roomCodeAtEnd = webrtcViewModel.roomCode.isEmpty ? nil : webrtcViewModel.roomCode
    let workerAdminSyncAtEnd = workerAdminSync
    let wasIPhoneRecording = streamingMode == .iPhone
    let recordingSource = wasIPhoneRecording ? "phone-recording" : "stream-capture"
    let iPhoneCameraForFinalization = wasIPhoneRecording ? iPhoneCameraManager : nil
    let conversationAudioRecorderForFinalization = conversationAudioRecorder
    let sopVideoRecorderForFinalization = sopVideoRecorder
    let proofImages = proofImagesByTargetID
    let checklistPayload: [[String: Any]] = checklistItems.map {
      [
        "name": $0.name,
        "checked": $0.isChecked,
        "source": $0.completionSource.rawValue
      ]
    }
    let completedCount = checklistItems.filter(\.isChecked).count
    let finalStepIndex = nextIncompleteStepIndex()

    WorkerLiveLogger.log(
      "session_end_requested",
      sessionID: sessionID,
      roomCode: roomCodeAtEnd,
      uploadState: "active"
    )

    isSopAuditRunning = false
    isDossierUploading = true
    updateDossierPipelineStatus("Registering replay upload...", kind: .active)
    if cancelCountdownTask {
      sopCountdownTask?.cancel()
    }
    sopCountdownTask = nil

    if wasIPhoneRecording {
      resetIPhoneAnalysisLane()
      iPhoneCameraManager = nil
      iPhonePreviewSession = nil
      currentVideoFrame = nil
      hasReceivedFirstFrame = false
      streamingStatus = .stopped
      streamingMode = .glasses
      geminiAssistant.streamingMode = .glasses
    }
    sopVideoRecorder = nil
    conversationAudioRecorder = nil
    proofImagesByTargetID = [:]

    await workerAdminSyncAtEnd?.updateCurrentStepIndex(finalStepIndex)
    await workerAdminSyncAtEnd?.updateHelpRequested(false, sendImmediateHeartbeat: false)
    let preparedVideoUpload = await workerAdminSyncAtEnd?.prepareVideoRecordingUpload(source: recordingSource)

    let videoUploadResult: WorkerMediaUploadResult
    if let workerAdminSyncAtEnd {
      videoUploadResult = await workerAdminSyncAtEnd.completeSession(
        pendingVideoUpload: preparedVideoUpload
      ) { [weak self] in
        guard let self else { return }

        if activeExecutionSession != nil {
          await self.postExecutionEvent(
            type: "session_completed",
            payload: [
              "termination_status": status.rawValue,
              "completed_steps": completedCount,
              "total_steps": self.checklistItems.count,
              "checklist": checklistPayload
            ]
          )

          await self.patchActiveExecutionSession(
            ExecutionSessionPatch(
              status: status == .allItemsChecked ? "completed" : "ended",
              currentSopID: completedSOP?.remoteID,
              currentStepIndex: finalStepIndex,
              helpRequested: false,
              endedAt: ISO8601DateFormatter().string(from: Date())
            )
          )
        } else {
          self.updateDossierPipelineStatus("Execution ended locally. No backend session was active.", kind: .info)
        }
      }
    } else {
      videoUploadResult = WorkerMediaUploadResult(
        assetType: "video",
        assetID: nil,
        bucket: nil,
        path: nil,
        byteSize: 0,
        uploadState: "failed",
        errorMessage: "Worker admin sync was unavailable during teardown."
      )

      if activeExecutionSession != nil {
        await postExecutionEvent(
          type: "session_completed",
          payload: [
            "termination_status": status.rawValue,
            "completed_steps": completedCount,
            "total_steps": checklistItems.count,
            "checklist": checklistPayload
          ]
        )

        await patchActiveExecutionSession(
            ExecutionSessionPatch(
              status: status == .allItemsChecked ? "completed" : "ended",
              currentSopID: completedSOP?.remoteID,
              currentStepIndex: finalStepIndex,
              helpRequested: false,
              endedAt: ISO8601DateFormatter().string(from: Date())
            )
          )
        } else {
        updateDossierPipelineStatus("Execution ended locally. No backend session was active.", kind: .info)
      }
    }

    if geminiAssistant.isGeminiActive {
      await geminiAssistant.stopSession()
      try? await Task.sleep(nanoseconds: 150_000_000)
    }

    didAttemptPendingRecordingRecovery = false
    launchBackgroundMediaFinalization(
      sessionID: sessionID ?? UUID().uuidString,
      workerAdminSync: workerAdminSyncAtEnd,
      preparedUpload: preparedVideoUpload,
      wasIPhoneRecording: wasIPhoneRecording,
      iPhoneCameraManager: iPhoneCameraForFinalization,
      conversationAudioRecorder: conversationAudioRecorderForFinalization,
      sopVideoRecorder: sopVideoRecorderForFinalization
    )

    if let activeExecutionSession {
      if let remoteSOPID = completedSOP?.remoteID {
        await createExecutionMemoryLink(
          sessionID: activeExecutionSession.id,
          sopID: remoteSOPID,
          completedSteps: completedCount
        )
      }
      await uploadEvidenceMediaAssets(
        sessionID: activeExecutionSession.id,
        proofImages: proofImages
      )
    }

    if status == .allItemsChecked, let completedSOP {
      recordPackageProgressIfNeeded(for: completedSOP)
    }

    if let completedSOP {
      markPendingTaskComplete(completedSOP)
    }

    if videoUploadResult.uploadState == "failed" {
      let errorMessage = videoUploadResult.errorMessage ?? "Video finalize failed."
      let recordingLabel = wasIPhoneRecording ? "Phone recording" : "Session recording"
      setCriticalOperationsSyncIssue(
        phase: "media_reservation",
        message: "\(recordingLabel) upload could not be reserved: \(errorMessage)"
      )
      updateDossierPipelineStatus("\(recordingLabel) upload reservation failed.", kind: .error)
    } else {
      updateDossierPipelineStatus(
        wasIPhoneRecording ? "Phone recording upload pending." : "Session recording upload pending.",
        kind: .success
      )
    }

    isDossierUploading = false

    appendHistoryRecord(
      ShippedSessionRecord(
        timestamp: Date(),
        sopName: completedSOP?.name ?? "Unknown SOP",
        status: videoUploadResult.isPending
          ? "Upload pending"
          : videoUploadResult.succeeded ? "Replay ready" : "Finalize failed"
      )
    )

    if let sessionID {
      WorkerLiveLogger.log(
        "session_end_completed",
        sessionID: sessionID,
        roomCode: roomCodeAtEnd,
        assetID: videoUploadResult.assetID,
        assetType: videoUploadResult.assetType,
        bucket: videoUploadResult.bucket,
        path: videoUploadResult.path,
        byteSize: videoUploadResult.byteSize,
        uploadState: videoUploadResult.uploadState,
        error: videoUploadResult.errorMessage
      )
    }

    if webrtcViewModel.isActive {
      webrtcViewModel.stopSession()
    }
    workerAdminSync = nil

    hasActiveHelpEscalation = false
    shouldResumeAiSupportAfterBackOffice = false
    resetLiveRoomSyncSnapshot()
    activeExecutionSession = nil
    currentSopSessionId = nil
    activeCaptureSOP = nil
    selectedSOP = nil
    await syncGeminiSessionInstruction()
    sopAuditSecondsRemaining = 0.0
    if canCloseCurrentPackage {
      packageClosureStatusMessage = "All required SOPs are complete. Close the package from NOW."
    }
    sopAuditStatusMessage = videoUploadResult.uploadState != "failed"
      ? (syncedToBackend ? "Execution synced" : "Execution uploaded")
      : "Execution ended with media reservation issues"
    isSpotterInferenceInFlight = false
    shouldDismissCapture = true
    showShipSuccessToast = true
    if !wasIPhoneRecording {
      await startHomeCameraPreviewIfNeeded()
    }
    successToastTask?.cancel()
    successToastTask = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: 2_000_000_000)
      self?.showShipSuccessToast = false
    }
    isFinalizingAndShipping = false
  }

  // MARK: - iPhone Camera Mode

  private func startHomeCameraPreviewIfNeeded() async {
    guard !isSopAuditRunning, activeCaptureSOP == nil else { return }
    if isStreaming, streamingMode == preferredCaptureMode {
      return
    }

    if isStreaming {
      await stopCurrentCameraTransportOnly()
    }

    switch preferredCaptureMode {
    case .glasses where hasActiveDevice:
      await handleStartStreaming()
    default:
      let granted = await IPhoneCameraManager.requestPermission()
      if granted {
        preferredCaptureMode = .iPhone
        startIPhoneSession()
      } else if !showError {
        showError("Camera permission denied. Please grant access in Settings.")
      }
    }
  }

  func handleStartIPhone() async {
    let granted = await IPhoneCameraManager.requestPermission()
    if granted {
      startIPhoneSession()
    } else {
      showError("Camera permission denied. Please grant access in Settings.")
    }
  }

  private func startIPhoneSession() {
    streamingMode = .iPhone
    geminiAssistant.streamingMode = .iPhone
    currentVideoFrame = nil
    hasReceivedFirstFrame = false
    resetIPhoneAnalysisLane()
    let camera = IPhoneCameraManager()
    camera.analysisFrameInterval = webrtcViewModel.isUnderLiveVideoPressure ? 0.45 : 0.2
    let realtimeVideoForwarder = webrtcViewModel.realtimeVideoForwarder
    camera.onFirstPreviewFrame = { [weak self] in
      Task { @MainActor [weak self] in
        self?.hasReceivedFirstFrame = true
      }
    }
    camera.onSampleBufferCaptured = { sampleBuffer in
      guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
      realtimeVideoForwarder.enqueuePixelBuffer(
        pixelBuffer,
        timeStampNs: Self.rtcTimestampNs(from: sampleBuffer)
      )
    }
    camera.onFrameCaptured = { [weak self] image in
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.enqueueIPhoneAnalysisFrame(image, shouldRecordAudit: self.isSopAuditRunning)
      }
    }
    camera.start()
    iPhoneCameraManager = camera
    iPhonePreviewSession = camera.previewSession
    streamingStatus = .streaming
    NSLog("[Stream] iPhone camera mode started")
  }

  private func observeWebRTCSession() {
    roomCodeCancellable = webrtcViewModel.$roomCode
      .removeDuplicates()
      .sink { [weak self] roomCode in
        guard let self else { return }
        Task { @MainActor [weak self] in
          guard let self else { return }
          if !roomCode.isEmpty, !self.hasLoggedRoomCreatedForSession {
            self.hasLoggedRoomCreatedForSession = true
            WorkerLiveLogger.log(
              "room_created",
              sessionID: self.currentSopSessionId,
              roomCode: roomCode,
              uploadState: "active"
            )
          }
          await self.syncLiveRoomState(roomCode: roomCode)
        }
      }

    connectionStateCancellable = webrtcViewModel.$connectionState
      .removeDuplicates { lhs, rhs in
        String(describing: lhs) == String(describing: rhs)
      }
      .sink { [weak self] state in
        guard let self else { return }
        Task { @MainActor [weak self] in
          self?.updateHelpStatus(for: state)
        }
      }

    livePressureCancellable = webrtcViewModel.$isUnderLiveVideoPressure
      .removeDuplicates()
      .sink { [weak self] isUnderPressure in
        guard let self else { return }
        Task { @MainActor [weak self] in
          self?.iPhoneCameraManager?.analysisFrameInterval = isUnderPressure ? 0.45 : 0.2
        }
      }
  }

  private func stopIPhoneSession() {
    sopCountdownTask?.cancel()
    sopCountdownTask = nil
    isSopAuditRunning = false
    isSpotterInferenceInFlight = false
    stopHoldToTalk()
    resetIPhoneAnalysisLane()

    iPhoneCameraManager?.stop()
    iPhoneCameraManager = nil
    iPhonePreviewSession = nil
    currentVideoFrame = nil
    hasReceivedFirstFrame = false
    streamingStatus = .stopped
    streamingMode = .glasses
    geminiAssistant.streamingMode = .glasses
    NSLog("[Stream] iPhone camera mode stopped")
  }

  func dismissError() {
    showError = false
    errorMessage = ""
  }

  func capturePhoto() {
    streamSession.capturePhoto(format: .jpeg)
  }

  func dismissPhotoPreview() {
    showPhotoPreview = false
    capturedPhoto = nil
  }

  private func updateStatusFromState(_ state: StreamSessionState) {
    switch state {
    case .stopped:
      currentVideoFrame = nil
      streamingStatus = .stopped
    case .waitingForDevice, .starting, .stopping, .paused:
      streamingStatus = .waiting
    case .streaming:
      streamingStatus = .streaming
    }
  }

  private func updateGuidancePolicy(_ policy: GuidancePolicy, reason: String) {
    guidancePolicy = policy
    guidancePolicyReason = reason
  }

  private func formatStreamingError(_ error: StreamSessionError) -> String {
    switch error {
    case .internalError:
      return "An internal error occurred. Please try again."
    case .deviceNotFound:
      return "Device not found. Please ensure your device is connected."
    case .deviceNotConnected:
      return "Device not connected. Please check your connection and try again."
    case .timeout:
      return "The operation timed out. Please try again."
    case .videoStreamingError:
      return "Video streaming failed. Please try again."
    case .audioStreamingError:
      return "Audio streaming failed. Please try again."
    case .permissionDenied:
      return "Camera permission denied. Please grant permission in Settings."
    case .hingesClosed:
      return "The hinges on the glasses were closed. Please open the hinges and try again."
    @unknown default:
      return "An unknown streaming error occurred."
    }
  }

  private func configureChecklist(for sop: SOPTemplate) {
    checklistItems = sop.steps
      .sorted { $0.order < $1.order }
      .map { step in
      ChecklistItemState(
        itemID: step.id,
        name: step.title,
        description: step.description,
        duration: step.duration,
        validation: step.validation,
        critical: step.critical,
        aiPrompt: step.aiPrompt,
        expectedObjects: step.expectedObjects,
        preconditions: step.preconditions,
        postconditions: step.postconditions,
        skipRisk: step.skipRisk,
        evidenceRequired: step.evidenceRequired,
        allowManualComplete: step.allowManualComplete
      )
    }
    spotterEvidenceWindow.resetAll()
    currentStepBecameActiveAt = Date()
    updateGuidancePolicy(.nextInstruction, reason: "A new SOP assignment started.")

    Task { @MainActor [weak self] in
      await self?.syncGeminiSessionInstruction(for: sop)
    }
  }

  private func appendHistoryRecord(_ record: ShippedSessionRecord) {
    shippedHistory.insert(record, at: 0)
    if shippedHistory.count > 100 {
      shippedHistory = Array(shippedHistory.prefix(100))
    }
    saveHistoryToDefaults()
  }

  private func loadHistoryFromDefaults() {
    guard let data = UserDefaults.standard.data(forKey: historyDefaultsKey) else { return }
    guard let decoded = try? JSONDecoder().decode([ShippedSessionRecord].self, from: data) else { return }
    shippedHistory = decoded
  }

  private func saveHistoryToDefaults() {
    guard let encoded = try? JSONEncoder().encode(shippedHistory) else { return }
    UserDefaults.standard.set(encoded, forKey: historyDefaultsKey)
  }

  private func rememberPendingRecording(sessionID: String, fileURL: URL) {
    PendingWorkerRecordingStore.remember(
      defaultsKey: pendingRecordingDefaultsKey,
      sessionID: sessionID,
      fileURL: fileURL
    )
  }

  private func clearPendingRecording() {
    PendingWorkerRecordingStore.clear(defaultsKey: pendingRecordingDefaultsKey)
  }

  private func loadPendingRecording() -> PendingWorkerRecording? {
    guard let data = UserDefaults.standard.data(forKey: pendingRecordingDefaultsKey) else { return nil }
    return try? JSONDecoder().decode(PendingWorkerRecording.self, from: data)
  }

  private func expectedIPhoneRecordingURL(for sessionID: String) -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("sop_\(sessionID)")
      .appendingPathExtension("mp4")
  }

  private func recoverPendingWorkerRecordingIfNeeded() async {
    guard !didAttemptPendingRecordingRecovery else { return }
    guard let pendingRecording = loadPendingRecording() else {
      didAttemptPendingRecordingRecovery = true
      return
    }

    didAttemptPendingRecordingRecovery = true
    let pendingURL = URL(fileURLWithPath: pendingRecording.filePath)
    let recoveryURL = FileManager.default.fileExists(atPath: pendingURL.path) ? pendingURL : nil
    let recoverySync = WorkerAdminLiveSessionCoordinator(
      api: opsAPIClient,
      sessionID: pendingRecording.sessionID,
      heartbeatIntervalNanoseconds: 0,
      telemetry: WorkerTelemetry.shared
    )

    let result = await recoverySync.uploadVideoRecording(
      from: recoveryURL,
      source: "phone-recording"
    )
    if result.succeeded {
      clearPendingRecording()
      if let recoveryURL {
        try? FileManager.default.removeItem(at: recoveryURL)
      }
    } else {
      setCriticalOperationsSyncIssue(
        phase: "media_finalize",
        message: "Recovered recording finalize failed: \(result.errorMessage ?? "Unknown error")"
      )
    }

    do {
      _ = try await opsAPIClient.updateExecutionSession(
        id: pendingRecording.sessionID,
        patch: ExecutionSessionPatch(
          status: "ended",
          helpRequested: false,
          endedAt: ISO8601DateFormatter().string(from: Date())
        )
      )
    } catch {
      if result.succeeded {
        setCriticalOperationsSyncIssue(
          phase: "session_patch",
          message: "Recovered video uploaded, but session end sync failed: \(error.localizedDescription)"
        )
      }
    }
  }

  private func requestSpeechPermissionsIfNeeded() {
    SFSpeechRecognizer.requestAuthorization { status in
      if status != .authorized {
        NSLog("[Speech] Speech recognition authorization denied: %@", String(describing: status))
      }
    }

    AVAudioApplication.requestRecordPermission { granted in
      if !granted {
        NSLog("[Speech] Microphone permission denied")
      }
    }
  }

  func startHoldToTalk() {
    guard !isListeningForVoice else { return }
    guard !geminiAssistant.isGeminiActive else {
      sopAuditStatusMessage = "AI guide is already listening through the active audio route."
      aiGuideStatusMessage = sopAuditStatusMessage
      return
    }
    guard let speechRecognizer, speechRecognizer.isAvailable else {
      sopAuditStatusMessage = "Speech recognizer unavailable"
      return
    }

    do {
      if let routeWarning = try configureWorkerAudioRoute(for: preferredCaptureMode, reason: .holdToTalk) {
        helpStatusMessage = routeWarning
      }
    } catch {
      sopAuditStatusMessage = "Audio session error: \(error.localizedDescription)"
      return
    }

    speechTask?.cancel()
    speechTask = nil

    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true
    speechRequest = request

    let inputNode = audioEngine.inputNode
    let recordingFormat = inputNode.outputFormat(forBus: 0)
    inputNode.removeTap(onBus: 0)
    inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
      request.append(buffer)
    }

    audioEngine.prepare()
    do {
      try audioEngine.start()
    } catch {
      sopAuditStatusMessage = "Mic start failed: \(error.localizedDescription)"
      stopHoldToTalk()
      return
    }

    isListeningForVoice = true

    speechTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
      guard let self else { return }

      if let result {
        let transcript = result.bestTranscription.formattedString.lowercased()
        self.handleVoiceTranscript(transcript)
      }

      if error != nil {
        self.stopHoldToTalk()
      }
    }
  }

  func stopHoldToTalk() {
    guard isListeningForVoice || audioEngine.isRunning else { return }

    if audioEngine.isRunning {
      audioEngine.stop()
      audioEngine.inputNode.removeTap(onBus: 0)
    }

    speechRequest?.endAudio()
    speechRequest = nil
    speechTask?.cancel()
    speechTask = nil
    isListeningForVoice = false
    let lease = holdToTalkAudioLease
    holdToTalkAudioLease = nil
    Task {
      if let lease {
        await WorkerAudioRouteCoordinator.shared.release(lease: lease)
      }
    }

    if webrtcViewModel.isActive && webrtcViewModel.isSupportMode {
      do {
        if let routeWarning = try configureWorkerAudioRoute(for: preferredCaptureMode, reason: .viewer) {
          helpStatusMessage = routeWarning
        }
      } catch {
        NSLog("[Speech] Failed to restore talkback audio route: %@", error.localizedDescription)
      }
    }
  }

  private func handleVoiceTranscript(_ transcript: String) {
    let normalized = transcript
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    guard !normalized.isEmpty, normalized != lastProcessedTranscript else { return }
    lastProcessedTranscript = normalized

    if isBackOfficeCallIntent(normalized) {
      recordAiCommandDetected("call_back_office", transcript: normalized)
      requestSupervisorHelp()
      return
    }

    if isStopAiGuideIntent(normalized) {
      if geminiAssistant.isGeminiActive {
        Task { @MainActor [weak self] in
          await self?.geminiAssistant.stopSession()
        }
      }
      aiGuideStatusMessage = "AI guide paused."
      sopAuditStatusMessage = aiGuideStatusMessage
      recordAiCommandDetected("pause_ai", transcript: normalized)
      return
    }

    if isVoiceStepAdvanceIntent(normalized) {
      guard shouldProcessAiCommand("advance_step", transcript: normalized) else { return }
      recordAiCommandDetected("advance_step", transcript: normalized)
      completeActiveStepByVoice(transcript: normalized)
      return
    }

    if isGuidedStepCheckIntent(normalized) {
      guard shouldProcessAiCommand("check_step", transcript: normalized) else { return }
      recordAiCommandDetected("check_step", transcript: normalized)
      requestGuidedStepValidation(trigger: "voice_check")
      return
    }

    guard let checkRange = normalized.range(of: "check ") else { return }
    let spokenItem = normalized[checkRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
    guard !spokenItem.isEmpty else { return }

    if let active = activeSpotterRequestItems().first,
      active.name.lowercased().contains(spokenItem) || spokenItem.contains(active.name.lowercased()) {
      guard shouldProcessAiCommand("check_named_step", transcript: normalized) else { return }
      recordAiCommandDetected("check_named_step", transcript: normalized)
      requestGuidedStepValidation(trigger: "voice_check")
    }
  }

  private func isStopAiGuideIntent(_ transcript: String) -> Bool {
    transcript.contains("stop ai") ||
      transcript.contains("pause ai") ||
      transcript.contains("stop guide") ||
      transcript.contains("pause guide")
  }

  private func isVoiceStepAdvanceIntent(_ transcript: String) -> Bool {
    transcript.contains("i'm done") ||
      transcript.contains("im done") ||
      transcript.contains("done with this") ||
      transcript.contains("done with the step") ||
      transcript.contains("next step") ||
      transcript.contains("ready for next") ||
      transcript.contains("move on")
  }

  private func isGuidedStepCheckIntent(_ transcript: String) -> Bool {
    transcript.contains("check this step") ||
      transcript.contains("check step") ||
      transcript.contains("check again") ||
      transcript.contains("validate this") ||
      transcript.contains("validate step") ||
      transcript.contains("what is missing") ||
      transcript.contains("what am i missing") ||
      transcript.contains("what's missing") ||
      transcript.contains("did i do it right")
  }

  private func shouldProcessAiCommand(_ commandKey: String, transcript: String) -> Bool {
    let now = Date()
    if commandKey == lastAiCommandKey,
       now.timeIntervalSince(lastAiCommandAt) < 3.0 {
      return false
    }
    lastAiCommandKey = commandKey
    lastAiCommandAt = now
    return true
  }

  private func recordAiCommandDetected(_ commandKey: String, transcript: String) {
    Task { [weak self] in
      guard let self else { return }
      await WorkerTelemetry.shared.record(
        "ai_command_detected",
        source: "gemini_live",
        stage: commandKey,
        sessionID: self.currentSopSessionId,
        payload: [
          "command": commandKey,
          "transcript": transcript
        ]
      )
      await self.postExecutionEvent(
        type: "ai_command_detected",
        payload: [
          "command": commandKey,
          "transcript": transcript
        ]
      )
    }
  }

  private func isBackOfficeCallIntent(_ transcript: String) -> Bool {
    let normalized = transcript.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard normalized.contains("back office") || normalized.contains("supervisor") || normalized.contains("support") else {
      return false
    }
    return normalized.contains("call") ||
      normalized.contains("dial") ||
      normalized.contains("ring") ||
      normalized.contains("request help") ||
      normalized.contains("need help")
  }

  private func markFirstUncheckedAsVoice() {
    guard let firstUnchecked = checklistItems.first(where: { !$0.isChecked }) else { return }
    setChecklistItemChecked(itemID: firstUnchecked.id, source: .voice)
  }

  private func completeActiveStepByVoice(transcript: String) {
    guard let firstUnchecked = checklistItems.first(where: { !$0.isChecked }) else {
      sopAuditStatusMessage = "All checklist steps are complete."
      aiGuideStatusMessage = sopAuditStatusMessage
      return
    }
    setChecklistItemChecked(itemID: firstUnchecked.id, source: .voice, voiceTranscript: transcript)
    sopAuditStatusMessage = "Step confirmed by voice. Moving to the next step."
    aiGuideStatusMessage = sopAuditStatusMessage
  }

  private func setChecklistItemChecked(
    itemID: UUID,
    source: ChecklistCompletionSource,
    voiceTranscript: String? = nil
  ) {
    guard let index = checklistItems.firstIndex(where: { $0.id == itemID }) else { return }
    guard !checklistItems[index].isChecked else { return }
    checklistItems[index].isChecked = true
    checklistItems[index].completionSource = source

    let item = checklistItems[index]
    spotterEvidenceWindow.reset(stepID: item.itemID)
    currentStepBecameActiveAt = Date()
    updateGuidancePolicy(.nextInstruction, reason: "Step completed by \(source.rawValue).")
    Task {
      await handleChecklistMutation(
        item: item,
        stepIndex: index,
        eventType: "step_complete"
      )
      if source == .voice {
        let nextIndex = nextIncompleteStepIndex()
        await WorkerTelemetry.shared.record(
          "voice_step_advanced",
          source: "gemini_live",
          stage: "advanced",
          sessionID: currentSopSessionId,
          payload: [
            "step_index": index,
            "step_id": item.itemID,
            "step_name": item.name,
            "next_step_index": nextIndex,
            "transcript": voiceTranscript ?? NSNull()
          ]
        )
        await postExecutionEvent(
          type: "voice_step_advanced",
          payload: [
            "step_index": index,
            "step_id": item.itemID,
            "step_name": item.name,
            "next_step_index": nextIndex,
            "transcript": voiceTranscript ?? NSNull()
          ]
        )
      }
    }

    if checklistItems.allSatisfy({ $0.isChecked }) {
      Task { await endAndShip(status: .allItemsChecked) }
    }
  }

  private func setChecklistItemCheckedBySpotterID(_ itemID: String) {
    setChecklistItemCheckedBySpotterID(itemID, evidence: nil)
  }

  private func setChecklistItemCheckedBySpotterID(_ itemID: String, evidence: [String: Any]?) {
    guard let index = checklistItems.firstIndex(where: { $0.itemID == itemID }) else { return }
    guard !checklistItems[index].isChecked else { return }

    checklistItems[index].isChecked = true
    checklistItems[index].completionSource = .vision
    dossierSpotterHitCount += 1
    spotterEvidenceWindow.reset(stepID: itemID)
    currentStepBecameActiveAt = Date()
    updateGuidancePolicy(.nextInstruction, reason: "Step completed after stable visual evidence.")
    updateDossierPipelineStatus("Live spotter hit #\(dossierSpotterHitCount)", kind: .active)

    let item = checklistItems[index]
    Task {
      await handleChecklistMutation(
        item: item,
        stepIndex: index,
        eventType: "step_complete",
        evidence: evidence
      )
    }

    if checklistItems.allSatisfy({ $0.isChecked }) {
      Task { await endAndShip(status: .allItemsChecked) }
    }
  }

  private func reconcileChecklistAfterServerAdvance(
    match: GeminiLiveSpotter.SpotterMatch,
    evidence: [String: Any]
  ) {
    guard let serverStepIndex = match.advancedToStepIndex else { return }

    let completedCount = match.completedSop
      ? checklistItems.count
      : min(max(serverStepIndex, 0), checklistItems.count)
    guard completedCount > 0 || match.completedSop else { return }
    let matchedWasAlreadyChecked =
      checklistItems.first(where: { $0.itemID == match.id })?.isChecked == true

    for index in checklistItems.indices {
      guard index < completedCount else { continue }
      if !checklistItems[index].isChecked {
        checklistItems[index].isChecked = true
        checklistItems[index].completionSource = .vision
      }
      spotterEvidenceWindow.reset(stepID: checklistItems[index].itemID)
    }

    if !matchedWasAlreadyChecked {
      dossierSpotterHitCount += 1
    }

    updateGuidancePolicy(.nextInstruction, reason: "Step advanced by server-confirmed visual evidence.")
    updateDossierPipelineStatus("Live spotter server advance", kind: .active)
    currentStepBecameActiveAt = Date()

    let nextIndex = nextIncompleteStepIndex()
    Task {
      await workerAdminSync?.updateCurrentStepIndex(nextIndex, sendImmediateHeartbeat: true)
      await postExecutionEvent(
        type: "phone_step_reconciled",
        payload: [
          "step_id": match.id,
          "server_step_index": serverStepIndex,
          "local_next_step_index": nextIndex,
          "completed_sop": match.completedSop,
          "evidence": evidence
        ]
      )
      await syncGeminiSessionInstruction()
    }

    if checklistItems.allSatisfy({ $0.isChecked }) || match.completedSop {
      Task { await endAndShip(status: .allItemsChecked) }
    }
  }

  private func captureProofImageIfNeeded(for itemID: String, from image: UIImage) {
    guard proofImagesByTargetID[itemID] == nil else { return }
    guard let jpegData = image.jpegData(compressionQuality: 0.9) else { return }
    proofImagesByTargetID[itemID] = jpegData
  }

  private func buildDossierMetadataJSONString() -> String {
    let checkedCount = checklistItems.filter { $0.isChecked }.count
    let complianceLevel: String
    if !checklistItems.isEmpty, checkedCount == checklistItems.count {
      complianceLevel = "FULLY"
    } else if checkedCount == 0 {
      complianceLevel = "NON"
    } else {
      complianceLevel = "PARTIALLY"
    }

    let foundItems: [[String: Any]] = checklistItems.map { item in
      let notes: String
      if item.isChecked {
        switch item.completionSource {
        case .vision:
          notes = "Spotted live by edge AI"
        case .voice:
          notes = "Confirmed by voice"
        case .manual:
          notes = "Checked by operator"
        case .pending:
          notes = "Found"
        }
      } else {
        notes = "Not found"
      }

      return [
        "target": item.itemID,
        "found": item.isChecked,
        "notes": notes
      ]
    }

    let checklist: [[String: Any]] = checklistItems.map { item in
      [
        "name": item.name,
        "checked": item.isChecked
      ]
    }

    let metadata: [String: Any] = [
      "compliance_level": complianceLevel,
      "found_items": foundItems,
      "checklist": checklist
    ]

    guard let data = try? JSONSerialization.data(withJSONObject: metadata, options: []),
          let json = String(data: data, encoding: .utf8) else {
      return "{}"
    }

    return json
  }

  func requestGuidedStepValidation(trigger: String = "tap") {
    guard isSopAuditRunning else { return }
    guard !isSpotterInferenceInFlight, !isStepValidationRunning else { return }
    guard let image = currentVideoFrame else {
      sopAuditStatusMessage = "Keep the current step visible so AI can check it."
      aiGuideStatusMessage = sopAuditStatusMessage
      return
    }
    let pendingItems = activeSpotterRequestItems()

    guard !pendingItems.isEmpty else {
      sopAuditStatusMessage = "All checklist steps are complete."
      aiGuideStatusMessage = sopAuditStatusMessage
      return
    }

    lastSpotterInferenceTime = Date()
    isSpotterInferenceInFlight = true
    isStepValidationRunning = true
    sopAuditStatusMessage = "Checking the current step..."
    aiGuideStatusMessage = sopAuditStatusMessage
    updateDossierPipelineStatus("On-demand AI check running", kind: .active)

    Task { [weak self] in
      guard let self else { return }
      let matches: [GeminiLiveSpotter.SpotterMatch]
      var spotterErrorMessage: String?
      var spotterConflict = false
      let requestStartedAt = CACurrentMediaTime()
      do {
        matches = try await self.geminiLiveSpotter.detectVisibleItemMatches(
          image: image,
          items: pendingItems,
          sessionID: self.currentSopSessionId,
          elapsedActiveMs: self.elapsedActiveMsForCurrentStep()
        )
      } catch {
        matches = []
        spotterErrorMessage = error.localizedDescription
        spotterConflict = self.isStaleSpotterConflict(error)
        await WorkerTelemetry.shared.record(
          spotterConflict ? "gemini_spotter_conflict" : "gemini_spotter_failed",
          source: "gemini_spotter",
          stage: spotterConflict ? "conflict" : "failed",
          sessionID: self.currentSopSessionId,
          payload: [
            "error": error.localizedDescription,
            "target_count": pendingItems.count
          ]
        )
      }
      let durationMs = (CACurrentMediaTime() - requestStartedAt) * 1000
      NSLog(
        "[Spotter] Guided step check trigger=%@ targets=%@ matched=%@ autoComplete=%@ duration=%.1fms",
        trigger,
        pendingItems.map(\.id).joined(separator: ","),
        matches.filter(\.matched).map(\.id).joined(separator: ","),
        matches.filter(\.autoComplete).map(\.id).joined(separator: ","),
        durationMs
      )
      if let firstMatch = matches.first {
        await WorkerTelemetry.shared.record(
          "gemini_spotter_result",
          source: "gemini_spotter",
          stage: firstMatch.autoComplete ? "auto_complete" : firstMatch.matched ? "matched" : "not_matched",
          sessionID: self.currentSopSessionId,
          durationMs: durationMs,
          metricValue: firstMatch.confidence,
          metricUnit: "confidence",
          payload: [
            "step_id": firstMatch.id,
            "trigger": trigger,
            "on_demand": true,
            "matched": firstMatch.matched,
            "auto_complete": firstMatch.autoComplete,
            "threshold": firstMatch.threshold,
            "reason": firstMatch.reason
          ]
        )
      }

      await MainActor.run {
        if let spotterErrorMessage {
          if spotterConflict {
            self.sopAuditStatusMessage = "Checklist moved on in the backend. Refreshing the active step..."
            self.aiGuideStatusMessage = self.sopAuditStatusMessage
            self.updateGuidancePolicy(.helpPrompt, reason: self.sopAuditStatusMessage)
            self.updateDossierPipelineStatus("AI check refreshed active step", kind: .info)
            Task { await self.recoverFromStaleSpotterConflict(message: spotterErrorMessage) }
            self.isStepValidationRunning = false
            self.isSpotterInferenceInFlight = false
            return
          }
          self.sopAuditStatusMessage = "AI check could not confirm the active step: \(spotterErrorMessage)"
          self.aiGuideStatusMessage = self.sopAuditStatusMessage
          self.updateGuidancePolicy(.helpPrompt, reason: self.sopAuditStatusMessage)
          self.updateDossierPipelineStatus("AI check conflict", kind: .info)
          Task { await self.syncGeminiSessionInstruction() }
          self.isStepValidationRunning = false
          self.isSpotterInferenceInFlight = false
          return
        }

        if let match = matches.first {
          if match.autoComplete, match.advancedToStepIndex != nil {
            self.captureProofImageIfNeeded(for: match.id, from: image)
            self.reconcileChecklistAfterServerAdvance(match: match, evidence: [
              "guided_trigger": trigger,
              "on_demand": true,
              "ai_confidence": match.confidence,
              "ai_reason": match.reason,
              "evidence_timestamp": match.evidenceTimestamp,
              "auto_complete": match.autoComplete,
              "advanced_to_step_index": match.advancedToStepIndex ?? NSNull(),
              "completed_sop": match.completedSop,
              "threshold": match.threshold
            ])
            self.sopAuditStatusMessage = "Step checked. Moving to the next step."
            self.aiGuideStatusMessage = self.sopAuditStatusMessage
          } else {
            let reason = match.reason.trimmingCharacters(in: .whitespacesAndNewlines)
            let message = reason.isEmpty
              ? (match.autoComplete
                ? "The server has not advanced this step yet. Try again in a moment."
                : "I still need clearer evidence before moving to the next step.")
              : reason
            self.sopAuditStatusMessage = "Step needs more evidence: \(message)"
            self.aiGuideStatusMessage = self.sopAuditStatusMessage
            self.updateGuidancePolicy(.helpPrompt, reason: self.sopAuditStatusMessage)
            self.updateDossierPipelineStatus("AI check incomplete", kind: .info)
          }
        } else {
          self.sopAuditStatusMessage = "AI check could not read the current step. Keep the work area visible and try again."
          self.aiGuideStatusMessage = self.sopAuditStatusMessage
          self.updateGuidancePolicy(.helpPrompt, reason: self.sopAuditStatusMessage)
          self.updateDossierPipelineStatus("AI check unavailable", kind: .info)
        }
        self.isStepValidationRunning = false
        self.isSpotterInferenceInFlight = false
      }
    }
  }

  private func elapsedActiveMsForCurrentStep() -> Int? {
    max(0, Int(Date().timeIntervalSince(currentStepBecameActiveAt) * 1000))
  }

  private func isStaleSpotterConflict(_ error: Error) -> Bool {
    if case AdminIngestError.server(let statusCode, _, _) = error {
      return statusCode == 409
    }
    return error.localizedDescription.contains("HTTP 409")
  }

  private func recoverFromStaleSpotterConflict(message: String) async {
    await postExecutionEvent(
      type: "phone_step_validation_conflict",
      payload: [
        "message": message,
        "local_next_step_index": nextIncompleteStepIndex()
      ]
    )
    await syncGeminiSessionInstruction()
  }

  private func startPreferredCamera() async {
    reconcileCaptureModeWithDeviceAvailability(allowTransportSwitch: false)
    switch preferredCaptureMode {
    case .iPhone:
      await handleStartIPhone()
    case .glasses:
      guard hasActiveDevice else {
        showError("Meta camera unavailable. Connect glasses or switch to iPhone.")
        return
      }
      await handleStartStreaming()
    }
  }

  private func reconcileCaptureModeWithDeviceAvailability(allowTransportSwitch: Bool) {
    if !hasActiveDevice, preferredCaptureMode == .glasses {
      preferredCaptureMode = .iPhone
      sopAuditStatusMessage = "Meta camera disconnected."
    } else if hasActiveDevice {
      sopAuditStatusMessage = "Meta camera ready. Use the camera selector when you want glasses."
    }

    guard allowTransportSwitch, isStreaming, !isSopAuditRunning else { return }
    Task { @MainActor [weak self] in
      await self?.switchToPreferredCaptureModeIfNeeded()
    }
  }

  private func captureModeEventValue(_ mode: StreamingMode) -> String {
    switch mode {
    case .glasses: return "glasses"
    case .iPhone: return "iphone"
    }
  }

  private func stopCurrentCameraTransportOnly() async {
    switch streamingMode {
    case .iPhone:
      iPhoneCameraManager?.stop()
      iPhoneCameraManager = nil
      currentVideoFrame = nil
      hasReceivedFirstFrame = false
      streamingStatus = .stopped
      // Default to glasses mode when stopped; next start sets active mode explicitly.
      streamingMode = .glasses
    case .glasses:
      await streamSession.stop()
      currentVideoFrame = nil
      hasReceivedFirstFrame = false
      streamingStatus = .stopped
    }
  }

  private enum WorkerAudioRouteReason {
    case viewer
    case holdToTalk
  }

  private func describeAudioPorts(_ ports: [AVAudioSessionPortDescription]) -> String {
    if ports.isEmpty {
      return "none"
    }

    return ports
      .map { "\($0.portType.rawValue):\($0.portName)" }
      .joined(separator: ",")
  }

  private func logWorkerAudioRoute(
    session: AVAudioSession,
    mode: StreamingMode,
    reason: WorkerAudioRouteReason,
    note: String? = nil
  ) {
    let modeLabel = mode == .iPhone ? "iphone" : "glasses"
    let reasonLabel = reason == .viewer ? "viewer" : "hold_to_talk"
    NSLog(
      "[WorkerAudio] reason=%@ mode=%@ muted=%@ inputs=%@ outputs=%@ note=%@",
      reasonLabel,
      modeLabel,
      webrtcViewModel.isMuted ? "true" : "false",
      describeAudioPorts(session.currentRoute.inputs),
      describeAudioPorts(session.currentRoute.outputs),
      note ?? "none"
    )
  }

  private func hasBluetoothTalkbackRoute(_ route: AVAudioSessionRouteDescription) -> Bool {
    route.inputs.contains {
      $0.portType == .bluetoothHFP ||
        $0.portType == .bluetoothLE
    } ||
    route.outputs.contains {
      $0.portType == .bluetoothHFP
        || $0.portType == .bluetoothLE
    }
  }

  private func preferredBluetoothHFPInput(_ session: AVAudioSession) -> AVAudioSessionPortDescription? {
    session.availableInputs?.first {
      $0.portType == .bluetoothHFP || $0.portType == .bluetoothLE
    }
  }

  @discardableResult
  private func configureWorkerAudioRoute(
    for mode: StreamingMode,
    reason: WorkerAudioRouteReason
  ) throws -> String? {
    if reason == .viewer, webrtcViewModel.isActive, webrtcViewModel.isSupportMode {
      return webrtcViewModel.refreshSupportAudioRoute(captureMode: mode)
    }

    let owner: WorkerAudioRouteOwner =
      reason == .holdToTalk
        ? .holdToTalk
        : .viewer
    let snapshot = try WorkerAudioRouteCoordinator.shared.acquire(
      owner: owner,
      mode: mode,
      reason: reason == .holdToTalk ? "hold_to_talk" : "live_support",
      forceSpeaker: SettingsManager.shared.speakerOutputEnabled,
      preferredIOBufferDuration: 0.02
    )
    switch owner {
    case .holdToTalk:
      holdToTalkAudioLease = snapshot.lease
    case .viewer:
      viewerAudioRouteLease = snapshot.lease
    case .aiGuide, .backOfficeWebRTC:
      break
    }
    return snapshot.fallbackMessage
  }

  private func liveRoomStatusMessage(localOnly: Bool, helpRequested: Bool, roomCode: String? = nil) -> String {
    if localOnly {
      return helpRequested
        ? "Live room is local-only. Admin can't join until the backend session sync succeeds."
        : "Local live room active. Admin visibility will start once the backend session sync succeeds."
    }

    if let roomCode, !roomCode.isEmpty {
      return helpRequested
        ? "Supervisor request sent. Room \(roomCode) is ready for manager join."
        : "Admin video observation active: \(roomCode)"
    }

    return helpRequested
      ? "Supervisor request sent. Waiting for the live room to finish syncing."
      : "Opening live execution room..."
  }

  private func waitForRoomCode(timeoutNanoseconds: UInt64 = 5_000_000_000) async -> String? {
    if !webrtcViewModel.roomCode.isEmpty {
      return webrtcViewModel.roomCode
    }

    let step: UInt64 = 150_000_000
    var waited: UInt64 = 0
    while waited < timeoutNanoseconds {
      try? await Task.sleep(nanoseconds: step)
      waited += step
      if !webrtcViewModel.roomCode.isEmpty {
        return webrtcViewModel.roomCode
      }
    }
    return nil
  }

  private func createOrFallbackSessionID(for sop: SOPTemplate) async -> String {
    if let activeExecutionSession {
      currentSopSessionId = activeExecutionSession.id
      isUsingLocalSessionFallback = false
      return activeExecutionSession.id
    }

    guard let workerID = workerProfile?.id else {
      isUsingLocalSessionFallback = true
      let fallback = UUID().uuidString
      setCriticalOperationsSyncIssue(
        phase: "session_create",
        message: "Worker context unavailable. Recording locally until ops-api is reachable."
      )
      return fallback
    }

    do {
      let shiftID = validRemoteUUID(sop.shiftID) ?? validRemoteUUID(activeShift?.id)
      let packageID = validRemoteUUID(sop.packageID) ?? validRemoteUUID(activeShift?.packageID) ?? validRemoteUUID(activeShift?.package?.id)
      let packageRunID = validRemoteUUID(sop.packageRunID) ?? validRemoteUUID(activePackageRunID)
      let currentSopID = validRemoteUUID(sop.remoteID)
      let createdSession = try await opsAPIClient.createExecutionSession(
        workerID: workerID,
        deviceID: registeredDevice?.id,
        shiftID: shiftID,
        packageID: packageID,
        packageRunID: packageRunID,
        currentSopID: currentSopID,
        sopVersion: sop.sopVersion,
        packageVersion: sop.packageVersion
      )
      activeExecutionSession = createdSession
      isUsingLocalSessionFallback = false
      clearOperationsSyncState(clearWarning: false)
      await postExecutionEvent(
        type: "session_started",
        payload: [
          "sop_name": sop.name,
          "capture_mode": selectedCaptureModeLabel.lowercased()
        ]
      )
      return createdSession.id
    } catch {
      isUsingLocalSessionFallback = true
      setCriticalOperationsSyncIssue(
        phase: "session_create",
        message: "Execution session could not sync. Continuing locally: \(error.localizedDescription)"
      )
      return UUID().uuidString
    }
  }

  private func handleChecklistMutation(
    item: ChecklistItemState,
    stepIndex: Int,
    eventType: String,
    evidence: [String: Any]? = nil
  ) async {
    let nextIndex = nextIncompleteStepIndex()
    await workerAdminSync?.updateCurrentStepIndex(nextIndex, sendImmediateHeartbeat: true)
    var eventPayload: [String: Any] = [
      "step_index": stepIndex,
      "step_name": item.name,
      "source": item.completionSource.rawValue,
      "checked": item.isChecked
    ]
    if let evidence {
      eventPayload["evidence"] = evidence
    }
    await postExecutionEvent(
      type: eventType,
      payload: eventPayload
    )
    await patchActiveExecutionSession(
      ExecutionSessionPatch(
        status: "active",
        currentSopID: selectedSOP?.remoteID,
        currentStepIndex: nextIndex
      )
    )
    await syncGeminiSessionInstruction()
  }

  private func nextIncompleteStepIndex() -> Int {
    checklistItems.firstIndex(where: { !$0.isChecked }) ?? checklistItems.count
  }

  private func activeSpotterRequestItems() -> [GeminiLiveSpotter.SpotterRequestItem] {
    let nextIndex = nextIncompleteStepIndex()
    guard nextIndex < checklistItems.count else { return [] }
    let currentStep = checklistItems[nextIndex]
    return [
      GeminiLiveSpotter.SpotterRequestItem(
        id: currentStep.itemID,
        name: currentStep.name,
        aiPrompt: currentStep.aiPrompt,
        expectedObjects: currentStep.expectedObjects,
        preconditions: currentStep.preconditions,
        postconditions: currentStep.postconditions,
        skipRisk: currentStep.skipRisk,
        evidenceRequired: currentStep.evidenceRequired,
        validation: currentStep.validation,
        critical: currentStep.critical
      )
    ]
  }

  private func nextCriticalStepTitleAfterActive(in sop: SOPTemplate, nextIndex: Int) -> String? {
    let orderedSteps = sop.steps.sorted { $0.order < $1.order }
    guard nextIndex + 1 < orderedSteps.count else { return nil }
    return orderedSteps
      .dropFirst(nextIndex + 1)
      .first(where: { $0.critical })?
      .title
  }

  func debugSpotterTargetIDs() -> [String] {
    activeSpotterRequestItems().map(\.id)
  }

  private func buildGeminiSessionInstruction(for sopOverride: SOPTemplate? = nil) -> String? {
    let sop = sopOverride ?? activeCaptureSOP ?? selectedSOP ?? currentAssignedSOP
    guard let sop else {
      geminiInstructionSyncStatus = ""
      return nil
    }

    let orderedSteps = sop.steps.sorted { $0.order < $1.order }
    let resolvedBaseInstruction = GeminiConfig.defaultSystemInstruction

    guard !orderedSteps.isEmpty else {
      geminiInstructionSyncStatus = "Gemini sync: \(sop.name) · no structured steps"
      return """
      \(resolvedBaseInstruction)

      Active SOP: \(sop.name)
      The SOP has no structured steps loaded. Ask clarifying questions, narrate what you need to see, and guide the worker toward the next safe action.
      """
    }

    let nextIndex = nextIncompleteStepIndex()
    let hasRemainingSteps = nextIndex < orderedSteps.count
    let step = orderedSteps[min(nextIndex, orderedSteps.count - 1)]
    let stepDescription = step.description.trimmingCharacters(in: .whitespacesAndNewlines)
    let aiPrompt = step.aiPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    let expectedObjects = step.expectedObjects
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .joined(separator: ", ")
    let preconditions = step.preconditions
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .joined(separator: "; ")
    let postconditions = step.postconditions
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .joined(separator: "; ")

    let directNextAction: String
    if hasRemainingSteps {
      directNextAction = "Guide the worker through this step now: \(step.title). Use the live camera to decide if it is truly complete before moving on."
    } else {
      directNextAction = "All SOP steps are marked complete. Confirm the finished state, call out any missing proof, and help the worker wrap up cleanly."
    }

    geminiInstructionSyncStatus = hasRemainingSteps
      ? "Gemini sync: \(sop.name) · Step \(step.order)/\(orderedSteps.count) · \(step.title)"
      : "Gemini sync: \(sop.name) · wrap-up guidance active"

    var lines = [
      resolvedBaseInstruction,
      "",
      "Live SOP context:",
      "SOP title: \(sop.name)",
      "Current step: \(step.order) of \(orderedSteps.count)",
      "Step title: \(step.title)"
    ]

    if !stepDescription.isEmpty {
      lines.append("Step description: \(stepDescription)")
    }

    lines.append("Vision completion prompt: \(aiPrompt.isEmpty ? "Use the step title and description as the visual rule." : aiPrompt)")

    if !expectedObjects.isEmpty {
      lines.append("Expected objects to look for: \(expectedObjects)")
    }
    if !preconditions.isEmpty {
      lines.append("Preconditions before this step: \(preconditions)")
    }
    if !postconditions.isEmpty {
      lines.append("Postconditions that prove completion: \(postconditions)")
    }
    lines.append("Skip risk: \(step.skipRisk)")
    lines.append("Evidence required: \(step.evidenceRequired ? "yes" : "no")")
    lines.append("Guidance policy: \(guidancePolicy.rawValue)")
    lines.append("Guidance policy reason: \(guidancePolicyReason)")
    lines.append("Guidance policy instruction: \(guidancePolicy.instruction)")

    if let nextCritical = nextCriticalStepTitleAfterActive(in: sop, nextIndex: nextIndex) {
      lines.append("Next critical checkpoint after this: \(nextCritical)")
    }

    lines.append("Direct next action: \(directNextAction)")
    lines.append("Treat the vision prompt and expected objects as the active verification rule for your spoken guidance.")

    return lines.joined(separator: "\n")
  }

  func debugGeminiInstructionPreview(for sop: SOPTemplate) -> String? {
    buildGeminiSessionInstruction(for: sop)
  }

  private func syncGeminiSessionInstruction(for sopOverride: SOPTemplate? = nil) async {
    await geminiAssistant.refreshSessionInstruction(buildGeminiSessionInstruction(for: sopOverride))
  }

  private func syncLivePreviewFrameIfNeeded(image: UIImage) async {
    guard isSopAuditRunning else { return }
    guard let sessionID = currentSopSessionId else { return }

    let now = Date()
    let underLiveVideoPressure = webrtcViewModel.isUnderLiveVideoPressure
    let uploadInterval: TimeInterval = underLiveVideoPressure
      ? (hasActiveHelpEscalation ? 1.5 : 2.0)
      : (hasActiveHelpEscalation ? 0.75 : 1.0)
    guard now.timeIntervalSince(lastLivePreviewSyncAt) >= uploadInterval else { return }
    lastLivePreviewSyncAt = now

    let compressionQuality = hasActiveHelpEscalation ? 0.5 : 0.45
    let encodeStartedAt = CACurrentMediaTime()
    guard let jpegData = await livePreviewFrameEncoder.encode(
      image: image,
      maxDimension: 640,
      compressionQuality: compressionQuality
    ) else { return }
    await WorkerTelemetry.shared.record(
      "live_preview_encode",
      source: "ios_app",
      stage: underLiveVideoPressure ? "pressure" : "normal",
      sessionID: sessionID,
      durationMs: (CACurrentMediaTime() - encodeStartedAt) * 1000,
      payload: [
        "bytes": jpegData.count,
        "under_live_video_pressure": underLiveVideoPressure,
        "upload_interval_seconds": uploadInterval
      ]
    )

    if streamingMode == .glasses, let fileURL = sopVideoRecorder?.outputURL {
      rememberPendingRecording(sessionID: sessionID, fileURL: fileURL)
    }

    await workerAdminSync?.enqueueFrameUpload(data: jpegData)
  }

  private func handleWorkerLiveHeartbeatFailure(sessionID: String, message: String) async {
    guard sessionID == currentSopSessionId else { return }

    let now = Date()
    guard now.timeIntervalSince(lastWorkerLiveHeartbeatFailureWarningAt) >= 5 else { return }
    lastWorkerLiveHeartbeatFailureWarningAt = now

    setOperationsSyncWarning(
      phase: "live_heartbeat",
      message: "Live heartbeat failed; keeping active audio and handoff routes unchanged. \(message)"
    )
    await WorkerTelemetry.shared.record(
      "worker_live_heartbeat_failed_no_audio_teardown",
      source: "ios_app",
      stage: "non_authoritative_error",
      sessionID: sessionID,
      payload: [
        "error": message,
        "gemini_active": geminiAssistant.isGeminiActive,
        "gemini_audio_ready": geminiAssistant.isAudioReady,
        "webrtc_active": webrtcViewModel.isActive,
        "has_active_help_escalation": hasActiveHelpEscalation,
        "audio_route_lease_protected": true,
        "av_audio_engine_state_protected": true,
        "support_mode_trusted": false
      ]
    )
  }

  private func isAuthoritativeHumanSupportEnd(_ response: WorkerLiveHeartbeatResponse) -> Bool {
    guard response.supportMode == "ai", response.humanSupportStatus == "ended" else {
      return false
    }

    return hasActiveHelpEscalation ||
      shouldResumeAiSupportAfterBackOffice ||
      (webrtcViewModel.isActive && webrtcViewModel.isSupportMode) ||
      response.supportUpdatedAt != nil
  }

  private func resetLiveRoomSyncSnapshot() {
    lastLiveRoomSyncSnapshot = nil
    lastLiveRoomSyncAt = .distantPast
    hasReceivedBackOfficeConnectedHandshake = false
  }

  private func handleWorkerLiveHeartbeatResponse(_ response: WorkerLiveHeartbeatResponse) async {
    guard response.sessionID == currentSopSessionId else { return }

    // Only successful heartbeat responses are authoritative enough to mutate
    // handoff state. HTTP failures are handled above and never release audio.
    let humanConnected =
      response.shouldOpenLiveRoom ||
      (response.supportMode == "back_office" && response.humanSupportStatus == "connected")
    let reportedHumanEnded =
      response.supportMode == "ai" && response.humanSupportStatus == "ended"
    let humanEnded = isAuthoritativeHumanSupportEnd(response)
    let humanRinging =
      response.supportMode == "handoff_requested" || response.humanSupportStatus == "ringing"

    if humanConnected {
      hasActiveHelpEscalation = true
      hasReceivedBackOfficeConnectedHandshake = true
      if !webrtcViewModel.isActive || !webrtcViewModel.isSupportMode {
        let wasObservationRoom = webrtcViewModel.isActive && !webrtcViewModel.isSupportMode
        helpStatusMessage = wasObservationRoom
          ? "Back office answered. Upgrading live room to video and audio..."
          : "Back office answered. Opening live video and audio..."
        if wasObservationRoom {
          await WorkerTelemetry.shared.record(
            "worker_live_support_upgrade_from_observation",
            source: "ios_app",
            stage: "handoff",
            sessionID: response.sessionID,
            payload: [
              "previous_room_code_present": !webrtcViewModel.roomCode.isEmpty,
              "support_mode": response.supportMode,
              "human_support_status": response.humanSupportStatus
            ]
          )
        }
        await ensureLiveRoomSession()
      } else if !webrtcViewModel.roomCode.isEmpty {
        await syncLiveRoomState(roomCode: webrtcViewModel.roomCode)
      }
      return
    }

    if reportedHumanEnded && !humanEnded {
      await WorkerTelemetry.shared.record(
        "worker_live_support_end_ignored_non_authoritative",
        source: "ios_app",
        stage: "non_authoritative_heartbeat",
        sessionID: response.sessionID,
        payload: [
          "support_mode": response.supportMode,
          "human_support_status": response.humanSupportStatus,
          "webrtc_active": webrtcViewModel.isActive,
          "webrtc_support_mode": webrtcViewModel.isSupportMode,
          "has_active_help_escalation": hasActiveHelpEscalation,
          "should_resume_ai": shouldResumeAiSupportAfterBackOffice,
          "support_updated_at_present": response.supportUpdatedAt != nil,
          "audio_route_lease_protected": true
        ]
      )
      return
    }

    if humanEnded {
      if webrtcViewModel.isActive && webrtcViewModel.isSupportMode {
        webrtcViewModel.stopSession()
      }
      hasActiveHelpEscalation = false
      resetLiveRoomSyncSnapshot()
      await workerAdminSync?.updateHelpRequested(false, sendImmediateHeartbeat: false)
      helpStatusMessage = "Back office ended. AI support is available again."
      await ensureObservationLiveRoomSession()

      if shouldResumeAiSupportAfterBackOffice, isSopAuditRunning, !geminiAssistant.isGeminiActive {
        shouldResumeAiSupportAfterBackOffice = false
        await ensureAiGuideStarted(reason: "support_ended")
      } else {
        shouldResumeAiSupportAfterBackOffice = false
      }
      return
    }

    if humanRinging {
      hasActiveHelpEscalation = true
      helpStatusMessage = "Calling back office. Live video and audio will open after they answer."
    }
  }

  private func requestSupervisorHelpFlow() async {
    guard canRequestHelp else {
      helpStatusMessage = "Start an SOP before requesting live support."
      return
    }

    isRequestingHelp = true
    defer { isRequestingHelp = false }

    let notes = helpRequestNotes.trimmingCharacters(in: .whitespacesAndNewlines)
    shouldResumeAiSupportAfterBackOffice = geminiAssistant.isGeminiActive
    if geminiAssistant.isGeminiActive {
      await geminiAssistant.stopSessionForHumanSupportHandoff()
      aiGuideStatusMessage = "AI guide paused while back office support is requested."
      sopAuditStatusMessage = aiGuideStatusMessage
    }

    guard let sessionID = activeExecutionSession?.id else {
      hasActiveHelpEscalation = true
      await workerAdminSync?.updateHelpRequested(true)
      helpStatusMessage = "Calling back office locally. Backend session sync is required before live media can open."
      return
    }

    do {
      _ = try await opsAPIClient.createIntervention(
        sessionID: sessionID,
        type: "help_request",
        notes: notes.isEmpty ? "Worker requested assistance." : notes
      )
      hasActiveHelpEscalation = true
      await workerAdminSync?.updateHelpRequested(true)
      await postExecutionEvent(
        type: "help_requested",
        payload: [
          "notes": notes,
          "room_code": NSNull()
        ]
      )
      await patchActiveExecutionSession(
        ExecutionSessionPatch(
          helpRequested: true
        )
      )
      helpStatusMessage = "Calling back office. Live video and audio will open after they answer."
    } catch {
      hasActiveHelpEscalation = false
      let shouldResumeAI = shouldResumeAiSupportAfterBackOffice
      shouldResumeAiSupportAfterBackOffice = false
      if shouldResumeAI, isSopAuditRunning, !geminiAssistant.isGeminiActive {
        await geminiAssistant.startSession(systemInstruction: buildGeminiSessionInstruction())
      }
      helpStatusMessage = "Back office call request failed: \(error.localizedDescription)"
    }
  }

  private func syncLiveRoomState(roomCode: String) async {
    let normalizedRoomCode = roomCode.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedRoomCode.isEmpty else { return }

    let backOfficeConnected =
      hasReceivedBackOfficeConnectedHandshake ||
      (hasActiveHelpEscalation &&
        webrtcViewModel.isActive &&
        webrtcViewModel.isSupportMode &&
        webrtcViewModel.connectionState == .connected)
    let nextSnapshot = LiveRoomSyncSnapshot(
      roomCode: normalizedRoomCode,
      helpRequested: hasActiveHelpEscalation,
      backOfficeConnected: backOfficeConnected
    )
    let previousSnapshot = lastLiveRoomSyncSnapshot
    let now = Date()
    let isFirstRoomCodePublish = previousSnapshot?.roomCode == nil
    let didChangeRoomCode = previousSnapshot?.roomCode != nil &&
      previousSnapshot?.roomCode != normalizedRoomCode
    let didInitiallyRequestHelp = hasActiveHelpEscalation &&
      previousSnapshot?.helpRequested != true
    let didInitiallyConnectBackOffice = backOfficeConnected &&
      previousSnapshot?.backOfficeConnected != true
    let shouldSendImmediateHeartbeat =
      isFirstRoomCodePublish ||
      didChangeRoomCode ||
      didInitiallyRequestHelp ||
      didInitiallyConnectBackOffice
    let isRedundantSync = previousSnapshot == nextSnapshot
    let didClearThrottle =
      now.timeIntervalSince(lastLiveRoomSyncAt) >= liveRoomRedundantSyncThrottleInterval

    let localOnly = activeExecutionSession == nil
    helpStatusMessage = liveRoomStatusMessage(
      localOnly: localOnly,
      helpRequested: hasActiveHelpEscalation,
      roomCode: normalizedRoomCode
    )

    guard shouldSendImmediateHeartbeat || !isRedundantSync || didClearThrottle else {
      return
    }

    await workerAdminSync?.updateRoomCode(
      normalizedRoomCode,
      sendImmediateHeartbeat: shouldSendImmediateHeartbeat
    )

    if !localOnly {
      await patchActiveExecutionSession(
        ExecutionSessionPatch(
          helpRequested: hasActiveHelpEscalation,
          webrtcRoomCode: normalizedRoomCode
        )
      )
    }

    lastLiveRoomSyncSnapshot = nextSnapshot
    lastLiveRoomSyncAt = now
  }

  private func closeCurrentPackageFlow() async {
    guard !isClosingPackage else { return }
    guard canCloseCurrentPackage else {
      packageClosureStatusMessage = "Complete all required SOPs before closing the package."
      return
    }
    guard let packageRunID = activePackageRunID else {
      packageClosureStatusMessage = "Package run is not synced yet. Ask ops-api to expose the package close route."
      return
    }
    guard let workerID = workerProfile?.id else {
      packageClosureStatusMessage = "Worker context missing. Refresh the assignment queue first."
      return
    }

    isClosingPackage = true
    defer { isClosingPackage = false }

    do {
      _ = try await opsAPIClient.closePackageRun(
        packageRunID: packageRunID,
        workerID: workerID
      )
      packageClosureStatusMessage = "Package closed and synced."
      await refreshWorkerContext()
    } catch {
      packageClosureStatusMessage = "Package close failed: \(error.localizedDescription)"
    }
  }

  private func updateHelpStatus(for state: WebRTCConnectionState) {
    let localOnly = activeExecutionSession == nil
    switch state {
    case .connected:
      if !hasLoggedRoomJoinedForSession {
        hasLoggedRoomJoinedForSession = true
        WorkerLiveLogger.log(
          "room_joined",
          sessionID: currentSopSessionId,
          roomCode: webrtcViewModel.roomCode.isEmpty ? nil : webrtcViewModel.roomCode,
          uploadState: "active"
        )
      }
      helpStatusMessage = localOnly
        ? "Local live room connected. Admin join stays unavailable until backend sync succeeds."
        : (webrtcViewModel.isSupportMode ? "Back office audio connected." : "Admin video observer connected.")
    case .waitingForPeer:
      if !webrtcViewModel.roomCode.isEmpty {
        helpStatusMessage = liveRoomStatusMessage(
          localOnly: localOnly,
          helpRequested: hasActiveHelpEscalation,
          roomCode: webrtcViewModel.roomCode
        )
      }
    case .connecting:
      helpStatusMessage = localOnly
        ? "Opening local live room..."
        : (webrtcViewModel.isSupportMode ? "Opening back office audio room..." : "Opening admin video observation...")
    case .backgrounded:
      helpStatusMessage = "Live room paused in background. Returning will reconnect."
    case .error(let message):
      helpStatusMessage = "Live room error: \(message)"
    case .disconnected:
      if !isRequestingHelp {
        helpStatusMessage = ""
      }
    }
  }

  private func ensureLiveRoomSession() async {
    // Heartbeats can arrive while Gemini is still yielding the audio route.
    // Only one support-room handoff may perform that awaited stop/start path.
    if webrtcViewModel.isActive && webrtcViewModel.isSupportMode {
      switch webrtcViewModel.connectionState {
      case .connected, .waitingForPeer, .connecting:
        if !webrtcViewModel.roomCode.isEmpty {
          await syncLiveRoomState(roomCode: webrtcViewModel.roomCode)
        }
        return
      case .backgrounded, .error, .disconnected:
        break
      }
    }

    guard !isLiveRoomHandoffInProgress else {
      if !webrtcViewModel.roomCode.isEmpty {
        await syncLiveRoomState(roomCode: webrtcViewModel.roomCode)
      }
      return
    }
    isLiveRoomHandoffInProgress = true
    defer { isLiveRoomHandoffInProgress = false }

    if geminiAssistant.isGeminiActive {
      shouldResumeAiSupportAfterBackOffice = true
      aiGuideStatusMessage = "AI guide paused while back office support connects."
      sopAuditStatusMessage = aiGuideStatusMessage
      await geminiAssistant.stopSessionForHumanSupportHandoff()
    }

    let hasRoomCode = !webrtcViewModel.roomCode.isEmpty

    if webrtcViewModel.isActive && webrtcViewModel.isSupportMode {
      switch webrtcViewModel.connectionState {
      case .connected, .waitingForPeer:
        if hasRoomCode {
          await syncLiveRoomState(roomCode: webrtcViewModel.roomCode)
          return
        }
      case .connecting:
        if hasRoomCode {
          await syncLiveRoomState(roomCode: webrtcViewModel.roomCode)
          return
        }
      case .backgrounded, .error, .disconnected:
        break
      }

      helpStatusMessage = "Restarting live room for this SOP..."
      webrtcViewModel.stopSession()
    } else if webrtcViewModel.isActive {
      helpStatusMessage = "Switching video observation into back office audio..."
      webrtcViewModel.stopSession()
    }

    await webrtcViewModel.startSession(captureMode: streamingMode, roomMode: .support)
    if let roomCode = await waitForRoomCode() {
      await syncLiveRoomState(roomCode: roomCode)
    } else if activeExecutionSession == nil {
      helpStatusMessage = "Opening local-only live room..."
      setOperationsSyncWarning(
        phase: "session_patch",
        message: "Live room is local-only until the backend execution session sync succeeds."
      )
    } else {
      helpStatusMessage = "Live room still syncing. Manager join will unlock once the room code is published."
      setOperationsSyncWarning(
        phase: "session_patch",
        message: "Live room did not publish a room code yet. Verify signal settings and session sync before expecting admin join."
      )
    }
  }

  private func ensureObservationLiveRoomSession() async {
    guard isSopAuditRunning, !hasActiveHelpEscalation else { return }
    guard WebRTCConfig.isConfigured else {
      setOperationsSyncWarning(
        phase: "live_room",
        message: "Video observation room is unavailable because signal settings are not configured."
      )
      return
    }

    if webrtcViewModel.isActive {
      if !webrtcViewModel.isSupportMode {
        if !webrtcViewModel.roomCode.isEmpty {
          await syncLiveRoomState(roomCode: webrtcViewModel.roomCode)
        }
        return
      }
      webrtcViewModel.stopSession()
    }

    helpStatusMessage = "Opening admin video observation..."
    await webrtcViewModel.startSession(captureMode: streamingMode, roomMode: .observation)
    if let roomCode = await waitForRoomCode(timeoutNanoseconds: 4_000_000_000) {
      await syncLiveRoomState(roomCode: roomCode)
      await WorkerTelemetry.shared.record(
        "webrtc_observation_room_ready",
        source: "webrtc",
        stage: "observation",
        sessionID: currentSopSessionId,
        payload: [
          "room_code_present": true,
          "capture_mode": captureModeEventValue(streamingMode)
        ]
      )
    } else {
      helpStatusMessage = "Admin video observation is still syncing."
      setOperationsSyncWarning(
        phase: "live_room",
        message: "Observation room did not publish a room code yet. Admin can still use frame fallback while signaling catches up."
      )
    }
  }

  private func postExecutionEvent(type: String, payload: [String: Any]) async {
    guard let sessionID = activeExecutionSession?.id else { return }
    do {
      _ = try await opsAPIClient.postExecutionEvent(
        sessionID: sessionID,
        eventType: type,
        payload: payload
      )
    } catch {
      setOperationsSyncWarning(
        phase: "session_event",
        message: "Event sync failed: \(error.localizedDescription)"
      )
    }
  }

  private func patchActiveExecutionSession(_ patch: ExecutionSessionPatch) async {
    guard let sessionID = activeExecutionSession?.id else { return }
    do {
      let updatedSession = try await opsAPIClient.updateExecutionSession(id: sessionID, patch: patch)
      activeExecutionSession = updatedSession
      if let warning = updatedSession.packageProgressWarning?.trimmingCharacters(in: .whitespacesAndNewlines),
         !warning.isEmpty {
        setOperationsSyncWarning(phase: "package_progress", message: warning)
      }
    } catch {
      setCriticalOperationsSyncIssue(
        phase: "session_patch",
        message: "Session sync failed: \(error.localizedDescription)"
      )
    }
  }

  private func uploadMediaAssetIfPossible(
    assetID: String,
    data: Data,
    contentType: String,
    label: String
  ) async -> Bool {
    guard !data.isEmpty else { return false }

    do {
      let uploadTarget = try await opsAPIClient.requestMediaUploadTarget(
        assetID: assetID,
        contentType: contentType,
        byteCount: data.count
      )
      try await opsAPIClient.uploadBinary(to: uploadTarget, data: data, contentType: contentType)
      _ = try await opsAPIClient.finalizeMediaAssetUpload(
        assetID: assetID,
        byteCount: data.count,
        contentType: contentType
      )
      return true
    } catch {
      setOperationsSyncWarning(
        phase: "media_upload",
        message: "\(label) upload is pending until ops-api exposes upload targets. \(error.localizedDescription)"
      )
      return false
    }
  }

  private func uploadEvidenceMediaAssets(
    sessionID: String,
    proofImages: [String: Data]
  ) async {
    for (targetID, imageData) in proofImages {
      do {
        let evidenceAsset = try await opsAPIClient.registerMediaAsset(
          sessionID: sessionID,
          bucket: "evidence-images",
          path: "sessions/\(sessionID)/proof/\(targetID).jpg",
          assetType: "photo",
          metadata: [
            "item_id": targetID,
            "upload_state": "pending",
            "bytes": imageData.count
          ]
        )
        _ = await uploadMediaAssetIfPossible(
          assetID: evidenceAsset.id,
          data: imageData,
          contentType: "image/jpeg",
          label: "Evidence image"
        )
      } catch {
        setOperationsSyncWarning(
          phase: "evidence_upload",
          message: "Evidence registration failed: \(error.localizedDescription)"
        )
      }
    }
  }

  private func createExecutionMemoryLink(
    sessionID: String,
    sopID: String,
    completedSteps: Int
  ) async {
    do {
      _ = try await opsAPIClient.createMemoryLink(
        sourceID: sessionID,
        sourceType: "execution_session",
        targetID: sopID,
        targetType: "sop",
        linkType: "executed",
        metadata: [
          "completed_steps": completedSteps,
          "total_steps": checklistItems.count
        ]
      )
    } catch {
      setOperationsSyncWarning(
        phase: "memory_link",
        message: "Memory link sync failed: \(error.localizedDescription)"
      )
    }
  }

  private func updateDossierPipelineStatus(_ message: String, kind: DossierPipelineStatusKind) {
    dossierPipelineStatusMessage = message
    dossierPipelineStatusKind = kind
    dossierPipelineStatusTimestamp = Self.pipelineTimestampFormatter.string(from: Date())
  }
}

private extension UIImage {
  func resizedForLivePreview(maxDimension: CGFloat) -> UIImage {
    let width = size.width
    let height = size.height
    guard width > 0, height > 0, maxDimension > 0 else { return self }

    let longest = max(width, height)
    guard longest > maxDimension else { return self }

    let scale = maxDimension / longest
    let targetSize = CGSize(width: width * scale, height: height * scale)
    let renderer = UIGraphicsImageRenderer(size: targetSize)
    return renderer.image { _ in
      self.draw(in: CGRect(origin: .zero, size: targetSize))
    }
  }
}
