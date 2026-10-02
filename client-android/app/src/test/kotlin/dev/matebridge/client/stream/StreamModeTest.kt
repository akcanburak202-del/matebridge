package dev.matebridge.client.stream

import dev.matebridge.client.protocol.StreamConfig
import dev.matebridge.client.protocol.StreamPrefs
import dev.matebridge.client.session.KeyValueStore
import dev.matebridge.client.session.Settings
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class StreamModeTest {
    private class MemStore : KeyValueStore {
        val map = HashMap<String, String>()
        override fun getString(key: String) = map[key]
        override fun putString(key: String, value: String) { map[key] = value }
    }

    @Test fun tableMatchesTheCard() {
        assertEquals(StreamPrefs(60, 1000), StreamMode.CLARITY.toPrefs())
        assertEquals(StreamPrefs(120, 1000), StreamMode.SMOOTH.toPrefs())
        assertEquals(StreamPrefs(120, 900), StreamMode.DRAWING.toPrefs()) // decision 0017
        assertEquals(StreamPrefs(120, 750), StreamMode.PERFORMANCE.toPrefs())
        assertEquals(StreamPrefs(120, 660), StreamMode.GAME.toPrefs()) // decision 0014
        assertEquals(StreamPrefs(60, 1000), StreamMode.GAME60.toPrefs()) // decision 0016
        assertEquals(listOf(StreamMode.GAME, StreamMode.GAME60), StreamMode.entries.filter { it.isGame })
        assertEquals(StreamMode.SMOOTH, StreamMode.DEFAULT)
    }

    @Test fun cycleVisitsEveryModeAndWraps() {
        var m = StreamMode.CLARITY
        val seen = ArrayList<StreamMode>()
        repeat(7) { m = m.next(); seen += m }
        assertEquals(
            listOf(StreamMode.SMOOTH, StreamMode.DRAWING, StreamMode.PERFORMANCE, StreamMode.GAME, StreamMode.GAME60, StreamMode.CLARITY, StreamMode.SMOOTH),
            seen,
        )
    }

    @Test fun idsAreUniqueAndParseRoundTrips() {
        assertEquals(StreamMode.entries.size, StreamMode.entries.map { it.id }.toSet().size)
        for (m in StreamMode.entries) assertEquals(m, StreamMode.parse(m.id))
        assertEquals(StreamMode.GAME60, StreamMode.parse("game60"))
        assertEquals(StreamMode.GAME, StreamMode.parse("game"))
        assertEquals(StreamMode.DRAWING, StreamMode.parse("drawing"))
        assertEquals(StreamMode.DEFAULT, StreamMode.parse(null))
        assertEquals(StreamMode.DEFAULT, StreamMode.parse("bogus"))
    }

    @Test fun drawScaleIsClampedAndOnlyAffectsDrawing() {
        assertEquals(500, StreamMode.clampDrawScale(100))
        assertEquals(1000, StreamMode.clampDrawScale(5000))
        assertEquals(850, StreamMode.clampDrawScale(850))
        assertEquals(StreamPrefs(120, 850, 0), StreamMode.DRAWING.toPrefs(drawScale = 850))
        assertEquals(StreamPrefs(120, 500, 0), StreamMode.DRAWING.toPrefs(drawScale = 1))
        assertEquals(StreamPrefs(120, 1000, 0), StreamMode.SMOOTH.toPrefs(drawScale = 850))
        assertEquals(StreamPrefs(120, 750, 0), StreamMode.PERFORMANCE.toPrefs(drawScale = 850))
        assertEquals(StreamPrefs(120, 660, 0), StreamMode.GAME.toPrefs(drawScale = 850))
        assertEquals("Çizim: 120 fps, %85", StreamMode.DRAWING.toastText(850))
    }

    @Test fun drawingIsNotAGameAndBuildsNoGameLayer() {
        assertEquals(false, StreamMode.DRAWING.isGame)
        val g = GameModeSettings(Settings(MemStore()))
        assertNull(g.onModeChanged(StreamMode.DRAWING))
        assertEquals(StreamPrefs(120, 850, 0), g.prefs(StreamMode.DRAWING, 850))
    }

    @Test fun drawingPersistsAndRestores() {
        val store = MemStore()
        Settings(store).setStreamMode(StreamMode.DRAWING)
        assertEquals(StreamMode.DRAWING, Settings(store).streamMode())
    }

    @Test fun texts() {
        assertEquals("Çizim: 120 fps, %90", StreamMode.DRAWING.toastText())
        assertEquals("Görüntü modu: Akıcı (120 fps)", StreamMode.SMOOTH.buttonText())
        assertEquals("Performans: 120 fps, %75", StreamMode.PERFORMANCE.toastText())
        assertEquals("Netlik: 60 fps, %100", StreamMode.CLARITY.toastText())
        assertEquals("Oyun 120: 120 fps, %66", StreamMode.GAME.toastText())
        assertEquals("Oyun 60: 60 fps, %100", StreamMode.GAME60.toastText())
    }

    @Test fun settingsPersistTheModeAndDefaultToSmooth() {
        val store = MemStore()
        assertEquals(StreamMode.SMOOTH, Settings(store).streamMode())
        Settings(store).setStreamMode(StreamMode.PERFORMANCE)
        assertEquals(StreamMode.PERFORMANCE, Settings(store).streamMode())
        Settings(store).setStreamMode(StreamMode.GAME) // T-109: game mode can be the stored mode
        assertEquals(StreamMode.GAME, Settings(store).streamMode())
        store.map["stream_mode"] = "performance144" // removed mode
        assertEquals(StreamMode.PERFORMANCE, Settings(store).streamMode())
        store.map["stream_mode"] = "garbage"
        assertEquals(StreamMode.SMOOTH, Settings(store).streamMode())
    }

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
        assertEquals("Mod Performans 120 fps | 2100x1380 @120", StreamMode.overlayLine(StreamMode.PERFORMANCE, cfg(2100, 1380)))
        assertEquals("Mod Akıcı 120 fps", StreamMode.overlayLine(StreamMode.SMOOTH, null))
    }
}
