package dev.matebridge.client.input

import dev.matebridge.client.protocol.Codec
import dev.matebridge.client.protocol.Ping
import dev.matebridge.client.session.ControlLink
import dev.matebridge.client.session.KeyValueStore
import dev.matebridge.client.session.SendQueue
import dev.matebridge.client.session.Settings
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Session-side pieces T-024 added: the finger-off setting and the send-queue backpressure signal. */
class InputSupportTest {
    private class MemStore : KeyValueStore {
        val map = HashMap<String, String>()
        override fun getString(key: String) = map[key]
        override fun putString(key: String, value: String) { map[key] = value }
    }

    @Test fun fingerTouchIsEnabledByDefaultAndTheSettingPersists() {
        val store = MemStore()
        assertFalse(Settings(store).fingerTouchDisabled()) // decision 0006: default is not "off"
        Settings(store).setFingerTouchDisabled(true)
        assertTrue(Settings(store).fingerTouchDisabled())
        Settings(store).setFingerTouchDisabled(false)
        assertFalse(Settings(store).fingerTouchDisabled())
    }

    @Test fun queueReportsQueuedBytesAndOldestAge() {
        val q = SendQueue()
        assertEquals(0, q.queuedBytes())
        assertEquals(0L, q.oldestAgeMs(500))
        q.offer(ByteArray(10), 100)
        q.offer(ByteArray(5), 130)
        assertEquals(15, q.queuedBytes())
        assertEquals(70L, q.oldestAgeMs(170))
        q.take()
        assertEquals(5, q.queuedBytes())
        assertEquals(40L, q.oldestAgeMs(170))
    }

    @Test fun controlLinkIsCongestedByBytesOrByAge() {
        var now = 0L
        val q = SendQueue()
        val link = ControlLink(q, { now }) {}
        assertFalse(link.congested())
        // age
        link.send(Ping(1, 1))
        now = ControlLink.CONGESTED_AGE_MS - 1
        assertFalse(link.congested())
        now = ControlLink.CONGESTED_AGE_MS
        assertTrue(link.congested())
        q.take() // writer caught up
        assertFalse(link.congested())
        // bytes
        val frame = Codec.encode(Ping(2, 2)).size
        val n = ControlLink.CONGESTED_BYTES / frame + 1
        repeat(n) { link.send(Ping(3, 3)) }
        assertTrue(link.congested())
    }
}
