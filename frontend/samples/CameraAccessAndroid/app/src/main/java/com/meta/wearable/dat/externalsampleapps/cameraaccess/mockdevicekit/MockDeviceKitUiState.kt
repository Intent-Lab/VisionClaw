/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

// MockDeviceKitUiState - DAT MockDeviceKit Testing State
//
// These data classes manage the state of simulated wearable devices for DAT testing. MockDeviceKit
// provides a complete testing environment for DAT applications without requiring physical wearable
// devices.
//
// MockDeviceInfo encapsulates:
// - device: MockRaybanMeta instance from DAT MockDeviceKit API
// - deviceId: UI identifier for tracking multiple mock devices
// - deviceName: Display name for the simulated device
// - hasCameraFeed: Whether mock video content has been configured
// - hasCapturedImage: Whether mock photo content has been configured

package com.meta.wearable.dat.externalsampleapps.cameraaccess.mockdevicekit

import com.meta.wearable.dat.mockdevice.api.MockRaybanMeta

data class MockDeviceInfo(
    val device: MockRaybanMeta,
    val deviceId: String,
    val deviceName: String,
    val hasCameraFeed: Boolean = false,
    val hasCapturedImage: Boolean = false,
)

data class MockDeviceKitUiState(
    val pairedDevices: List<MockDeviceInfo> = emptyList(),
)
