package dev.matebridge.client.cursor

import dev.matebridge.client.protocol.Bytes
import dev.matebridge.client.protocol.CursorPrefs
import dev.matebridge.client.protocol.CursorShape
import dev.matebridge.client.protocol.CursorState
import java.util.concurrent.Executor
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CursorLinkTest {
    private fun state(seq: Long, x: Int = 100, y: Int = 200, visible: Boolean = true, shape: Long = 7, hostUs: Long = 0) =
        CursorState(seq, x, y, visible, shape, hostUs)

    private fun png(): ByteArray {
        fun be(v: Int) = byteArrayOf((v ushr 24).toByte(), (v ushr 16).toByte(), (v ushr 8).toByte(), v.toByte())
        return byteArrayOf(0x89.toByte(), 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A) + be(13) + "IHDR".toByteArray() + be(18) + be(36) + ByteArray(9)
    }

    private class Rig {
        var now = 1_000L
        val frames = ArrayList<CursorFrame?>()
        val stats = CursorStats()
        val shapes = CursorShapes<String>(executor = Executor { it.run() }, decode = { "bmp" })
        val link = CursorLink(shapes, stats, { now }) { frames += it }
    }

    @Test fun messagesOfAnotherGenerationOrWithoutASessionAreDropped() {
        val r = Rig()
        r.link.enable(true)
        r.link.onMessage(state(1), 1) // nothing armed
        r.link.beginSession(3)
        r.link.onMessage(state(2), 2) // an older reader
        r.link.onMessage(CursorShape(7, 144, 288, 64, 144, 1, Bytes(png())), 2)
        assertNull(r.link.slot.latest())
        assertEquals(0, r.shapes.size)
        r.link.onMessage(state(3), 3)
        assertEquals(3L, r.link.slot.latest()!!.seq)
        r.link.endSession()
        r.link.onMessage(state(4), 3)
        assertNull(r.link.slot.latest())
    }

    @Test fun theNewestSeqWinsAndOlderOnesAreCountedAsStale() {
        val r = Rig()
        r.link.enable(true)
        r.link.beginSession(1)
        r.frames.clear()
        r.link.onMessage(state(10, x = 1), 1)
        r.link.onMessage(state(12, x = 3), 1)
        r.link.onMessage(state(11, x = 2), 1) // arrives late: ignored
        r.link.onMessage(state(12, x = 9), 1) // a duplicate: ignored
        assertEquals(3, r.link.slot.latest()!!.x)
        assertEquals(2, r.frames.size) // only accepted states ask for a redraw
        val s = r.stats.take()
        assertEquals(4, s.states)
        assertEquals(2, s.stale)
    }

    @Test fun statesAreIgnoredWhileTheLayerIsOffButShapesAreKept() {
        val r = Rig()
        r.link.beginSession(1)
        r.link.onMessage(CursorShape(7, 144, 288, 64, 144, 1, Bytes(png())), 1)
        r.link.onMessage(state(1), 1)
        assertNull(r.link.slot.latest())
        assertEquals(0L, r.link.lastStateMs)
        assertNotNull(r.shapes.lookup(7)) // the host believes we hold it
        r.link.enable(true)
        r.now = 2_000
        r.link.onMessage(state(2), 1)
        assertEquals(2L, r.link.slot.latest()!!.seq)
        assertEquals(2_000L, r.link.lastStateMs)
    }

    @Test fun turningTheLayerOffHidesItAndForgetsTheState() {
        val r = Rig()
        r.link.beginSession(1)
        r.link.enable(true)
        r.link.onMessage(state(5), 1)
        r.frames.clear()
        r.link.enable(false)
        assertNull(r.link.slot.latest())
        assertEquals(listOf<CursorFrame?>(null), r.frames)
        // a new enable starts fresh: seq 1 is accepted again
        r.link.enable(true)
        r.link.onMessage(state(1), 1)
        assertEquals(1L, r.link.slot.latest()!!.seq)
    }

    @Test fun aStateUsesItsShapeInTheCache() {
        val r = Rig()
        r.link.beginSession(1)
        r.link.enable(true)
        for (id in 1L..64L) r.link.onMessage(CursorShape(id, 144, 288, 64, 144, 1, Bytes(png())), 1)
        r.link.onMessage(state(1, shape = 1), 1) // shape 1 is in use now
        r.link.onMessage(CursorShape(65, 144, 288, 64, 144, 1, Bytes(png())), 1)
        assertNotNull(r.shapes.lookup(1))
        assertNull(r.shapes.lookup(2))
    }

    @Test fun aNewSessionDropsTheCacheAndTheState() {
        val r = Rig()
        r.link.beginSession(1)
        r.link.enable(true)
        r.link.onMessage(CursorShape(7, 144, 288, 64, 144, 1, Bytes(png())), 1)
        r.link.onMessage(state(9), 1)
        r.link.beginSession(2) // a reconnect or a migration switch
        assertNull(r.link.slot.latest())
        assertEquals(0, r.shapes.size)
        assertEquals(0L, r.link.lastStateMs)
        assertNull(r.frames.last()) // the layer was told to clear
        r.link.onMessage(state(1), 1) // the old reader
        assertNull(r.link.slot.latest())
        r.link.onMessage(state(1), 2)
        assertEquals(1L, r.link.slot.latest()!!.seq)
    }

    @Test fun otherMessagesAreIgnored() {
        val r = Rig()
        r.link.beginSession(1)
        r.link.enable(true)
        r.link.onMessage(CursorPrefs(true), 1)
        assertTrue(r.link.slot.latest() == null)
        assertFalse(r.link.lastStateMs != 0L)
    }

    @Test fun onlyAcceptedStatesKeepTheTimeoutAway() {
        val r = Rig()
        r.link.beginSession(1)
        r.link.enable(true)
        r.now = 2_000
        r.link.onMessage(state(50), 1)
        assertEquals(2_000L, r.link.lastStateMs)
        r.now = 3_000
        r.link.onMessage(state(50), 1) // a duplicate
        r.link.onMessage(state(49), 1) // older
        assertEquals(2_000L, r.link.lastStateMs) // a frozen cursor keeps timing out
    }

    @Test fun aHandlerOfTheOldConnectionCannotPoisonTheNewSession() {
        // Thread A is inside onMessage for generation 1 (held in the redraw callback) while the connection switches to 2.
        val entered = java.util.concurrent.CountDownLatch(1)
        val release = java.util.concurrent.CountDownLatch(1)
        var first = true
        val frames = ArrayList<CursorFrame?>()
        val shapes = CursorShapes<String>(executor = Executor { it.run() }, decode = { "bmp" })
        val link = CursorLink(shapes, CursorStats(), { 1L }) { f ->
            frames += f
            if (f != null && first) { first = false; entered.countDown(); release.await() }
        }
        link.beginSession(1)
        link.enable(true)
        val a = Thread { link.onMessage(state(4_000_000_000L), 1) }
        a.start()
        assertTrue(entered.await(2, java.util.concurrent.TimeUnit.SECONDS))
        val switched = java.util.concurrent.atomic.AtomicBoolean(false)
        val b = Thread { link.beginSession(2); link.enable(true); switched.set(true) }
        b.start()
        Thread.sleep(100)
        assertFalse("the switch must wait for the handler that is already accepting", switched.get())
        release.countDown()
        a.join(2_000); b.join(2_000)
        assertTrue(switched.get())
        assertNull(link.slot.latest()) // the old seq did not survive the switch
        link.onMessage(state(1), 2) // the new session starts at 1
        assertEquals(1L, link.slot.latest()!!.seq)
        assertTrue(link.lastStateMs >= 0)
    }

    @Test fun theLocalPredictionIsFedByAcceptedStatesAndFollowsTheLayerAndTheSession() {
        val stats = CursorStats()
        val predictor = CursorPredictor({ null }, { 1_000L }, stats)
        predictor.setStream(1000, 500)
        var us = 100_000L
        val link = CursorLink(CursorShapes<String>(executor = Executor { it.run() }, decode = { "bmp" }), stats, { 1_000L }, predictor, { us }) {}
        val out = CursorPredictor.Result()
        link.beginSession(1)
        link.enable(true)
        link.onMessage(state(5, x = 32_768, y = 16_384), 1)
        assertTrue(predictor.advance(5, us, out))
        link.onMessage(state(4, x = 1, y = 1), 1) // stale: not the anchor
        assertTrue(predictor.advance(5, us, out))
        link.onMessage(state(6, x = 1, y = 1, visible = false), 1)
        assertFalse(predictor.advance(6, us, out)) // hidden: no prediction
        link.onMessage(state(7, x = 1, y = 1), 1)
        link.enable(false) // the layer turned off: the anchor is gone
        assertFalse(predictor.active)
        assertFalse(predictor.advance(7, us, out))
        link.enable(true)
        link.onMessage(state(8, x = 1, y = 1), 1)
        assertTrue(predictor.advance(8, us, out))
        link.endSession()
        assertFalse(predictor.advance(8, us, out))
    }

    @Test fun shapeIdZeroIsAcceptedAsAStateAndHasNoShapeSoTheArrowIsDrawn() {
        val r = Rig()
        r.link.beginSession(1)
        r.link.enable(true)
        r.link.onMessage(CursorShape(0, 144, 288, 64, 144, 1, Bytes(png())), 1) // not a shape
        r.link.onMessage(state(1, shape = 0), 1) // "the host could not read the shape"
        assertEquals(0L, r.link.slot.latest()!!.shapeId)
        assertNull(r.shapes.lookup(0)) // unknown id: the layer draws the built-in arrow
        assertEquals(0, r.shapes.size)
    }
}
