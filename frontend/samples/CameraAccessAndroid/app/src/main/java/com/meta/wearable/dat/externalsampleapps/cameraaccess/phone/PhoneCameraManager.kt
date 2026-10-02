package com.meta.wearable.dat.externalsampleapps.cameraaccess.phone

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Matrix
import android.util.Size
import android.util.Log
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleOwner
import java.util.concurrent.Executors

class PhoneCameraManager(private val context: Context) {
    companion object {
        private const val TAG = "PhoneCameraManager"
        private const val FRAME_INTERVAL_MS = 200L
    }

    var onFrameCaptured: ((Bitmap) -> Unit)? = null
    var onError: ((String) -> Unit)? = null

    private var cameraProvider: ProcessCameraProvider? = null
    private val executor = Executors.newSingleThreadExecutor()
    private var lastFrameAt = 0L

    fun start(lifecycleOwner: LifecycleOwner) {
        val cameraProviderFuture = ProcessCameraProvider.getInstance(context)
        cameraProviderFuture.addListener({
            try {
                cameraProvider = cameraProviderFuture.get()

                val imageAnalysis = ImageAnalysis.Builder()
                    .setTargetResolution(Size(640, 480))
                    .setOutputImageFormat(ImageAnalysis.OUTPUT_IMAGE_FORMAT_RGBA_8888)
                    .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                    .setImageQueueDepth(1)
                    .build()

                imageAnalysis.setAnalyzer(executor) { imageProxy ->
                    val now = System.currentTimeMillis()
                    if (now - lastFrameAt >= FRAME_INTERVAL_MS) {
                        lastFrameAt = now
                        val bitmap = imageProxyToBitmap(imageProxy)
                        if (bitmap != null) {
                            onFrameCaptured?.invoke(bitmap)
                        }
                    }
                    imageProxy.close()
                }

                val cameraSelector = CameraSelector.DEFAULT_BACK_CAMERA
                cameraProvider?.unbindAll()
                cameraProvider?.bindToLifecycle(
                    lifecycleOwner,
                    cameraSelector,
                    imageAnalysis,
                )

                Log.d(TAG, "Phone camera started")
            } catch (e: Exception) {
                val message = "Failed to start camera: ${e.message}"
                Log.e(TAG, message, e)
                onError?.invoke(message)
            }
        }, ContextCompat.getMainExecutor(context))
    }

    fun stop() {
        cameraProvider?.unbindAll()
        cameraProvider = null
        Log.d(TAG, "Phone camera stopped")
    }

    private fun imageProxyToBitmap(imageProxy: ImageProxy): Bitmap? {
        return try {
            val width = imageProxy.width
            val height = imageProxy.height
            val plane = imageProxy.planes[0]
            val buffer = plane.buffer
            buffer.rewind()
            val rowStride = plane.rowStride
            val pixelStride = plane.pixelStride
            val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)

            if (rowStride == width * pixelStride) {
                bitmap.copyPixelsFromBuffer(buffer)
            } else {
                val row = ByteArray(rowStride)
                val pixels = IntArray(width * height)
                for (y in 0 until height) {
                    buffer.get(row, 0, rowStride)
                    for (x in 0 until width) {
                        val offset = x * pixelStride
                        val r = row[offset].toInt() and 0xFF
                        val g = row[offset + 1].toInt() and 0xFF
                        val b = row[offset + 2].toInt() and 0xFF
                        val a = row[offset + 3].toInt() and 0xFF
                        pixels[y * width + x] =
                            (a shl 24) or (r shl 16) or (g shl 8) or b
                    }
                }
                bitmap.setPixels(pixels, 0, width, 0, 0, width, height)
            }

            // Rotate based on image rotation
            val rotation = imageProxy.imageInfo.rotationDegrees
            if (rotation != 0) {
                val matrix = Matrix()
                matrix.postRotate(rotation.toFloat())
                val rotated = Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
                if (rotated != bitmap) bitmap.recycle()
                rotated
            } else {
                bitmap
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to convert image: ${e.message}", e)
            null
        }
    }
}
