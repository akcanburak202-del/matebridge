package dev.matebridge.client.audio

import dev.matebridge.client.session.Transport.USB
import dev.matebridge.client.session.Transport.WIFI
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** T-123: safety remembered per output API and transport. */
class SafetyTransportTest {
    private class MapStore : SafetyStore {
        val map = HashMap<String, Int>()
        var puts = 0
        override fun get(key: String): Int? = map[key]
        override fun put(key: String, ms: Int) { map[key] = ms; puts++ }
    }

    /** One 1 s window of 96-frame bursts at the target (clean playback). */
    private fun cleanWindow(d: DriftController) {
        repeat(500) { d.onBurst(d.targetFrames, 96) }
    }

    @Test fun keysAreApiSlashTransport() {
        assertEquals("aaudio/usb", SafetyMemory.key("aaudio", USB))
        assertEquals("aaudio/wifi", SafetyMemory.key("aaudio", WIFI))
        assertEquals("track/usb", SafetyMemory.key("track", USB))
        assertEquals("track/wifi", SafetyMemory.key("track", WIFI))
    }

    @Test fun profiles() {
        assertEquals(SafetyMemory.Profile(20, 30, 40), SafetyMemory.profile("aaudio", USB))
        assertEquals(SafetyMemory.Profile(5, 30, 40), SafetyMemory.profile("track", USB))
        assertEquals(SafetyMemory.Profile(40, 50, 70), SafetyMemory.profile("aaudio", WIFI))
        assertEquals(SafetyMemory.Profile(40, 50, 70), SafetyMemory.profile("track", WIFI))
        for (api in listOf("aaudio", "track")) {
            val u = SafetyMemory.profile(api, USB)
            val w = SafetyMemory.profile(api, WIFI)
            assertTrue(w.defaultMs > u.defaultMs)
            assertTrue(w.rememberMaxMs > u.rememberMaxMs)
            assertTrue(w.sessionMaxMs > u.sessionMaxMs)
        }
    }

    // (a) migration: the old single-key 30 becomes the USB value; Wi-Fi starts from its default.
    @Test fun oldSingleKeyValueMigratesToUsb() {
        val store = MapStore().apply { map["aaudio"] = 30; map["track"] = 12 }
        val m = SafetyMemory(store)
        val usb = m.initial("aaudio", USB)
        assertEquals(30, usb.ms)
        assertTrue(usb.stored)
        val wifi = m.initial("aaudio", WIFI)
        assertEquals(SafetyMemory.WIFI_DEFAULT_MS, wifi.ms)
        assertFalse(wifi.stored)
        assertNull(wifi.storedMs)
        assertEquals(12, m.initial("track", USB).ms)
        assertEquals(40, m.initial("track", WIFI).ms)
        assertEquals(0, store.puts) // reading migrates nothing on disk
    }

    @Test fun newUsbKeyWinsOverTheOldOne() {
        val store = MapStore().apply { map["aaudio"] = 30; map["aaudio/usb"] = 22 }
        assertEquals(22, SafetyMemory(store).initial("aaudio", USB).ms)
    }

    @Test fun migratedValueIsWrittenUnderTheNewKeyWhenItMoves() {
        val store = MapStore().apply { map["aaudio"] = 30 }
        val m = SafetyMemory(store)
        m.initial("aaudio", USB)
        m.flush("aaudio", USB, 30)
        assertEquals(0, store.puts) // unchanged
        m.flush("aaudio", USB, 24)
        assertEquals(24, store.map["aaudio/usb"])
        assertEquals(30, store.map["aaudio"]) // left alone, no longer read
        assertEquals(24, SafetyMemory(store).initial("aaudio", USB).ms)
    }

    // (b) a margin grown on Wi-Fi does not touch the USB record.
    @Test fun wifiGrowthLeavesUsbAlone() {
        val store = MapStore().apply { map["aaudio/usb"] = 25 }
        val m = SafetyMemory(store)
        m.initial("aaudio", WIFI)
        m.onSafety("aaudio", WIFI, 60, nowMs = 0)
        m.flush("aaudio", WIFI, 65)
        assertEquals(SafetyMemory.WIFI_REMEMBER_MAX_MS, store.map["aaudio/wifi"])
        assertEquals(25, store.map["aaudio/usb"])
        val next = SafetyMemory(store)
        assertEquals(25, next.initial("aaudio", USB).ms)
        assertEquals(50, next.initial("aaudio", WIFI).ms)
    }

    @Test fun wifiRemembersAtMostFifty() {
        val store = MapStore().apply { map["aaudio/wifi"] = 70 }
        val init = SafetyMemory(store).initial("aaudio", WIFI)
        assertEquals(50, init.ms)
        assertEquals("stored", init.source)
    }

