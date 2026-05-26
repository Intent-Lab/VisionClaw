/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

package com.meta.wearable.dat.externalsampleapps.cameraaccess.ui

import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.LocalActivity
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.PhotoLibrary
import androidx.compose.material.icons.filled.Videocam
import androidx.compose.material.icons.filled.VideocamOff
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import kotlinx.coroutines.launch
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.meta.wearable.dat.externalsampleapps.cameraaccess.gallery.CapturedPhoto
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.meta.wearable.dat.camera.types.StreamSessionState
import com.meta.wearable.dat.externalsampleapps.cameraaccess.R
import com.meta.wearable.dat.externalsampleapps.cameraaccess.gemini.GeminiSessionViewModel
import com.meta.wearable.dat.externalsampleapps.cameraaccess.stream.StreamViewModel
import com.meta.wearable.dat.externalsampleapps.cameraaccess.settings.SettingsManager
import com.meta.wearable.dat.externalsampleapps.cameraaccess.stream.StreamingMode
import com.meta.wearable.dat.externalsampleapps.cameraaccess.wearables.WearablesViewModel
import com.meta.wearable.dat.externalsampleapps.cameraaccess.webrtc.WebRTCSessionViewModel

@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
fun StreamScreen(
    wearablesViewModel: WearablesViewModel,
    isPhoneMode: Boolean = false,
    modifier: Modifier = Modifier,
    streamViewModel: StreamViewModel =
        viewModel(
            factory =
                StreamViewModel.Factory(
                    application = (LocalActivity.current as ComponentActivity).application,
                    wearablesViewModel = wearablesViewModel,
                ),
        ),
    geminiViewModel: GeminiSessionViewModel = viewModel(),
    webrtcViewModel: WebRTCSessionViewModel = viewModel(),
) {
    val streamUiState by streamViewModel.uiState.collectAsStateWithLifecycle()
    val geminiUiState by geminiViewModel.uiState.collectAsStateWithLifecycle()
    val webrtcUiState by webrtcViewModel.uiState.collectAsStateWithLifecycle()
    val captureEvent by geminiViewModel.captureEvent.collectAsStateWithLifecycle()
    val lifecycleOwner = LocalLifecycleOwner.current
    val context = LocalContext.current

    // Gallery navigation state
    var showGallery by remember { mutableStateOf(false) }
    var selectedGalleryPhoto by remember { mutableStateOf<CapturedPhoto?>(null) }

    // Show toast when photo is captured via Gemini
    LaunchedEffect(captureEvent) {
        captureEvent?.let {
            Toast.makeText(context, "Photo captured", Toast.LENGTH_SHORT).show()
        }
    }

    // Wire Gemini VM to Stream VM for frame forwarding
    LaunchedEffect(geminiViewModel) {
        streamViewModel.geminiViewModel = geminiViewModel
    }

    // Wire WebRTC VM to Stream VM for frame forwarding
    LaunchedEffect(webrtcViewModel) {
        streamViewModel.webrtcViewModel = webrtcViewModel
    }

    var videoStreamingEnabled by remember { mutableStateOf(SettingsManager.videoStreamingEnabled) }
    val tabOptions = listOf("Camera", "Chat")
    val pagerState = rememberPagerState(pageCount = { 2 })
    val coroutineScope = rememberCoroutineScope()

    // Auto-switch to chat tab when Gemini starts in audio-only mode
    LaunchedEffect(geminiUiState.isGeminiActive) {
        if (geminiUiState.isGeminiActive && !SettingsManager.videoStreamingEnabled) {
            pagerState.animateScrollToPage(1)
        }
    }

    // Start stream or phone camera
    LaunchedEffect(isPhoneMode, videoStreamingEnabled) {
        geminiViewModel.streamingMode = if (isPhoneMode) StreamingMode.PHONE else StreamingMode.GLASSES
        streamViewModel.setStreamingMode(if (isPhoneMode) StreamingMode.PHONE else StreamingMode.GLASSES)

        if (videoStreamingEnabled) {
            if (isPhoneMode) {
                streamViewModel.startPhoneCamera(lifecycleOwner)
            } else {
                streamViewModel.startStream()
            }
        } else {
            streamViewModel.setVideoStreamingEnabled(false, lifecycleOwner)
        }
    }

    // Clean up on exit
    DisposableEffect(Unit) {
        onDispose {
            if (geminiUiState.isGeminiActive) {
                geminiViewModel.stopSession()
            }
            if (webrtcUiState.isActive) {
                webrtcViewModel.stopSession()
            }
        }
    }

    // Show errors as toasts
    LaunchedEffect(geminiUiState.errorMessage) {
        geminiUiState.errorMessage?.let { msg ->
            Toast.makeText(context, msg, Toast.LENGTH_LONG).show()
            geminiViewModel.clearError()
        }
    }
    LaunchedEffect(webrtcUiState.errorMessage) {
        webrtcUiState.errorMessage?.let { msg ->
            Toast.makeText(context, msg, Toast.LENGTH_LONG).show()
            webrtcViewModel.clearError()
        }
    }

    Box(modifier = modifier.fillMaxSize()) {
        HorizontalPager(
            state = pagerState,
            modifier = Modifier.fillMaxSize(),
        ) { page ->
            Box(modifier = Modifier.fillMaxSize()) {
                if (page == 0) {
                    // --- Camera tab ---
                    streamUiState.videoFrame?.let { videoFrame ->
                        Image(
                            bitmap = videoFrame.asImageBitmap(),
                            contentDescription = stringResource(R.string.live_stream),
                            modifier = Modifier.fillMaxSize(),
                            contentScale = ContentScale.Crop,
                        )
                    }

                    if (streamUiState.videoFrame == null && !videoStreamingEnabled) {
                        Text(
                            text = "Audio-only mode\nAll video streaming is off.",
                            modifier = Modifier.align(Alignment.Center),
                        )
                    }

                    if (streamUiState.streamSessionState == StreamSessionState.STARTING) {
                        CircularProgressIndicator(
                            modifier = Modifier.align(Alignment.Center),
                        )
                    }
                } else {
                    // --- Chat tab ---
                    ChatTranscriptView(
                        messages = geminiUiState.messages,
                        modifier = Modifier.padding(top = 100.dp, bottom = 80.dp),
                    )
                }
            }
        }

        // Overlays + controls
        Box(modifier = Modifier.fillMaxSize().padding(horizontal = 16.dp)) {
            // Top overlays (below status bar)
            Column(modifier = Modifier.align(Alignment.TopStart).statusBarsPadding().padding(top = 8.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Surface(
                        shape = CircleShape,
                        color = Color.Black.copy(alpha = 0.5f),
                        modifier = Modifier.size(36.dp)
                    ) {
                        IconButton(onClick = {
                            val newEnabled = !videoStreamingEnabled
                            SettingsManager.videoStreamingEnabled = newEnabled
                            videoStreamingEnabled = newEnabled
                        }) {
                            Icon(
                                imageVector = if (videoStreamingEnabled) Icons.Default.Videocam else Icons.Default.VideocamOff,
                                contentDescription = if (videoStreamingEnabled) "Switch to audio-only" else "Enable video",
                                tint = Color.White,
                                modifier = Modifier.size(18.dp)
                            )
                        }
                    }

                    Spacer(modifier = Modifier.weight(1f))

                    // Tab switcher (centered)
                    SingleChoiceSegmentedButtonRow {
                        tabOptions.forEachIndexed { index, label ->
                            SegmentedButton(
                                shape = SegmentedButtonDefaults.itemShape(index = index, count = tabOptions.size),
                                onClick = { coroutineScope.launch { pagerState.animateScrollToPage(index) } },
                                selected = pagerState.currentPage == index,
                            ) {
                                Text(label)
                            }
                        }
                    }

                    Spacer(modifier = Modifier.weight(1f))

                    // Gallery button (top right)
                    Surface(
                        shape = CircleShape,
                        color = Color.Black.copy(alpha = 0.5f),
                        modifier = Modifier.size(36.dp)
                    ) {
                        IconButton(onClick = { showGallery = true }) {
                            Icon(
                                Icons.Default.PhotoLibrary,
                                contentDescription = "Gallery",
                                tint = Color.White,
                                modifier = Modifier.size(18.dp)
                            )
                        }
                    }
                }

                Spacer(modifier = Modifier.height(8.dp))

                // Gemini overlay (camera tab only)
                if (geminiUiState.isGeminiActive && pagerState.currentPage == 0) {
                    GeminiOverlay(uiState = geminiUiState)
                }

                // WebRTC overlay
                if (webrtcUiState.isActive && pagerState.currentPage == 0) {
                    Spacer(modifier = Modifier.height(4.dp))
                    WebRTCOverlay(uiState = webrtcUiState)
                }
            }

            // Controls at bottom
            ControlsRow(
                onStopStream = {
                    if (geminiUiState.isGeminiActive) geminiViewModel.stopSession()
                    if (webrtcUiState.isActive) webrtcViewModel.stopSession()
                    streamViewModel.stopStream()
                    wearablesViewModel.navigateToDeviceSelection()
                },
                onToggleAI = {
                    if (geminiUiState.isGeminiActive) {
                        geminiViewModel.stopSession()
                    } else {
                        geminiViewModel.startSession()
                    }
                },
                isAIActive = geminiUiState.isGeminiActive,
                onToggleMic = { geminiViewModel.toggleMic() },
                isMicEnabled = geminiUiState.isMicEnabled,
                modifier = Modifier.align(Alignment.BottomCenter),
            )
        }
    }

    // Share photo dialog
    streamUiState.capturedPhoto?.let { photo ->
        if (streamUiState.isShareDialogVisible) {
            SharePhotoDialog(
                photo = photo,
                onDismiss = { streamViewModel.hideShareDialog() },
                onShare = { bitmap ->
                    streamViewModel.sharePhoto(bitmap)
                    streamViewModel.hideShareDialog()
                },
            )
        }
    }

    // Gallery as full-screen overlay (not replacing StreamScreen, so session stays alive)
    if (showGallery || selectedGalleryPhoto != null) {
        if (selectedGalleryPhoto != null) {
            GalleryDetailScreen(
                photo = selectedGalleryPhoto!!,
                onBack = { selectedGalleryPhoto = null }
            )
        } else {
            GalleryScreen(
                onBack = { showGallery = false },
                onPhotoSelected = { selectedGalleryPhoto = it }
            )
        }
    }
}
