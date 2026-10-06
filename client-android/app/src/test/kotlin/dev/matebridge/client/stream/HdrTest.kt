package dev.matebridge.client.stream

import dev.matebridge.client.protocol.Codec
import dev.matebridge.client.protocol.StreamConfig
import dev.matebridge.client.protocol.StreamPrefs
import dev.matebridge.client.session.KeyValueStore
import dev.matebridge.client.session.Settings
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** T-238 (decision 0032): HDR10 capability, the request rule (capability x mode x setting) and the panel texts. */
/** No colour store: the default "Renk" is Keskin kenarlar (decision 0034 addendum), so `chroma` is 1. */
private const val SHARP = StreamPrefs.CHROMA_SHARP

class HdrTest {
    private class MemStore : KeyValueStore {
        val map = HashMap<String, String>()
        override fun getString(key: String) = map[key]
        override fun putString(key: String, value: String) { map[key] = value }
    }

    private val store = MemStore()
    private val settings = Settings(store)
    private val capable = HdrCapability(displayHdr10 = true, decoderMain10Hdr10 = true)
    private val SDR = StreamPrefs.DYNAMIC_RANGE_SDR
    private val HDR = StreamPrefs.DYNAMIC_RANGE_HDR10

    private fun hevc(vararg profiles: Int) = HdrCapability.CodecEntry(false, listOf("video/hevc"), profiles)

    // ---- capability ----

    @Test fun displayNeedsTheHdr10Type() {
        assertTrue(HdrCapability.displayHdr10(intArrayOf(2, 3))) // the tablet: HDR10, HLG
        assertFalse(HdrCapability.displayHdr10(intArrayOf(3)))
        assertFalse(HdrCapability.displayHdr10(intArrayOf()))
        assertFalse(HdrCapability.displayHdr10(null))
    }

    @Test fun decoderIsTheFirstHevcDecoderOfTheList() {
        val main = 1; val main10 = 2
        val hisi = hevc(main, main10, HdrCapability.HEVC_PROFILE_MAIN10_HDR10)
        val sw = hevc(main)
        val encoder = HdrCapability.CodecEntry(true, listOf("video/hevc"), null)
        val avc = HdrCapability.CodecEntry(false, listOf("video/avc"), intArrayOf(HdrCapability.HEVC_PROFILE_MAIN10_HDR10))
        assertTrue(HdrCapability.decoderMain10Hdr10(listOf(encoder, avc, hisi, sw)))
        // createDecoderByType would pick the software one first: it does not advertise Main10HDR10.
        assertFalse(HdrCapability.decoderMain10Hdr10(listOf(sw, hisi)))
        assertFalse(HdrCapability.decoderMain10Hdr10(listOf(encoder, avc)))
        assertFalse(HdrCapability.decoderMain10Hdr10(emptyList()))
        assertFalse(HdrCapability.decoderMain10Hdr10(listOf(HdrCapability.CodecEntry(false, listOf("VIDEO/HEVC"), null))))
        assertTrue(HdrCapability.decoderMain10Hdr10(listOf(HdrCapability.CodecEntry(false, listOf("VIDEO/HEVC"), intArrayOf(0x1000)))))
    }

    @Test fun capsLogLine() {
        assertEquals("display_hdr10=1 decoder_main10hdr10=1", capable.logFields())
        assertEquals("display_hdr10=1 decoder_main10hdr10=0", HdrCapability(true, false).logFields())
        assertTrue(capable.supported)
        assertFalse(HdrCapability(true, false).supported)
        assertFalse(HdrCapability(false, true).supported)
        assertFalse(HdrCapability.NONE.supported)
    }

    // ---- request rule ----

    @Test fun hdr10OnlyWithCapabilityOyunAndTheSettingOn() {
        val caps = listOf(capable, HdrCapability(true, false), HdrCapability(false, true), HdrCapability.NONE)
        for (cap in caps) for (mode in StreamMode.entries) for (on in listOf(false, true)) {
            val want = if (cap.supported && mode == StreamMode.GAME && on) HDR else SDR
            assertEquals("cap=$cap mode=$mode on=$on", want, HdrPolicy.dynamicRange(cap, mode, on))
        }
    }

    @Test fun settingDefaultsOffAndPersists() {
        assertFalse(settings.hdrGame())
        settings.setHdrGame(true)
        assertTrue(Settings(store).hdrGame())
        settings.setHdrGame(false)
        assertFalse(settings.hdrGame())
        store.map["hdr_game"] = "yes" // anything but "1" is off
        assertFalse(settings.hdrGame())
    }

    @Test fun prefsCarryTheDynamicRangeOnlyInOyun() {
        settings.setHdrGame(true)
        val g = GameModeSettings(settings, hdr = capable)
        assertEquals(HDR, g.prefs(StreamMode.GAME).dynamicRange)
        assertEquals(SDR, g.prefs(StreamMode.DAILY).dynamicRange)
        assertEquals(SDR, g.prefs(StreamMode.DRAWING).dynamicRange)
        // Oyun's prefs: game display and HDR10 -> 14 bytes; the others stay today's 8 bytes.
        val game = g.prefs(StreamMode.GAME)
        assertEquals(StreamPrefs(60, 1000, 0, 1848, 1214, HDR).copy(chroma = SHARP), game)
        assertEquals(14, Codec.encodePayload(game).size)
        assertEquals(8, Codec.encodePayload(g.prefs(StreamMode.DAILY).copy(chroma = 0)).size)
    }

