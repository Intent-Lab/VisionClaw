/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

package com.meta.wearable.dat.externalsampleapps.cameraaccess.ui

import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp

@Composable
fun SwitchButton(
    label: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    isDestructive: Boolean = false,
    enabled: Boolean = true,
) {
  Button(
      modifier = modifier.height(56.dp).fillMaxWidth(),
      onClick = onClick,
      colors =
          ButtonDefaults.buttonColors(
              containerColor =
                  if (isDestructive) AppColor.DestructiveBackground else AppColor.DeepBlue,
              disabledContainerColor = Color.Gray,
              disabledContentColor = Color.DarkGray,
              contentColor = if (isDestructive) AppColor.DestructiveForeground else Color.White,
          ),
      enabled = enabled,
  ) {
    Text(label)
  }
}
