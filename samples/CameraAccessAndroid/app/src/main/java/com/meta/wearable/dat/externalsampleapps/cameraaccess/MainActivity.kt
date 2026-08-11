/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

package com.meta.wearable.dat.externalsampleapps.cameraaccess

import android.Manifest.permission.BLUETOOTH_CONNECT
import android.Manifest.permission.CAMERA
import android.Manifest.permission.RECORD_AUDIO
import android.os.Bundle
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts.RequestMultiplePermissions
import androidx.activity.viewModels
import androidx.lifecycle.ViewModelProvider
import com.meta.wearable.dat.core.Wearables
import com.meta.wearable.dat.externalsampleapps.cameraaccess.livekit.LiveKitSessionViewModel
import com.meta.wearable.dat.core.types.Permission
import com.meta.wearable.dat.core.types.PermissionStatus
import com.meta.wearable.dat.externalsampleapps.cameraaccess.settings.CaptureSource
import com.meta.wearable.dat.externalsampleapps.cameraaccess.settings.SettingsManager
import com.meta.wearable.dat.externalsampleapps.cameraaccess.ui.CameraAccessScaffold
import com.meta.wearable.dat.externalsampleapps.cameraaccess.wearables.WearablesViewModel
import kotlin.coroutines.resume
import kotlinx.coroutines.CancellableContinuation
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

class MainActivity : ComponentActivity() {
  companion object {
    // Runtime permissions only: legacy BLUETOOTH and INTERNET are install-time
    // grants that the runtime dialog reports as "denied" on modern Android,
    // which made an all-of-them check fail (and snackbar) on every launch.
    val PERMISSIONS: Array<String> = arrayOf(
        BLUETOOTH_CONNECT, RECORD_AUDIO, CAMERA,
    )
  }

  val viewModel: WearablesViewModel by viewModels()

  private var permissionContinuation: CancellableContinuation<PermissionStatus>? = null
  private val permissionMutex = Mutex()
  private val permissionsResultLauncher =
      registerForActivityResult(Wearables.RequestPermissionContract()) { result ->
        val permissionStatus = result.getOrDefault(PermissionStatus.Denied)
        permissionContinuation?.resume(permissionStatus)
        permissionContinuation = null
      }

  suspend fun requestWearablesPermission(permission: Permission): PermissionStatus {
    return permissionMutex.withLock {
      suspendCancellableCoroutine { continuation ->
        permissionContinuation = continuation
        continuation.invokeOnCancellation { permissionContinuation = null }
        permissionsResultLauncher.launch(permission)
      }
    }
  }

  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    enableEdgeToEdge()

    // Initialize settings with app context
    SettingsManager.init(this)

    // Keep screen on while streaming
    window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

    // First, ensure the app has necessary Android permissions
    checkPermissions {
      // The DAT SDK starts lazily so phone mode never pays its startup cost:
      // startMonitoring runs Wearables.initialize via WearablesInit, and the
      // scaffold triggers the same path when the user switches to glasses.
      if (SettingsManager.captureSource == CaptureSource.GLASSES) {
        viewModel.startMonitoring()
      } else {
        // First-ever launch: the phone screen composed before the grant and
        // its auto-start declined; retry now that the permissions exist.
        ViewModelProvider(this)[LiveKitSessionViewModel::class.java].autoStartIfNeeded()
      }
    }

    setContent {
      CameraAccessScaffold(
          viewModel = viewModel,
          onRequestWearablesPermission = ::requestWearablesPermission,
      )
    }
  }

  fun checkPermissions(onPermissionsGranted: () -> Unit) {
    registerForActivityResult(RequestMultiplePermissions()) { permissionsResult ->
          // Only the current mode's needs gate startup: phone calls need
          // camera + mic; the Bluetooth grant matters only for glasses.
          val needed =
              if (SettingsManager.captureSource == CaptureSource.GLASSES) {
                listOf(CAMERA, RECORD_AUDIO, BLUETOOTH_CONNECT)
              } else {
                listOf(CAMERA, RECORD_AUDIO)
              }
          val missing = needed.filter { permissionsResult[it] == false }
          if (missing.isEmpty()) {
            onPermissionsGranted()
          } else {
            viewModel.setRecentError(
                "Missing permissions: " + missing.joinToString { it.substringAfterLast('.') }
            )
          }
        }
        .launch(PERMISSIONS)
  }
}
