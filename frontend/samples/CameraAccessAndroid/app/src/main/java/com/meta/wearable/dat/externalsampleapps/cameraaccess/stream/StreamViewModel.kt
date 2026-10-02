/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

package com.meta.wearable.dat.externalsampleapps.cameraaccess.stream

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

import android.app.Application
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageFormat
import android.graphics.Matrix
import android.graphics.Rect
import android.graphics.YuvImage
import android.os.SystemClock
import android.util.Log
import androidx.core.content.FileProvider
import androidx.exifinterface.media.ExifInterface
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import com.meta.wearable.dat.camera.StreamSession
import com.meta.wearable.dat.camera.startStreamSession
import com.meta.wearable.dat.camera.types.PhotoData
import com.meta.wearable.dat.camera.types.StreamConfiguration
import com.meta.wearable.dat.camera.types.StreamSessionState
import com.meta.wearable.dat.camera.types.VideoFrame
import com.meta.wearable.dat.camera.types.VideoQuality
import com.meta.wearable.dat.core.Wearables
import com.meta.wearable.dat.core.selectors.DeviceSelector
import com.meta.wearable.dat.externalsampleapps.cameraaccess.gemini.GeminiSessionViewModel
import com.meta.wearable.dat.externalsampleapps.cameraaccess.openclaw.VisualMemoryFrameStore
import com.meta.wearable.dat.externalsampleapps.cameraaccess.phone.PhoneCameraManager
import com.meta.wearable.dat.externalsampleapps.cameraaccess.wearables.WearablesViewModel
import com.meta.wearable.dat.externalsampleapps.cameraaccess.webrtc.WebRTCSessionViewModel
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import kotlinx.coroutines.Job
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.conflate
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class StreamViewModel(
    application: Application,
    private val wearablesViewModel: WearablesViewModel,
) : AndroidViewModel(application) {

  companion object {
    private const val TAG = "StreamViewModel"
    private const val GLASSES_START_TIMEOUT_MS = 12_000L
    private const val GLASSES_FRAME_INTERVAL_MS = 100L
    private const val GLASSES_FRAME_LOG_INTERVAL_MS = 5_000L
    private const val GLASSES_STABLE_RESET_MS = 30_000L
    private val INITIAL_STATE = StreamUiState()
  }

  private val deviceSelector: DeviceSelector = wearablesViewModel.deviceSelector
  private var streamSession: StreamSession? = null

  private val _uiState = MutableStateFlow(INITIAL_STATE)
  val uiState: StateFlow<StreamUiState> = _uiState.asStateFlow()

  private var videoJob: Job? = null
  private var stateJob: Job? = null
  private var startTimeoutJob: Job? = null
  private var isStreamingServiceRunning = false
    private var hasReachedGlassesStreaming = false
    private var lastGlassesFrameAt = 0L
    private var lastGlassesFrameLogAt = 0L
    private var userRequestedStop = false
  private var autoRestartJob: Job? = null
  private var autoRestartAttempts = 0
  private var stableStreamJob: Job? = null

  // VisionClaw additions
  var geminiViewModel: GeminiSessionViewModel? = null
  var webrtcViewModel: WebRTCSessionViewModel? = null
  private var phoneCameraManager: PhoneCameraManager? = null

  fun startStream() {
    userRequestedStop = false
    stopActiveStream()
    hasReachedGlassesStreaming = false
    _uiState.update {
      it.copy(
        streamingMode = StreamingMode.GLASSES,
        streamSessionState = StreamSessionState.STARTING,
        errorMessage = null,
      )
    }

    VisualMemoryFrameStore.freshStillProvider = ::captureFreshVisualFrame
    Log.d(TAG, "Starting glasses stream session with HIGH/30fps")
    val streamSession =
        Wearables.startStreamSession(
                getApplication(),
                deviceSelector,
                StreamConfiguration(videoQuality = VideoQuality.HIGH, 30),
            )
            .also { streamSession = it }
    _uiState.update { it.copy(streamingMode = StreamingMode.GLASSES) }
    videoJob =
        viewModelScope.launch {
          streamSession.videoStream
              .conflate()
              .collectLatest { handleVideoFrame(it) }
        }
    startTimeoutJob =
        viewModelScope.launch {
          delay(GLASSES_START_TIMEOUT_MS)
          if (
              _uiState.value.streamingMode == StreamingMode.GLASSES &&
                  _uiState.value.streamSessionState != StreamSessionState.STREAMING
          ) {
            Log.w(TAG, "Glasses stream did not reach STREAMING before timeout")
            stopActiveStream()
            _uiState.update {
              it.copy(
                  streamingMode = StreamingMode.GLASSES,
                  streamSessionState = StreamSessionState.STOPPED,
                  errorMessage =
                      "Glasses stream did not start. Reconnect the glasses/Meta AI app, then try Start Streaming again.",
              )
            }
          }
        }
    stateJob =
        viewModelScope.launch {
          streamSession.state.collect { currentState ->
            val prevState = _uiState.value.streamSessionState
            Log.d(TAG, "Glasses stream state: $prevState -> $currentState")
            _uiState.update { it.copy(streamSessionState = currentState) }

            if (currentState == StreamSessionState.STREAMING && !isStreamingServiceRunning) {
              hasReachedGlassesStreaming = true
              startTimeoutJob?.cancel()
              startTimeoutJob = null
              scheduleStableStreamReset()
              StreamingService.start(getApplication())
              isStreamingServiceRunning = true
            }

            if (
                currentState != prevState &&
                    currentState == StreamSessionState.STOPPED &&
                    hasReachedGlassesStreaming &&
                    !userRequestedStop
            ) {
              _uiState.update {
                it.copy(
                  errorMessage =
                      "Glasses video stream stopped. Check Bluetooth, Meta AI app connection, and camera permission.",
                )
              }
              if (isStreamingServiceRunning) {
                StreamingService.stop(getApplication())
                  isStreamingServiceRunning = false
              }
              scheduleGlassesStreamRestart()
            }
          }
        }
  }

  fun startPhoneCamera(lifecycleOwner: LifecycleOwner) {
    val manager = PhoneCameraManager(getApplication())
    phoneCameraManager = manager
    VisualMemoryFrameStore.freshStillProvider = ::captureFreshVisualFrame

    manager.onFrameCaptured = { bitmap ->
      _uiState.update { it.copy(videoFrame = bitmap, errorMessage = null) }
      // Forward to Gemini (throttled inside the VM)
      geminiViewModel?.sendVideoFrameIfThrottled(bitmap)
      // Forward to WebRTC (every frame)
      webrtcViewModel?.pushVideoFrame(bitmap)
    }
    manager.onError = { message ->
      _uiState.update { it.copy(errorMessage = message) }
      Log.e(TAG, message)
    }

    _uiState.update {
      it.copy(
        streamingMode = StreamingMode.PHONE,
        streamSessionState = StreamSessionState.STREAMING,
        errorMessage = null,
      )
    }
    manager.start(lifecycleOwner)
    Log.d(TAG, "Phone camera mode started")
  }

  fun stopStream() {
    userRequestedStop = true
    autoRestartJob?.cancel()
    autoRestartJob = null
    stableStreamJob?.cancel()
    stableStreamJob = null
    stopActiveStream()
    _uiState.update { INITIAL_STATE }
  }

  private fun stopActiveStream() {
    startTimeoutJob?.cancel()
    startTimeoutJob = null

    if (isStreamingServiceRunning) {
      StreamingService.stop(getApplication())
      isStreamingServiceRunning = false
    }

    videoJob?.cancel()
    videoJob = null
    stateJob?.cancel()
    stateJob = null
    stableStreamJob?.cancel()
    stableStreamJob = null
    streamSession?.close()
    streamSession = null
    phoneCameraManager?.stop()
    phoneCameraManager = null
    VisualMemoryFrameStore.freshStillProvider = null
    lastGlassesFrameAt = 0L
    lastGlassesFrameLogAt = 0L
  }

  private fun scheduleGlassesStreamRestart() {
    if (autoRestartJob?.isActive == true) return
    if (autoRestartAttempts >= 2) {
      _uiState.update {
        it.copy(
            errorMessage =
                "Glasses video stream stopped repeatedly. Reconnect Bluetooth/Meta AI app, then start streaming again.",
        )
      }
      return
    }
    autoRestartAttempts += 1
    autoRestartJob =
        viewModelScope.launch {
          Log.w(TAG, "Auto-restarting glasses stream attempt $autoRestartAttempts")
          delay(1_500L)
          if (!userRequestedStop && _uiState.value.streamingMode == StreamingMode.GLASSES) {
            startStream()
          }
        }
  }

  private fun scheduleStableStreamReset() {
    stableStreamJob?.cancel()
    stableStreamJob =
        viewModelScope.launch {
          delay(GLASSES_STABLE_RESET_MS)
          if (
              !userRequestedStop &&
                  _uiState.value.streamingMode == StreamingMode.GLASSES &&
                  _uiState.value.streamSessionState == StreamSessionState.STREAMING
          ) {
            autoRestartAttempts = 0
            Log.d(TAG, "Glasses stream stable for ${GLASSES_STABLE_RESET_MS}ms; restart counter reset")
          }
        }
  }

  private val photoCaptureMutex = Mutex()

  fun capturePhoto() {
    if (uiState.value.isCapturing) {
      Log.d(TAG, "Photo capture already in progress, ignoring request")
      return
    }

    if (uiState.value.streamSessionState == StreamSessionState.STREAMING) {
      // Phone mode: capture current video frame as photo
      if (uiState.value.streamingMode == StreamingMode.PHONE) {
        uiState.value.videoFrame?.let { frame ->
          _uiState.update { it.copy(capturedPhoto = frame, isShareDialogVisible = true) }
        }
        return
      }

      Log.d(TAG, "Starting photo capture")
      _uiState.update { it.copy(isCapturing = true) }

      viewModelScope.launch {
        try {
          val result = photoCaptureMutex.withLock {
            currentCoroutineContext().ensureActive()
            withContext(NonCancellable) { streamSession?.capturePhoto() }
          }
          currentCoroutineContext().ensureActive()
          result?.onSuccess { photoData -> handlePhotoData(photoData) }
              ?.onFailure { Log.e(TAG, "Photo capture failed") }
        } finally {
          _uiState.update { it.copy(isCapturing = false) }
        }
      }
    } else {
      Log.w(
          TAG,
          "Cannot capture photo: stream not active (state=${uiState.value.streamSessionState})",
      )
    }
  }

  fun showShareDialog() {
    _uiState.update { it.copy(isShareDialogVisible = true) }
  }

  fun hideShareDialog() {
    _uiState.update { it.copy(isShareDialogVisible = false) }
  }

  fun sharePhoto(bitmap: Bitmap) {
    val context = getApplication<Application>()
    val imagesFolder = File(context.cacheDir, "images")
    try {
      imagesFolder.mkdirs()
      val file = File(imagesFolder, "shared_image.png")
      FileOutputStream(file).use { stream ->
        bitmap.compress(Bitmap.CompressFormat.PNG, 90, stream)
      }

      val uri = FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)
      val intent = Intent(Intent.ACTION_SEND)
      intent.flags = Intent.FLAG_ACTIVITY_NEW_TASK
      intent.putExtra(Intent.EXTRA_STREAM, uri)
      intent.type = "image/png"
      intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)

      val chooser = Intent.createChooser(intent, "Share Image")
      chooser.flags = Intent.FLAG_ACTIVITY_NEW_TASK
      context.startActivity(chooser)
    } catch (e: IOException) {
      Log.e("StreamViewModel", "Failed to share photo", e)
    }
  }

  private suspend fun handleVideoFrame(videoFrame: VideoFrame) {
    val now = SystemClock.elapsedRealtime()
    if (now - lastGlassesFrameAt < GLASSES_FRAME_INTERVAL_MS) {
      return
    }
    lastGlassesFrameAt = now

    if (now - lastGlassesFrameLogAt >= GLASSES_FRAME_LOG_INTERVAL_MS) {
      Log.d(TAG, "Glasses frame ${videoFrame.width}x${videoFrame.height}")
      lastGlassesFrameLogAt = now
    }

    // VideoFrame contains raw I420 video data in a ByteBuffer
    val buffer = videoFrame.buffer
    val dataSize = buffer.remaining()
    val byteArray = ByteArray(dataSize)

    // Save current position
    val originalPosition = buffer.position()
    buffer.get(byteArray)
    // Restore position
    buffer.position(originalPosition)

    val bitmap = withContext(Dispatchers.Default) {
      decodeI420FrameToBitmap(byteArray, videoFrame.width, videoFrame.height)
    } ?: return
    _uiState.update { it.copy(videoFrame = bitmap) }

    // Forward to Gemini (throttled inside the VM)
    geminiViewModel?.sendVideoFrameIfThrottled(bitmap)
    // Forward to WebRTC only after the glasses frame rate is reduced above.
    webrtcViewModel?.pushVideoFrame(bitmap)
  }

  private suspend fun captureFreshVisualFrame(): VisualMemoryFrameStore.VisualFrame? {
    return when (_uiState.value.streamingMode) {
      StreamingMode.PHONE -> {
        _uiState.value.videoFrame?.let {
          _uiState.update { state -> state.copy(capturedPhoto = it) }
          VisualMemoryFrameStore.bitmapToVisualFrame(it, "phone_camera_still")
        }
      }
      StreamingMode.GLASSES -> {
        try {
          // DAT video delivery trails the real scene. Capture only after the spoken request has
          // completed and allow the glasses camera pipeline to catch up before taking the still.
          delay(2000L)
          val photoData = photoCaptureMutex.withLock {
            currentCoroutineContext().ensureActive()
            withContext(NonCancellable) { streamSession?.capturePhoto()?.getOrNull() }
          } ?: return null
          currentCoroutineContext().ensureActive()
          val bitmap = withContext(Dispatchers.Default) { photoDataToBitmap(photoData) }
          _uiState.update { state -> state.copy(capturedPhoto = bitmap) }
          VisualMemoryFrameStore.bitmapToVisualFrame(bitmap, "glasses_capture_photo")
        } catch (e: CancellationException) {
          throw e
        } catch (e: Exception) {
          Log.w(TAG, "Fresh glasses photo capture failed, falling back to latest frame: ${e.message}")
          null
        }
      }
    }
  }

  private fun decodeI420FrameToBitmap(byteArray: ByteArray, width: Int, height: Int): Bitmap? {
    return try {
      // Convert I420 to NV21 format which is supported by Android's YuvImage.
      val nv21 = convertI420toNV21(byteArray, width, height)
      val image = YuvImage(nv21, ImageFormat.NV21, width, height, null)
      val out =
          ByteArrayOutputStream().use { stream ->
            image.compressToJpeg(Rect(0, 0, width, height), 45, stream)
            stream.toByteArray()
          }
      BitmapFactory.decodeByteArray(out, 0, out.size)
    } catch (e: Exception) {
      Log.e(TAG, "Failed to decode glasses video frame: ${e.message}", e)
      null
    }
  }

  // Convert I420 (YYYYYYYY:UUVV) to NV21 (YYYYYYYY:VUVU)
  private fun convertI420toNV21(input: ByteArray, width: Int, height: Int): ByteArray {
    val output = ByteArray(input.size)
    val size = width * height
    val quarter = size / 4

    input.copyInto(output, 0, 0, size) // Y is the same

    for (n in 0 until quarter) {
      output[size + n * 2] = input[size + quarter + n] // V first
      output[size + n * 2 + 1] = input[size + n] // U second
    }
    return output
  }

  private fun handlePhotoData(photo: PhotoData) {
    val capturedPhoto = photoDataToBitmap(photo)
    _uiState.update { it.copy(capturedPhoto = capturedPhoto, isShareDialogVisible = true) }
  }

  private fun photoDataToBitmap(photo: PhotoData): Bitmap =
      when (photo) {
        is PhotoData.Bitmap -> photo.bitmap
        is PhotoData.HEIC -> {
          val byteArray = ByteArray(photo.data.remaining())
          photo.data.get(byteArray)

          // Extract EXIF transformation matrix and apply to bitmap.
          val exifInfo = getExifInfo(byteArray)
          val transform = getTransform(exifInfo)
          decodeHeic(byteArray, transform)
        }
      }

  // HEIC Decoding with EXIF transformation
  private fun decodeHeic(heicBytes: ByteArray, transform: Matrix): Bitmap {
    val bitmap = BitmapFactory.decodeByteArray(heicBytes, 0, heicBytes.size)
    return applyTransform(bitmap, transform)
  }

  private fun getExifInfo(heicBytes: ByteArray): ExifInterface? {
    return try {
      ByteArrayInputStream(heicBytes).use { inputStream -> ExifInterface(inputStream) }
    } catch (e: IOException) {
      Log.w(TAG, "Failed to read EXIF from HEIC", e)
      null
    }
  }

  private fun getTransform(exifInfo: ExifInterface?): Matrix {
    val matrix = Matrix()

    if (exifInfo == null) {
      return matrix // Identity matrix (no transformation)
    }

    when (
        exifInfo.getAttributeInt(
            ExifInterface.TAG_ORIENTATION,
            ExifInterface.ORIENTATION_NORMAL,
        )
    ) {
      ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> {
        matrix.postScale(-1f, 1f)
      }
      ExifInterface.ORIENTATION_ROTATE_180 -> {
        matrix.postRotate(180f)
      }
      ExifInterface.ORIENTATION_FLIP_VERTICAL -> {
        matrix.postScale(1f, -1f)
      }
      ExifInterface.ORIENTATION_TRANSPOSE -> {
        matrix.postRotate(90f)
        matrix.postScale(-1f, 1f)
      }
      ExifInterface.ORIENTATION_ROTATE_90 -> {
        matrix.postRotate(90f)
      }
      ExifInterface.ORIENTATION_TRANSVERSE -> {
        matrix.postRotate(270f)
        matrix.postScale(-1f, 1f)
      }
      ExifInterface.ORIENTATION_ROTATE_270 -> {
        matrix.postRotate(270f)
      }
      ExifInterface.ORIENTATION_NORMAL,
      ExifInterface.ORIENTATION_UNDEFINED -> {
        // No transformation needed
      }
    }

    return matrix
  }

  private fun applyTransform(bitmap: Bitmap, matrix: Matrix): Bitmap {
    if (matrix.isIdentity) {
      return bitmap
    }

    return try {
      val transformed = Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
      if (transformed != bitmap) {
        bitmap.recycle()
      }
      transformed
    } catch (e: OutOfMemoryError) {
      Log.e(TAG, "Failed to apply transformation due to memory", e)
      bitmap
    }
  }

  override fun onCleared() {
    super.onCleared()
    stopStream()
    stateJob?.cancel()
  }

  class Factory(
      private val application: Application,
      private val wearablesViewModel: WearablesViewModel,
  ) : ViewModelProvider.Factory {
    override fun <T : ViewModel> create(modelClass: Class<T>): T {
      if (modelClass.isAssignableFrom(StreamViewModel::class.java)) {
        @Suppress("UNCHECKED_CAST", "KotlinGenericsCast")
        return StreamViewModel(
            application = application,
            wearablesViewModel = wearablesViewModel,
        )
            as T
      }
      throw IllegalArgumentException("Unknown ViewModel class")
    }
  }
}
