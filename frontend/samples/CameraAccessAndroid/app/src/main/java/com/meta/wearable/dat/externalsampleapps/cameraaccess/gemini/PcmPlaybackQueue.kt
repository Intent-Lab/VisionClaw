package com.meta.wearable.dat.externalsampleapps.cameraaccess.gemini

/** Caller serializes enqueue/write/clear with the AudioTrack lock, including interruption flush. */
internal class PcmPlaybackQueue(private val maxBytes: Int = 24_000 * 2 * 60) {
    private val chunks = ArrayDeque<ByteArray>()
    private var offset = 0
    private var pendingBytes = 0

    val hasPendingAudio: Boolean get() = pendingBytes > 0

    fun offer(bytes: ByteArray): Boolean {
        if (bytes.isEmpty()) return true
        if (bytes.size > maxBytes - pendingBytes) return false
        chunks.addLast(bytes)
        pendingBytes += bytes.size
        return true
    }

    fun writeNext(write: (ByteArray, Int, Int) -> Int): Int {
        val chunk = chunks.firstOrNull() ?: return 0
        val remaining = chunk.size - offset
        val written = write(chunk, offset, remaining)
        check(written <= remaining)
        if (written > 0) {
            offset += written
            pendingBytes -= written
            if (offset == chunk.size) {
                chunks.removeFirst()
                offset = 0
            }
        }
        return written
    }

    fun clear() {
        chunks.clear()
        offset = 0
        pendingBytes = 0
    }
}
