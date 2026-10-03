package dev.matebridge.client.stream

import dev.matebridge.client.audio.AudioOutPref
import dev.matebridge.client.protocol.StreamPrefs
import dev.matebridge.client.session.KeyValueStore
import dev.matebridge.client.session.Settings
import dev.matebridge.client.video.VideoRenderer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** T-109 (decision 0014): game mode's temporary defaults and its jitter buffer. */
class GameModeTest {
    /** Records every write, so a test can prove the stored settings were never touched. */
    private class MemStore : KeyValueStore {
        val map = HashMap<String, String>()
        val writes = ArrayList<String>()
        override fun getString(key: String) = map[key]
        override fun putString(key: String, value: String) { writes += key; map[key] = value }
    }

    private val store = MemStore()
    private val settings = Settings(store)

    /** User's stored choices: TRACK audio, trail and dot on; bit rate as given. */
    private fun storeUserChoices(bitrateKbps: Long = Bitrate.AUTO_KBPS) {
        settings.setBitrateKbps(bitrateKbps)
        settings.setAudioOut(AudioOutPref.TRACK)
        settings.setPenTrail(true)
        settings.setPenDot(true)
        store.writes.clear()
    }

    private val stored = { GameModeSettings.Values(settings.bitrateKbps(), settings.audioOut(), settings.penTrail(), settings.penDot()) }

    @Test fun enterBuildsTheGameDefaults() {
        storeUserChoices()
        val g = GameModeSettings(settings)
        assertFalse(g.active)
        assertEquals(GameModeSettings.Change.ENTER, g.onModeChanged(StreamMode.GAME))
        assertTrue(g.active)
        assertEquals(GameModeSettings.Values(60_000, AudioOutPref.AUTO, penTrail = false, penDot = false), g.effective())
        assertEquals(StreamPrefs(120, 660, 60_000, 1848, 1214), g.prefs(StreamMode.GAME))
        assertTrue(store.writes.isEmpty())
    }

    @Test fun storedNonAutoBitrateIsKept() {
        storeUserChoices(bitrateKbps = 30_000)
        val g = GameModeSettings(settings)
        g.onModeChanged(StreamMode.GAME)
        assertEquals(30_000L, g.bitrateKbps)
        assertEquals(StreamPrefs(120, 660, 30_000, 1848, 1214), g.prefs(StreamMode.GAME))
        storeUserChoices(bitrateKbps = 100_000)
        val g2 = GameModeSettings(settings)
        g2.onModeChanged(StreamMode.GAME)
        assertEquals(100_000L, g2.bitrateKbps)
    }

    @Test fun changesInGameModeOnlyTouchTheLayer() {
        storeUserChoices()
        val before = stored()
        val g = GameModeSettings(settings)
        g.onModeChanged(StreamMode.GAME)
        g.setBitrateKbps(15_000)
        g.setAudioOut(AudioOutPref.TRACK)
        g.setPenTrail(true)
        g.setPenDot(true)
        assertEquals(GameModeSettings.Values(15_000, AudioOutPref.TRACK, penTrail = true, penDot = true), g.effective())
        assertEquals(StreamPrefs(120, 660, 15_000, 1848, 1214), g.prefs(StreamMode.GAME))
        g.setBitrateKbps(12_345) // not an option: Otomatik, still only in the layer
        assertEquals(Bitrate.AUTO_KBPS, g.bitrateKbps)
        assertTrue(store.writes.isEmpty())
        assertEquals(before, stored())
        assertEquals(before, g.saved())
    }

    @Test fun exitRestoresTheStoredValuesAndReentryStartsFresh() {
        storeUserChoices()
        val before = stored()
        val g = GameModeSettings(settings)
        g.onModeChanged(StreamMode.GAME)
        g.setPenTrail(true)
        g.setBitrateKbps(100_000)
        assertEquals(GameModeSettings.Change.EXIT, g.onModeChanged(StreamMode.SMOOTH))
        assertFalse(g.active)
        assertEquals(before, g.effective())
        assertEquals(StreamPrefs(120, 1000, 0), g.prefs(StreamMode.SMOOTH))
        assertEquals(GameModeSettings.Change.ENTER, g.onModeChanged(StreamMode.GAME))
        assertEquals(GameModeSettings.Values(60_000, AudioOutPref.AUTO, penTrail = false, penDot = false), g.effective())
        assertTrue(store.writes.isEmpty())
        assertEquals(before, stored())
    }

