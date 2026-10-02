package dev.matebridge.client.audio

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SafetyMemoryTest {
    private class MapStore : SafetyStore {
        val map = HashMap<String, Int>()
        var puts = 0
        override fun get(api: String): Int? = map[api]
        override fun put(api: String, ms: Int) { map[api] = ms; puts++ }
    }

    @Test fun aaudioStartsAtTheSafeDefaultWithoutAStoredValue() {
        val init = SafetyMemory(MapStore()).initial("aaudio")
        assertEquals(20, init.ms)
        assertEquals(SafetyMemory.AAUDIO_DEFAULT_MS, init.ms)
        assertFalse(init.stored)
        assertEquals("default", init.source)
        assertNull(init.storedMs)
    }

    @Test fun trackDefaultIsUnchanged() {
        val init = SafetyMemory(MapStore()).initial("track")
        assertEquals(DriftController.SAFETY_MIN_MS, init.ms)
        assertEquals("default", init.source)
    }

    @Test fun storedValueAboveTheDefaultIsUsed() {
        val store = MapStore().apply { map["aaudio"] = 27 }
        val init = SafetyMemory(store).initial("aaudio")
        assertEquals(27, init.ms)
        assertEquals("stored", init.source)
    }

    @Test fun storedValueBelowTheDefaultGivesTheDefault() {
        val store = MapStore().apply { map["aaudio"] = 10 }
        val init = SafetyMemory(store).initial("aaudio")
        assertEquals(20, init.ms)
        assertEquals("default", init.source)
        assertEquals(10, init.storedMs)
    }

    @Test fun storedValueIsClampedToTheRememberedRange() {
        val store = MapStore().apply { map["aaudio"] = 500; map["track"] = -3 }
        val m = SafetyMemory(store)
        assertEquals(SafetyMemory.REMEMBER_MAX_MS, m.initial("aaudio").ms)
        assertEquals(DriftController.SAFETY_MIN_MS, m.initial("track").ms)
    }

    @Test fun valuesAreKeptPerApi() {
        val store = MapStore()
        val m = SafetyMemory(store)
        m.initial("aaudio"); m.initial("track")
        m.flush("aaudio", 30)
        m.flush("track", 10)
        assertEquals(30, store.map["aaudio"])
        assertEquals(10, store.map["track"])
    }

    @Test fun savedValueIsReadBackByTheNextSession() {
        val store = MapStore()
        val first = SafetyMemory(store)
        first.initial("aaudio")
        first.onSafety("aaudio", 25, nowMs = 1_000)
        first.flush("aaudio", 28)
        val next = SafetyMemory(store).initial("aaudio")
        assertEquals(28, next.ms)
        assertTrue(next.stored)
    }

    @Test fun unchangedValueIsNotWritten() {
        val store = MapStore()
        val m = SafetyMemory(store)
        m.initial("aaudio")
        m.onSafety("aaudio", 20, nowMs = 0)
        m.flush("aaudio", 20)
        assertEquals(0, store.puts)
    }

    @Test fun changesAreSavedAtMostEveryTenSeconds() {
        val store = MapStore()
        val m = SafetyMemory(store)
        m.initial("aaudio")
        m.onSafety("aaudio", 25, nowMs = 1_000)
        assertEquals(1, store.puts)
        m.onSafety("aaudio", 30, nowMs = 5_000) // too soon
        assertEquals(1, store.puts)
        assertEquals(25, store.map["aaudio"])
        m.onSafety("aaudio", 30, nowMs = 11_000)
        assertEquals(2, store.puts)
        assertEquals(30, store.map["aaudio"])
        m.flush("aaudio", 28) // closing: at once
        assertEquals(28, store.map["aaudio"])
    }

    // T-118 (a): an older stored 40 starts at 30; the session may still learn up to 40, but 30 is what is kept.
    @Test fun storedFortyStartsAtThirty() {
        val store = MapStore().apply { map["aaudio"] = 40 }
        val init = SafetyMemory(store).initial("aaudio")
        assertEquals(30, SafetyMemory.REMEMBER_MAX_MS)
        assertEquals(30, init.ms)
        assertTrue(init.stored)
        assertEquals(30, init.storedMs)
        val d = DriftController()
        d.resetSafety(init.ms, SafetyMemory.defaultMs("aaudio"))
        assertEquals(30 * 48, d.safetyFrames)
        repeat(4) { d.onUnderrun() }
        assertEquals("the in-session ceiling stays 40", DriftController.SAFETY_MAX_MS * 48, d.safetyFrames)
    }

    @Test fun savedValuesAreCappedAtThirty() {
        val store = MapStore()
        val m = SafetyMemory(store)
        m.initial("aaudio")
        m.onSafety("aaudio", 40, nowMs = 0)
        assertEquals(30, store.map["aaudio"])
        // a session sitting at 35-40 does not rewrite the same 30 every ten seconds
        m.onSafety("aaudio", 35, nowMs = 20_000)
        m.onSafety("aaudio", 40, nowMs = 40_000)
        m.flush("aaudio", 38)
        assertEquals(1, store.puts)
        assertEquals(30, SafetyMemory(store).initial("aaudio").ms)
    }

    @Test fun storedThirtyNeedsNoRewriteWhenTheSessionIsHigher() {
        val store = MapStore().apply { map["aaudio"] = 40 } // written before T-118
        val m = SafetyMemory(store)
        m.initial("aaudio")
        m.flush("aaudio", 40)
        assertEquals(0, store.puts) // read back as 30, still 30: nothing to write
    }

    @Test fun storeFailuresAreContained() {
        val broken = object : SafetyStore {
            override fun get(api: String): Int? = throw ClassCastException("not an int")
            override fun put(api: String, ms: Int) = throw IllegalStateException("disk")
        }
        val m = SafetyMemory(broken)
        assertEquals(20, m.initial("aaudio").ms)
        m.onSafety("aaudio", 25, nowMs = 0)
        m.flush("aaudio", 30)
    }

    @Test fun controllerStartsAtTheInitialValueAndDecaysToTheDefault() {
        val store = MapStore().apply { map["aaudio"] = 22 }
        val init = SafetyMemory(store).initial("aaudio")
        val d = DriftController()
        d.resetSafety(init.ms, SafetyMemory.defaultMs("aaudio"))
        assertEquals(22 * 48, d.safetyFrames)
        repeat(DriftController.DECAY_WINDOWS * 10) { d.onBurst(remainingFrames = 22 * 48, outFrames = 48_000) }
        assertEquals("never below the safe AAudio start", 20 * 48, d.safetyFrames)
    }
}
