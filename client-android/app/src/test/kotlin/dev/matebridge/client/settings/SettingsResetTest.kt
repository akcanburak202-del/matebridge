package dev.matebridge.client.settings

import dev.matebridge.client.audio.AudioBufferConfig
import dev.matebridge.client.audio.AudioOutPref
import dev.matebridge.client.audio.OutBufMemory
import dev.matebridge.client.audio.OutBufStore
import dev.matebridge.client.audio.SafetyMemory
import dev.matebridge.client.audio.SafetyStore
import dev.matebridge.client.files.FilesRoot
import dev.matebridge.client.session.Endpoint
import dev.matebridge.client.session.KeyValueStore
import dev.matebridge.client.session.Settings
import dev.matebridge.client.session.Transport
import dev.matebridge.client.session.TransportMode
import dev.matebridge.client.stream.GameResolution
import dev.matebridge.client.stream.StreamMode
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** T-191 "Varsayılanlara dön": user settings and learned audio state reset; pairing, device id and wake data kept. */
class SettingsResetTest {
    private class MapKv : KeyValueStore {
        val map = LinkedHashMap<String, String>()
        override fun getString(key: String) = map[key]
        override fun putString(key: String, value: String) { map[key] = value }
        override fun remove(key: String) { map.remove(key) }
    }

    private class MapOutBuf : OutBufStore {
        val map = HashMap<String, Int>()
        override fun get(path: String) = map[path]
        override fun put(path: String, bursts: Int) { map[path] = bursts }
        override fun clear() = map.clear()
    }

    private class MapSafety : SafetyStore {
        val map = HashMap<String, Int>()
        override fun get(key: String) = map[key]
        override fun put(key: String, ms: Int) { map[key] = ms }
        override fun clear() = map.clear()
    }

    /** Every getter's value, for comparing against a fresh install. */
    private fun snapshot(s: Settings): List<Any> = listOf(
        s.statsOverlay(), s.streamMode(), s.bitrateKbps(), s.touchpadSpeed(), s.mouseSpeed(), s.clipboardShare(),
        s.filesShare(), s.filesRoot(), s.filesReadOnly(), s.audioEnabled(), s.audioOut(), s.penTrail(), s.penDot(),
        s.fingerTouchDisabled(), s.transportMode(), s.gameResolution(), s.modeFps(StreamMode.DAILY), s.modeFps(StreamMode.GAME),
        s.hdrGame(), // T-238
        s.cursorLocal(), // T-276
    )

    private fun setEverythingNonDefault(s: Settings) {
        s.setStatsOverlay(true)
        s.setStreamMode(StreamMode.GAME)
        s.setModeFps(StreamMode.DAILY, 60) // T-223
        s.setModeFps(StreamMode.GAME, 120)
        s.setGameResolution(GameResolution.R1400) // T-215
        s.setBitrateKbps(60_000)
        s.setTouchpadSpeed(2f)
        s.setMouseSpeed(0.5f)
        s.setClipboardShare(false)
        s.setFilesShare(true)
        s.setFilesRoot(FilesRoot.ALL)
        s.setFilesReadOnly(true)
        s.setAudioEnabled(false)
        s.setAudioOut(AudioOutPref.TRACK)
        s.setPenTrail(true)
        s.setPenDot(true)
        s.setFingerTouchDisabled(true)
        s.setTransportMode(TransportMode.USB)
        s.setHdrGame(true) // T-238
        s.setCursorLocal(false) // T-276: Görüntüde
    }

