package dev.matebridge.client.stream

import dev.matebridge.client.protocol.StreamConfig
import dev.matebridge.client.protocol.StreamPrefs
import dev.matebridge.client.session.KeyValueStore
import dev.matebridge.client.session.Settings
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** T-260 (decision 0034 §2): the "Renk" store (with the 0033 migration), the panel policy and the GameModeSettings path. */
class ColourPanelTest {
    private class MemStore : KeyValueStore {
        val map = HashMap<String, String>()
        override fun getString(key: String) = map[key]
        override fun putString(key: String, value: String) { map[key] = value }
        override fun remove(key: String) { map.remove(key) }
    }

    private val kv = MemStore()
    private val cfg420 = StreamConfig(1, 2, 2800, 1840, 1400, 920, 60, 50000, 1, 13, 1, 1)
    private val cfgPacked = cfg420.copy(chromaLayout = 1)
    private val hdr10 = StreamConfig(3, 2, 1848, 1214, 1848, 1214, 120, 60000, 9, 16, 9, 0)

    @Test fun defaultsToNormalAndStoresEachChoice() {
        val s = ColourStore(kv)
        assertEquals(ColourChoice.NORMAL, s.get())
        for (c in ColourChoice.entries) { s.set(c); assertEquals(c, s.get()); assertEquals(c.id, kv.map["colour"]) }
        kv.map["colour"] = "garbage"
        assertEquals(ColourChoice.NORMAL, s.get())
    }

    @Test fun migratesTheOldOnOffSwitch() {
        val s = ColourStore(kv)
        kv.map["sharp_chroma"] = "1"
        assertTrue(s.migrate())
        assertEquals("sharp", kv.map["colour"]) // Açık -> Keskin kenarlar
        assertNull(kv.map["sharp_chroma"])
        assertEquals(ColourChoice.SHARP, s.get())
        assertFalse(s.migrate()) // nothing left to move
    }

    @Test fun migrationOfOffDropsTheKeyAndAStoredColourWins() {
        val s = ColourStore(kv)
        kv.map["sharp_chroma"] = "0"
        assertTrue(s.migrate())
        assertNull(kv.map["colour"])
        assertNull(kv.map["sharp_chroma"])
        assertEquals(ColourChoice.NORMAL, s.get())
        kv.map["colour"] = "full"
        kv.map["sharp_chroma"] = "1"
        s.migrate()
        assertEquals("full", kv.map["colour"])
    }

    @Test fun resetClearsBothKeys() {
        val s = ColourStore(kv)
        assertFalse(s.reset())
        kv.map["sharp_chroma"] = "1"
        assertTrue(s.reset())
        assertEquals(ColourChoice.NORMAL, s.get())
        s.set(ColourChoice.FULL)
        assertTrue(s.reset())
        assertNull(kv.map["colour"])
    }

    @Test fun policyLabelsSelectionAndMarks() {
        assertEquals("Normal", ColourPolicy.label(ColourChoice.NORMAL, false))
        assertEquals("Keskin kenarlar", ColourPolicy.label(ColourChoice.SHARP, false))
        assertEquals("Tam renk", ColourPolicy.label(ColourChoice.FULL, true))
        assertEquals("Tam renk (Bu cihazda yok)", ColourPolicy.label(ColourChoice.FULL, false))
        assertFalse(ColourPolicy.optionEnabled(ColourChoice.FULL, false))
        assertTrue(ColourPolicy.optionEnabled(ColourChoice.FULL, true))
        assertTrue(ColourPolicy.optionEnabled(ColourChoice.SHARP, false))
        assertEquals("full", ColourPolicy.selected(ColourChoice.FULL, true))
        assertEquals("sharp", ColourPolicy.selected(ColourChoice.FULL, false)) // what actually applies
        assertTrue(ColourPolicy.rowEnabled(null))
        assertTrue(ColourPolicy.rowEnabled(cfg420))
        assertFalse(ColourPolicy.rowEnabled(hdr10))
        assertEquals("", ColourPolicy.marker(cfg420))
        assertEquals(" (HDR açıkken etkisiz)", ColourPolicy.marker(hdr10))
        assertEquals("chroma=2", ColourPolicy.profileField(2))
    }

    @Test fun noteAndAppliedLines() {
        val full = ColourChoice.FULL
        assertEquals("", ColourPolicy.note(ColourChoice.SHARP, true, 1, cfg420))
        assertEquals("", ColourPolicy.note(full, false, 1, cfg420)) // option is grey instead
        assertEquals("", ColourPolicy.note(full, true, 2, cfg420))
        assertEquals("", ColourPolicy.note(full, true, 1, hdr10)) // HDR mark wins
        assertEquals("Tam renk yalnız Günlük 60'ta, şimdi: Keskin kenarlar", ColourPolicy.note(full, true, 1, cfg420))
        assertEquals("", ColourPolicy.applied(1, cfgPacked))
        assertEquals("", ColourPolicy.applied(2, null))
        assertEquals("", ColourPolicy.applied(2, hdr10))
        assertEquals("Uygulanan: Tam renk", ColourPolicy.applied(2, cfgPacked))
        assertEquals("Uygulanan: Normal (Mac yetişemedi)", ColourPolicy.applied(2, cfg420))
    }

    @Test fun gameModeSettingsMigratesAtConstructionAndSelects() {
        kv.map["sharp_chroma"] = "1"
        var capable = false
        val g = GameModeSettings(Settings(kv), colourStore = ColourStore(kv), fullChromaAvailable = { capable })
        assertEquals("sharp", kv.map["colour"])
        assertEquals(ColourChoice.SHARP, g.colourChoice())
        val daily = StreamMode.DAILY
        g.selectFrameRate(daily, 60)
        assertNull(g.selectColour(ColourChoice.SHARP, daily)) // same value: nothing to send
        assertEquals(StreamPrefs.CHROMA_NORMAL, g.selectColour(ColourChoice.NORMAL, daily)?.chroma)
        assertNull(g.selectColour(ColourChoice.FULL, daily)) // refused without the capability
        assertEquals(ColourChoice.NORMAL, g.colourChoice())
        capable = true
        assertEquals(StreamPrefs.CHROMA_FULL, g.selectColour(ColourChoice.FULL, daily)?.chroma)
        assertEquals(ColourChoice.FULL, g.colourChoice())
        assertEquals(StreamPrefs.CHROMA_SHARP, g.selectColour(ColourChoice.SHARP, daily)?.chroma)
        // Günlük 120: Tam renk asks for the sharp value, so Keskin <-> Tam renk sends nothing but is stored.
        g.selectFrameRate(daily, 120)
        assertNull(g.selectColour(ColourChoice.FULL, daily))
        assertEquals(ColourChoice.FULL, g.colourChoice())
        assertNotNull(g.selectColour(ColourChoice.NORMAL, daily)) // 1 -> 0
        assertTrue(g.resetColour())
        assertEquals(ColourChoice.NORMAL, g.colourChoice())
    }

    @Test fun withoutAStoreEverythingIsNormal() {
        val g = GameModeSettings(Settings(kv))
        assertEquals(ColourChoice.NORMAL, g.colourChoice())
        assertNull(g.selectColour(ColourChoice.SHARP, StreamMode.DAILY))
        assertFalse(g.resetColour())
    }
}