    @Test fun modeChangeResendsTheRightDynamicRange() {
        settings.setHdrGame(true)
        val g = GameModeSettings(settings, hdr = capable)
        // The caller sends prefs(mode) on every mode change (MainActivity.setStreamMode).
        val sent = StreamMode.entries.map { m -> g.onModeChanged(m); g.prefs(m).dynamicRange }
        assertEquals(listOf(SDR, SDR, HDR), sent) // Günlük, Çizim, Oyun
        g.onModeChanged(StreamMode.DAILY)
        assertEquals(SDR, g.prefs(StreamMode.DAILY).dynamicRange)
    }

    @Test fun sdrPrefsAreByteIdenticalToBeforeHdr() {
        // With HDR off (or no capability) every mode's STREAM_PREFS is what the pre-T-238 code sent.
        for (cap in listOf(capable, HdrCapability.NONE)) {
            val g = GameModeSettings(settings, hdr = cap)
            assertEquals(StreamPrefs(120, 1000, 0).copy(chroma = SHARP), g.prefs(StreamMode.DAILY))
            assertEquals(StreamPrefs(120, 1000, 0).copy(chroma = SHARP), g.prefs(StreamMode.DRAWING))
            assertEquals(StreamPrefs(60, 1000, 0, 1848, 1214).copy(chroma = SHARP), g.prefs(StreamMode.GAME))
        }
        // The game display off (dev knob) with HDR10: the display group is written as 0x0.
        settings.setHdrGame(true)
        val native = GameModeSettings(settings, gameDisplay = false, hdr = capable).prefs(StreamMode.GAME)
        assertEquals(StreamPrefs(60, 1000, 0, 0, 0, HDR).copy(chroma = SHARP), native)
        assertEquals(14, Codec.encodePayload(native).size)
    }

    @Test fun selectHdrReturnsPrefsOnlyWhenOyunsRequestChanges() {
        val g = GameModeSettings(settings, hdr = capable)
        assertEquals(StreamPrefs(60, 1000, 0, 1848, 1214, HDR).copy(chroma = SHARP), g.selectHdr(true, StreamMode.GAME))
        assertTrue(settings.hdrGame())
        assertNull(g.selectHdr(true, StreamMode.GAME)) // no change
        assertEquals(StreamPrefs(60, 1000, 0, 1848, 1214, SDR).copy(chroma = SHARP), g.selectHdr(false, StreamMode.GAME))
        // Outside Oyun: stored, nothing to send; the next Oyun entry uses it.
        assertNull(g.selectHdr(true, StreamMode.DAILY))
        assertTrue(settings.hdrGame())
        assertEquals(HDR, g.prefs(StreamMode.GAME).dynamicRange)
    }

    @Test fun withoutCapabilityNothingIsStoredOrRequested() {
        val g = GameModeSettings(settings, hdr = HdrCapability(displayHdr10 = true, decoderMain10Hdr10 = false))
        assertNull(g.selectHdr(true, StreamMode.GAME))
        assertFalse(settings.hdrGame())
        settings.setHdrGame(true) // stored earlier, e.g. on another build
        assertEquals(SDR, g.prefs(StreamMode.GAME).dynamicRange)
        assertFalse(HdrPolicy.rowEnabled(g.hdr))
        assertEquals("off", HdrPolicy.selected(g.hdr, settings.hdrGame()))
        assertEquals(" (Bu cihazda yok)", HdrPolicy.marker(g.hdr))
    }

    // ---- panel and logs ----

    @Test fun panelRowVisibilityAndTexts() {
        assertTrue(HdrPolicy.rowHidden(StreamMode.DAILY))
        assertTrue(HdrPolicy.rowHidden(StreamMode.DRAWING))
        assertFalse(HdrPolicy.rowHidden(StreamMode.GAME))
        assertTrue(HdrPolicy.rowEnabled(capable))
        assertEquals("", HdrPolicy.marker(capable))
        assertEquals("on", HdrPolicy.selected(capable, true))
        assertEquals("off", HdrPolicy.selected(capable, false))
    }

    @Test fun appliedLabelComesFromStreamConfigOnly() {
        val sdr = StreamConfig(2, 2, 1848, 1214, 1848, 1214, 120, 60000, 1, 13, 1, 1)
        assertEquals("Uygulanan: —", HdrPolicy.appliedLabel(null))
        assertEquals("Uygulanan: SDR", HdrPolicy.appliedLabel(sdr))
        assertEquals("Uygulanan: HDR10", HdrPolicy.appliedLabel(sdr.copy(colorPrimaries = 9, transfer = 16, matrix = 9, fullRange = 0)))
    }

    @Test fun requestLogOncePerChange() {
        val log = HdrRequestLog()
        assertTrue(log.take(SDR)) // the first request
        assertFalse(log.take(SDR))
        assertTrue(log.take(HDR))
        assertFalse(log.take(HDR))
        assertTrue(log.take(SDR))
        assertEquals("dynamic_range=1 mode=game setting=on capable=1", HdrPolicy.requestFields(HDR, StreamMode.GAME, true, capable))
        assertEquals("dynamic_range=0 mode=daily setting=off capable=0", HdrPolicy.requestFields(SDR, StreamMode.DAILY, false, HdrCapability.NONE))
    }
}
