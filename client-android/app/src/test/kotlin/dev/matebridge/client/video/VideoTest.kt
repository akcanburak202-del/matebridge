package dev.matebridge.client.video

import dev.matebridge.client.protocol.Bytes
import dev.matebridge.client.protocol.KeyframeRequest
import dev.matebridge.client.protocol.VideoFrame
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class FrameQueueTest {
    private fun frame(seq: Long, flags: Int = 0) =
        VideoFrame(seq, seq * 1000, flags, 0, 1, 3, Bytes(byteArrayOf(1, 2, 3)))

    private val cfg = VideoFrame.CODEC_CONFIG
    private val key = VideoFrame.KEYFRAME

    /** Depth 2 (pre-T-121) keeps these rule tests short; the T-121 depth is covered in FrameQueueBurstTest. */
    private fun newQueue(): Pair<FrameQueue, VideoStats> {
        val s = VideoStats()
        return FrameQueue(s, maxPending = 2) to s
    }

    @Test fun pFramesBeforeKeyframeAreNotDelivered() {
        val (q, s) = newQueue()
        assertNull(q.offer(frame(0)))
        assertNull(q.poll(0))
        assertEquals(1, s.snapshot().dropped)
        assertTrue(q.isWaitingKeyframe())
    }

    @Test fun configThenKeyframeThenPFramesFlow() {
        val (q, _) = newQueue()
        q.offer(frame(0, cfg)); q.offer(frame(1, key)); q.offer(frame(2))
        assertEquals(0L, q.poll(0)!!.frameSeq)
        assertEquals(1L, q.poll(0)!!.frameSeq)
        assertEquals(2L, q.poll(0)!!.frameSeq)
        assertNull(q.poll(0))
        assertFalse(q.isWaitingKeyframe())
    }

    @Test fun overflowDropsAllPendingAndRequestsKeyframe() {
        val (q, s) = newQueue()
        q.offer(frame(0, key))
        q.poll(0)
        assertNull(q.offer(frame(1)))
        assertNull(q.offer(frame(2)))
        assertEquals(KeyframeRequest.FRAMES_DROPPED, q.offer(frame(3)))
        assertEquals(0, q.pending())
        assertEquals(3, s.snapshot().dropped)
        assertTrue(q.isWaitingKeyframe())
        // P-frames are refused until a keyframe
        assertNull(q.offer(frame(4)))
        assertNull(q.poll(0))
        q.offer(frame(5, key))
        assertEquals(5L, q.poll(0)!!.frameSeq)
    }

    @Test fun keyframeFlushesStalePendingFrames() {
        val (q, s) = newQueue()
        q.offer(frame(0, key)); q.offer(frame(1))
        q.offer(frame(2, key))
        assertEquals(2L, q.poll(0)!!.frameSeq)
        assertNull(q.poll(0))
        assertEquals(2, s.snapshot().dropped)
    }

    @Test fun configIsKeptAndDeduplicatedAndNotCountedInBound() {
        val (q, _) = newQueue()
        q.offer(frame(0, cfg)); q.offer(frame(1, cfg)); q.offer(frame(2, key))
        q.offer(frame(3))
        assertEquals(3, q.pending()) // 1 config + key + 1 P
        assertEquals(1L, q.poll(0)!!.frameSeq)
    }

    @Test fun resetReplaysConfigAndRequestsStartup() {
        val (q, _) = newQueue()
        q.offer(frame(0, cfg)); q.offer(frame(1, key)); q.poll(0); q.poll(0)
        assertEquals(KeyframeRequest.STARTUP, q.reset())
        assertEquals(0L, q.poll(0)!!.frameSeq)
        assertTrue(q.isWaitingKeyframe())
        q.offer(frame(2))
        assertNull(q.poll(0))
    }

    @Test fun decoderErrorClosesGate() {
        val (q, _) = newQueue()
        q.offer(frame(0, key)); q.offer(frame(1))
        assertEquals(KeyframeRequest.DECODE_ERROR, q.onDecoderError())
        assertNull(q.poll(0))
        assertTrue(q.isWaitingKeyframe())
    }
}

