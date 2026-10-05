package dev.matebridge.client.video

import dev.matebridge.client.protocol.Bytes
import dev.matebridge.client.protocol.KeyframeRequest
import dev.matebridge.client.protocol.StreamConfig
import dev.matebridge.client.protocol.VideoFrame
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** T-259 review: a given-up auxiliary decoder stops ingesting and requesting; the owner is told once. */
class AuxDecoderTest {
    private val config = StreamConfig(1, StreamConfig.CODEC_HEVC, 2800, 1840, 1400, 920, 60, 30000, 1, 13, 1, 1, 1)
    private val factory = FakeDecoderFactory().also { it.failCreates = 1000 }
    private val env = TestDecoderEnv()
    private val requests = CopyOnWriteArrayList<Int>()
    private val gaveUp = CountDownLatch(1)
    private val queue = AuxFrameQueue(4)
    private var dec: AuxDecoder? = null

    @After fun tearDown() { dec?.stop() }

    @Test fun giveUpClearsActiveAndStopsRequests() {
        val d = AuxDecoder(config, Any(), queue, { requests.add(it) }, factory, env, { gaveUp.countDown() }, longArrayOf(1, 1, 1))
        dec = d
        d.start()
        assertTrue(gaveUp.await(5, TimeUnit.SECONDS))
        assertTrue(d.gaveUp)
        val before = requests.size
        d.onFrame(VideoFrame(1, 1, VideoFrame.KEYFRAME, 0, 1, 1, Bytes(byteArrayOf(1)), VideoFrame.VIEW_AUX))
        assertEquals(0, queue.pendingFrames()) // not ingested
        assertEquals(before, requests.size) // nothing requested after the give-up
        assertTrue(requests.contains(KeyframeRequest.STARTUP))
        assertFalse(requests.isEmpty())
    }
}
