package dev.matebridge.client.stream

import dev.matebridge.client.protocol.StreamConfig
import dev.matebridge.client.protocol.StreamPrefs
import dev.matebridge.client.session.KeyValueStore
import dev.matebridge.client.session.Settings
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** T-223 (decision 0030): the three modes, their frame rates and the old-id migration. */
class StreamModeTest {
    private class MemStore : KeyValueStore {
        val map = HashMap<String, String>()
        override fun getString(key: String) = map[key]
        override fun putString(key: String, value: String) { map[key] = value }
        override fun remove(key: String) { map.remove(key) }
    }

    @Test fun threeModesInCycleOrder() {
        assertEquals(listOf(StreamMode.DAILY, StreamMode.DRAWING, StreamMode.GAME), StreamMode.entries)
        assertEquals(listOf("Günlük", "Çizim", "Oyun"), StreamMode.entries.map { it.label })
        assertEquals(listOf("daily", "drawing", "game"), StreamMode.entries.map { it.id })
        assertEquals(StreamMode.DAILY, StreamMode.DEFAULT)
        assertEquals(listOf(StreamMode.GAME), StreamMode.entries.filter { it.isGame })
        assertEquals(listOf(StreamMode.DRAWING), StreamMode.entries.filter { it.isDrawing })
        assertEquals(listOf(StreamMode.DAILY, StreamMode.GAME), StreamMode.entries.filter { it.hasFpsSetting })
    }

    @Test fun tableMatchesTheCard() {
        // Günlük 120 = (120, 1000, auto); Oyun defaults to 60; Çizim is always 120; the scale is always 1000
        assertEquals(StreamPrefs(120, 1000, 0), StreamMode.DAILY.toPrefs())
        assertEquals(StreamPrefs(60, 1000, 0), StreamMode.DAILY.toPrefs(fps = 60))
        assertEquals(StreamPrefs(60, 1000, 0), StreamMode.GAME.toPrefs())
        assertEquals(StreamPrefs(120, 1000, 60_000), StreamMode.GAME.toPrefs(fps = 120, bitrateKbps = 60_000))
        assertEquals(StreamPrefs(120, 1000, 0), StreamMode.DRAWING.toPrefs())
        assertEquals(StreamPrefs(120, 1000, 0), StreamMode.DRAWING.toPrefs(fps = 60)) // never 60
        assertEquals(120, StreamMode.DAILY.defaultFps)
        assertEquals(120, StreamMode.DRAWING.defaultFps)
        assertEquals(60, StreamMode.GAME.defaultFps)
        assertEquals(1000, StreamMode.SCALE_PERMILLE)
    }

    @Test fun invalidFrameRatesFallBackToTheModeDefault() {
        assertEquals(120, StreamMode.DAILY.resolveFps(90))
        assertEquals(120, StreamMode.DAILY.resolveFps(null))
        assertEquals(60, StreamMode.GAME.resolveFps(144))
        assertEquals(60, StreamMode.GAME.resolveFps(null))
        assertEquals(120, StreamMode.GAME.resolveFps(120))
        assertEquals(120, StreamMode.DRAWING.resolveFps(60))
        assertEquals(listOf(60, 120), StreamMode.FPS_OPTIONS)
    }

    @Test fun cycleVisitsThreeModesAndWraps() {
        var m = StreamMode.DAILY
        val seen = ArrayList<StreamMode>()
        repeat(4) { m = m.next(); seen += m }
        assertEquals(listOf(StreamMode.DRAWING, StreamMode.GAME, StreamMode.DAILY, StreamMode.DRAWING), seen)
    }

    @Test fun idsAreUniqueAndParseRoundTrips() {
        assertEquals(StreamMode.entries.size, StreamMode.entries.map { it.id }.toSet().size)
        for (m in StreamMode.entries) assertEquals(m, StreamMode.parse(m.id))
        assertEquals(StreamMode.DEFAULT, StreamMode.parse(null))
        assertEquals(StreamMode.DEFAULT, StreamMode.parse("bogus"))
        assertEquals(StreamMode.DEFAULT, StreamMode.parse(""))
    }

    @Test fun removedPreT223IdsFallBackToTheDefault() {
        for (id in listOf("clarity", "smooth", "performance", "performance144", "game60")) assertEquals(id, StreamMode.DEFAULT, StreamMode.parse(id))
        assertEquals(StreamMode.GAME, StreamMode.parse("game")) // still a current id
    }

