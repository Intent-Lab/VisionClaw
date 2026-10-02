/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

// InstrumentationTest - DAT Integration Testing Suite
//
// This instrumentation test suite demonstrates testing for DAT applications.
// It shows how to test DAT functionality end-to-end using MockDeviceKit and UI automation.
//
// Test Scenarios Covered:
// 1. App launch with no devices (HomeScreen)
// 2. App behavior with mock device paired (NonStreamScreen)
// 3. Permission checking workflow with MockDeviceKit (auto-grants permissions)
// 4. Complete streaming workflow from device setup to video display

package com.meta.wearable.dat.externalsampleapps.cameraaccess

import android.content.Context
import android.net.Uri
import android.util.Log
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.filters.LargeTest
import androidx.test.platform.app.InstrumentationRegistry
import com.meta.wearable.dat.mockdevice.MockDeviceKit
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import org.junit.After
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@OptIn(ExperimentalTestApi::class)
@RunWith(AndroidJUnit4::class)
@LargeTest
class InstrumentationTest {

  companion object {
    private const val TAG = "InstrumentationTest"
  }

  @get:Rule val composeTestRule = createAndroidComposeRule<MainActivity>()
  val targetContext: Context = InstrumentationRegistry.getInstrumentation().targetContext

  @Before
  fun setup() {
    grantPermissions()
  }

  @After
  fun tearDown() {
    MockDeviceKit.getInstance(targetContext).reset()
  }

  @Test
  fun showsHomeScreenOnLaunch() {
    val homeTip = targetContext.getString(R.string.home_tip_video)
    composeTestRule.waitUntilExactlyOneExists(
        hasText(homeTip),
        timeoutMillis = 5000,
    )
  }

  @Test
  fun showsNonStreamScreenWhenMockPaired() {
    val nonStreamScreenText = targetContext.getString(R.string.non_stream_screen_description)
    val mockDeviceKit = MockDeviceKit.getInstance(targetContext)
    mockDeviceKit.pairRaybanMeta().powerOn()

    composeTestRule.waitUntilExactlyOneExists(hasText(nonStreamScreenText), timeoutMillis = 5000)
  }

  @Test
  fun startThenStopStreaming() {
    val startStreamButtonTitle = targetContext.getString(R.string.stream_button_title)
    val streamContentDescription = targetContext.getString(R.string.live_stream)
    val captureButtonIcon = targetContext.getString(R.string.capture_photo)
    val capturedImageContentDescription = targetContext.getString(R.string.captured_photo)

    // Pair mock device and provide fake camera feed and captured image
    val mockDeviceKit = MockDeviceKit.getInstance(targetContext)
    val device = mockDeviceKit.pairRaybanMeta()
    device.powerOn()
    device.don()
    val mockCameraKit = device.getCameraKit()
    mockCameraKit.setCameraFeed(getFileUri("plant.mp4"))
    mockCameraKit.setCapturedImage(getFileUri("plant.png"))

    // Start streaming and verify stream is displayed
    composeTestRule.onNodeWithText(startStreamButtonTitle).performClick()
    composeTestRule.waitUntilExactlyOneExists(
        hasContentDescription(streamContentDescription),
        timeoutMillis = 5000,
    )

    // Trigger capture and verify captured image is displayed
    composeTestRule.onNodeWithContentDescription(captureButtonIcon).performClick()
    composeTestRule.waitUntilExactlyOneExists(
        hasContentDescription(capturedImageContentDescription),
        timeoutMillis = 15000,
    )
  }

  private fun grantPermissions() {
    grantPermission("android.permission.BLUETOOTH")
    grantPermission("android.permission.BLUETOOTH_CONNECT")
    grantPermission("android.permission.INTERNET")
  }

  private fun grantPermission(permission: String) {
    val packageName = targetContext.packageName
    try {
      val instrumentation = InstrumentationRegistry.getInstrumentation()
      instrumentation.uiAutomation.executeShellCommand("pm grant $packageName $permission")
      Log.d(TAG, "Granted permission: $permission")
    } catch (e: IOException) {
      Log.e(TAG, "Failed to grant permission", e)
    }
  }

  private fun copyAssetToCache(assetName: String): File {
    val context = InstrumentationRegistry.getInstrumentation().targetContext
    val assetManager = InstrumentationRegistry.getInstrumentation().context.assets
    val inputStream = assetManager.open(assetName)
    val outFile = File(context.cacheDir, assetName)
    FileOutputStream(outFile).use { output -> inputStream.copyTo(output) }
    inputStream.close()
    return outFile
  }

  // Helper to get asset uri in the test run
  private fun getFileUri(assetName: String): Uri {
    val file = copyAssetToCache(assetName)
    val fileUri = Uri.fromFile(file)
    return fileUri
  }
}
