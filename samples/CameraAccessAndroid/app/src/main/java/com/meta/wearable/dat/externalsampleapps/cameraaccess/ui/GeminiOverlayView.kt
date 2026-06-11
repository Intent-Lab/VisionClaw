package com.meta.wearable.dat.externalsampleapps.cameraaccess.ui

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.meta.wearable.dat.externalsampleapps.cameraaccess.gemini.GeminiConnectionState
import com.meta.wearable.dat.externalsampleapps.cameraaccess.gemini.GeminiUiState
import com.meta.wearable.dat.externalsampleapps.cameraaccess.openclaw.OpenClawConnectionState
import com.meta.wearable.dat.externalsampleapps.cameraaccess.openclaw.ToolCallStatus

@Composable
fun GeminiOverlay(
    uiState: GeminiUiState,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier.fillMaxWidth().padding(horizontal = 16.dp),
    ) {
        // Status bar
        GeminiStatusBar(
            connectionState = uiState.connectionState,
            openClawState = uiState.openClawConnectionState,
        )

        Spacer(modifier = Modifier.height(8.dp))

        // Transcripts
        if (uiState.userTranscript.isNotEmpty() || uiState.aiTranscript.isNotEmpty()) {
            TranscriptView(
                userTranscript = uiState.userTranscript,
                aiTranscript = uiState.aiTranscript,
            )
        }

        // Tool call status
        val toolStatus = uiState.toolCallStatus
        if (toolStatus !is ToolCallStatus.Idle) {
            Spacer(modifier = Modifier.height(4.dp))
            ToolCallStatusView(status = toolStatus)
        }

        // Speaking indicator
        if (uiState.isModelSpeaking) {
            Spacer(modifier = Modifier.height(4.dp))
            SpeakingIndicator()
        }
    }
}

@Composable
fun GeminiStatusBar(
    connectionState: GeminiConnectionState,
    openClawState: OpenClawConnectionState,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        StatusPill(
            label = "AI",
            color = when (connectionState) {
                is GeminiConnectionState.Ready -> Color(0xFF4CAF50)
                is GeminiConnectionState.Connecting,
                is GeminiConnectionState.SettingUp -> Color(0xFFFF9800)
                is GeminiConnectionState.Error -> Color(0xFFF44336)
                is GeminiConnectionState.Disconnected -> Color(0xFF9E9E9E)
            },
        )

        if (openClawState !is OpenClawConnectionState.NotConfigured) {
            StatusPill(
                label = "Video AI Analyst",
                color = when (openClawState) {
                    is OpenClawConnectionState.Connected -> Color(0xFF4CAF50)
                    is OpenClawConnectionState.Checking -> Color(0xFFFF9800)
                    is OpenClawConnectionState.Unreachable -> Color(0xFFF44336)
                    is OpenClawConnectionState.NotConfigured -> Color(0xFF9E9E9E)
                },
            )
        }
    }
}

@Composable
fun StatusPill(
    label: String,
    color: Color,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier
            .background(Color.Black.copy(alpha = 0.6f), RoundedCornerShape(12.dp))
            .padding(horizontal = 10.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Box(
            modifier = Modifier
                .size(8.dp)
                .clip(CircleShape)
                .background(color),
        )
        Text(
            text = label,
            color = Color.White,
            fontSize = 12.sp,
        )
    }
}

@Composable
fun TranscriptView(
    userTranscript: String,
    aiTranscript: String,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier
            .background(Color.Black.copy(alpha = 0.5f), RoundedCornerShape(8.dp))
            .padding(horizontal = 12.dp, vertical = 8.dp),
    ) {
        if (userTranscript.isNotEmpty()) {
            Text(
                text = userTranscript,
                color = Color.White.copy(alpha = 0.6f),
                fontSize = 13.sp,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
        }
        if (aiTranscript.isNotEmpty()) {
            Text(
                text = aiTranscript,
                color = Color.White,
                fontSize = 13.sp,
                maxLines = 3,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

@Composable
fun ToolCallStatusView(
    status: ToolCallStatus,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier
            .background(Color.Black.copy(alpha = 0.5f), RoundedCornerShape(8.dp))
            .padding(horizontal = 12.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        when (status) {
            is ToolCallStatus.Executing -> {
                CircularProgressIndicator(
                    modifier = Modifier.size(14.dp),
                    color = Color.White,
                    strokeWidth = 2.dp,
                )
            }
            is ToolCallStatus.Completed -> {
                Text(text = "[OK]", color = Color(0xFF4CAF50), fontSize = 12.sp, fontFamily = FontFamily.Monospace)
            }
            is ToolCallStatus.Failed -> {
                Text(text = "[X]", color = Color(0xFFF44336), fontSize = 12.sp, fontFamily = FontFamily.Monospace)
            }
            is ToolCallStatus.Cancelled -> {
                Text(text = "[--]", color = Color(0xFFFF9800), fontSize = 12.sp, fontFamily = FontFamily.Monospace)
            }
            else -> {}
        }
        Text(
            text = status.displayText,
            color = Color.White.copy(alpha = 0.8f),
            fontSize = 12.sp,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

@Composable
fun SpeakingIndicator(modifier: Modifier = Modifier) {
    val infiniteTransition = rememberInfiniteTransition(label = "speaking")
    Row(
        modifier = modifier
            .background(Color.Black.copy(alpha = 0.5f), RoundedCornerShape(8.dp))
            .padding(horizontal = 12.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(3.dp),
    ) {
        repeat(4) { index ->
            val height by infiniteTransition.animateFloat(
                initialValue = 4f,
                targetValue = 16f,
                animationSpec = infiniteRepeatable(
                    animation = tween(400, delayMillis = index * 100, easing = LinearEasing),
                    repeatMode = RepeatMode.Reverse,
                ),
                label = "bar$index",
            )
            Box(
                modifier = Modifier
                    .width(3.dp)
                    .height(height.dp)
                    .clip(RoundedCornerShape(1.5.dp))
                    .background(Color.White),
            )
        }
        Spacer(modifier = Modifier.width(6.dp))
        Text(text = "Speaking", color = Color.White.copy(alpha = 0.7f), fontSize = 11.sp)
    }
}