class VideoStatsTest {
    @Test fun countersAndAverageDecodeTime() {
        val s = VideoStats()
        s.onReceived(100); s.onReceived(50)
        s.onInput(1, 1000); s.onInput(2, 2000)
        s.onOutput(1, 3000); s.onOutput(2, 6000)
        s.onRendered(); s.onDropped(2)
        val snap = s.snapshot(reset = true)
        assertEquals(2, snap.received); assertEquals(2, snap.decoded)
        assertEquals(1, snap.rendered); assertEquals(2, snap.dropped)
        assertEquals(150, snap.bytesReceived)
        assertEquals(3000, snap.decodeTimeAvgUs) // (2000 + 4000) / 2
        assertEquals(0, s.snapshot().received)
    }

    @Test fun inputTimesAreBounded() {
        val s = VideoStats()
        for (i in 0L until 1000) s.onInput(i, i)
        s.onOutput(0, 5000) // evicted: decoded counts, no timing sample
        assertEquals(0, s.snapshot().decodeTimeAvgUs)
    }
}

class ColorMappingTest {
    @Test fun mapsH273() {
        assertEquals(ColorMapping.STANDARD_BT709, ColorMapping.standard(1))
        assertEquals(ColorMapping.STANDARD_BT2020, ColorMapping.standard(9))
        assertNull(ColorMapping.standard(0))
        assertEquals(ColorMapping.TRANSFER_SDR_VIDEO, ColorMapping.transfer(13))
        assertEquals(ColorMapping.TRANSFER_ST2084, ColorMapping.transfer(16))
        assertEquals(ColorMapping.RANGE_FULL, ColorMapping.range(1))
        assertEquals(ColorMapping.RANGE_LIMITED, ColorMapping.range(0))
    }
}

class AnnexBSplitterTest {
    private fun nal(type: Int, firstSlice: Boolean = true, vararg body: Int): ByteArray {
        val third = if (firstSlice) 0x80 else 0x00
        return byteArrayOf(0, 0, 0, 1, (type shl 1).toByte(), 1, third.toByte()) +
            body.map { it.toByte() }.toByteArray()
    }

    @Test fun splitsConfigKeyframeAndPFrames() {
        val stream = nal(32) + nal(33) + nal(34) + nal(19, true, 9) + nal(1, true, 8) + nal(1, true, 7)
        val f = AnnexBSplitter.split(stream)
        assertEquals(4, f.size)
        assertTrue(f[0].isCodecConfig)
        assertTrue(f[1].isKeyframe)
        assertFalse(f[2].isKeyframe || f[2].isCodecConfig)
        assertEquals(listOf(0L, 1L, 2L, 3L), f.map { it.frameSeq })
        assertEquals(f[0].data.size.toLong(), f[0].frameSize)
    }

    @Test fun multiSliceFrameStaysOneUnit() {
        val stream = nal(19, true, 1) + nal(19, false, 2) + nal(1, true, 3)
        val f = AnnexBSplitter.split(stream)
        assertEquals(2, f.size)
        assertTrue(f[0].isKeyframe)
    }

    @Test fun handlesThreeByteStartCodesAndTrailingZeros() {
        val a = byteArrayOf(0, 0, 1, (19 shl 1).toByte(), 1, 0x80.toByte(), 5, 0)
        val b = byteArrayOf(0, 0, 1, (1 shl 1).toByte(), 1, 0x80.toByte(), 6)
        val f = AnnexBSplitter.split(a + b)
        assertEquals(2, f.size)
        assertEquals(4 + 4, f[0].data.size) // start code + 4 NAL bytes, trailing zero stripped
    }
}

class RestartPolicyTest {
    @Test fun allowsThreeThenGivesUpUntilWindowPasses() {
        val p = RestartPolicy(3, 10_000)
        assertTrue(p.allow(0)); assertTrue(p.allow(1000)); assertTrue(p.allow(2000))
        assertFalse(p.allow(3000))
        assertTrue(p.allow(10_000)) // first attempt left the window
    }
}