    @Test fun texts() {
        assertEquals("Görüntü modu: Günlük (120 fps)", StreamMode.DAILY.buttonText(120))
        assertEquals("Görüntü modu: Çizim (120 fps)", StreamMode.DRAWING.buttonText(60)) // always 120
        assertEquals("Günlük: 120 fps", StreamMode.DAILY.toastText(120))
        assertEquals("Günlük: 60 fps", StreamMode.DAILY.toastText(60))
        assertEquals("Çizim: 120 fps", StreamMode.DRAWING.toastText(120))
        assertEquals("Oyun: 60 fps", StreamMode.GAME.toastText(60)) // game display off
        assertEquals("Oyun: 60 fps, 1848×1214", StreamMode.GAME.toastText(60, GameResolution.R1848))
        assertEquals("Oyun: 120 fps, 2240×1472", StreamMode.GAME.toastText(120, GameResolution.R2240))
    }

    @Test fun settingsPersistTheModeAndDefaultToDaily() {
        val store = MemStore()
        assertEquals(StreamMode.DAILY, Settings(store).streamMode())
        Settings(store).setStreamMode(StreamMode.DRAWING)
        assertEquals(StreamMode.DRAWING, Settings(store).streamMode())
        Settings(store).setStreamMode(StreamMode.GAME) // T-109: Oyun can be the stored mode
        assertEquals(StreamMode.GAME, Settings(store).streamMode())
        store.map["stream_mode"] = "performance144" // removed mode
        assertEquals(StreamMode.DAILY, Settings(store).streamMode())
        store.map["stream_mode"] = "garbage"
        assertEquals(StreamMode.DAILY, Settings(store).streamMode())
    }

    // ---- per-mode frame rate setting ----

    @Test fun eachModeRemembersItsOwnFrameRate() {
        val store = MemStore()
        val s = Settings(store)
        assertEquals(120, s.modeFps(StreamMode.DAILY)) // defaults
        assertEquals(60, s.modeFps(StreamMode.GAME))
        assertEquals(120, s.modeFps(StreamMode.DRAWING))
        s.setModeFps(StreamMode.DAILY, 60)
        s.setModeFps(StreamMode.GAME, 120)
        assertEquals("60", store.map["fps_daily"])
        assertEquals("120", store.map["fps_game"])
        val again = Settings(store) // a new process
        assertEquals(60, again.modeFps(StreamMode.DAILY))
        assertEquals(120, again.modeFps(StreamMode.GAME))
        again.setModeFps(StreamMode.DAILY, 120) // changing one leaves the other
        assertEquals(120, again.modeFps(StreamMode.DAILY))
        assertEquals(120, again.modeFps(StreamMode.GAME))
    }

    @Test fun drawingIsAlways120AndStoresNothing() {
        val store = MemStore()
        val s = Settings(store)
        s.setModeFps(StreamMode.DRAWING, 60)
        assertTrue(store.map.isEmpty())
        assertEquals(120, s.modeFps(StreamMode.DRAWING))
    }

    @Test fun invalidStoredOrSetRatesAreIgnored() {
        val store = MemStore()
        val s = Settings(store)
        s.setModeFps(StreamMode.DAILY, 90)
        assertTrue(store.map.isEmpty())
        store.map["fps_daily"] = "144"
        store.map["fps_game"] = "garbage"
        assertEquals(120, s.modeFps(StreamMode.DAILY)) // Günlük default
        assertEquals(60, s.modeFps(StreamMode.GAME)) // Oyun default
    }

    // ---- layout ----

    private fun cfg(wPx: Int, hPx: Int, fps: Int = 120) = StreamConfig(1, 2, wPx, hPx, 1400, 920, fps, 20000, 1, 1, 1, 1)

    @Test fun smallEncodedSizeFillsTheSameRectangleAsFullSize() {
        val full = cfg(2800, 1840)
        val small = cfg(2100, 1380) // 75 percent
        val odd = cfg(2102, 1382) // rounding must not move the picture
        val vp = { c: StreamConfig -> VideoLayout.aspectSize(c).let { (w, h) -> VideoViewport(2800, 1840, w, h) } }
        for (c in listOf(full, small, odd)) {
            val v = vp(c)
            assertEquals(2800f, v.width, 0.01f)
            assertEquals(1840f, v.height, 0.01f)
            assertEquals(0, v.normX(0f))
            assertEquals(65535, v.normX(2800f))
        }
    }

    @Test fun missingPointSizeFallsBackToPixels() {
        val c = StreamConfig(1, 2, 2100, 1380, 0, 0, 60, 1, 1, 1, 1, 1)
        assertEquals(2100 to 1380, VideoLayout.aspectSize(c))
    }

    @Test fun overlayLineShowsModeAndEncodedSize() {
        assertEquals("Mod Oyun 60 fps | 1848x1214 @60", StreamMode.overlayLine(StreamMode.GAME, 60, cfg(1848, 1214, 60)))
        assertEquals("Mod Günlük 120 fps", StreamMode.overlayLine(StreamMode.DAILY, 120, null))
        assertEquals("Mod Çizim 120 fps", StreamMode.overlayLine(StreamMode.DRAWING, 60, null))
        assertFalse(StreamMode.overlayLine(StreamMode.DAILY, 60, null).contains("120"))
    }
}
