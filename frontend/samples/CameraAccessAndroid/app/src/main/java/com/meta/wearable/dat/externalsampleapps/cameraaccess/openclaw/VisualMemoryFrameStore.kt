package com.meta.wearable.dat.externalsampleapps.cameraaccess.openclaw

import android.graphics.Bitmap
import android.util.Base64
import java.io.ByteArrayOutputStream

object VisualMemoryFrameStore {
    private const val JPEG_QUALITY = 82
    private const val STILL_JPEG_QUALITY = 94
    private const val MAX_FRESH_FRAME_AGE_MS = 1_200L

    data class VisualFrame(
        val base64: String,
        val capturedAtMs: Long,
        val ageMs: Long,
        val source: String,
        val width: Int,
        val height: Int,
        val jpegBytes: Int,
    )

    @Volatile
    private var latestJpeg: ByteArray? = null

    @Volatile
    private var latestCapturedAtMs: Long = 0L

    @Volatile
    private var latestWidth: Int = 0

    @Volatile
    private var latestHeight: Int = 0

    @Volatile
    var freshStillProvider: (suspend () -> VisualFrame?)? = null

    fun update(bitmap: Bitmap) {
        val output = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.JPEG, JPEG_QUALITY, output)
        latestJpeg = output.toByteArray()
        latestCapturedAtMs = System.currentTimeMillis()
        latestWidth = bitmap.width
        latestHeight = bitmap.height
    }

    fun latestBase64(): String? {
        val jpeg = latestJpeg ?: return null
        return Base64.encodeToString(jpeg, Base64.NO_WRAP)
    }

    fun latestCapturedAtMs(): Long = latestCapturedAtMs

    fun latestAgeMs(nowMs: Long = System.currentTimeMillis()): Long? {
        if (latestJpeg == null || latestCapturedAtMs == 0L) return null
        return nowMs - latestCapturedAtMs
    }

    fun isLatestFresh(nowMs: Long = System.currentTimeMillis()): Boolean {
        val ageMs = latestAgeMs(nowMs) ?: return false
        return ageMs <= MAX_FRESH_FRAME_AGE_MS
    }

    suspend fun captureFreshVisual(): VisualFrame? {
        freshStillProvider?.invoke()?.let { return it }
        val nowMs = System.currentTimeMillis()
        val jpeg = latestJpeg ?: return null
        val ageMs = latestAgeMs(nowMs) ?: return null
        if (ageMs > MAX_FRESH_FRAME_AGE_MS) return null
        return VisualFrame(
            base64 = Base64.encodeToString(jpeg, Base64.NO_WRAP),
            capturedAtMs = latestCapturedAtMs,
            ageMs = ageMs,
            source = "latest_video_frame",
            width = latestWidth,
            height = latestHeight,
            jpegBytes = jpeg.size,
        )
    }

    fun bitmapToVisualFrame(bitmap: Bitmap, source: String): VisualFrame {
        val output = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.JPEG, STILL_JPEG_QUALITY, output)
        val jpeg = output.toByteArray()
        val capturedAtMs = System.currentTimeMillis()
        return VisualFrame(
            base64 = Base64.encodeToString(jpeg, Base64.NO_WRAP),
            capturedAtMs = capturedAtMs,
            ageMs = 0L,
            source = source,
            width = bitmap.width,
            height = bitmap.height,
            jpegBytes = jpeg.size,
        )
    }
}