    @Test fun everyGetterReturnsItsDefaultAfterTheReset() {
        val kv = MapKv()
        val s = Settings(kv)
        val fresh = snapshot(Settings(MapKv()))
        setEverythingNonDefault(s)
        snapshot(s).zip(fresh).forEachIndexed { i, (now, def) -> assertTrue("setting $i must start non-default", now != def) }

        assertEquals(20, s.resetToDefaults())

        assertEquals(fresh, snapshot(s))
        assertFalse(s.statsOverlay())
        assertEquals(StreamMode.DAILY, s.streamMode()) // Günlük
        assertEquals(120, s.modeFps(StreamMode.DAILY)) // T-223: Günlük 120
        assertEquals(60, s.modeFps(StreamMode.GAME)) // Oyun 60
        assertEquals(0L, s.bitrateKbps()) // Otomatik
        assertEquals(1f, s.touchpadSpeed())
        assertEquals(1f, s.mouseSpeed())
        assertTrue(s.clipboardShare())
        assertFalse(s.filesShare())
        assertEquals(FilesRoot.MATEBRIDGE, s.filesRoot()) // T-190: back to the MateBridge folder
        assertEquals("matebridge", s.filesRoot().id)
        assertFalse(s.filesReadOnly()) // T-190: read-only off
        assertTrue(s.audioEnabled())
        assertEquals(AudioOutPref.AUTO, s.audioOut())
        assertFalse(s.penTrail())
        assertFalse(s.penDot())
        assertFalse(s.fingerTouchDisabled())
        assertEquals(TransportMode.AUTO, s.transportMode())
        assertEquals(GameResolution.R1848, s.gameResolution()) // T-215: 1848×1214
        assertFalse(s.hdrGame()) // T-238: HDR off
        assertTrue(s.cursorLocal()) // T-276: İmleç back to Tablette
    }

    @Test fun identityEndpointMigrationWakeDataAndPairKeysAreKeptByteForByte() {
        val kv = MapKv()
        val pairKeys = MapKv() // the separate `matebridge_pairkeys` file
        pairKeys.putString("trusted_0123", "wrapped-key-bytes")
        pairKeys.putString("pending_4567", "pending-key-bytes")
        val s = Settings(kv)
        val id = s.deviceId()
        s.saveEndpoint(Endpoint("192.168.1.20", 47800))
        kv.putString("transport", "usb")
        assertEquals("usb", s.migrateTransportToAutoOnce()) // sets transport_auto_migrated
        kv.putString("wol_macs", "aa:bb:cc:dd:ee:ff")
        kv.putString("wol_host", "192.168.1.20")
        kv.putString("wol_port", "47800")
        kv.putString("wol_subnet", "192.168.1.0/24")
        kv.putString("future_key", "x") // anything not on the user-setting list stays
        setEverythingNonDefault(s)
        val kept = kv.map.filterKeys {
            it in setOf("device_id", "last_endpoint", "transport_auto_migrated", "wol_macs", "wol_host", "wol_port", "wol_subnet", "future_key")
        }
        assertEquals(8, kept.size)
        val pairBefore = LinkedHashMap(pairKeys.map)

        s.resetToDefaults()

        assertEquals(kept, kv.map) // only the kept keys remain, values unchanged
        assertEquals(pairBefore, pairKeys.map)
        assertArrayEquals(id, Settings(kv).deviceId())
        assertEquals(Endpoint("192.168.1.20", 47800), s.lastEndpoint())
        assertNull(s.migrateTransportToAutoOnce()) // the T-096 migration does not run again
    }

    @Test fun resetOnAFreshInstallRemovesNothing() {
        val kv = MapKv()
        val s = Settings(kv)
        s.deviceId()
        val before = LinkedHashMap(kv.map)
        assertEquals(0, s.resetToDefaults())
        assertEquals(before, kv.map)
    }

    @Test fun outBufClearStartsFromTheDefaultEvenWithACachedValue() {
        val store = MapOutBuf().apply {
            map[OutBufMemory.PATH_EXCLUSIVE] = 6
            map[OutBufMemory.PATH_SHARED] = 5
        }
        val m = OutBufMemory(store)
        val def = AudioBufferConfig.AAUDIO_DEFAULT_BURSTS
        assertEquals(OutBufMemory.SOURCE_STORED, m.initial(OutBufMemory.PATH_EXCLUSIVE, null, def).source) // cached now
        assertEquals(OutBufMemory.SOURCE_STORED, m.initial(OutBufMemory.PATH_SHARED, null, def).source)

        assertTrue(m.clear())

        assertTrue(store.map.isEmpty())
        for (path in listOf(OutBufMemory.PATH_EXCLUSIVE, OutBufMemory.PATH_SHARED)) {
            val init = m.initial(path, null, def) // the same instance
            assertEquals(OutBufMemory.SOURCE_DEFAULT, init.source)
            assertEquals(def, init.bursts)
            assertNull(init.storedBursts)
        }
        assertEquals(OutBufMemory.SOURCE_DEFAULT, OutBufMemory(store).initial(OutBufMemory.PATH_EXCLUSIVE, null, def).source)
    }

