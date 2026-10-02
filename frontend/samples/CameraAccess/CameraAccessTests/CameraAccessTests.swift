/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation
import MWDATCore
import MWDATMockDevice
import SwiftUI
import XCTest

@testable import CameraAccess

@MainActor
class ViewModelIntegrationTests: XCTestCase {

  private var mockDevice: MockRaybanMeta?
  private var cameraKit: MockCameraKit?

  override func setUp() async throws {
    try await super.setUp()
    try? Wearables.configure()

    // Pair mock device and set up camera kit
    let pairedMockDevice = MockDeviceKit.shared.pairRaybanMeta()
    mockDevice = pairedMockDevice
    cameraKit = pairedMockDevice.getCameraKit()

    // Power on and unfold the device to make it available
    pairedMockDevice.powerOn()
    pairedMockDevice.unfold()

    // Wait for device to be available in Wearables
    try await Task.sleep(nanoseconds: 1_000_000_000)
  }

  override func tearDown() async throws {
    MockDeviceKit.shared.pairedDevices.forEach { mockDevice in
      MockDeviceKit.shared.unpairDevice(mockDevice)
    }
    mockDevice = nil
    cameraKit = nil
    try await super.tearDown()
  }

  // MARK: - Video Streaming Flow Tests

  func testVideoStreamingFlow() async throws {
    guard let camera = cameraKit else {
      XCTFail("Mock device and camera should be available")
      return
    }

    guard let videoURL = Bundle(for: type(of: self)).url(forResource: "plant", withExtension: "mp4") else {
      XCTFail("Could not find resource in test bundle")
      return
    }

    // Setup camera feed
    await camera.setCameraFeed(fileURL: videoURL)

    let viewModel = StreamSessionViewModel(wearables: Wearables.shared)

    // Initially not streaming
    XCTAssertEqual(viewModel.streamingStatus, .stopped)
    XCTAssertFalse(viewModel.isStreaming)
    XCTAssertFalse(viewModel.hasReceivedFirstFrame)
    XCTAssertNil(viewModel.currentVideoFrame)

    // Start streaming session
    await viewModel.handleStartStreaming()

    // Wait for streaming to establish
    try await Task.sleep(nanoseconds: 10_000_000_000)

    // Verify streaming is active and receiving frames
    XCTAssertTrue(viewModel.isStreaming)
    XCTAssertTrue(viewModel.hasReceivedFirstFrame)
    XCTAssertNotNil(viewModel.currentVideoFrame)
    XCTAssertTrue([.streaming, .waiting].contains(viewModel.streamingStatus))

    // Stop streaming
    await viewModel.stopSession()

    // Wait for session to stop
    try await Task.sleep(nanoseconds: 1_000_000_000)

    // Verify streaming stopped (allow for final states to be stopped or waiting)
    XCTAssertFalse(viewModel.isStreaming)
    XCTAssertTrue([.stopped, .waiting].contains(viewModel.streamingStatus))
  }

  // MARK: - Photo Capture Flow Tests

  func testStreamingAndPhotoCaptureFlow() async throws {
    guard let camera = cameraKit else {
      XCTFail("Mock device and camera should be available")
      return
    }

    guard let videoURL = Bundle(for: type(of: self)).url(forResource: "plant", withExtension: "mp4") else {
      XCTFail("Could not find resource in test bundle")
      return
    }

    guard let imageURL = Bundle(for: type(of: self)).url(forResource: "plant", withExtension: "png") else {
      XCTFail("Could not find resource in test bundle")
      return
    }

    // Setup camera feed
    await camera.setCameraFeed(fileURL: videoURL)
    await camera.setCapturedImage(fileURL: imageURL)

    let viewModel = StreamSessionViewModel(wearables: Wearables.shared)

    // Initially not streaming
    XCTAssertEqual(viewModel.streamingStatus, .stopped)
    XCTAssertFalse(viewModel.isStreaming)
    XCTAssertFalse(viewModel.hasReceivedFirstFrame)
    XCTAssertNil(viewModel.currentVideoFrame)

    // Start streaming session
    await viewModel.handleStartStreaming()

    // Wait for streaming to establish
    try await Task.sleep(nanoseconds: 10_000_000_000)

    // Verify streaming is active and receiving frames
    XCTAssertTrue(viewModel.isStreaming)
    XCTAssertTrue(viewModel.hasReceivedFirstFrame)
    XCTAssertNotNil(viewModel.currentVideoFrame)
    XCTAssertTrue([.streaming, .waiting].contains(viewModel.streamingStatus))

    // Capture photo while streaming
    viewModel.capturePhoto()
    try await Task.sleep(nanoseconds: 10_000_000_000)

    // Verify photo captured while maintaining stream (allow for some timing flexibility)
    XCTAssertTrue(viewModel.capturedPhoto != nil)
    XCTAssertTrue(viewModel.showPhotoPreview)
    XCTAssertTrue(viewModel.isStreaming)

    // Dismiss photo and stop streaming
    viewModel.dismissPhotoPreview()
    XCTAssertFalse(viewModel.showPhotoPreview)
    XCTAssertNil(viewModel.capturedPhoto)

    await viewModel.stopSession()
    try await Task.sleep(nanoseconds: 1_000_000_000)

    XCTAssertFalse(viewModel.isStreaming)
    XCTAssertTrue([.stopped, .waiting].contains(viewModel.streamingStatus))
  }
}
