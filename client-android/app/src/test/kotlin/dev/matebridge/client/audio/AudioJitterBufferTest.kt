package dev.matebridge.client.audio

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs

class AudioJitterBufferTest {
    /** Stereo s16le packet whose left and right samples are both [value]. */
    private fun pcm(frames: Int, value: Int): ByteArray = ByteArray(frames * 4).also {
        for (f in 0 until frames) for (c in 0 until 2) {
            it[f * 4 + c * 2] = (value and 0xFF).toByte()
            it[f * 4 + c * 2 + 1] = (value shr 8).toByte()
        }
    }

    private fun readAll(b: AudioJitterBuffer): ShortArray {
        val out = ShortArray(b.level * 2)
        val n = b.peek(out, b.level)
        b.consume(n)
        return out
    }

    @Test fun contiguousPacketsAreReadBackUnchanged() {
        val b = AudioJitterBuffer()
        b.write(1000, 50_000, pcm(480, 1234), 480)
        b.write(1480, 60_000, pcm(480, -500), 480)
        assertEquals(960, b.level)
        val out = readAll(b)
        assertTrue(out.take(960).all { it == 1234.toShort() })
        assertTrue(out.drop(960).all { it == (-500).toShort() })
        assertEquals(0, b.level)
        assertEquals(0L, b.gapEvents)
        assertEquals(0L, b.dropEvents)
    }

    @Test fun gapIsFilledWithSilenceAndEdgesAreFaded() {
        val b = AudioJitterBuffer(fadeFrames = 16)
        b.write(0, 0, pcm(100, 10_000), 100)
        b.write(150, 0, pcm(100, 10_000), 100) // host dropped 50 frames
        assertEquals(250, b.level)
        assertEquals(1L, b.gapEvents)
        assertEquals(50L, b.gapFrames)
        val out = readAll(b)
        val left = ShortArray(250) { out[it * 2] }
        assertEquals(10_000.toShort(), left[0])
        // tail of the first packet fades towards zero, never jumping up
        for (i in 85 until 99) assertTrue(left[i + 1] <= left[i])
        assertTrue(left[99] < 1000)
        for (i in 100 until 150) assertEquals(0.toShort(), left[i])
        // the next packet fades in
        assertTrue(left[150] < 1000)
        for (i in 150 until 165) assertTrue(left[i + 1] >= left[i])
        assertEquals(10_000.toShort(), left[170])
    }

    @Test fun longJumpIsNotFilledAndRestartsAtTheNewIndex() {
        val b = AudioJitterBuffer(fadeFrames = 16)
        b.write(0, 1_000_000, pcm(480, 10_000), 480)
        b.write(1_000_000, 21_000_000, pcm(480, 10_000), 480) // host IO restarted 20 s later
        assertEquals(960, b.level) // no silence, no added latency
        assertEquals(1L, b.gapEvents)
        assertEquals(1L, b.jumpEvents)
        assertEquals(1L, b.discontinuities)
        // continues from the new index
        b.write(1_000_480, 21_010_000, pcm(480, 10_000), 480)
        assertEquals(1440, b.level)
        assertEquals(1L, b.gapEvents)
        val out = readAll(b)
        val left = ShortArray(1440) { out[it * 2] }
        assertTrue(left[479] < 1000) // the old tail fades out
        assertTrue(left[480] < 1000) // the new packet fades in
        assertEquals(10_000.toShort(), left[600])
        assertEquals(21_000_000L, b.captureTimeAt(480))
    }

    @Test fun shortGapUpToTwoPacketsIsStillFilled() {
        val b = AudioJitterBuffer()
        b.write(0, 0, pcm(480, 1), 480)
        b.write(1440, 30_000, pcm(480, 1), 480) // 960 frames (20 ms) dropped by the host
        assertEquals(480 + 960 + 480, b.level)
        assertEquals(0L, b.jumpEvents)
    }

