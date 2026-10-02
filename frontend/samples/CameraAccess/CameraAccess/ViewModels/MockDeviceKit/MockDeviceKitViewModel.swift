/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// MockDeviceKitViewModel.swift
//
// View model for managing mock devices during development and testing of DAT SDK features.
// Mock devices simulate real Meta wearable device behavior, allowing developers to test
// streaming, photo capture, and device management workflows without physical hardware.
//

#if canImport(MWDATMockDevice)

import Foundation
import MWDATMockDevice

extension MockDeviceKitView {
  @MainActor
  class ViewModel: ObservableObject {
    private let mockDeviceKit: MockDeviceKitInterface
    @Published var cardViewModels: [MockDeviceCardView.ViewModel] = []

    init(mockDeviceKit: MockDeviceKitInterface) {
      self.mockDeviceKit = mockDeviceKit
      self.cardViewModels = mockDeviceKit.pairedDevices.map { MockDeviceCardView.ViewModel(device: $0) }
    }

    // Add a new mock Ray-Ban Meta device
    func pairRaybanMeta() {
      let mockDevice = mockDeviceKit.pairRaybanMeta()
      cardViewModels.append(MockDeviceCardView.ViewModel(device: mockDevice))
    }

    func unpairDevice(_ device: MockDevice) {
      if let idx = cardViewModels.firstIndex(where: { $0.id == device.deviceIdentifier }) {
        cardViewModels.remove(at: idx)
        mockDeviceKit.unpairDevice(device)
      }
    }
  }
}

#endif
