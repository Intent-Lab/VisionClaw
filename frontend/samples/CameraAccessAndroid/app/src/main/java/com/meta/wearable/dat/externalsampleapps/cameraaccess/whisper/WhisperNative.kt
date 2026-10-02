package com.meta.wearable.dat.externalsampleapps.cameraaccess.whisper

import android.os.Build
import android.util.Log
import java.io.File

class WhisperContext private constructor(private var ptr: Long) {
    suspend fun transcribe(data: FloatArray, language: String = "ko"): String {
        require(ptr != 0L)
        val threads = WhisperCpuConfig.preferredThreadCount
        WhisperNative.fullTranscribe(ptr, threads, language, data)
        val count = WhisperNative.getTextSegmentCount(ptr)
        return buildString {
            for (i in 0 until count) {
                append(WhisperNative.getTextSegment(ptr, i))
            }
        }.trim()
    }

    fun release() {
        if (ptr != 0L) {
            WhisperNative.freeContext(ptr)
            ptr = 0L
        }
    }

    companion object {
        fun create(modelPath: String): WhisperContext {
            val ptr = WhisperNative.initContext(modelPath)
            if (ptr == 0L) {
                throw IllegalStateException("Whisper model load failed: $modelPath")
            }
            return WhisperContext(ptr)
        }
    }
}

class WhisperNative {
    companion object {
        private const val TAG = "WhisperNative"

        init {
            Log.d(TAG, "Primary ABI: ${Build.SUPPORTED_ABIS.firstOrNull().orEmpty()}")
            val cpuInfo = cpuInfo().orEmpty()
            when {
                Build.SUPPORTED_ABIS.firstOrNull() == "armeabi-v7a" && cpuInfo.contains("vfpv4") -> {
                    System.loadLibrary("jarvis_whisper_vfpv4")
                }
                Build.SUPPORTED_ABIS.firstOrNull() == "arm64-v8a" && cpuInfo.contains("fphp") -> {
                    System.loadLibrary("jarvis_whisper_v8fp16_va")
                }
                else -> {
                    System.loadLibrary("jarvis_whisper")
                }
            }
            Log.d(TAG, getSystemInfo())
        }

        external fun initContext(modelPath: String): Long
        external fun freeContext(contextPtr: Long)
        external fun fullTranscribe(
            contextPtr: Long,
            numThreads: Int,
            language: String,
            audioData: FloatArray,
        )
        external fun getTextSegmentCount(contextPtr: Long): Int
        external fun getTextSegment(contextPtr: Long, index: Int): String
        external fun getSystemInfo(): String

        private fun cpuInfo(): String? = try {
            File("/proc/cpuinfo").inputStream().bufferedReader().use { it.readText() }
        } catch (e: Exception) {
            Log.w(TAG, "Couldn't read cpuinfo", e)
            null
        }
    }
}
