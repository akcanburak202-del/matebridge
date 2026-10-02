package dev.matebridge.client.audio

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class OutBufMemoryTest {
    private class MapStore : OutBufStore {
        val map = HashMap<String, Int>()
        var puts = 0
        var gets = 0
        override fun get(path: String): Int? { gets++; return map[path] }
        override fun put(path: String, bursts: Int) { map[path] = bursts; puts++ }
    }

    private val ex = OutBufMemory.PATH_EXCLUSIVE
    private val def = AudioBufferConfig.AAUDIO_DEFAULT_BURSTS

    @Test fun defaultWithoutAStoredValue() {
        val init = OutBufMemory(MapStore()).initial(ex, null, def)
        assertEquals(4, init.bursts) // T-114: 4 bursts (20 ms)
        assertEquals("default", init.source)
        assertNull(init.storedBursts)
    }

    @Test fun storedValueAboveTheDefaultIsUsed() {
        val init = OutBufMemory(MapStore().apply { map[ex] = 5 }).initial(ex, null, def)
        assertEquals(5, init.bursts)
        assertEquals("stored", init.source)
        assertEquals(5, init.storedBursts)
    }

    @Test fun storedValueAtOrBelowTheDefaultGivesTheDefault() {
        val init = OutBufMemory(MapStore().apply { map[ex] = 1 }).initial(ex, null, def)
        assertEquals(4, init.bursts)
        assertEquals("default", init.source)
        assertEquals(1, init.storedBursts)
        // A size grown under the old 2-burst default (T-110) is now below the default.
        val old = OutBufMemory(MapStore().apply { map[ex] = 3 }).initial(ex, null, def)
        assertEquals(4, old.bursts)
        assertEquals("default", old.source)
        val same = OutBufMemory(MapStore().apply { map[ex] = 4 }).initial(ex, null, def)
        assertEquals(4, same.bursts)
        assertEquals("default", same.source)
    }

    @Test fun overrideWinsOverTheStoredValue() {
        val m = OutBufMemory(MapStore().apply { map[ex] = 5 })
        val init = m.initial(ex, 1, def)
        assertEquals(1, init.bursts)
        assertEquals("override", init.source)
        assertEquals(5, init.storedBursts)
        assertEquals(6, m.initial(ex, 9, def).bursts) // clamped
    }

    @Test fun storedValueIsClamped() {
        val store = MapStore().apply { map[ex] = 40; map[OutBufMemory.PATH_SHARED] = -2 }
        val m = OutBufMemory(store)
        assertEquals(6, m.initial(ex, null, def).bursts)
        assertEquals(4, m.initial(OutBufMemory.PATH_SHARED, null, def).bursts)
    }

    @Test fun growthIsStoredAndReadBackByTheNextSession() {
        val store = MapStore()
        val first = OutBufMemory(store)
        first.initial(ex, null, def)
        assertTrue(first.onGrown(ex, 5))
        assertEquals(5, store.map[ex])
        // A new app launch (new memory, same store) starts from it.
        val init = OutBufMemory(store).initial(ex, null, def)
        assertEquals(5, init.bursts)
        assertEquals("stored", init.source)
    }

    @Test fun storedValueOnlyIncreases() {
        val store = MapStore().apply { map[ex] = 4 }
        val m = OutBufMemory(store)
        m.initial(ex, 2, def) // an override run starting below the stored size
        assertFalse(m.onGrown(ex, 3))
        assertFalse(m.onGrown(ex, 4))
        assertEquals(0, store.puts)
        assertTrue(m.onGrown(ex, 5))
        assertEquals(5, store.map[ex])
        assertEquals(1, store.puts)
        assertTrue(m.onGrown(ex, 9))
        assertEquals(6, store.map[ex]) // clamped
    }

    @Test fun pathsAreKeptApart() {
        val store = MapStore()
        val m = OutBufMemory(store)
        m.onGrown(ex, 5)
        assertEquals(5, m.initial(ex, null, def).bursts)
        assertEquals(4, m.initial(OutBufMemory.PATH_SHARED, null, def).bursts)
        assertNull(store.map[OutBufMemory.PATH_SHARED])
    }

    @Test fun storeIsReadOncePerPath() {
        val store = MapStore()
        val m = OutBufMemory(store)
        repeat(3) { m.initial(ex, null, def) }
        m.onGrown(ex, 3)
        assertEquals(1, store.gets)
    }

    @Test fun storeFailuresAreContained() {
        val broken = object : OutBufStore {
            override fun get(path: String): Int? = throw IllegalStateException()
            override fun put(path: String, bursts: Int) = throw IllegalStateException()
        }
        val m = OutBufMemory(broken)
        assertEquals(4, m.initial(ex, null, def).bursts)
        assertTrue(m.onGrown(ex, 5))
        assertEquals(5, m.initial(ex, null, def).bursts) // kept in memory for this launch
    }
}
