/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

package com.meta.wearable.dat.externalsampleapps.cameraaccess

import android.Manifest.permission.BLUETOOTH
import android.Manifest.permission.BLUETOOTH_CONNECT
import android.Manifest.permission.CAMERA
import android.Manifest.permission.INTERNET
import android.Manifest.permission.RECORD_AUDIO
import android.os.Bundle
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts.RequestMultiplePermissions
import androidx.activity.viewModels
import com.meta.wearable.dat.core.Wearables
import com.meta.wearable.dat.core.types.Permission
import com.meta.wearable.dat.core.types.PermissionStatus
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
    val PERMISSIONS: Array<String> = arrayOf(
        BLUETOOTH, BLUETOOTH_CONNECT, INTERNET, RECORD_AUDIO, CAMERA,
    )
  }

  val viewModel: WearablesViewModel by viewModels()

  private var permissionContinuation: CancellableContinuation<PermissionStatus>? = null
  private val permissionMutex = Mutex()
  private val permissionsResultLauncher =
      registerForActivityResult(Wearables.RequestPermissionContract()) { result ->
        val permissionStatus = result.getOrDefault(PermissionStatus.Denied)
        // Snapshot then null out before resuming so a re-entrant call
        // from inside resume() can't observe a stale continuation.
        val cont = permissionContinuation
        permissionContinuation = null
        cont?.resume(permissionStatus)
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

  // System-permissions flow. The launcher is registered once at field
  // init time (per AndroidX rules) and the granted callback is stored
  // here so checkPermissions() can be called more than once safely.
  private var onSystemPermissionsResult: ((Boolean) -> Unit)? = null
  private val systemPermissionsResultLauncher =
      registerForActivityResult(RequestMultiplePermissions()) { result ->
        val cb = onSystemPermissionsResult
        onSystemPermissionsResult = null
        val granted = result.entries.all { it.value }
        cb?.invoke(granted)
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
      // Initialize the DAT SDK once the permissions are granted
      Wearables.initialize(this)

      // Start observing Wearables state after SDK is initialized
      viewModel.startMonitoring()
    }

    setContent {
      CameraAccessScaffold(
          viewModel = viewModel,
          onRequestWearablesPermission = ::requestWearablesPermission,
      )
    }
  }

  fun checkPermissions(onPermissionsGranted: () -> Unit) {
    // Reuse the once-registered launcher (registerForActivityResult
    // must happen before the activity reaches STARTED, which the
    // field-initializer registration above guarantees). If a request
    // is already in flight, we drop the new one rather than
    // overwriting the in-flight callback.
    if (onSystemPermissionsResult != null) return
    onSystemPermissionsResult = { granted ->
      if (granted) {
        onPermissionsGranted()
      } else {
        viewModel.setRecentError(
            "Allow All Permissions (Bluetooth, Bluetooth Connect, Internet, Microphone, Camera)"
        )
      }
    }
    systemPermissionsResultLauncher.launch(PERMISSIONS)
  }
}
