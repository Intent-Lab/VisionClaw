/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

// CameraAccessScaffold - Navigation Orchestrator
//
// Routing is driven by the capture source setting plus DAT registration state:
// - Phone mode: LiveKitStreamScreen is the root -- camera preview + call button,
//   no onboarding.
// - Glasses mode, registered (or mock device): the same LiveKitStreamScreen with
//   glasses frames as the video source; DAT streaming auto-starts, no
//   start-choice interstitial.
// - Glasses mode, NOT registered: HomeScreen shows the registration UI calling
//   Wearables.startRegistration().
//

package com.meta.wearable.dat.externalsampleapps.cameraaccess.ui

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Error
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Snackbar
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel as composeViewModel
import com.meta.wearable.dat.core.types.Permission
import com.meta.wearable.dat.core.types.PermissionStatus
import com.meta.wearable.dat.externalsampleapps.cameraaccess.livekit.LiveKitSessionViewModel
import com.meta.wearable.dat.externalsampleapps.cameraaccess.settings.CaptureSource
import com.meta.wearable.dat.externalsampleapps.cameraaccess.settings.SettingsManager
import com.meta.wearable.dat.externalsampleapps.cameraaccess.wearables.WearablesViewModel

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CameraAccessScaffold(
    viewModel: WearablesViewModel,
    onRequestWearablesPermission: suspend (Permission) -> PermissionStatus,
    modifier: Modifier = Modifier,
) {
  val uiState by viewModel.uiState.collectAsStateWithLifecycle()
  val captureSource by SettingsManager.captureSourceFlow.collectAsStateWithLifecycle()
  val liveKitViewModel: LiveKitSessionViewModel = composeViewModel()
  val snackbarHostState = remember { SnackbarHostState() }

  // Observe camera permission errors and show snackbar
  LaunchedEffect(uiState.recentError) {
    uiState.recentError?.let { errorMessage ->
      snackbarHostState.showSnackbar(errorMessage)
      viewModel.clearCameraPermissionError()
    }
  }

  // Swap capture pipelines live when the Settings choice changes. Both modes
  // run the same LiveKit session, so an actual switch tears it down (video
  // source is chosen at track creation) and the next screen auto-starts with
  // the new source.
  var previousSource by remember { mutableStateOf<CaptureSource?>(null) }
  LaunchedEffect(captureSource) {
    if (previousSource != null && previousSource != captureSource) {
      liveKitViewModel.leave()
    }
    when (captureSource) {
      CaptureSource.GLASSES ->
          // Initializes the DAT SDK on first use (no-op afterwards) so phone
          // mode never pays its startup cost.
          viewModel.startMonitoring()
      CaptureSource.PHONE ->
          if (uiState.isStreaming) {
            viewModel.navigateToDeviceSelection()
          }
    }
    previousSource = captureSource
  }

  // Glasses mode never shows a start-choice page: entering it with registered
  // glasses (or a mock device) runs the DAT permission flow automatically and
  // the call screen's "Waiting for glasses video" placeholder is the loading
  // state. One attempt per entry into glasses mode, so a denied permission
  // surfaces once through the snackbar instead of looping.
  var glassesStartAttempted by remember { mutableStateOf(false) }
  var previousDeviceAvailable by remember { mutableStateOf(false) }
  LaunchedEffect(captureSource, uiState.isRegistered, uiState.hasActiveDevice) {
    if (captureSource == CaptureSource.PHONE) {
      glassesStartAttempted = false
    } else {
      // Glasses waking up (no device -> device) re-arms the single attempt,
      // so auto-start follows availability transitions instead of looping.
      if (uiState.hasActiveDevice && !previousDeviceAvailable) {
        glassesStartAttempted = false
      }
      if (uiState.isRegistered && !uiState.isStreaming && !glassesStartAttempted) {
        glassesStartAttempted = true
        viewModel.navigateToStreaming(onRequestWearablesPermission, quietIfUnavailable = true)
      }
    }
    previousDeviceAvailable = uiState.hasActiveDevice
  }

  Surface(modifier = modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
    Box(modifier = Modifier.fillMaxSize()) {
      when {
        uiState.isSettingsVisible ->
            SettingsScreen(
                onBack = { viewModel.hideSettings() },
            )
        // Phone mode is the app's front door: no onboarding, no intermediate
        // screen -- the camera preview + call button IS the home screen.
        captureSource == CaptureSource.PHONE ->
            LiveKitStreamScreen(
                onOpenSettings = { viewModel.showSettings() },
            )
        // Glasses mode with registered glasses: the SAME call screen, with
        // glasses frames as the video source, is the root -- streaming
        // auto-starts, so there is no start-choice interstitial.
        uiState.isRegistered ->
            LiveKitStreamScreen(
                onOpenSettings = { viewModel.showSettings() },
                glassesIssue = uiState.glassesIssue,
            )
        // Unregistered glasses mode: the connect screen.
        else ->
            HomeScreen(
                viewModel = viewModel,
            )
      }

      SnackbarHost(
          hostState = snackbarHostState,
          modifier =
              Modifier.align(Alignment.BottomCenter)
                  .navigationBarsPadding()
                  .padding(horizontal = 16.dp, vertical = 32.dp),
          snackbar = { data ->
            Snackbar(
                shape = RoundedCornerShape(24.dp),
                containerColor = MaterialTheme.colorScheme.errorContainer,
                contentColor = MaterialTheme.colorScheme.onErrorContainer,
            ) {
              Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    imageVector = Icons.Default.Error,
                    contentDescription = "Camera Access error",
                    tint = MaterialTheme.colorScheme.error,
                )
                Spacer(modifier = Modifier.width(8.dp))
                Text(data.visuals.message)
              }
            }
          },
      )

    }
  }
}
