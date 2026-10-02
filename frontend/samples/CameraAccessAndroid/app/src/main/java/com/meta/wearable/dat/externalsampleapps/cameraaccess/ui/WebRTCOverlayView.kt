package com.meta.wearable.dat.externalsampleapps.cameraaccess.ui

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.widget.Toast
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.meta.wearable.dat.externalsampleapps.cameraaccess.webrtc.WebRTCConnectionState
import com.meta.wearable.dat.externalsampleapps.cameraaccess.webrtc.WebRTCUiState
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

@Composable
fun WebRTCOverlay(
    uiState: WebRTCUiState,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier.fillMaxWidth().padding(horizontal = 16.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        // Status pill
        StatusPill(
            label = when (uiState.connectionState) {
                is WebRTCConnectionState.Connected -> "Live"
                is WebRTCConnectionState.Connecting -> "Connecting..."
                is WebRTCConnectionState.WaitingForPeer -> "Waiting..."
                is WebRTCConnectionState.Backgrounded -> "Paused"
                is WebRTCConnectionState.Error -> "Error"
                is WebRTCConnectionState.Disconnected -> "Off"
            },
            color = when (uiState.connectionState) {
                is WebRTCConnectionState.Connected -> Color(0xFF4CAF50)
                is WebRTCConnectionState.Connecting,
                is WebRTCConnectionState.WaitingForPeer -> Color(0xFFFF9800)
                is WebRTCConnectionState.Backgrounded -> Color(0xFFFF9800)
                is WebRTCConnectionState.Error -> Color(0xFFF44336)
                is WebRTCConnectionState.Disconnected -> Color(0xFF9E9E9E)
            },
        )

        // Room code pill (tap to copy)
        if (uiState.viewerUrl.isNotEmpty()) {
            ShareLinkPill(url = uiState.viewerUrl)
            ShareLiveLinkButton(url = uiState.viewerUrl)
        }

        // Mic status
        if (uiState.connectionState is WebRTCConnectionState.Connected) {
            StatusPill(
                label = if (uiState.isMuted) "Muted" else "Mic On",
                color = if (uiState.isMuted) Color(0xFFF44336) else Color(0xFF4CAF50),
            )
        }
    }
}

@Composable
fun ShareLinkPill(
    url: String,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var showCopied by remember { mutableStateOf(false) }

    Row(
        modifier = modifier
            .background(Color.Black.copy(alpha = 0.6f), RoundedCornerShape(12.dp))
            .clickable {
                val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                clipboard.setPrimaryClip(ClipData.newPlainText("Jarvis Live View", url))
                showCopied = true
                Toast.makeText(context, "Live link copied", Toast.LENGTH_SHORT).show()
                scope.launch {
                    delay(1500)
                    showCopied = false
                }
            }
            .padding(horizontal = 12.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Text(
            text = if (showCopied) "Copied" else "Live Link",
            color = if (showCopied) Color(0xFF4CAF50) else Color.White,
            fontSize = 14.sp,
            fontWeight = FontWeight.Bold,
        )
    }
}

@Composable
fun ShareLiveLinkButton(url: String) {
    val context = LocalContext.current
    Text(
        text = "Share",
        color = Color.White,
        fontSize = 14.sp,
        fontWeight = FontWeight.Bold,
        modifier = Modifier
            .background(Color.Black.copy(alpha = 0.6f), RoundedCornerShape(12.dp))
            .clickable {
                val intent = Intent(Intent.ACTION_SEND).apply {
                    type = "text/plain"
                    putExtra(Intent.EXTRA_TEXT, "Jarvis live view: $url")
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                context.startActivity(Intent.createChooser(intent, "Share live link"))
            }
            .padding(horizontal = 12.dp, vertical = 4.dp),
    )
}
