package com.meta.wearable.dat.externalsampleapps.cameraaccess.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.wrapContentWidth
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.IosShare
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.PowerSettingsNew
import androidx.compose.material.icons.filled.StopCircle
import androidx.compose.material.icons.filled.Videocam
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

@Composable
fun ControlsRow(
    onStopStream: () -> Unit,
    onToggleAI: () -> Unit,
    isAIActive: Boolean,
    aiEnabled: Boolean,
    onToggleRecording: () -> Unit,
    isRecording: Boolean,
    isRecordingProcessing: Boolean,
    onToggleLive: () -> Unit,
    isLiveActive: Boolean,
    onShareLive: () -> Unit,
    canShareLive: Boolean,
    modifier: Modifier = Modifier,
) {
    Surface(
        modifier = modifier.fillMaxWidth(),
        color = Color.White,
        shape = RoundedCornerShape(18.dp),
        tonalElevation = 2.dp,
        shadowElevation = 4.dp,
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 10.dp, vertical = 10.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            ControlButton(
                label = "종료",
                icon = {
                    Icon(
                        imageVector = Icons.Default.PowerSettingsNew,
                        contentDescription = "Stop stream",
                    )
                },
                onClick = onStopStream,
                containerColor = AppColor.DestructiveBackground,
                contentColor = AppColor.DestructiveForeground,
                modifier = Modifier.weight(1f),
            )

            ControlButton(
                label = if (isAIActive) "AI ON" else "AI",
                icon = {
                    Icon(
                        imageVector = Icons.Default.AutoAwesome,
                        contentDescription = if (isAIActive) "Stop AI" else "Start AI",
                    )
                },
                onClick = onToggleAI,
                enabled = aiEnabled,
                containerColor = if (isAIActive) AppColor.Green else Color(0xFFEAF1FB),
                contentColor = if (isAIActive) Color.White else Color(0xFF1B263B),
                modifier = Modifier.weight(1f),
            )

            ControlButton(
                label = when {
                    isRecordingProcessing -> "정리 중"
                    isRecording -> "회의 중"
                    else -> "회의"
                },
                icon = {
                    Icon(
                        imageVector = if (isRecording) Icons.Default.StopCircle else Icons.Default.Mic,
                        contentDescription = if (isRecording) "Stop meeting recording" else "Start meeting recording",
                    )
                },
                onClick = onToggleRecording,
                enabled = !isRecordingProcessing,
                containerColor = when {
                    isRecordingProcessing -> Color(0xFFFFF3D9)
                    isRecording -> AppColor.Red
                    else -> Color(0xFFEAF1FB)
                },
                contentColor = when {
                    isRecordingProcessing -> Color(0xFF7A5A00)
                    isRecording -> Color.White
                    else -> Color(0xFF1B263B)
                },
                modifier = Modifier.weight(1f),
            )

            ControlButton(
                label = if (isLiveActive) "Live ON" else "Live",
                icon = {
                    Icon(
                        imageVector = Icons.Default.Videocam,
                        contentDescription = if (isLiveActive) "Stop Live" else "Start Live",
                    )
                },
                onClick = onToggleLive,
                containerColor = if (isLiveActive) AppColor.DeepBlue else Color(0xFFEAF1FB),
                contentColor = if (isLiveActive) Color.White else Color(0xFF1B263B),
                modifier = Modifier.weight(1f),
            )

            if (canShareLive) {
                ControlButton(
                    label = "공유",
                    icon = {
                        Icon(
                            imageVector = Icons.Default.IosShare,
                            contentDescription = "Share Live",
                        )
                    },
                    onClick = onShareLive,
                    containerColor = Color(0xFFE8F6EA),
                    contentColor = Color(0xFF1E6B32),
                    modifier = Modifier.weight(1f),
                )
            }
        }
    }
}

@Composable
private fun ControlButton(
    label: String,
    icon: @Composable () -> Unit,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    containerColor: Color,
    contentColor: Color,
) {
    Button(
        onClick = onClick,
        enabled = enabled,
        modifier = modifier.height(72.dp),
        shape = RoundedCornerShape(16.dp),
        colors = ButtonDefaults.buttonColors(
            containerColor = containerColor,
            contentColor = contentColor,
            disabledContainerColor = Color(0xFFE5EAF1),
            disabledContentColor = Color(0xFF8A97A8),
        ),
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center,
        ) {
            Box(
                modifier = Modifier
                    .size(24.dp)
                    .wrapContentWidth(),
                contentAlignment = Alignment.Center,
            ) {
                icon()
            }
            Text(
                text = label,
                fontSize = 11.sp,
                fontWeight = FontWeight.Medium,
                textAlign = TextAlign.Center,
                modifier = Modifier.widthIn(min = 32.dp),
                maxLines = 1,
            )
        }
    }
}
