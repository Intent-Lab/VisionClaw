package com.example.facedetectionapp


import android.graphics.Bitmap
import androidx.core.graphics.createBitmap
import java.nio.ByteBuffer

internal object YuvToBitmapConverter {

    // Cached buffers to avoid allocations in hot path (single-threaded access from Main thread)
    private var pixels: IntArray = IntArray(0)
    private var yuvBytes: ByteArray = ByteArray(0)
    private var cachedBitmap: Bitmap? = null
    private var lastWidth: Int = 0
    private var lastHeight: Int = 0

    /**
     * Converts I420 YUV data to an ARGB_8888 Bitmap.
     *
     * I420 format: Y plane (width * height bytes), U plane (width/2 * height/2 bytes), V plane
     * (width/2 * height/2 bytes)
     *
     * The convert assumes width and height are even.
     *
     * Optimizations:
     * - Reuses Bitmap across frames
     * - Bulk ByteBuffer copy
     * - Branchless RGB clamping (avoids branch misprediction)
     * - Bit-shift UV indexing (faster than division)
     *
     * @param yuvData The I420 YUV data as a ByteBuffer
     * @param width The width of the image in pixels
     * @param height The height of the image in pixels
     * @return A Bitmap in ARGB_8888 format, or null if conversion fails
     */
    fun convert(yuvData: ByteBuffer, width: Int, height: Int): Bitmap? {
        if (width <= 0 || height <= 0) {
            return null
        }

        if (width % 2 == 1 || height % 2 == 1) {
            return null
        }

        val frameSize = width * height
        val expectedSize = frameSize + (frameSize shr 1) // Y + U + V planes
        if (yuvData.remaining() < expectedSize) {
            return null
        }

        // Resize pixel buffer if needed
        if (pixels.size < frameSize) {
            pixels = IntArray(frameSize)
        }

        // Resize YUV byte array if needed
        if (yuvBytes.size < expectedSize) {
            yuvBytes = ByteArray(expectedSize)
        }

        // Reuse or create bitmap - Bitmap.createBitmap is expensive (~5-10ms)
        val currentBitmap = cachedBitmap
        val bitmap =
            if (
                currentBitmap != null &&
                lastWidth == width &&
                lastHeight == height &&
                !currentBitmap.isRecycled
            ) {
                currentBitmap
            } else {
                currentBitmap?.recycle()
                try {
                    val newBitmap = createBitmap(width, height)
                    cachedBitmap = newBitmap
                    lastWidth = width
                    lastHeight = height
                    newBitmap
                } catch (@Suppress("EmptyCatchBlock") _: OutOfMemoryError) {
                    return null
                }
            }

        // Save buffer position
        val originalPosition = yuvData.position()

        // Bulk copy - single native memcpy instead of millions of JNI calls
        yuvData.get(yuvBytes, 0, expectedSize)

        // Restore buffer position
        yuvData.position(originalPosition)

        // Convert YUV to ARGB
        convertI420ToArgb(yuvBytes, pixels, width, height)

        // Copy pixels to bitmap - faster than createBitmap with pixel array
        bitmap.setPixels(pixels, 0, width, 0, 0, width, height)

        return bitmap
    }

    /**
     * Converts I420 YUV data directly to ARGB pixel array.
     *
     * Uses BT.709 color conversion coefficients with limited range (studio swing): R = 1.164*(Y-16) +
     * 1.793*(V-128) G = 1.164*(Y-16) - 0.213*(U-128) - 0.533*(V-128) B = 1.164*(Y-16) + 2.112*(U-128)
     *
     * BT.709 weights: Kr=0.2126, Kg=0.7152, Kb=0.0722 Limited range: Y scaled by 255/219, UV scaled
     * by 255/224
     *
     * Optimizations:
     * - Bulk ByteBuffer to ByteArray copy (eliminates per-pixel ByteBuffer.get() overhead)
     * - Integer-only arithmetic (fixed-point with 10-bit precision)
     * - Bit-shift division for UV plane indexing
     * - Branchless clamping (eliminates branch misprediction)
     * - Row-based UV caching (reduces redundant calculations)
     */
    private fun convertI420ToArgb(yuvBytes: ByteArray, argbOut: IntArray, width: Int, height: Int) {
        val frameSize = width * height
        val uvPlaneSize = frameSize shr 2

        // Plane offsets within the byte array
        val uOffset = frameSize
        val vOffset = uOffset + uvPlaneSize

        // Fixed-point coefficients (scaled by 1024 = 2^10)
        // BT.709 limited range:
        //   R = 1.164*(Y-16) + 1.793*(V-128)
        //   G = 1.164*(Y-16) - 0.213*(U-128) - 0.533*(V-128)
        //   B = 1.164*(Y-16) + 2.112*(U-128)
        val coeffVr = 1836 // 1.793 * 1024
        val coeffUg = 218 // 0.213 * 1024
        val coeffVg = 546 // 0.533 * 1024
        val coeffUb = 2163 // 2.112 * 1024

        val halfWidth = width shr 1
        var pixelIndex = 0

        for (row in 0 until height) {
            val uvRowOffset = (row shr 1) * halfWidth

            for (col in 0 until width) {
                val uvIndex = uvRowOffset + (col shr 1)

                // Get Y, U, V values
                val y = (yuvBytes[pixelIndex].toInt() and 0xFF) - 16
                val u = (yuvBytes[uOffset + uvIndex].toInt() and 0xFF) - 128
                val v = (yuvBytes[vOffset + uvIndex].toInt() and 0xFF) - 128

                // Scale Y from limited range (16-235) to full range (0-255): 255/219 ≈ 1.164
                val yScaled = (y * 1192) shr 10

                // Calculate RGB using fixed-point arithmetic
                val r = yScaled + ((coeffVr * v) shr 10)
                val g = yScaled - ((coeffUg * u + coeffVg * v) shr 10)
                val b = yScaled + ((coeffUb * u) shr 10)

                // Branchless clamp to 0-255: faster than coerceIn() which uses comparisons
                // Formula: clamp(x) = x - (x and (x shr 31)) - ((x - 255) and ((255 - x) shr 31))
                // Simplified: use min/max bit tricks
                val rClamped = (r and (r shr 31).inv()) or ((255 - r) shr 31 and 255) and 255
                val gClamped = (g and (g shr 31).inv()) or ((255 - g) shr 31 and 255) and 255
                val bClamped = (b and (b shr 31).inv()) or ((255 - b) shr 31 and 255) and 255

                // Pack into ARGB format (0xAARRGGBB)
                argbOut[pixelIndex] =
                    0xFF000000.toInt() or (rClamped shl 16) or (gClamped shl 8) or (bClamped)

                pixelIndex++
            }
        }
    }
}