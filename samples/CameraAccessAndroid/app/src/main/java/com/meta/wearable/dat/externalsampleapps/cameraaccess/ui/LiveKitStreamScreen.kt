package com.meta.wearable.dat.externalsampleapps.cameraaccess.ui

import androidx.activity.compose.BackHandler
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.sizeIn
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Call
import androidx.compose.material.icons.filled.CallEnd
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.meta.wearable.dat.externalsampleapps.cameraaccess.livekit.AgentStatus
import com.meta.wearable.dat.externalsampleapps.cameraaccess.livekit.LiveKitSessionViewModel
import com.meta.wearable.dat.externalsampleapps.cameraaccess.livekit.LiveKitUiState
import com.meta.wearable.dat.externalsampleapps.cameraaccess.livekit.SessionState
import io.livekit.android.renderer.TextureViewRenderer
import io.livekit.android.room.Room
import io.livekit.android.room.track.VideoTrack
import livekit.org.webrtc.RendererCommon

/**
 * Phone-mode main screen under LiveKit, and the app's front door: the camera
 * preview + call button IS the home screen. Joins the room on sight -- camera,
 * mic and the assistant all come up together; everything intelligent lives
 * server-side.
 */
@Composable
fun LiveKitStreamScreen(
    onOpenSettings: () -> Unit,
    modifier: Modifier = Modifier,
    // Glasses mode is entered from the DAT connection flow, so back returns
    // there; phone mode is the app's root and back exits like iOS.
    onExitGlasses: (() -> Unit)? = null,
    viewModel: LiveKitSessionViewModel = viewModel(),
) {
    val uiState by viewModel.uiState.collectAsStateWithLifecycle()

    LaunchedEffect(Unit) {
        if (!viewModel.autoStartIfNeeded()) {
            // Re-entering from Settings: apply an engine switch by redialing,
            // and make sure the between-calls preview is up.
            viewModel.redialIfEngineChanged()
            viewModel.startPreview()
        }
    }

    if (onExitGlasses != null) {
        BackHandler { onExitGlasses() }
    }

    Box(modifier = modifier.fillMaxSize().background(Color.Black)) {
        val track = uiState.displayTrack
        if (track != null) {
            // Pinch zoom drives the phone camera; glasses have no camera
            // control, so the gesture is not installed for them.
            val zoomModifier = if (uiState.isGlassesSource) {
                Modifier
            } else {
                Modifier.pointerInput(Unit) {
                    detectTransformGestures { _, _, zoom, _ -> viewModel.zoomBy(zoom) }
                }
            }
            VideoTrackView(
                room = viewModel.room,
                track = track,
                modifier = Modifier
                    .fillMaxSize()
                    .then(zoomModifier)
                    .pointerInput(Unit) {
                        detectTapGestures(onLongPress = { viewModel.toggleFreeze() })
                    },
            )
        }

        if (uiState.isGlassesSource && !uiState.glassesStreaming &&
            uiState.frozenFrame == null && uiState.state != SessionState.Connecting &&
            uiState.state !is SessionState.Failed
        ) {
            Column(
                modifier = Modifier.align(Alignment.Center).padding(horizontal = 32.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Text(
                    text = "Waiting for glasses video",
                    color = Color.White,
                    fontSize = 17.sp,
                    fontWeight = FontWeight.SemiBold,
                )
                Text(
                    text = "Video will appear when your glasses start streaming.",
                    color = Color.White.copy(alpha = 0.7f),
                    fontSize = 13.sp,
                    textAlign = TextAlign.Center,
                )
            }
        }

        if (uiState.zoomFactor > 1.05f) {
            Text(
                text = String.format("%.1fx", uiState.zoomFactor),
                color = Color.White,
                fontSize = 13.sp,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier
                    .align(Alignment.TopStart)
                    .statusBarsPadding()
                    .padding(start = 16.dp, top = 16.dp)
                    .background(Color.Black.copy(alpha = 0.45f), RoundedCornerShape(50))
                    .padding(horizontal = 10.dp, vertical = 6.dp),
            )
        }

        when (val state = uiState.state) {
            is SessionState.Failed -> {
                Column(
                    modifier = Modifier.align(Alignment.Center).padding(horizontal = 32.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    Text(
                        text = "Not connected",
                        color = Color.White,
                        fontSize = 17.sp,
                        fontWeight = FontWeight.SemiBold,
                    )
                    Text(
                        text = state.message,
                        color = Color.White.copy(alpha = 0.7f),
                        fontSize = 13.sp,
                        textAlign = TextAlign.Center,
                    )
                }
            }
            SessionState.Connecting -> {
                Column(
                    modifier = Modifier.align(Alignment.Center),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(16.dp),
                ) {
                    CircularProgressIndicator(color = Color.White)
                    Text(
                        text = "Connecting",
                        color = Color.White.copy(alpha = 0.7f),
                        fontSize = 15.sp,
                    )
                }
            }
            else -> {}
        }

        // Pinned frame floats as a card over the still-live view: the user
        // keeps their bearings, and the caption doubles as the release
        // affordance. The model is seeing nothing newer than this frame, so
        // screen and model agree on what "this" means.
        uiState.frozenFrame?.let { frozen ->
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .background(Color.Black.copy(alpha = 0.55f))
                    .clickable { viewModel.unfreeze() },
                contentAlignment = Alignment.Center,
            ) {
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(16.dp),
                ) {
                    Image(
                        bitmap = frozen.asImageBitmap(),
                        contentDescription = "Frozen frame",
                        modifier = Modifier
                            .sizeIn(maxWidth = 300.dp, maxHeight = 480.dp)
                            .clip(RoundedCornerShape(20.dp))
                            .border(2.dp, Color.White.copy(alpha = 0.9f), RoundedCornerShape(20.dp)),
                    )
                    Text(
                        text = "Tap anywhere to return to live",
                        color = Color.White.copy(alpha = 0.85f),
                        fontSize = 15.sp,
                    )
                }
            }
        }

        // Agent liveness, top and center: a call can connect perfectly and
        // still be an empty room if the worker never dispatches. The pill
        // makes the difference visible -- stuck on "Waiting for agent" means
        // the backend is down, not that the model is ignoring you.
        if (uiState.state == SessionState.Connected && uiState.agentStatus != AgentStatus.NONE) {
            AgentStatusPill(
                status = uiState.agentStatus,
                modifier = Modifier
                    .align(Alignment.TopCenter)
                    .statusBarsPadding()
                    .padding(top = 16.dp),
            )
        }

        IconButton(
            onClick = onOpenSettings,
            modifier = Modifier
                .align(Alignment.TopEnd)
                .statusBarsPadding()
                .padding(end = 8.dp),
        ) {
            Icon(
                imageVector = Icons.Default.Settings,
                contentDescription = "Settings",
                tint = Color.White.copy(alpha = 0.85f),
                modifier = Modifier
                    .background(Color.Black.copy(alpha = 0.35f), CircleShape)
                    .padding(8.dp),
            )
        }

        // Shutter front and center: pinning what you see is the primary act.
        Box(
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .navigationBarsPadding()
                .padding(bottom = 24.dp),
        ) {
            FreezeButton(
                isFrozen = uiState.frozenFrame != null,
                onClick = { viewModel.toggleFreeze() },
            )
        }
        Row(
            modifier = Modifier
                .align(Alignment.BottomStart)
                .navigationBarsPadding()
                .padding(start = 24.dp, bottom = 32.dp),
        ) {
            LiveKitCallButton(
                uiState = uiState,
                onStart = { viewModel.start() },
                onStop = { viewModel.stop() },
            )
        }
    }
}

