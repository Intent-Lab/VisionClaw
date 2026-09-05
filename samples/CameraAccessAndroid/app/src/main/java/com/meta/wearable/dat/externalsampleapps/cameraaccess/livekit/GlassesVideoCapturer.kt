package com.meta.wearable.dat.externalsampleapps.cameraaccess.livekit

import android.content.Context
import java.nio.ByteBuffer
import livekit.org.webrtc.CapturerObserver
import livekit.org.webrtc.JavaI420Buffer
import livekit.org.webrtc.SurfaceTextureHelper
import livekit.org.webrtc.VideoCapturer
import livekit.org.webrtc.VideoFrame

/**
 * Feeds DAT glasses frames into a LiveKit video track. The capture hardware
 * is the glasses stream itself, so start/stop only gate frame delivery; the
 * DAT streaming session's lifecycle is owned by LiveKitSessionViewModel.
 */
class GlassesVideoCapturer : VideoCapturer {
    private var observer: CapturerObserver? = null

    @Volatile private var capturing = false

    override fun initialize(
        surfaceTextureHelper: SurfaceTextureHelper?,
        context: Context?,
        capturerObserver: CapturerObserver?,
    ) {
        observer = capturerObserver
    }

    override fun startCapture(width: Int, height: Int, framerate: Int) {
        capturing = true
        observer?.onCapturerStarted(true)
    }

    override fun stopCapture() {
        capturing = false
        observer?.onCapturerStopped()
    }

    override fun changeCaptureFormat(width: Int, height: Int, framerate: Int) {}

    override fun dispose() {
        capturing = false
        observer = null
    }

    override fun isScreencast(): Boolean = false

    /**
     * DAT delivers raw I420 planar buffers (Y, then U, then V, contiguous).
     * Copied into a WebRTC-owned buffer because the DAT buffer is only valid
     * for the duration of the emission.
     */
    fun pushI420(src: ByteBuffer, width: Int, height: Int) {
        val observer = observer ?: return
        if (!capturing) return
        if (width <= 0 || height <= 0 || width % 2 != 0 || height % 2 != 0) return
        val ySize = width * height
        val chromaSize = ySize / 4
        val base = src.position()
        if (src.remaining() < ySize + 2 * chromaSize) return

        val i420 = JavaI420Buffer.allocate(width, height)
        val dup = src.duplicate()
        dup.limit(base + ySize)
        dup.position(base)
        i420.dataY.put(dup)
        dup.limit(base + ySize + chromaSize)
        dup.position(base + ySize)
        i420.dataU.put(dup)
        dup.limit(base + ySize + 2 * chromaSize)
        dup.position(base + ySize + chromaSize)
        i420.dataV.put(dup)

        val frame = VideoFrame(i420, 0, System.nanoTime())
        observer.onFrameCaptured(frame)
        frame.release()
    }
}
