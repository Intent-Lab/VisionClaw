package com.meta.wearable.dat.externalsampleapps.cameraaccess.whisper

import android.util.Log
import java.io.BufferedReader
import java.io.FileReader

object WhisperCpuConfig {
    val preferredThreadCount: Int
        get() = CpuInfo.getHighPerfCpuCount().coerceIn(2, 6)
}

private class CpuInfo(private val lines: List<String>) {
    private fun getHighPerfCpuCount(): Int = try {
        getHighPerfCpuCountByFrequencies()
    } catch (e: Exception) {
        Log.d("WhisperCpuConfig", "Couldn't read CPU frequencies", e)
        Runtime.getRuntime().availableProcessors() - 4
    }

    private fun getHighPerfCpuCountByFrequencies(): Int =
        getCpuValues("processor") { getMaxCpuFrequency(it.toInt()) }
            .sorted()
            .dropWhile { it == getCpuValues("processor") { cpu -> getMaxCpuFrequency(cpu.toInt()) }.minOrNull() }
            .size

    private fun getCpuValues(property: String, mapper: (String) -> Int) = lines
        .asSequence()
        .filter { it.startsWith(property) }
        .map { mapper(it.substringAfter(':').trim()) }
        .toList()

    companion object {
        fun getHighPerfCpuCount(): Int = try {
            readCpuInfo().getHighPerfCpuCount().coerceAtLeast(2)
        } catch (e: Exception) {
            Log.d("WhisperCpuConfig", "Couldn't read CPU info", e)
            (Runtime.getRuntime().availableProcessors() - 4).coerceAtLeast(2)
        }

        private fun readCpuInfo() = CpuInfo(
            BufferedReader(FileReader("/proc/cpuinfo")).useLines { it.toList() }
        )

        private fun getMaxCpuFrequency(cpuIndex: Int): Int {
            val path = "/sys/devices/system/cpu/cpu${cpuIndex}/cpufreq/cpuinfo_max_freq"
            return BufferedReader(FileReader(path)).use { it.readLine() }.toInt()
        }
    }
}
