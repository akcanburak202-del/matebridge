package dev.matebridge.client.session

import dev.matebridge.client.video.PacerTuning
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DevKnobsTest {
    /** Intent-like extras: a missing key or a value of another type reads as the default. */
    private class Extras(private val m: Map<String, Any>) : LaunchExtras {
        override fun has(key: String) = key in m
        override fun int(key: String, default: Int) = m[key] as? Int ?: default
        override fun bool(key: String, default: Boolean) = m[key] as? Boolean ?: default
        override fun string(key: String): String? = m[key] as? String
    }

    private fun parse(vararg e: Pair<String, Any>) = DevKnobs.parse(Extras(e.toMap()))

    /** Every debug-only key with a non-default value. */
    private val allDebugOnly: Array<Pair<String, Any>> = arrayOf(
        "hz" to 120, "lead_us" to 4000, "deadline_us" to -1, "ping_ms" to 100,
        "audio" to false, "transport" to "wifi", "audio_out" to "track",
        "audio_buf_bursts" to 3, "quickack" to false, "net_bench" to "192.168.1.20:5201", "net_bench_s" to 5,
        "net_bench_dir" to "up", "net_bench_streams" to 2, "net_bench_rcvbuf_kb" to 512, "decoder_fault" to "dequeue",
        "decoder_fault_after_s" to 15, "game_display" to 0,
        "pace_dcap_half" to 3, "pace_feedback" to false,
        "catch_up" to false, "dec_out_park" to "off", "cursor_predict" to false,
        "audio_idle_pause" to "stop",
    )

    private fun assertDefaults(k: DevKnobs) {
        val d = DevKnobs()
        assertNull(k.hz)
        assertNull(k.leadUs)
        assertNull(k.deadlineUs)
        assertEquals(WifiKnobs(), k.wifi)
        assertTrue(k.audio)
        assertNull(k.transport)
        assertNull(k.audioOut)
        assertNull(k.audioBufBursts)
        assertNull(k.audioIdlePause)
        assertTrue(k.quickAck)
        assertFalse(k.netBench)
        assertNull(k.decoderFault)
        assertNull(k.decoderFaultAfterS)
        assertTrue(k.gameDisplay)
        assertEquals(PacerTuning.STANDARD, k.pacerTuning) // T-251
        assertTrue(k.catchUp) // T-252
        assertTrue(k.cursorPredict) // T-278
        assertTrue(k.decOutPark) // T-312, default on since T-317
        assertEquals(d.copy(dev = k.dev, ignored = k.ignored, knobs = k.knobs, stats1s = k.stats1s, paceTrace = k.paceTrace, stallDiag = k.stallDiag), k)
    }

    @Test fun absentExtrasGiveDefaultsAndNoIgnoreList() {
        val k = parse()
        assertFalse(k.dev)
        assertEquals(emptyList<String>(), k.ignored)
        assertEquals(emptyList<String>(), k.knobs)
        assertDefaults(k)
        assertEquals("dev=0 ignored=-", k.logFields())
        assertEquals(DevKnobs(), k)
    }

    @Test fun withoutDevEveryDebugOnlyKeyKeepsItsDefaultAndIsIgnored() {
        val k = parse(*allDebugOnly)
        assertFalse(k.dev)
        assertDefaults(k)
        assertEquals(DevKnobs.SPECS.filter { it.debugOnly }.map { it.key }, k.ignored)
        assertEquals(allDebugOnly.map { it.first }.toSet(), k.ignored.toSet())
        assertEquals(emptyList<String>(), k.knobs)
    }

    @Test fun devFalseIsTheSameAsAbsent() {
        val k = parse("dev" to false, "hz" to 1)
        assertNull(k.hz)
        assertEquals("dev=0 ignored=hz", k.logFields())
    }

    @Test fun ignoredLineNamesKeysOnly() {
        val k = parse("hz" to 1, "net_bench" to "10.0.0.5:5201")
        assertEquals("dev=0 ignored=hz,net_bench", k.logFields())
        assertFalse(k.logFields().contains("10.0.0.5"))
    }

    @Test fun withDevAllDebugOnlyKeysApply() {
        val k = parse("dev" to true, *allDebugOnly)
        assertTrue(k.dev)
        assertEquals(emptyList<String>(), k.ignored)
        assertEquals(120, k.hz)
        assertEquals(4000, k.leadUs)
        assertEquals(-1, k.deadlineUs)
        assertEquals(WifiKnobs(pingMs = 100), k.wifi)
        assertFalse(k.audio)
        assertEquals("wifi", k.transport)
        assertEquals("track", k.audioOut)
        assertEquals(3, k.audioBufBursts)
        assertEquals("stop", k.audioIdlePause)
        assertFalse(k.quickAck)
        assertTrue(k.netBench)
        assertEquals("dequeue", k.decoderFault)
        assertEquals(15, k.decoderFaultAfterS)
        assertFalse(k.gameDisplay)
        assertEquals(PacerTuning(3, false), k.pacerTuning)
        assertEquals("dev=1 ignored=-", k.logFields())
    }

    @Test fun negativeLeadIsIgnoredAndDeadlineKeepsMinusOne() {
        assertNull(parse("dev" to true, "lead_us" to -5).leadUs)
        assertEquals(-1, parse("dev" to true, "deadline_us" to -1).deadlineUs)
    }

    @Test fun keepKeysApplyWithoutDev() {
        val k = parse("stats_1s" to true, "pace_trace" to true, "stall_diag" to true)
        assertTrue(k.stats1s)
        assertTrue(k.paceTrace)
        assertTrue(k.stallDiag)
        assertEquals(emptyList<String>(), k.ignored)
        assertEquals(listOf("stats_1s:1", "pace_trace:1", "stall_diag:1"), k.knobs)
    }

    @Test fun keepKeysApplyWithDev() {
        val k = parse("dev" to true, "stats_1s" to true, "pace_trace" to true, "stall_diag" to true)
        assertTrue(k.stats1s && k.paceTrace && k.stallDiag)
    }

    @Test fun keepKeysAreNotDebugOnly() {
        for (key in listOf("stats_1s", "pace_trace", "stall_diag")) assertFalse(key in DevKnobs.DEBUG_ONLY_KEYS)
        assertFalse("dev" in DevKnobs.DEBUG_ONLY_KEYS)
    }

    @Test fun knobsListHonouredKeysWithValuesButNeverTheBenchEndpoint() {
        val k = parse("dev" to true, *allDebugOnly, "stats_1s" to true)
        assertEquals(
            listOf(
                "hz:120", "lead_us:4000", "deadline_us:-1", "ping_ms:100",
                "audio:0", "transport:wifi", "audio_out:track", "audio_buf_bursts:3", "audio_idle_pause:stop", "quickack:0",
                "decoder_fault:dequeue", "decoder_fault_after_s:15", "game_display:0",
                "pace_dcap_half:3", "pace_feedback:0", "catch_up:0", "dec_out_park:off", "cursor_predict:0", "stats_1s:1",
            ),
            k.knobs,
        )
        assertFalse(k.knobs.any { it.startsWith("net_bench") })
    }

    @Test fun unknownStringValuesAreLoggedAsOther() {
        val k = parse("dev" to true, "transport" to "10.0.0.5:7000", "audio_out" to "AAudio ", "decoder_fault" to "boom")
        assertEquals(listOf("transport:other", "audio_out:aaudio", "decoder_fault:other"), k.knobs)
        assertEquals("10.0.0.5:7000", k.transport) // the effective raw value still reaches its parser
    }

    // ---- ev=profile ----

    private fun profile(
        transport: String = "usb",
        mode: String = "smooth",
        audioOut: String = "auto",
        settingKbps: Long = 0,
    ) = StreamProfile(
        mode = mode, fps = 120, widthPx = 2800, heightPx = 1840, scalePermille = 1000, bitrateKbps = 60_000,
        bitrateSettingKbps = settingKbps, transport = transport, transportMode = "auto", audioOn = true,
        audioOut = audioOut,
    )

    @Test fun profileHasTheDocumentedFieldsInOrder() {
        val line = profile().logFields("abc1234", "2026-10-03T12:34Z", parse())
        assertEquals(
            "mode=smooth fps=120 size=2800x1840 scale_permille=1000 display=native hdr=0 bitrate_kbps=60000 bitrate_setting=auto " +
                "transport=usb transport_mode=auto audio=1 audio_out=auto pacer=adaptive " +
                "sha=abc1234 built=2026-10-03T12:34Z dev=0 knobs=-",
            line,
        )
    }

    @Test fun profileShowsTheAppliedHdr() { // T-238, decision 0032
        val line = profile().copy(mode = "game", hdr = true).logFields("abc1234", "2026-10-03T12:34Z", parse())
        assertTrue(line, line.contains(" display=native hdr=1 bitrate_kbps=60000 "))
    }

    @Test fun profileShowsBitrateSettingDevAndKnobs() {
        val k = parse("dev" to true, "hz" to 120, "pace_trace" to true)
        val line = profile(transport = "wifi", settingKbps = 40_000).logFields("abc1234-dirty", "unknown", k)
        assertTrue(line, line.contains(" bitrate_setting=40000 "))
        assertTrue(line, line.contains(" transport=wifi "))
        assertTrue(line, line.contains(" pacer=adaptive "))
        assertTrue(line, line.contains(" sha=abc1234-dirty built=unknown dev=1 "))
        assertTrue(line, line.endsWith(" knobs=hz:120;pace_trace:1"))
    }

    @Test fun gameDisplayKnob() {
        // T-215: only `0` turns the game display off, and only with `--ez dev true`.
        assertTrue(parse().gameDisplay)
        val ignored = parse("game_display" to 0)
        assertTrue(ignored.gameDisplay)
        assertEquals("dev=0 ignored=game_display", ignored.logFields())
        val off = parse("dev" to true, "game_display" to 0)
        assertFalse(off.gameDisplay)
        assertEquals(listOf("game_display:0"), off.knobs)
        assertTrue(parse("dev" to true, "game_display" to 1).gameDisplay)
        assertTrue(parse("dev" to true, "game_display" to "0").gameDisplay) // wrong type reads as the default
    }

    @Test fun profileShowsTheGameDisplay() {
        val base = profile(mode = "game")
        val asked = base.copy(displayWidthPx = 1848, displayHeightPx = 1214, displayApplied = true).logFields("abc1234", "unknown", parse())
        assertTrue(asked, asked.contains(" scale_permille=1000 display=1848x1214 display_applied=1 hdr=0 bitrate_kbps="))
        val old = base.copy(displayWidthPx = 1400, displayHeightPx = 920).logFields("abc1234", "unknown", parse())
        assertTrue(old, old.contains(" display=1400x920 display_applied=0 "))
        val native = base.logFields("abc1234", "unknown", parse())
        assertTrue(native, native.contains(" display=native hdr=0 bitrate_kbps="))
        assertFalse(native, native.contains("display_applied"))
    }

    @Test fun profileNeverContainsAnEndpointSerialOrDeviceId() {
        val k = parse(
            "dev" to true, "net_bench" to "192.168.1.20:5201", "transport" to "192.168.1.20:5201",
            "audio_out" to "fe80::1%wlan0", "decoder_fault" to "SERIAL-ABC123",
        )
        // Even garbage in the string fields cannot pass through: only ids, numbers and build tokens are written.
        val line = profile(transport = "192.168.1.20", mode = "Mate Pad", audioOut = "fe80::1")
            .logFields("10.0.0.1", "serial=XYZ", k)
        assertFalse(line, Regex("""\d+\.\d+\.\d+\.\d+""").containsMatchIn(line))
        assertFalse(line, line.contains("fe80"))
        assertFalse(line, line.contains("5201"))
        assertFalse(line, line.contains("SERIAL", ignoreCase = true))
        assertFalse(line, line.contains("Mate Pad"))
        for (field in listOf("serial", "device_id", "android_id", "host", "addr", "ip=", "endpoint")) {
            assertFalse("$field in $line", line.contains(field))
        }
        // Each field stays one key=value token.
        assertTrue(line, line.split(' ').all { it.count { c -> c == '=' } == 1 })
    }

    @Test fun removedExperimentKnobsAreUnknownAndNeverListed() { // T-300
        val removed = listOf(
            "tos_ctl" to 0xB8, "tos_video" to 0x88, "wifi_ll" to true, "hz_pin" to "all", "dec_lowlat" to "all",
            "dec_oprate" to "fps", "color_range" to "limited", "color_standard" to "bt601", "color_transfer" to "unset",
        )
        val k = parse("dev" to true, *removed.toTypedArray())
        assertEquals(parse("dev" to true).knobs, k.knobs)
        assertEquals(parse("dev" to true), k)
        // Without dev they are not "ignored" debug-only keys either: they are simply not known any more.
        assertEquals("dev=0 ignored=-", parse(*removed.toTypedArray()).logFields())
        for ((key, _) in removed) assertFalse(key, key in DevKnobs.DEBUG_ONLY_KEYS)
    }

    @Test fun cursorPredictKnobIsDebugOnlyDefaultOnAndProfileListed() {
        assertTrue(parse().cursorPredict)
        assertTrue(parse("cursor_predict" to false).cursorPredict) // ignored without dev
        val k = parse("dev" to true, "cursor_predict" to false)
        assertFalse(k.cursorPredict)
        assertEquals(listOf("cursor_predict:0"), k.knobs)
        assertTrue("cursor_predict" in DevKnobs.DEBUG_ONLY_KEYS)
    }

    @Test fun removedDecWaitAndAeadPathKnobsAreIgnoredAndNeverListed() { // T-295
        val k = parse("dev" to true, "dec_wait" to "poll", "aead_path" to "legacy")
        assertEquals(parse("dev" to true).knobs, k.knobs)
        assertTrue(k.knobs.none { it.startsWith("dec_wait") || it.startsWith("aead_path") })
        assertTrue("dec_wait" !in DevKnobs.DEBUG_ONLY_KEYS && "aead_path" !in DevKnobs.DEBUG_ONLY_KEYS)
    }

    @Test fun catchUpKnobIsDebugOnlyDefaultOnAndProfileListed() {
        assertTrue(parse().catchUp)
        assertTrue(parse("catch_up" to false).catchUp) // ignored without dev
        val k = parse("dev" to true, "catch_up" to false)
        assertFalse(k.catchUp)
        assertEquals(listOf("catch_up:0"), k.knobs)
        assertTrue(parse("dev" to true, "catch_up" to true).catchUp)
        assertTrue("catch_up" in DevKnobs.DEBUG_ONLY_KEYS)
    }

    @Test fun decOutParkKnobDefaultsOnOffIsDebugOnlyFallbackAndProfileListed() { // T-312, default on since T-317
        assertTrue(parse().decOutPark)
        assertEquals(emptyList<String>(), parse().knobs)
        assertTrue(parse("dec_out_park" to "off").decOutPark) // ignored without dev
        assertTrue(parse("dev" to true, "dec_out_park" to "bogus").decOutPark)
        val on = parse("dev" to true, "dec_out_park" to " ON ")
        assertTrue(on.decOutPark)
        assertEquals(emptyList<String>(), on.knobs) // effective on is not listed
        assertEquals(emptyList<String>(), parse("dev" to true, "dec_out_park" to "bogus").knobs)
        val k = parse("dev" to true, "dec_out_park" to " OFF ")
        assertFalse(k.decOutPark)
        assertEquals(listOf("dec_out_park:off"), k.knobs)
        assertTrue("dec_out_park" in DevKnobs.DEBUG_ONLY_KEYS)
    }

    @Test fun pacerKnobsParseAndAreProfileListed() {
        val k = parse("dev" to true, "pace_dcap_half" to 3, "pace_feedback" to false)
        assertEquals(PacerTuning(3, false), k.pacerTuning)
        assertEquals(listOf("pace_dcap_half:3", "pace_feedback:0"), k.knobs)
        assertEquals(PacerTuning.STANDARD, parse("dev" to true, "pace_dcap_half" to 0).pacerTuning)
        assertEquals(PacerTuning(PacerTuning.MAX_CAP_HALF, true), parse("dev" to true, "pace_dcap_half" to 99).pacerTuning)
        assertEquals(PacerTuning.STANDARD, parse("pace_dcap_half" to 3, "pace_feedback" to false).pacerTuning)
    }
}
