package dev.matebridge.client.stream

import dev.matebridge.client.protocol.Capabilities
import dev.matebridge.client.protocol.StreamPrefs
import dev.matebridge.client.session.KeyValueStore
import dev.matebridge.client.session.Settings
import dev.matebridge.client.video.FullChromaCapability
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** T-259 (decision 0034): the colour choice, the `chroma` request rules and the stored capability result. */
class FullChromaPrefsTest {
    private class MemStore : KeyValueStore {
        val map = HashMap<String, String>()
        override fun getString(key: String) = map[key]
        override fun putString(key: String, value: String) { map[key] = value }
        override fun remove(key: String) { map.remove(key) }
    }

    private val kv = MemStore()

    private fun request(choice: ColourChoice, mode: StreamMode = StreamMode.DAILY, fps: Int = 60, natural: Boolean = true,
                        scale: Int = 1000, dr: Int = 0, capable: Boolean = true) =
        FullChromaPolicy.chromaRequest(choice, mode, fps, natural, scale, dr, capable)

    @Test fun fullColourOnlyInDailyAt60OnTheNativeDisplayInSdrWithCapability() {
        assertEquals(StreamPrefs.CHROMA_FULL, request(ColourChoice.FULL))
        assertEquals(StreamPrefs.CHROMA_SHARP, request(ColourChoice.FULL, fps = 120))
        assertEquals(StreamPrefs.CHROMA_SHARP, request(ColourChoice.FULL, mode = StreamMode.DRAWING, fps = 120))
        assertEquals(StreamPrefs.CHROMA_SHARP, request(ColourChoice.FULL, mode = StreamMode.GAME, natural = false))
        assertEquals(StreamPrefs.CHROMA_SHARP, request(ColourChoice.FULL, natural = false))
        assertEquals(StreamPrefs.CHROMA_SHARP, request(ColourChoice.FULL, scale = 750))
        assertEquals(StreamPrefs.CHROMA_SHARP, request(ColourChoice.FULL, dr = StreamPrefs.DYNAMIC_RANGE_HDR10))
        assertEquals(StreamPrefs.CHROMA_SHARP, request(ColourChoice.FULL, capable = false))
    }

    @Test fun otherChoicesNeverRequestFull() {
        assertEquals(StreamPrefs.CHROMA_NORMAL, request(ColourChoice.NORMAL))
        assertEquals(StreamPrefs.CHROMA_SHARP, request(ColourChoice.SHARP))
        assertEquals(StreamPrefs.CHROMA_NORMAL, request(ColourChoice.NORMAL, capable = false, fps = 120))
    }

    @Test fun storeReadsColourKeyThenTheLegacySharpSwitch() {
        val s = ColourStore(kv)
        assertEquals(ColourChoice.SHARP, s.get())
        kv.map["sharp_chroma"] = "0"
        assertEquals(ColourChoice.NORMAL, s.get())
        kv.map["sharp_chroma"] = "1"
        assertEquals(ColourChoice.SHARP, s.get())
        kv.map["colour"] = "full"
        assertEquals(ColourChoice.FULL, s.get())
        kv.map["colour"] = "garbage"
        assertEquals(ColourChoice.SHARP, s.get())
        s.set(ColourChoice.NORMAL)
        assertEquals(ColourChoice.NORMAL, s.get())
    }

    @Test fun gameModeSettingsPrefsCarryTheRequest() {
        var capable = false
        val g = GameModeSettings(Settings(kv), colourStore = ColourStore(kv), fullChromaAvailable = { capable })
        kv.map["colour"] = "full"
        val daily = StreamMode.DAILY
        // Pin the stored frame rate through the same path the panel uses.
        g.selectFrameRate(daily, 60)
        assertEquals(StreamPrefs.CHROMA_SHARP, g.prefs(daily).chroma) // capability not passed yet
        capable = true
        assertEquals(StreamPrefs.CHROMA_FULL, g.prefs(daily).chroma)
        g.selectFrameRate(daily, 120)
        assertEquals(StreamPrefs.CHROMA_SHARP, g.prefs(daily).chroma)
        assertEquals(StreamPrefs.CHROMA_SHARP, g.prefs(StreamMode.DRAWING).chroma)
        assertEquals(StreamPrefs.CHROMA_SHARP, g.prefs(StreamMode.GAME).chroma)
    }

    // ---- capability ----

    @Test fun capabilityStartsUnknownAndNeedsATest() {
        val c = FullChromaCapability(kv, "abc|1")
        assertEquals(FullChromaCapability.State.UNKNOWN, c.status().state)
        assertTrue(c.needsTest())
        assertFalse(c.available())
        assertEquals(0L, c.helloBits())
    }

    @Test fun passEnablesBit11_failDoesNot_andAnotherBuildRetests() {
        val c = FullChromaCapability(kv, "build1")
        c.recordPass()
        assertTrue(c.available())
        assertFalse(c.needsTest())
        assertEquals(Capabilities.FULL_CHROMA.toLong(), c.helloBits())
        // an APK update (different build key) forgets the result
        val next = FullChromaCapability(kv, "build2")
        assertTrue(next.needsTest())
        assertEquals(0L, next.helloBits())
        next.recordFail("gl yuv target missing")
        assertEquals(FullChromaCapability.State.FAILED, next.status().state)
        assertEquals("gl_yuv_target_missing", next.status().reason)
        assertFalse(next.needsTest())
        assertEquals(0L, next.helloBits())
    }

    @Test fun inconclusiveRetriesThenFails() {
        val c = FullChromaCapability(kv, "b")
        c.recordInconclusive("codec busy")
        assertTrue(c.needsTest())
        c.recordInconclusive("codec busy")
        assertTrue(c.needsTest())
        c.recordInconclusive("codec busy")
        assertEquals(FullChromaCapability.State.FAILED, c.status().state)
        assertFalse(c.needsTest())
        assertFalse(c.available())
    }

    @Test fun aPassAfterRetriesCounts() {
        val c = FullChromaCapability(kv, "b")
        c.recordInconclusive("x")
        c.recordPass()
        assertTrue(c.available())
    }
}
