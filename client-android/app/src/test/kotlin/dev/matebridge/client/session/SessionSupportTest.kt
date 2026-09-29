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
        assertFalse(q.offer(ByteArray(5), 0)) // 11 > 10
        assertTrue(q.offer(ByteArray(4) { 2 }, 0))
        assertEquals(1, q.take()!![0].toInt())
        assertEquals(2, q.take()!![0].toInt())
        assertTrue(q.offer(ByteArray(10), 0)) // space freed
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
}
