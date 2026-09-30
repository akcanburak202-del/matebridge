package dev.matebridge.client.session

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Random

class SessionSupportTest {
    private class MemStore : KeyValueStore {
        val map = HashMap<String, String>()
        override fun getString(key: String) = map[key]
        override fun putString(key: String, value: String) { map[key] = value }
    }

    @Test fun deviceIdIsGeneratedOnceAndPersisted() {
        val store = MemStore()
        val first = Settings(store, Random(1)).deviceId()
        assertEquals(16, first.size)
        // A different random source must not matter: the stored value wins.
        assertArrayEquals(first, Settings(store, Random(2)).deviceId())
    }

    @Test fun corruptStoredDeviceIdIsRegenerated() {
        val store = MemStore().apply { map["device_id"] = "zz" }
        assertEquals(16, Settings(store, Random(3)).deviceId().size)
    }

    @Test fun lastEndpointRoundTrips() {
        val s = Settings(MemStore())
        assertNull(s.lastEndpoint())
        s.saveEndpoint(Endpoint("192.168.1.20", 7420))
        assertEquals(Endpoint("192.168.1.20", 7420), s.lastEndpoint())
    }

    @Test fun penOverlayDefaultsOnAndPersist() {
        val st = MemStore()
        val s = Settings(st)
        assertTrue(s.penTrail())
        assertTrue(s.penDot())
        s.setPenTrail(false)
        s.setPenDot(false)
        assertFalse(Settings(st).penTrail())
        assertFalse(Settings(st).penDot())
        s.setPenTrail(true)
        assertTrue(Settings(st).penTrail())
    }

    @Test fun endpointParsing() {
        assertEquals(Endpoint("192.168.1.20", 7420), Endpoint.parse(" 192.168.1.20:7420 "))
        assertEquals(Endpoint("mac.local", 1), Endpoint.parse("mac.local:1"))
        for (bad in listOf("", "host", "host:", ":80", "host:0", "host:65536", "host:abc", "a b:80", "::1:80")) {
            assertNull(bad, Endpoint.parse(bad))
        }
    }

    @Test fun truncateUtf8KeepsCodePoints() {
        assertEquals("abc", truncateUtf8("abcdef", 3))
        assertEquals("é", truncateUtf8("éé", 3)) // 2 bytes each, second would exceed
        assertEquals("", truncateUtf8("😀", 3))
        assertEquals("😀", truncateUtf8("😀x", 4))
    }

    @Test fun sendQueueIsFifoAndBoundedByBytes() {
        val q = SendQueue(maxBytes = 10)
        assertTrue(q.offer(ByteArray(6) { 1 }, 0))
        assertTrue(q.offer(ByteArray(4) { 2 }, 0))
        assertEquals(1, q.take()!![0].toInt())
        assertEquals(2, q.take()!![0].toInt())
        assertTrue(q.offer(ByteArray(10), 0)) // space freed
        assertFalse(q.offer(ByteArray(1), 0)) // 11 > 10
    }

    @Test fun sendQueueOverflowsWhenOldestIsTooOld() {
        val q = SendQueue(maxAgeMs = 1000)
        assertTrue(q.offer(ByteArray(1), 0))
        assertTrue(q.offer(ByteArray(1), 1000))
        assertFalse(q.offer(ByteArray(1), 1001))
    }

    @Test fun gracefulCloseDrainsThenEnds() {
        val q = SendQueue()
        q.offer(byteArrayOf(9), 0)
        q.closeGracefully()
        assertFalse(q.offer(byteArrayOf(1), 0))
        assertNotNull(q.take())
        assertNull(q.take())
    }

    @Test fun abortDropsQueued() {
        val q = SendQueue()
        q.offer(byteArrayOf(9), 0)
        q.abort()
        assertNull(q.take())
        assertEquals(0, q.size())
    }

