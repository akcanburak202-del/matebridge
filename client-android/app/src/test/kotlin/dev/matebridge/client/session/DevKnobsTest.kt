package dev.matebridge.client.session

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
        "jitter" to 1, "hz" to 120, "lead_us" to 4000, "deadline_us" to -1, "ping_ms" to 100, "tos_ctl" to 0xB8,
        "tos_video" to 0x88, "wifi_ll" to true, "audio" to false, "transport" to "wifi", "audio_out" to "track",
        "audio_buf_bursts" to 3, "quickack" to false, "net_bench" to "192.168.1.20:5201", "net_bench_s" to 5,
        "net_bench_dir" to "up", "net_bench_streams" to 2, "net_bench_rcvbuf_kb" to 512, "decoder_fault" to "dequeue",
        "decoder_fault_after_s" to 15,
    )

    private fun assertDefaults(k: DevKnobs) {
        val d = DevKnobs()
        assertNull(k.jitter)
        assertNull(k.hz)
        assertNull(k.leadUs)
        assertNull(k.deadlineUs)
        assertEquals(WifiKnobs(), k.wifi)
        assertTrue(k.audio)
        assertNull(k.transport)
        assertNull(k.audioOut)
        assertNull(k.audioBufBursts)
        assertTrue(k.quickAck)
        assertFalse(k.netBench)
        assertNull(k.decoderFault)
        assertNull(k.decoderFaultAfterS)
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
        val k = parse("dev" to false, "jitter" to 1)
        assertNull(k.jitter)
        assertEquals("dev=0 ignored=jitter", k.logFields())
    }

    @Test fun ignoredLineNamesKeysOnly() {
        val k = parse("jitter" to 1, "net_bench" to "10.0.0.5:5201")
        assertEquals("dev=0 ignored=jitter,net_bench", k.logFields())
        assertFalse(k.logFields().contains("10.0.0.5"))
    }

    @Test fun withDevAllDebugOnlyKeysApply() {
        val k = parse("dev" to true, *allDebugOnly)
        assertTrue(k.dev)
        assertEquals(emptyList<String>(), k.ignored)
        assertEquals(1, k.jitter)
        assertEquals(120, k.hz)
        assertEquals(4000, k.leadUs)
        assertEquals(-1, k.deadlineUs)
        assertEquals(WifiKnobs(pingMs = 100, tosCtl = 0xB8, tosVideo = 0x88, wifiLowLatency = true), k.wifi)
        assertFalse(k.audio)
        assertEquals("wifi", k.transport)
        assertEquals("track", k.audioOut)
        assertEquals(3, k.audioBufBursts)
        assertFalse(k.quickAck)
        assertTrue(k.netBench)
        assertEquals("dequeue", k.decoderFault)
        assertEquals(15, k.decoderFaultAfterS)
        assertEquals("dev=1 ignored=-", k.logFields())
    }

    @Test fun jitterIsClampedAndAdaptiveOffMeansZero() {
        assertEquals(0, parse("dev" to true, "jitter" to -1).jitter)
        assertEquals(2, parse("dev" to true, "jitter" to 9).jitter)
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
                "jitter:1", "hz:120", "lead_us:4000", "deadline_us:-1", "ping_ms:100", "tos_ctl:184", "tos_video:136",
                "wifi_ll:1", "audio:0", "transport:wifi", "audio_out:track", "audio_buf_bursts:3", "quickack:0",
                "decoder_fault:dequeue", "decoder_fault_after_s:15", "stats_1s:1",
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
        bufferFrames: Int = -1,
        settingKbps: Long = 0,
    ) = StreamProfile(
        mode = mode, fps = 120, widthPx = 2800, heightPx = 1840, scalePermille = 1000, bitrateKbps = 60_000,
        bitrateSettingKbps = settingKbps, transport = transport, transportMode = "auto", audioOn = true,
        audioOut = audioOut, bufferFrames = bufferFrames,
    )

    @Test fun profileHasTheDocumentedFieldsInOrder() {
        val line = profile().logFields("abc1234", "2026-10-03T12:34Z", parse())
        assertEquals(
            "mode=smooth fps=120 size=2800x1840 scale_permille=1000 bitrate_kbps=60000 bitrate_setting=auto " +
                "transport=usb transport_mode=auto audio=1 audio_out=auto pacer=adaptive " +
                "sha=abc1234 built=2026-10-03T12:34Z dev=0 knobs=-",
            line,
        )
    }

    @Test fun profileShowsFixedBufferBitrateSettingDevAndKnobs() {
        val k = parse("dev" to true, "jitter" to 1, "pace_trace" to true)
        val line = profile(transport = "wifi", bufferFrames = 1, settingKbps = 40_000).logFields("abc1234-dirty", "unknown", k)
        assertTrue(line, line.contains(" bitrate_setting=40000 "))
        assertTrue(line, line.contains(" transport=wifi "))
        assertTrue(line, line.contains(" pacer=buffer1 "))
        assertTrue(line, line.contains(" sha=abc1234-dirty built=unknown dev=1 "))
        assertTrue(line, line.endsWith(" knobs=jitter:1;pace_trace:1"))
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
}