    @Test fun captureTimeJumpWithContinuousIndexIsADiscontinuity() {
        val b = AudioJitterBuffer()
        b.write(0, 1_000_000, pcm(480, 1), 480)
        b.write(480, 1_010_000, pcm(480, 1), 480) // continuous
        b.write(960, 1_025_000, pcm(480, 1), 480) // 5 ms late capture: host timing noise, not silence
        assertEquals(0L, b.discontinuities)
        b.write(1440, 1_600_000, pcm(480, 1), 480) // the host captured nothing for ~565 ms
        assertEquals(1L, b.discontinuities)
        assertEquals(0L, b.gapEvents)
        assertEquals(4L, b.packets)
        assertEquals(1920, b.level)
    }

    @Test fun overlappingAndOldFramesAreDiscarded() {
        val b = AudioJitterBuffer()
        b.write(0, 0, pcm(480, 7), 480)
        b.write(0, 0, pcm(480, 9), 480) // duplicate
        assertEquals(480, b.level)
        b.write(240, 0, pcm(480, 9), 480) // half overlaps
        assertEquals(720, b.level)
        assertEquals(480L + 240L, b.lateFrames)
        val out = readAll(b)
        assertEquals(7.toShort(), out[479 * 2])
        assertEquals(9.toShort(), out[480 * 2])
    }

    @Test fun overflowDropsOldestWithCrossfade() {
        val b = AudioJitterBuffer(capacityFrames = 1000, fadeFrames = 10)
        b.write(0, 0, pcm(600, 1000), 600)
        b.write(600, 0, pcm(600, 5000), 600) // 200 too many
        assertEquals(1000, b.level)
        assertEquals(1L, b.dropEvents)
        assertEquals(200L, b.dropFrames)
        val out = readAll(b)
        val left = ShortArray(1000) { out[it * 2] }
        // crossfade starts close to the old value the reader would have played next
        assertTrue(abs(left[0] - 1000) < 400)
        for (i in 0 until 10) assertTrue(left[i + 1] >= left[i])
        assertEquals(1000.toShort(), left[300])
        assertEquals(5000.toShort(), left[999])
    }

    @Test fun neverHoldsMoreThanCapacity() {
        val b = AudioJitterBuffer()
        for (k in 0 until 100) b.write(k * 480L, 0, pcm(480, 1), 480)
        assertEquals(AudioJitterBuffer.DEFAULT_CAPACITY_FRAMES, b.level)
    }

    @Test fun captureTimeFollowsAnchors() {
        val b = AudioJitterBuffer()
        assertNull(b.readHeadCaptureUs())
        b.write(0, 1_000_000, pcm(480, 1), 480)
        b.write(480, 1_010_000, pcm(480, 1), 480)
        assertEquals(1_000_000L, b.readHeadCaptureUs())
        b.consume(240)
        assertEquals(1_005_000L, b.readHeadCaptureUs())
        b.consume(240)
        assertEquals(1_010_000L, b.readHeadCaptureUs())
        b.consume(480)
        assertEquals(1_020_000L, b.readHeadCaptureUs()) // extrapolated past the last packet
    }

    @Test fun resetEmptiesEverything() {
        val b = AudioJitterBuffer()
        b.write(5000, 1, pcm(480, 1), 480)
        b.reset()
        assertEquals(0, b.level)
        assertNull(b.readHeadCaptureUs())
        b.write(0, 1, pcm(480, 1), 480) // a new stream may start from 0 again
        assertEquals(480, b.level)
        assertEquals(0L, b.gapEvents)
    }

    @Test fun skipCrossfadeDropsFrames() {
        val b = AudioJitterBuffer()
        b.write(0, 0, pcm(4800, 100), 4800)
        b.skipCrossfade(3000)
        assertEquals(1800, b.level)
        b.skipCrossfade(10_000)
        assertEquals(0, b.level)
    }
}