    @Test fun overflowRefusesEveryLaterOffer() {
        val q = SendQueue(maxBytes = 10)
        assertTrue(q.offer(ByteArray(8), 0))
        assertFalse(q.offer(ByteArray(5), 0)) // overflow
        assertTrue(q.isOverflowed())
        assertFalse(q.offer(ByteArray(1), 0)) // would fit, but must be refused
        q.take()
        assertFalse(q.offer(ByteArray(1), 0))
    }

    @Test fun controlLinkOverflowForcesConnectionCloseExactlyOnce() {
        var closes = 0
        // Tiny bound: a KEY message (13 byte payload + header) does not fit twice.
        val link = ControlLink(SendQueue(maxBytes = 30), { 0L }) { closes++ }
        val key = dev.matebridge.client.protocol.Key(0, 30, 0, dev.matebridge.client.protocol.Key.UP, 0)
        assertTrue(link.send(key))
        assertFalse(link.send(key))
        assertEquals(1, closes)
        assertFalse(link.send(dev.matebridge.client.protocol.ReleaseAll(0))) // later events refused too
        assertEquals(1, closes)
    }

    @Test fun controlLinkGracefulCloseIsNotAnOverflow() {
        var closes = 0
        val q = SendQueue()
        val link = ControlLink(q, { 0L }) { closes++ }
        assertTrue(link.send(dev.matebridge.client.protocol.Bye(0)))
        q.closeGracefully()
        assertFalse(link.send(dev.matebridge.client.protocol.Bye(0)))
        assertEquals(0, closes)
    }

    @Test fun rapidStartStopCoalescesToOneIntent() {
        val latest = Latest<SessionMachine.Event>()
        repeat(10_000) { i ->
            latest.post(if (i % 2 == 0) SessionMachine.Event.Start(Endpoint("h", 1 + i % 60000)) else SessionMachine.Event.Stop)
        }
        assertEquals(SessionMachine.Event.Stop, latest.take()) // last of 10,000 wins
        assertNull(latest.take()) // nothing else retained
    }

    @Test fun closeNotificationsKeepOnlyNewestGeneration() {
        val slot = LatestGen<SessionMachine.Event.ControlClosed> { it.gen }
        repeat(10_000) { slot.post(SessionMachine.Event.ControlClosed(it % 50)) }
        slot.post(SessionMachine.Event.ControlClosed(7))
        assertEquals(49, slot.take()!!.gen)
        assertNull(slot.take())
    }

    @Test fun speedMultipliersDefaultClampAndPersist() {
        val store = MemStore()
        val st = Settings(store, Random(1))
        assertEquals(1f, st.touchpadSpeed(), 0f)
        assertEquals(1f, st.mouseSpeed(), 0f)
        st.setTouchpadSpeed(10f)
        assertEquals(SpeedRange.MAX, Settings(store, Random(1)).touchpadSpeed(), 0f)
        st.setMouseSpeed(0.01f)
        assertEquals(SpeedRange.MIN, Settings(store, Random(1)).mouseSpeed(), 0f)
        store.map["touchpad_speed"] = "junk"
        assertEquals(1f, st.touchpadSpeed(), 0f)
        store.map["touchpad_speed"] = "99"
        assertEquals(SpeedRange.MAX, st.touchpadSpeed(), 0f)
    }

    @Test fun adjustSpeedStepsClampsAndKeepsKindsSeparate() {
        val st = Settings(MemStore(), Random(1))
        assertEquals(0.85f, st.adjustSpeed(false, SpeedRange.STEP_DOWN), 0.0001f)
        assertEquals(1f, st.mouseSpeed(), 0f)
        repeat(40) { st.adjustSpeed(false, SpeedRange.STEP_DOWN) }
        assertEquals(SpeedRange.MIN, st.touchpadSpeed(), 0f)
        repeat(60) { st.adjustSpeed(true, SpeedRange.STEP_UP) }
        assertEquals(SpeedRange.MAX, st.mouseSpeed(), 0f)
        assertEquals("Touchpad hızı: 0,85", SpeedRange.label(false, 0.85f))
        assertEquals("Fare hızı: 1,15", SpeedRange.label(true, 1.15f))
    }
}
