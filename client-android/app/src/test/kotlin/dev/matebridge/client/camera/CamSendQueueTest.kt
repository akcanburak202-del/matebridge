package dev.matebridge.client.camera

import dev.matebridge.client.camera.CamSendQueue.Offer
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CamSendQueueTest {
    private fun bytes(vararg b: Int) = ByteArray(b.size) { b[it].toByte() }
    private val config = bytes(0, 0, 0, 1, 0x67)

    private fun active(): CamSendQueue = CamSendQueue().also { it.onConfig(config, 5); it.setActive(true) }

    @Test fun framesAreDroppedWhileNoConnectionIsActive() {
        val q = CamSendQueue()
        assertEquals(Offer.DROPPED, q.offer(bytes(1), 1, true))
        assertEquals(0, q.size())
        assertEquals(1L to 1L, q.counters())
    }

    @Test fun theFirstFrameMustBeAKeyframeAndItCarriesTheConfig() {
        val q = active()
        assertEquals(Offer.DROPPED, q.offer(bytes(2), 10, false)) // before any keyframe: dropped, no request needed (the gate is open for a key)
        assertEquals(Offer.QUEUED, q.offer(bytes(1), 11, true))
        val u = q.take(10)!!
        assertArrayEquals(config, u.config)
        assertArrayEquals(bytes(1), u.data)
        assertTrue(u.keyframe)
        assertEquals(5L, u.configTimeUs)
        assertEquals(Offer.QUEUED, q.offer(bytes(3), 12, false))
        val d = q.take(10)!!
        assertNull(d.config) // the config goes only once, in front of the keyframe
        assertFalse(d.keyframe)
    }

    @Test fun aKeyframeWaitsForTheConfigIfNoneIsKnownYet() {
        val q = CamSendQueue()
        q.setActive(true)
        assertEquals(Offer.QUEUED, q.offer(bytes(1), 1, true))
        assertNull(q.take(5)) // no config: nothing is released
        q.onConfig(config, 2)
        val u = q.take(5)
        assertNotNull(u)
        assertArrayEquals(config, u!!.config)
    }

    @Test fun overflowDropsWaitingDeltasAndGatesUntilTheNextKeyframe() {
        val q = active()
        q.offer(bytes(1), 1, true)
        q.take(5) // the keyframe left
        assertEquals(Offer.QUEUED, q.offer(bytes(2), 2, false))
        assertEquals(Offer.QUEUED, q.offer(bytes(3), 3, false))
        // the queue is full (2): the next delta forces the oldest ones out and breaks the chain
        assertEquals(Offer.DROPPED_NEED_KEYFRAME, q.offer(bytes(4), 4, false))
        assertTrue(q.needKeyframe)
        assertEquals(0, q.size())
        assertEquals(Offer.DROPPED, q.offer(bytes(5), 5, false)) // gated
        assertEquals(Offer.QUEUED, q.offer(bytes(6), 6, true))
        assertFalse(q.needKeyframe)
        assertTrue(q.take(5)!!.keyframe)
        assertEquals(6L to 4L, q.counters()) // offered 6; dropped: the two waiting deltas, the one that broke the chain, the gated one
    }

    @Test fun neverMoreThanTwoFramesWait() {
        val q = active()
        q.offer(bytes(1), 1, true)
        q.offer(bytes(2), 2, false)
        assertEquals(2, q.size())
        q.offer(bytes(3), 3, false)
        assertTrue(q.size() <= CamSendQueue.CAPACITY)
        repeat(50) { q.offer(bytes(9), 10L + it, it % 7 == 0) }
        assertTrue(q.size() <= CamSendQueue.CAPACITY)
    }

    @Test fun aKeyframeOnOverflowStartsANewChain() {
        val q = active()
        q.offer(bytes(1), 1, true)
        q.offer(bytes(2), 2, false)
        assertEquals(Offer.QUEUED, q.offer(bytes(3), 3, true)) // the full queue gives up its waiting delta; the keyframe restarts the chain
        val first = q.take(5)!!
        assertTrue(first.keyframe)
        val second = q.take(5)!!
        assertTrue(second.keyframe)
        assertNull(q.take(1))
    }

    @Test fun aHostKeyframeRequestDropsWaitingDeltasAndResendsTheConfig() {
        val q = active()
        q.offer(bytes(1), 1, true)
        q.take(5)
        q.offer(bytes(2), 2, false)
        q.onKeyframeRequested()
        assertEquals(0, q.size())
        assertTrue(q.needKeyframe)
        assertEquals(Offer.DROPPED, q.offer(bytes(3), 3, false))
        q.offer(bytes(4), 4, true)
        val u = q.take(5)!!
        assertArrayEquals(config, u.config) // "CAM_KEYFRAME_REQUEST: CODEC_CONFIG in front"
    }

    @Test fun aNewConfigGatesAndPrecedesTheNextKeyframe() {
        val q = active()
        q.offer(bytes(1), 1, true)
        q.take(5)
        val cfg2 = bytes(0, 0, 0, 1, 0x68)
        q.onConfig(cfg2, 9) // e.g. after a facing switch
        assertEquals(Offer.DROPPED, q.offer(bytes(2), 2, false))
        q.offer(bytes(3), 3, true)
        assertArrayEquals(cfg2, q.take(5)!!.config)
    }

    @Test fun deactivatingClearsWhatWaits() {
        val q = active()
        q.offer(bytes(1), 1, true)
        q.setActive(false)
        assertEquals(0, q.size())
        q.setActive(true)
        assertTrue(q.needKeyframe) // a new connection starts at a keyframe
    }

    @Test fun closeWakesAWaitingTaker() {
        val q = active()
        var result: CamSendQueue.Out? = bytes(1).let { CamSendQueue.Out(null, it, 0, false, 0) }
        val t = Thread { result = q.take(5_000) }
        t.start()
        Thread.sleep(50)
        q.close()
        t.join(2_000)
        assertFalse(t.isAlive)
        assertNull(result)
    }
}
