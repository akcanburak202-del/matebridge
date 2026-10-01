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
        val store = MapStore().apply { map["aaudio"] = 33 }
        val init = SafetyMemory(store).initial("aaudio")
        assertEquals(33, init.ms)
        assertEquals("stored", init.source)
    }

    @Test fun storedValueBelowTheDefaultGivesTheDefault() {
        val store = MapStore().apply { map["aaudio"] = 10 }
        val init = SafetyMemory(store).initial("aaudio")
        assertEquals(20, init.ms)
        assertEquals("default", init.source)
        assertEquals(10, init.storedMs)
    }

    @Test fun storedValueIsClampedToTheControllerRange() {
        val store = MapStore().apply { map["aaudio"] = 500; map["track"] = -3 }
        val m = SafetyMemory(store)
        assertEquals(DriftController.SAFETY_MAX_MS, m.initial("aaudio").ms)
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
        m.flush("aaudio", 35) // closing: at once
        assertEquals(35, store.map["aaudio"])
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
