/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

// HomeScreen - DAT Registration Entry Point

package com.meta.wearable.dat.externalsampleapps.cameraaccess.ui

import android.widget.Toast
import androidx.activity.compose.LocalActivity
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.meta.wearable.dat.externalsampleapps.cameraaccess.R
import com.meta.wearable.dat.externalsampleapps.cameraaccess.wearables.WearablesViewModel

@Composable
fun HomeScreen(
    viewModel: WearablesViewModel,
    modifier: Modifier = Modifier,
) {
  val scrollState = rememberScrollState()
  val activity = LocalActivity.current
  val context = LocalContext.current

  Box(modifier = modifier.fillMaxSize()) {
    // Settings gear (top-right)
    Box(modifier = Modifier.align(Alignment.TopEnd).systemBarsPadding().padding(8.dp)) {
      IconButton(onClick = { viewModel.showSettings() }) {
        Icon(
            imageVector = Icons.Default.Settings,
            contentDescription = "Settings",
            tint = Color.Gray,
            modifier = Modifier.size(28.dp),
        )
      }
    }

    Column(
        modifier =
            Modifier
                .fillMaxSize()
                .verticalScroll(scrollState)
                .padding(all = 24.dp)
                .navigationBarsPadding(),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(24.dp),
    ) {
      Spacer(modifier = Modifier.weight(1f))
      Column(
          horizontalAlignment = Alignment.CenterHorizontally,
          verticalArrangement = Arrangement.spacedBy(8.dp),
      ) {
        Icon(
            painter = painterResource(id = R.drawable.camera_access_icon),
            contentDescription = stringResource(R.string.camera_access_icon_description),
            tint = AppColor.DeepBlue,
            modifier = Modifier.size(80.dp * LocalDensity.current.density),
        )
        Text(
            text = stringResource(R.string.home_app_title),
            fontSize = 32.sp,
            fontWeight = FontWeight.Bold,
            textAlign = TextAlign.Center,
        )
        Text(
            text = stringResource(R.string.home_app_tagline),
            color = Color.Gray,
            textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp),
        )
        Column(
            verticalArrangement = Arrangement.spacedBy(12.dp),
            modifier = Modifier.fillMaxWidth().padding(horizontal = 10.dp, vertical = 8.dp),
        ) {
          TipItem(
              iconResId = R.drawable.smart_glasses_icon,
              title = stringResource(R.string.home_tip_video_title),
              text = stringResource(R.string.home_tip_video),
          )
          TipItem(
              iconResId = R.drawable.sound_icon,
              title = stringResource(R.string.home_tip_audio_title),
              text = stringResource(R.string.home_tip_audio),
          )
          TipItem(
              iconResId = R.drawable.tap_icon,
              title = stringResource(R.string.home_tip_hands_title),
              text = stringResource(R.string.home_tip_hands),
          )
        }
      }
      Spacer(modifier = Modifier.weight(1f))

      Column(
          verticalArrangement = Arrangement.spacedBy(12.dp),
      ) {
        // App Registration Button
        Text(
            text = stringResource(R.string.home_redirect_message),
            color = Color.Gray,
            textAlign = TextAlign.Center,
            modifier = Modifier.padding(horizontal = 24.dp),
        )
        SwitchButton(
            label = stringResource(R.string.register_button_title),
            onClick = {
              activity?.let { viewModel.startRegistration(it) }
                  ?: Toast.makeText(context, "Activity not available", Toast.LENGTH_SHORT).show()
            },
        )

        // Phone mode button
        SwitchButton(
            label = "Start on Phone",
            onClick = { viewModel.navigateToPhoneMode() },
        )
      }
    }
  }
}

@Composable
private fun TipItem(
    iconResId: Int,
    title: String,
    text: String,
    modifier: Modifier = Modifier,
) {
  Row(modifier = modifier.fillMaxWidth()) {
    Icon(
        painter = painterResource(id = iconResId),
        contentDescription = "Tip icon",
        modifier = Modifier.padding(start = 4.dp, top = 4.dp).width(24.dp),
    )
    Spacer(modifier = Modifier.width(12.dp))
    Column(
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
      Text(
          text = title,
          fontSize = 20.sp,
          fontWeight = FontWeight.SemiBold,
      )
      Text(text = text, color = Color.Gray)
    }
  }
}
