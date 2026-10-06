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
}
