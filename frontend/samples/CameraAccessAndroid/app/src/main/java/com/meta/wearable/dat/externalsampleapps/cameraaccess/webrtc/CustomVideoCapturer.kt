package com.meta.wearable.dat.externalsampleapps.cameraaccess.webrtc

import android.graphics.Bitmap
import android.util.Log
import org.webrtc.JavaI420Buffer
import org.webrtc.SurfaceTextureHelper
import org.webrtc.VideoCapturer
import org.webrtc.VideoFrame
import org.webrtc.VideoSource
import java.nio.ByteBuffer

/**
 * Custom video capturer that converts Android Bitmaps (from DAT SDK / phone camera)
 * into WebRTC VideoFrames and feeds them to a VideoSource.
 *
 * Replaces iOS CustomVideoCapturer.swift which converts UIImage -> CVPixelBuffer -> RTCVideoFrame.
 */
class CustomVideoCapturer {
    companion object {
        private const val TAG = "CustomVideoCapturer"
    }

    private var videoSource: VideoSource? = null
    private var frameCount: Long = 0

    fun initialize(videoSource: VideoSource) {
        this.videoSource = videoSource
    }

    /**
     * Push a Bitmap frame into the WebRTC video track.
     * Converts ARGB_8888 Bitmap -> I420 YUV -> WebRTC VideoFrame.
     */
    fun pushFrame(bitmap: Bitmap) {
        val source = videoSource ?: return

        val width = bitmap.width
        val height = bitmap.height

        // Extract ARGB pixels
        val argbBuffer = IntArray(width * height)
        bitmap.getPixels(argbBuffer, 0, width, 0, 0, width, height)

        // Allocate I420 buffers
        val ySize = width * height
        val uvSize = (width / 2) * (height / 2)
        val i420Buffer = JavaI420Buffer.allocate(width, height)

        val yBuffer = i420Buffer.dataY
        val uBuffer = i420Buffer.dataU
        val vBuffer = i420Buffer.dataV

        // Convert ARGB -> I420
        var yIndex = 0
        var uvIndex = 0
        for (y in 0 until height) {
            for (x in 0 until width) {
                val pixel = argbBuffer[y * width + x]
                val r = (pixel shr 16) and 0xFF
                val g = (pixel shr 8) and 0xFF
                val b = pixel and 0xFF

                // Y plane
                val yVal = ((66 * r + 129 * g + 25 * b + 128) shr 8) + 16
                yBuffer.put(yIndex++, yVal.coerceIn(0, 255).toByte())

                // U and V planes (subsampled 2x2)
                if (y % 2 == 0 && x % 2 == 0) {
                    val uVal = ((-38 * r - 74 * g + 112 * b + 128) shr 8) + 128
                    val vVal = ((112 * r - 94 * g - 18 * b + 128) shr 8) + 128
                    uBuffer.put(uvIndex, uVal.coerceIn(0, 255).toByte())
                    vBuffer.put(uvIndex, vVal.coerceIn(0, 255).toByte())
                    uvIndex++
                }
            }
        }

        val timestampNs = System.nanoTime()
        val videoFrame = VideoFrame(i420Buffer, 0, timestampNs)
        source.capturerObserver?.onFrameCaptured(videoFrame)
        videoFrame.release()

        frameCount++
        if (frameCount == 1L || frameCount % 120 == 0L) {
            Log.d(TAG, "Pushed frame #$frameCount (${width}x${height})")
        }
    }

    fun dispose() {
        videoSource = null
    }
}
