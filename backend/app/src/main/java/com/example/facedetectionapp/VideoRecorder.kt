package com.example.facedetectionapp

import android.graphics.Bitmap
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import android.view.Surface

/**
 * MediaCodec + MediaMuxer 기반 MP4 녹화기.
 * feedBitmap() 으로 프레임을 넣으면 H.264 인코딩 후 MP4에 기록한다.
 */
class VideoRecorder {

    private var encoder: MediaCodec? = null
    private var inputSurface: Surface? = null
    private var muxer: MediaMuxer? = null
    private var trackIndex = -1
    private var muxerStarted = false
    private var startPtsUs = -1L

    val isStarted: Boolean get() = encoder != null

    fun start(outputPath: String, width: Int = 1280, height: Int = 720, fps: Int = 24) {
        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height).apply {
            setInteger(MediaFormat.KEY_BIT_RATE, 2_500_000)
            setInteger(MediaFormat.KEY_FRAME_RATE, fps)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 2)
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
        }
        val enc = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
        enc.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        inputSurface = enc.createInputSurface()
        enc.start()
        encoder = enc
        muxer = MediaMuxer(outputPath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
    }

    fun feedBitmap(bitmap: Bitmap) {
        val surface = inputSurface ?: return
        try {
            val canvas = surface.lockCanvas(null)
            canvas.drawBitmap(bitmap, 0f, 0f, null)
            surface.unlockCanvasAndPost(canvas)
        } catch (_: Exception) {
            return
        }
        drainEncoder(false)
    }

    fun stop() {
        try {
            drainEncoder(true)
            encoder?.stop()
            encoder?.release()
            if (muxerStarted) muxer?.stop()
            muxer?.release()
        } catch (_: Exception) {
        } finally {
            encoder = null
            muxer = null
            inputSurface = null
            trackIndex = -1
            muxerStarted = false
            startPtsUs = -1L
        }
    }

    private fun drainEncoder(endOfStream: Boolean) {
        val enc = encoder ?: return
        val mux = muxer ?: return
        if (endOfStream) {
            try { enc.signalEndOfInputStream() } catch (_: Exception) { return }
        }
        val info = MediaCodec.BufferInfo()
        loop@ while (true) {
            val timeout = if (endOfStream) 100_000L else 5_000L
            when (val idx = enc.dequeueOutputBuffer(info, timeout)) {
                MediaCodec.INFO_TRY_AGAIN_LATER -> if (!endOfStream) break@loop
                MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    trackIndex = mux.addTrack(enc.outputFormat)
                    mux.start()
                    muxerStarted = true
                }
                else -> if (idx >= 0) {
                    if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) {
                        enc.releaseOutputBuffer(idx, false)
                        continue@loop
                    }
                    if (muxerStarted && info.size > 0) {
                        val buf = enc.getOutputBuffer(idx)!!
                        if (startPtsUs < 0L) startPtsUs = info.presentationTimeUs
                        info.presentationTimeUs -= startPtsUs
                        mux.writeSampleData(trackIndex, buf, info)
                    }
                    enc.releaseOutputBuffer(idx, false)
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) break@loop
                }
            }
        }
    }
}