    @Test fun outsideGameModeWritesGoToTheStoredSettings() {
        val g = GameModeSettings(settings)
        g.onModeChanged(StreamMode.PERFORMANCE)
        g.setBitrateKbps(30_000)
        g.setAudioOut(AudioOutPref.TRACK)
        g.setPenTrail(true)
        g.setPenDot(true)
        assertEquals(30_000L, settings.bitrateKbps())
        assertEquals(AudioOutPref.TRACK, settings.audioOut())
        assertTrue(settings.penTrail())
        assertTrue(settings.penDot())
        assertEquals(StreamPrefs(120, 750, 30_000), g.prefs(StreamMode.PERFORMANCE))
        // and game mode then starts from those stored values (30 Mbps kept, the rest game defaults)
        g.onModeChanged(StreamMode.GAME)
        assertEquals(GameModeSettings.Values(30_000, AudioOutPref.AUTO, penTrail = false, penDot = false), g.effective())
    }

    @Test fun onlyRealTransitionsChangeAnything() {
        val g = GameModeSettings(settings)
        assertNull(g.onModeChanged(StreamMode.SMOOTH))
        assertNull(g.onModeChanged(StreamMode.CLARITY))
        assertEquals(GameModeSettings.Change.ENTER, g.onModeChanged(StreamMode.GAME))
        g.setPenDot(true)
        assertNull(g.onModeChanged(StreamMode.GAME)) // game to game keeps the layer
        assertTrue(g.penDot)
        assertEquals(GameModeSettings.Change.EXIT, g.onModeChanged(StreamMode.CLARITY))
        assertNull(g.onModeChanged(StreamMode.PERFORMANCE))
    }

    @Test fun game120And60ShareTheLayer() {
        storeUserChoices()
        val g = GameModeSettings(settings)
        assertEquals(GameModeSettings.Change.ENTER, g.onModeChanged(StreamMode.GAME))
        g.setPenDot(true)
        g.setBitrateKbps(30_000)
        assertNull(g.onModeChanged(StreamMode.GAME60)) // 120 -> 60 is not leaving game mode
        assertTrue(g.active)
        assertTrue(g.penDot)
        assertEquals(StreamPrefs(60, 1000, 30_000, 1848, 1214), g.prefs(StreamMode.GAME60))
        assertNull(g.onModeChanged(StreamMode.GAME)) // and back
        assertTrue(g.penDot)
        assertEquals(GameModeSettings.Change.EXIT, g.onModeChanged(StreamMode.GAME60.next()))
        assertFalse(g.active)
        // entering directly into Oyun 60 builds the layer too
        val g2 = GameModeSettings(settings)
        assertEquals(GameModeSettings.Change.ENTER, g2.onModeChanged(StreamMode.GAME60))
        assertEquals(GameModeSettings.Values(60_000, AudioOutPref.AUTO, penTrail = false, penDot = false), g2.effective())
        assertEquals(
            GameJitter.Choice(VideoRenderer.BUFFER_ADAPTIVE, GameJitter.Source.MODE),
            GameJitter.choose(VideoRenderer.BUFFER_ADAPTIVE, null, g2.active),
        )
        assertEquals(GameModeSettings.Change.EXIT, g2.onModeChanged(StreamMode.CLARITY))
    }

    @Test fun appStartedWithStoredGame60StartsWithTheDefaults() {
        storeUserChoices()
        settings.setStreamMode(StreamMode.GAME60)
        val s2 = Settings(store)
        val g = GameModeSettings(s2)
        assertEquals(GameModeSettings.Change.ENTER, g.onModeChanged(s2.streamMode()))
        assertEquals(StreamPrefs(60, 1000, 60_000, 1848, 1214), g.prefs(s2.streamMode()))
    }

    @Test fun appStartedWithStoredGameModeStartsWithTheDefaults() {
        storeUserChoices()
        settings.setStreamMode(StreamMode.GAME)
        store.writes.clear()
        // a new process: fresh objects over the same store
        val s2 = Settings(store)
        val g = GameModeSettings(s2)
        assertEquals(GameModeSettings.Change.ENTER, g.onModeChanged(s2.streamMode()))
        assertEquals(GameModeSettings.Values(60_000, AudioOutPref.AUTO, penTrail = false, penDot = false), g.effective())
        assertEquals(StreamPrefs(120, 660, 60_000, 1848, 1214), g.prefs(s2.streamMode()))
        assertTrue(store.writes.isEmpty())
        assertEquals(AudioOutPref.TRACK, s2.audioOut())
        assertTrue(s2.penTrail())
    }

    @Test fun jitterIsAdaptiveInGameModesFromTheMode() {
        // Decision 0014 §2 amended 2026-10-04 (T-211): game modes use the adaptive pacer too.
        val adaptive = VideoRenderer.BUFFER_ADAPTIVE
        val fromMode = GameJitter.Choice(adaptive, GameJitter.Source.MODE)
        assertEquals(fromMode, GameJitter.choose(adaptive, null, game = false))
        assertEquals(fromMode, GameJitter.choose(adaptive, null, game = true))
        for (mode in listOf(StreamMode.GAME, StreamMode.GAME60)) {
            val g = GameModeSettings(settings)
            assertEquals(GameModeSettings.Change.ENTER, g.onModeChanged(mode))
            val c = GameJitter.choose(adaptive, null, g.active)
            assertEquals(fromMode, c)
            assertEquals(
                "action=enter overrides=bitrate,audio,pen jitter=adaptive bitrate_kbps=60000 audio_out=auto",
                GameModeSettings.logFields(GameModeSettings.Change.ENTER, c, g.effective()),
            )
        }
    }