    @Test fun wifiValueBelowItsDefaultStartsAtTheDefault() {
        val store = MapStore().apply { map["aaudio/wifi"] = 25 }
        val init = SafetyMemory(store).initial("aaudio", WIFI)
        assertEquals(40, init.ms)
        assertEquals("default", init.source)
        assertEquals(25, init.storedMs)
    }

    @Test fun wifiSessionCeilingIsSeventyAndDecayStopsAtForty() {
        val init = SafetyMemory(MapStore()).initial("aaudio", WIFI)
        val d = DriftController()
        d.resetSafety(init.ms, init.profile.defaultMs, init.profile.sessionMaxMs)
        assertEquals(40 * 48, d.safetyFrames)
        repeat(10) { d.onUnderrun() }
        assertEquals(70 * 48, d.safetyFrames)
        // T-118 decay speed: 1 ms per 5 clean windows, 70 -> 40 in 150 s, never below the Wi-Fi floor
        var windows = 0
        while (d.safetyFrames > 40 * 48) { cleanWindow(d); windows++ }
        assertEquals(30 * DriftController.DECAY_WINDOWS, windows)
        repeat(100) { cleanWindow(d) }
        assertEquals(40 * 48, d.safetyFrames)
    }

    // (c) USB -> Wi-Fi under a playing output: the margin rises to Wi-Fi's remembered value at once.
    @Test fun switchToWifiRisesAtOnce() {
        val store = MapStore().apply { map["aaudio/wifi"] = 47 }
        val m = SafetyMemory(store)
        val usb = m.initial("aaudio", USB)
        val d = DriftController()
        d.resetSafety(usb.ms, usb.profile.defaultMs, usb.profile.sessionMaxMs)
        repeat(3) { cleanWindow(d) }
        assertEquals(20 * 48, d.safetyFrames)
        val wifi = m.initial("aaudio", WIFI)
        assertTrue(d.retarget(wifi.ms, wifi.profile.defaultMs, wifi.profile.sessionMaxMs))
        assertEquals(47 * 48, d.safetyFrames)
        // Wi-Fi rules now: ceiling 70, floor 40
        repeat(10) { d.onUnderrun() }
        assertEquals(70 * 48, d.safetyFrames)
        repeat(1_000) { cleanWindow(d) }
        assertEquals(40 * 48, d.safetyFrames)
    }

    // (c) Wi-Fi -> USB: no sudden drop; the normal decay brings it down to the USB floor.
    @Test fun switchToUsbFallsThroughTheDecay() {
        val m = SafetyMemory(MapStore())
        val wifi = m.initial("aaudio", WIFI)
        val d = DriftController()
        d.resetSafety(wifi.ms, wifi.profile.defaultMs, wifi.profile.sessionMaxMs)
        repeat(4) { d.onUnderrun() }
        assertEquals(60 * 48, d.safetyFrames)
        val usb = m.initial("aaudio", USB)
        assertFalse(d.retarget(usb.ms, usb.profile.defaultMs, usb.profile.sessionMaxMs))
        assertEquals("kept, above the USB ceiling until it decays", 60 * 48, d.safetyFrames)
        d.onUnderrun()
        assertEquals("an underrun never lowers it", 60 * 48, d.safetyFrames)
        repeat(DriftController.DECAY_WINDOWS) { cleanWindow(d) }
        assertEquals(59 * 48, d.safetyFrames)
        var windows = DriftController.DECAY_WINDOWS
        while (d.safetyFrames > 20 * 48) { cleanWindow(d); windows++ }
        assertEquals(40 * DriftController.DECAY_WINDOWS, windows) // 60 -> 20 at the T-118 speed
        repeat(100) { cleanWindow(d) }
        assertEquals(20 * 48, d.safetyFrames)
        // USB rules again: underruns stop at 40
        repeat(10) { d.onUnderrun() }
        assertEquals(40 * 48, d.safetyFrames)
    }

    @Test fun retargetToTheSameTransportChangesNothing() {
        val d = DriftController()
        d.resetSafety(25, 20, 40)
        assertFalse(d.retarget(20, 20, 40))
        assertEquals(25 * 48, d.safetyFrames)
    }

    @Test fun resetSafetyTakesTheTransportCeiling() {
        val d = DriftController()
        d.resetSafety(initialMs = 90, floorMs = 40, maxMs = 70)
        assertEquals(70 * 48, d.safetyFrames)
        d.resetSafety(initialMs = 200, floorMs = 5, maxMs = 500)
        assertEquals(DriftController.SAFETY_CEILING_MS * 48, d.safetyFrames)
    }
}