/** Renders a local video track full-bleed through the SDK's TextureView. */
@Composable
private fun VideoTrackView(
    room: Room,
    track: VideoTrack,
    modifier: Modifier = Modifier,
) {
    var renderer by remember { mutableStateOf<TextureViewRenderer?>(null) }

    AndroidView(
        modifier = modifier,
        factory = { context ->
            TextureViewRenderer(context).also {
                room.initVideoRenderer(it)
                it.setScalingType(RendererCommon.ScalingType.SCALE_ASPECT_FILL)
                renderer = it
            }
        },
    )

    DisposableEffect(track, renderer) {
        val view = renderer
        view?.let { track.addRenderer(it) }
        onDispose { view?.let { track.removeRenderer(it) } }
    }

    DisposableEffect(Unit) {
        onDispose { renderer?.release() }
    }
}

/** One glance answers "is anything actually listening to me right now?" */
@Composable
private fun AgentStatusPill(
    status: AgentStatus,
    modifier: Modifier = Modifier,
) {
    val label = when (status) {
        AgentStatus.WAITING -> "Waiting for agent"
        AgentStatus.STARTING -> "Agent starting"
        AgentStatus.LISTENING -> "Listening"
        AgentStatus.THINKING -> "Thinking"
        AgentStatus.SPEAKING -> "Speaking"
        AgentStatus.LEFT -> "Agent left the call"
        AgentStatus.NONE -> ""
    }
    val dotColor = when (status) {
        AgentStatus.LISTENING -> AppColor.Green
        AgentStatus.THINKING -> AppColor.Yellow
        AgentStatus.SPEAKING -> AppColor.DeepBlue
        AgentStatus.LEFT -> AppColor.Red
        else -> null
    }

    Row(
        modifier = modifier
            .background(Color.Black.copy(alpha = 0.45f), RoundedCornerShape(50)),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Box(modifier = Modifier.padding(start = 12.dp)) {
            if (dotColor != null) {
                Box(
                    modifier = Modifier
                        .size(8.dp)
                        .clip(CircleShape)
                        .background(dotColor),
                )
            } else {
                CircularProgressIndicator(
                    modifier = Modifier.size(12.dp),
                    color = Color.White,
                    strokeWidth = 2.dp,
                )
            }
        }
        Text(
            text = label,
            color = Color.White,
            fontSize = 13.sp,
            fontWeight = FontWeight.SemiBold,
            modifier = Modifier.padding(end = 12.dp, top = 7.dp, bottom = 7.dp),
        )
    }
}