    @Test fun jitterSurvivesExitAndReentry() {
        val adaptive = VideoRenderer.BUFFER_ADAPTIVE
        // no launch value: adaptive throughout, the source stays `mode`
        val g = GameModeSettings(settings)
        for (mode in listOf(StreamMode.GAME, StreamMode.SMOOTH, StreamMode.GAME60, StreamMode.CLARITY, StreamMode.GAME)) {
            g.onModeChanged(mode)
            assertEquals(mode.isGame, g.active)
            assertEquals(GameJitter.Choice(adaptive, GameJitter.Source.MODE), GameJitter.choose(adaptive, null, g.active))
        }
        // `--ez dev true --ei jitter 0`: buffer 0 in and out of game mode, across re-entry
        val g2 = GameModeSettings(settings)
        for (mode in listOf(StreamMode.GAME60, StreamMode.SMOOTH, StreamMode.GAME)) {
            g2.onModeChanged(mode)
            assertEquals(GameJitter.Choice(0, GameJitter.Source.EXTRA), GameJitter.choose(0, GameJitter.Source.EXTRA, g2.active))
        }
    }

    @Test fun launchJitterZeroGivesTheOldGameBuffer() {
        // T-211 A/B: `--ez dev true --ei jitter 0` -> MainActivity passes (0, EXTRA).
        val c = GameJitter.choose(0, GameJitter.Source.EXTRA, game = true)
        assertEquals(GameJitter.Choice(0, GameJitter.Source.EXTRA), c)
        val e = GameModeSettings.Values(60_000L, AudioOutPref.AUTO, penTrail = false, penDot = false)
        assertEquals(
            "action=enter overrides=bitrate,audio,pen jitter=0 jitter_src=extra bitrate_kbps=60000 audio_out=auto",
            GameModeSettings.logFields(GameModeSettings.Change.ENTER, c, e),
        )
    }

    @Test fun launchAdaptiveJitterWinsInGameMode() {
        // T-210: `--ez dev true --ei jitter -1` -> MainActivity passes (BUFFER_ADAPTIVE, EXTRA).
        val adaptive = VideoRenderer.BUFFER_ADAPTIVE
        val c = GameJitter.choose(adaptive, GameJitter.Source.EXTRA, game = true)
        assertEquals(GameJitter.Choice(adaptive, GameJitter.Source.EXTRA), c)
        assertEquals("adaptive", GameJitter.label(c.bufferFrames))
        val e = GameModeSettings.Values(60_000L, AudioOutPref.AUTO, penTrail = false, penDot = false)
        assertEquals(
            "action=enter overrides=bitrate,audio,pen jitter=adaptive jitter_src=extra bitrate_kbps=60000 audio_out=auto",
            GameModeSettings.logFields(GameModeSettings.Change.ENTER, c, e),
        )
    }

    @Test fun launchJitterWins() {
        assertEquals(GameJitter.Choice(2, GameJitter.Source.EXTRA), GameJitter.choose(2, GameJitter.Source.EXTRA, game = true))
        assertEquals(GameJitter.Choice(1, GameJitter.Source.EXTRA), GameJitter.choose(1, GameJitter.Source.EXTRA, game = false))
    }

    @Test fun logLine() {
        val e = GameModeSettings.Values(60_000, AudioOutPref.AUTO, penTrail = false, penDot = false)
        assertEquals(
            "action=enter overrides=bitrate,audio,pen jitter=0 bitrate_kbps=60000 audio_out=auto",
            GameModeSettings.logFields(GameModeSettings.Change.ENTER, GameJitter.Choice(0, GameJitter.Source.MODE), e),
        )
        assertEquals(
            "action=exit overrides=bitrate,audio,pen jitter=adaptive bitrate_kbps=0 audio_out=track",
            GameModeSettings.logFields(
                GameModeSettings.Change.EXIT,
                GameJitter.Choice(VideoRenderer.BUFFER_ADAPTIVE, GameJitter.Source.MODE),
                e.copy(bitrateKbps = 0, audioOut = AudioOutPref.TRACK),
            ),
        )
        assertEquals(
            "action=enter overrides=bitrate,audio,pen jitter=2 jitter_src=extra bitrate_kbps=60000 audio_out=auto",
            GameModeSettings.logFields(GameModeSettings.Change.ENTER, GameJitter.Choice(2, GameJitter.Source.EXTRA), e),
        )
    }
}
