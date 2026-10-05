package dev.matebridge.client.stream

import dev.matebridge.client.protocol.StreamConfig
import dev.matebridge.client.session.KeyValueStore
import dev.matebridge.client.session.Settings
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** T-241 (decision 0033): "Keskin renk kenarları" store, panel policy and the GameModeSettings path. */
class SharpChromaTest {
    private class MemStore : KeyValueStore {
        val map = HashMap<String, String>()
        override fun getString(key: String) = map[key]
        override fun putString(key: String, value: String) { map[key] = value }
        override fun remove(key: String) { map.remove(key) }
    }

    private val kv = MemStore()
    private val store = SharpChromaStore(kv)
    private val sdr = StreamConfig(1, 2, 2800, 1840, 1400, 920, 60, 50000, 1, 13, 1, 1)
    private val hdr10 = StreamConfig(3, 2, 1848, 1214, 1848, 1214, 120, 60000, 9, 16, 9, 0)

    @Test fun storeDefaultsOffAndOnlyAStoredOneEnables() {
        assertFalse(store.get())
        kv.map[SharpChromaStore.KEY] = "yes"
        assertFalse(store.get())
        store.set(true)
        assertEquals("1", kv.map["sharp_chroma"])
        assertTrue(store.get())
        store.set(false)
        assertFalse(store.get())
    }

    @Test fun resetRemovesTheKeyAndReportsWhetherOneWasStored() {
        assertFalse(store.reset())
        store.set(true)
        assertTrue(store.reset())
        assertNull(kv.map[SharpChromaStore.KEY])
        assertFalse(store.get())
    }

    @Test fun policyValuesAndHdrGreying() {
        assertEquals(0, SharpChromaPolicy.chroma(false))
        assertEquals(1, SharpChromaPolicy.chroma(true))
        assertEquals("off", SharpChromaPolicy.selected(false))
        assertEquals("on", SharpChromaPolicy.selected(true))
        // No stream yet, or SDR: enabled, no mark. HDR10 applied (transfer 16): grey and marked.
        assertTrue(SharpChromaPolicy.rowEnabled(null))
        assertTrue(SharpChromaPolicy.rowEnabled(sdr))
        assertEquals("", SharpChromaPolicy.marker(sdr))
        assertFalse(SharpChromaPolicy.rowEnabled(hdr10))
        assertEquals(" (HDR açıkken etkisiz)", SharpChromaPolicy.marker(hdr10))
        assertEquals("chroma=0", SharpChromaPolicy.profileField(false))
        assertEquals("chroma=1", SharpChromaPolicy.profileField(true))
    }

    @Test fun gameModeSettingsStoresAndReturnsPrefsOnlyOnChange() {
        val g = GameModeSettings(Settings(kv), hdr = HdrCapability.NONE, chromaStore = store)
        assertFalse(g.sharpChroma)
        assertEquals(0, g.chroma)
        for (m in StreamMode.entries) {
            val k = MemStore()
            val gm = GameModeSettings(Settings(k), chromaStore = SharpChromaStore(k))
            assertNotNull("mode=$m", gm.selectSharpChroma(true, m)) // every mode
            assertEquals(1, gm.chroma)
        }
        assertNotNull(g.selectSharpChroma(true, StreamMode.DAILY))
        assertTrue(store.get())
        assertNull(g.selectSharpChroma(true, StreamMode.DAILY)) // same value: nothing to send
        assertNotNull(g.selectSharpChroma(false, StreamMode.GAME))
        assertFalse(g.sharpChroma)
    }

    @Test fun gameModeSettingsResetAndNoStore() {
        val g = GameModeSettings(Settings(kv), chromaStore = store)
        g.selectSharpChroma(true, StreamMode.DAILY)
        assertTrue(g.resetSharpChroma())
        assertFalse(g.sharpChroma)
        assertFalse(g.resetSharpChroma())
        // Without a store: always off, nothing stored, nothing sent.
        val none = GameModeSettings(Settings(MemStore()))
        assertFalse(none.sharpChroma)
        assertNull(none.selectSharpChroma(true, StreamMode.DAILY))
        assertFalse(none.resetSharpChroma())
    }

    @Test fun theLayerDoesNotTouchIt() {
        val g = GameModeSettings(Settings(kv), chromaStore = store)
        g.selectSharpChroma(true, StreamMode.DAILY)
        g.onModeChanged(StreamMode.GAME)
        assertTrue(g.sharpChroma)
        g.onModeChanged(StreamMode.DRAWING)
        assertTrue(g.sharpChroma)
        g.onModeChanged(StreamMode.DAILY)
        assertTrue(g.sharpChroma)
    }
}