/** Same call semantics as before: green to connect, red to hang up. */
@Composable
private fun LiveKitCallButton(
    uiState: LiveKitUiState,
    onStart: () -> Unit,
    onStop: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val connecting = uiState.state == SessionState.Connecting
    Box(
        modifier = modifier
            .size(48.dp)
            .clip(CircleShape)
            .background(if (uiState.isActive) AppColor.Red.copy(alpha = 0.9f) else AppColor.Green.copy(alpha = 0.9f))
            .clickable(enabled = !connecting) {
                if (uiState.isActive) onStop() else onStart()
            },
        contentAlignment = Alignment.Center,
    ) {
        if (connecting) {
            CircularProgressIndicator(
                modifier = Modifier.size(20.dp),
                color = Color.White,
                strokeWidth = 2.dp,
            )
        } else {
            Icon(
                imageVector = if (uiState.isActive) Icons.Default.CallEnd else Icons.Default.Call,
                contentDescription = if (uiState.isActive) "End call" else "Start call",
                tint = Color.White,
            )
        }
    }
}

/** Camera-app shutter: tap to pin the current frame, tap again to release. */
@Composable
private fun FreezeButton(
    isFrozen: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val color = if (isFrozen) AppColor.Yellow else Color.White
    val innerSize by animateDpAsState(if (isFrozen) 50.dp else 54.dp, label = "shutter")
    Box(
        modifier = modifier
            .size(68.dp)
            .border(4.dp, color, CircleShape)
            .clip(CircleShape)
            .clickable { onClick() },
        contentAlignment = Alignment.Center,
    ) {
        Box(
            modifier = Modifier
                .size(innerSize)
                .clip(CircleShape)
                .background(color),
        )
    }
}
