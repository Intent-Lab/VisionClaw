/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

// MockDeviceKitScreen - DAT Testing Interface
//
// This screen allows developers to simulate wearable devices and test DAT functionality without
// hardware.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.ui

import android.net.Uri
import androidx.activity.ComponentActivity
import androidx.activity.compose.LocalActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.meta.wearable.dat.externalsampleapps.cameraaccess.R
import com.meta.wearable.dat.externalsampleapps.cameraaccess.mockdevicekit.MockDeviceInfo
import com.meta.wearable.dat.externalsampleapps.cameraaccess.mockdevicekit.MockDeviceKitViewModel

@Composable
fun MockDeviceKitScreen(
    modifier: Modifier = Modifier,
    viewModel: MockDeviceKitViewModel = viewModel(LocalActivity.current as ComponentActivity),
) {
  val uiState by viewModel.uiState.collectAsStateWithLifecycle()

  Column(
      modifier = modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp),
      verticalArrangement = Arrangement.spacedBy(12.dp),
  ) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        elevation = CardDefaults.cardElevation(defaultElevation = 2.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
    ) {
      Column(modifier = Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
          Text(
              text = stringResource(R.string.mock_device_kit_title),
              style = MaterialTheme.typography.headlineSmall,
              fontWeight = FontWeight.Bold,
          )
          Text(
              text = stringResource(R.string.devices_paired_count, uiState.pairedDevices.size),
              style = MaterialTheme.typography.bodyMedium,
              color = AppColor.Green,
              textAlign = TextAlign.Center,
          )
        }
        Text(
            text = stringResource(R.string.mock_device_kit_description),
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        HorizontalDivider()

        ActionButton(
            modifier = Modifier.fillMaxWidth(),
            text = stringResource(R.string.pair_rayban_meta),
            onClick = { viewModel.pairRaybanMeta() },
            enabled = uiState.pairedDevices.size < 3,
        )
      }
    }

    if (uiState.pairedDevices.isNotEmpty()) {
      uiState.pairedDevices.forEach { deviceInfo ->
        MockDeviceCard(deviceInfo = deviceInfo, viewModel = viewModel)
      }
    }
  }
}

@Composable
private fun ActionButton(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    containerColor: Color = AppColor.DeepBlue,
    contentColor: Color = Color.White,
) {
  Button(
      modifier = modifier,
      colors =
          ButtonDefaults.buttonColors(
              containerColor = containerColor,
              contentColor = contentColor,
          ),
      onClick = onClick,
      enabled = enabled,
  ) {
    Text(text, fontWeight = FontWeight.Medium)
  }
}

@Composable
private fun StatusText(
    hasContent: Boolean,
    positiveText: String,
    negativeText: String,
    modifier: Modifier = Modifier,
) {
  Text(
      modifier = modifier,
      text = if (hasContent) positiveText else negativeText,
      style = MaterialTheme.typography.bodyMedium,
      color = if (hasContent) AppColor.Green else AppColor.Yellow,
      textAlign = TextAlign.Left,
  )
}

@Composable
private fun MockDeviceCard(
    deviceInfo: MockDeviceInfo,
    viewModel: MockDeviceKitViewModel,
) {
  val videoPickerLauncher =
      rememberLauncherForActivityResult(contract = ActivityResultContracts.GetContent()) { uri: Uri?
        ->
        uri?.let { selectedUri -> viewModel.setCameraFeed(deviceInfo, selectedUri) }
      }
  val imagePickerLauncher =
      rememberLauncherForActivityResult(contract = ActivityResultContracts.GetContent()) { uri: Uri?
        ->
        uri?.let { selectedUri -> viewModel.setCapturedImage(deviceInfo, selectedUri) }
      }

  Card(
      modifier = Modifier.fillMaxWidth(),
      elevation = CardDefaults.cardElevation(defaultElevation = 2.dp),
      colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
  ) {
    Column(modifier = Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
      // Device header
      Row(
          modifier = Modifier.fillMaxWidth(),
          horizontalArrangement = Arrangement.SpaceBetween,
          verticalAlignment = Alignment.CenterVertically,
      ) {
        Column {
          Text(
              text = deviceInfo.deviceName,
              style = MaterialTheme.typography.titleMedium,
              fontWeight = FontWeight.SemiBold,
          )
          Text(
              text = deviceInfo.deviceId,
              style = MaterialTheme.typography.bodySmall,
              color = MaterialTheme.colorScheme.onSurfaceVariant,
          )
        }
        ActionButton(
            text = stringResource(R.string.unpair),
            onClick = { viewModel.unpairDevice(deviceInfo) },
            containerColor = AppColor.Red,
        )
      }

      HorizontalDivider()

      // Power controls
      Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        ActionButton(
            text = stringResource(R.string.power_on),
            onClick = { viewModel.powerOn(deviceInfo) },
            modifier = Modifier.weight(1f),
        )
        ActionButton(
            text = stringResource(R.string.power_off),
            onClick = { viewModel.powerOff(deviceInfo) },
            modifier = Modifier.weight(1f),
        )
      }

      // Fold/Unfold controls
      Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        ActionButton(
            text = stringResource(R.string.unfold),
            onClick = { viewModel.unfold(deviceInfo) },
            modifier = Modifier.weight(1f),
        )
        ActionButton(
            text = stringResource(R.string.fold),
            onClick = { viewModel.fold(deviceInfo) },
            modifier = Modifier.weight(1f),
        )
      }

      // Don/Doff controls
      Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        ActionButton(
            text = stringResource(R.string.don),
            onClick = { viewModel.don(deviceInfo) },
            modifier = Modifier.weight(1f),
        )
        ActionButton(
            text = stringResource(R.string.doff),
            onClick = { viewModel.doff(deviceInfo) },
            modifier = Modifier.weight(1f),
        )
      }

      // Media selection buttons
      Row(
          modifier = Modifier.fillMaxWidth(),
          horizontalArrangement = Arrangement.spacedBy(8.dp),
          verticalAlignment = Alignment.CenterVertically,
      ) {
        ActionButton(
            text = stringResource(R.string.select_video),
            onClick = { videoPickerLauncher.launch("video/*") },
            modifier = Modifier.weight(1f),
        )
        StatusText(
            hasContent = deviceInfo.hasCameraFeed,
            positiveText = stringResource(R.string.has_camera_feed),
            negativeText = stringResource(R.string.no_camera_feed),
            modifier = Modifier.weight(1f).padding(start = 8.dp),
        )
      }

      Row(
          modifier = Modifier.fillMaxWidth(),
          horizontalArrangement = Arrangement.spacedBy(8.dp),
          verticalAlignment = Alignment.CenterVertically,
      ) {
        ActionButton(
            text = stringResource(R.string.select_image),
            onClick = { imagePickerLauncher.launch("image/*") },
            modifier = Modifier.weight(1f),
        )
        StatusText(
            hasContent = deviceInfo.hasCapturedImage,
            positiveText = stringResource(R.string.has_captured_image),
            negativeText = stringResource(R.string.no_captured_image),
            modifier = Modifier.weight(1f).padding(start = 8.dp),
        )
      }
    }
  }
}
