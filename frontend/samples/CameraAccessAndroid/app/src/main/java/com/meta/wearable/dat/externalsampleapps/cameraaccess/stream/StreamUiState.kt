/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

// StreamUiState - DAT Camera Streaming UI State
//
// This data class manages UI state for camera streaming operations using the DAT API.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.stream

import android.graphics.Bitmap
import com.meta.wearable.dat.camera.types.StreamSessionState

enum class StreamingMode { GLASSES, PHONE }

data class StreamUiState(
    val streamSessionState: StreamSessionState = StreamSessionState.STOPPED,
    val videoFrame: Bitmap? = null,
    val capturedPhoto: Bitmap? = null,
    val isShareDialogVisible: Boolean = false,
    val isCapturing: Boolean = false,
    val streamingMode: StreamingMode = StreamingMode.GLASSES,
    val errorMessage: String? = null,
)
