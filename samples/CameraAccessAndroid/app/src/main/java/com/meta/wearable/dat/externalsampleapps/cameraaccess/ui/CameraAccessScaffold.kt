/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

// CameraAccessScaffold - DAT Application Navigation Orchestrator
//
// This scaffold demonstrates a typical DAT application navigation pattern based on device
// registration and streaming states from the DAT API.
//
// DAT State-Based Navigation:
// - HomeScreen: When NOT registered (uiState.isRegistered = false) Shows initial registration UI
//   calling Wearables.startRegistration()
// - NonStreamScreen: When registered (uiState.isRegistered = true) but not streaming Shows device
//   selection, permission checking, and pre-streaming setup
// - StreamScreen: When actively streaming (uiState.isStreaming = true) Shows live video from
//   StreamSession.videoStream and photo capture UI
//
// The scaffold also provides a debug menu (in DEBUG builds) that gives access to
// MockDeviceKitScreen for testing DAT functionality without physical devices.

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
import androidx.compose.material.icons.filled.BugReport
import androidx.compose.material.icons.filled.Error
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Snackbar
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel as composeViewModel
import com.meta.wearable.dat.externalsampleapps.cameraaccess.BuildConfig
import com.meta.wearable.dat.externalsampleapps.cameraaccess.gemini.GeminiSessionViewModel
import com.meta.wearable.dat.externalsampleapps.cameraaccess.wearables.WearablesViewModel

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CameraAccessScaffold(
    viewModel: WearablesViewModel,
    modifier: Modifier = Modifier,
) {
  val uiState by viewModel.uiState.collectAsStateWithLifecycle()
  val geminiViewModel: GeminiSessionViewModel = composeViewModel()
  val snackbarHostState = remember { SnackbarHostState() }
  val bottomSheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)

  // Observe camera permission errors and show snackbar
  LaunchedEffect(uiState.recentError) {
    uiState.recentError?.let { errorMessage ->
      snackbarHostState.showSnackbar(errorMessage)
      viewModel.clearCameraPermissionError()
    }
  }

  Surface(modifier = modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
    Box(modifier = Modifier.fillMaxSize()) {
      when {
        uiState.isSettingsVisible ->
            SettingsScreen(
                onBack = { viewModel.hideSettings() },
                onDebugMenu = if (BuildConfig.DEBUG) {{ viewModel.showDebugMenu() }} else null,
                onOpenClawNewSession = if (BuildConfig.DEBUG) {
                    { geminiViewModel.runOpenClawDeveloperCommand("/new") }
                } else null,
                onOpenClawCompactSession = if (BuildConfig.DEBUG) {
                    { geminiViewModel.runOpenClawDeveloperCommand("/compact") }
                } else null,
            )
        uiState.isStreaming ->
            StreamScreen(
                wearablesViewModel = viewModel,
                isPhoneMode = uiState.isPhoneMode,
                geminiViewModel = geminiViewModel,
            )
        uiState.isRegistered ->
            NonStreamScreen(
                viewModel = viewModel,
            )
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

      if (BuildConfig.DEBUG && uiState.isDebugMenuVisible) {
        ModalBottomSheet(
            onDismissRequest = { viewModel.hideDebugMenu() },
            sheetState = bottomSheetState,
            modifier = Modifier.fillMaxSize(),
        ) {
          MockDeviceKitScreen(modifier = Modifier.fillMaxSize())
        }
      }
    }
  }
}
