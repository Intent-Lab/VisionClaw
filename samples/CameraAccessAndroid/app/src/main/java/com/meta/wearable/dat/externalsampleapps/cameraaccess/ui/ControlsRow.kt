package com.meta.wearable.dat.externalsampleapps.cameraaccess.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.MicOff
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp

@Composable
fun ControlsRow(
    onStopStream: () -> Unit,
    onToggleAI: () -> Unit,
    isAIActive: Boolean,
    onToggleMic: () -> Unit,
    isMicEnabled: Boolean,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier
            .navigationBarsPadding()
            .fillMaxWidth()
            .height(56.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        SwitchButton(
            label = "Stop",
            onClick = onStopStream,
            isDestructive = true,
            modifier = Modifier.weight(1f),
        )

        // AI toggle button
        Button(
            onClick = onToggleAI,
            modifier = Modifier.aspectRatio(1f),
            colors = ButtonDefaults.buttonColors(
                containerColor = if (isAIActive) AppColor.Green else AppColor.DeepBlue,
            ),
            shape = CircleShape,
            contentPadding = PaddingValues(0.dp),
        ) {
            Icon(
                imageVector = Icons.Default.AutoAwesome,
                contentDescription = if (isAIActive) "Stop AI" else "Start AI",
                tint = Color.White,
            )
        }

        // Mic toggle button (only meaningful when AI is active)
        Button(
            onClick = onToggleMic,
            enabled = isAIActive,
            modifier = Modifier.aspectRatio(1f),
            colors = ButtonDefaults.buttonColors(
                containerColor = if (!isAIActive) AppColor.DeepBlue
                else if (isMicEnabled) AppColor.DeepBlue
                else AppColor.Red,
                disabledContainerColor = AppColor.DeepBlue,
            ),
            shape = CircleShape,
            contentPadding = PaddingValues(0.dp),
        ) {
            Icon(
                imageVector = if (isMicEnabled) Icons.Default.Mic else Icons.Default.MicOff,
                contentDescription = if (isMicEnabled) "Mute Mic" else "Unmute Mic",
                tint = Color.White,
            )
        }

    }
}