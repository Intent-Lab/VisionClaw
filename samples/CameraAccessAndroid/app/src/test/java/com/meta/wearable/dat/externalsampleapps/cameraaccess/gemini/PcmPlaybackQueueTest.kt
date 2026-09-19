package com.meta.wearable.dat.externalsampleapps.cameraaccess.gemini

import org.junit.Assert.*
import org.junit.Test

class PcmPlaybackQueueTest {
    @Test fun partialWritesAndBackpressurePreserveAudioOrder() {
        val queue = PcmPlaybackQueue()
        queue.offer(byteArrayOf(1, 2, 3, 4))
        queue.offer(byteArrayOf(5, 6))
        val played = mutableListOf<Byte>()
        val write: (ByteArray, Int, Int) -> Int = { data, offset, count ->
            val accepted = minOf(count, 2)
            played.addAll(data.slice(offset until offset + accepted))
            accepted
        }
        assertEquals(2, queue.writeNext(write))
        assertEquals(0, queue.writeNext { _, _, _ -> 0 })
        assertEquals(2, queue.writeNext(write))
        assertEquals(2, queue.writeNext(write))
        assertEquals(0, queue.writeNext(write))
        assertArrayEquals(byteArrayOf(1, 2, 3, 4, 5, 6), played.toByteArray())
    }

    @Test fun interruptionDiscardsPartiallyWrittenAndQueuedResponse() {
        val queue = PcmPlaybackQueue()
        queue.offer(byteArrayOf(1, 2, 3, 4))
        queue.offer(byteArrayOf(5, 6))
        queue.writeNext { _, _, _ -> 2 }
        queue.clear()
        queue.offer(byteArrayOf(7, 8))
        assertEquals(2, queue.writeNext { bytes, offset, count ->
            assertArrayEquals(byteArrayOf(7, 8), bytes)
            assertEquals(0, offset)
            count
        })
        assertEquals(0, queue.writeNext { _, _, _ -> error("Old response survived interruption") })
    }

    @Test fun queueIsBoundedAndReclaimsSpaceAfterPlaybackAndStop() {
        val queue = PcmPlaybackQueue(maxBytes = 4)
        assertTrue(queue.offer(byteArrayOf(1, 2, 3, 4)))
        assertFalse(queue.offer(byteArrayOf(5, 6)))
        queue.writeNext { _, _, _ -> 2 }
        assertTrue(queue.offer(byteArrayOf(5, 6)))
        assertFalse(queue.offer(byteArrayOf(7, 8)))
        queue.clear()
        assertTrue(queue.offer(byteArrayOf(9, 10, 11, 12)))
    }

    @Test fun outputErrorDoesNotConsumeAudio() {
        val queue = PcmPlaybackQueue()
        queue.offer(byteArrayOf(1, 2))
        assertEquals(-6, queue.writeNext { _, _, _ -> -6 })
        assertEquals(2, queue.writeNext { bytes, offset, count ->
            assertArrayEquals(byteArrayOf(1, 2), bytes)
            assertEquals(0, offset)
            count
        })
    }
}
