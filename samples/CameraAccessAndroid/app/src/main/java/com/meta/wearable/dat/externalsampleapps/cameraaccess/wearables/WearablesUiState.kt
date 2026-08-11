/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

// WearablesUiState - DAT API State Management
//
// This data class aggregates DAT API state for the UI layer

package com.meta.wearable.dat.externalsampleapps.cameraaccess.wearables

import com.meta.wearable.dat.core.types.DeviceIdentifier
import com.meta.wearable.dat.core.types.RegistrationState
import kotlinx.collections.immutable.ImmutableList
import kotlinx.collections.immutable.persistentListOf

/**
 * Glasses conditions the call screen renders inline in its placeholder area.
 * The app has one voice: state speaks through our own surfaces, not system
 * alarm styling, so these are typed states rather than error strings.
 */
sealed class GlassesIssue {
  data object MetaAiMissing : GlassesIssue()

  data object PermissionDenied : GlassesIssue()

  data class DeviceUpdateRequired(val deviceName: String) : GlassesIssue()

  data object Reconnecting : GlassesIssue()
}

data class WearablesUiState(
    val registrationState: RegistrationState = RegistrationState.Unavailable(),
    val devices: ImmutableList<DeviceIdentifier> = persistentListOf(),
    val recentError: String? = null,
    val isStreaming: Boolean = false,
    val hasMockDevices: Boolean = false,
    val isDebugMenuVisible: Boolean = false,
    val isGettingStartedSheetVisible: Boolean = false,
    val hasActiveDevice: Boolean = false,
    val isSettingsVisible: Boolean = false,
    val glassesIssue: GlassesIssue? = null,
) {
  val isRegistered: Boolean = registrationState is RegistrationState.Registered || hasMockDevices
}