    @Test fun outBufGrowthAfterClearIsStoredAgainAndASecondClearForgetsIt() {
        // AudioPlayout: a writer live at the reset may still grow; the next stream start clears once more.
        val store = MapOutBuf()
        val m = OutBufMemory(store)
        m.onGrown(OutBufMemory.PATH_EXCLUSIVE, 6)
        m.clear()
        assertTrue(m.onGrown(OutBufMemory.PATH_EXCLUSIVE, 5)) // the live writer
        assertEquals(5, store.map[OutBufMemory.PATH_EXCLUSIVE])
        m.clear() // stream start
        assertEquals(OutBufMemory.SOURCE_DEFAULT, m.initial(OutBufMemory.PATH_EXCLUSIVE, null, 4).source)
    }

    @Test fun safetyClearRemovesEveryValueAndStartsFromTheDefaults() {
        val store = MapSafety().apply {
            map["aaudio/usb"] = 28
            map["aaudio/wifi"] = 48
            map["track/usb"] = 12
            map["aaudio"] = 25 // pre-T-123 key, read as the USB value
        }
        val m = SafetyMemory(store)
        assertEquals("stored", m.initial("aaudio", Transport.USB).source) // lastSaved cached now
        assertEquals("stored", m.initial("aaudio", Transport.WIFI).source)

        assertTrue(m.clear())

        assertTrue(store.map.isEmpty())
        for (api in listOf("aaudio", "track")) for (tr in Transport.entries) {
            val init = m.initial(api, tr)
            assertEquals("default", init.source)
            assertEquals(SafetyMemory.defaultMs(api, tr), init.ms)
            assertNull(init.storedMs)
        }
    }

    @Test fun safetyClearDropsTheSaveCacheSoTheNextChangeIsNotSkipped() {
        val store = MapSafety()
        val m = SafetyMemory(store)
        m.initial("aaudio", Transport.USB)
        m.onSafety("aaudio", Transport.USB, 26, nowMs = 0)
        assertEquals(26, store.map["aaudio/usb"])
        m.clear()
        assertTrue(store.map.isEmpty())
        // A writer still running stores its value again at once (cache and save timer dropped) ...
        m.onSafety("aaudio", Transport.USB, 26, nowMs = 1)
        assertEquals(26, store.map["aaudio/usb"])
        // ... which is why AudioPlayout clears again at the next stream start.
        m.clear()
        assertEquals("default", m.initial("aaudio", Transport.USB).source)
    }

    @Test fun aStoreWithoutClearReportsFailureButTheCacheIsDropped() {
        val outStore = object : OutBufStore {
            val map = HashMap<String, Int>()
            override fun get(path: String) = map[path]
            override fun put(path: String, bursts: Int) { map[path] = bursts }
        }
        val out = OutBufMemory(outStore)
        out.onGrown(OutBufMemory.PATH_EXCLUSIVE, 6)
        assertFalse(out.clear()) // the interface's default body throws; the memory never does
        val safety = SafetyMemory(object : SafetyStore {
            override fun get(key: String): Int? = null
            override fun put(key: String, ms: Int) {}
        })
        assertFalse(safety.clear())
    }

    @Test fun aStoreWithoutRemoveFailsLoudly() {
        val s = Settings(object : KeyValueStore {
            override fun getString(key: String): String? = "1"
            override fun putString(key: String, value: String) {}
        })
        try {
            s.resetToDefaults()
            throw AssertionError("expected UnsupportedOperationException")
        } catch (_: UnsupportedOperationException) {
        }
    }
}
