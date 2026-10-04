package dev.matebridge.client.video

import dev.matebridge.client.protocol.StreamConfig
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** T-231: the decoder colour-key overrides and the `ev=decoder_output_format` report. */
class ColorOverridesTest {
    /** HEVC 2800x1840 @ 60, BT.709 primaries, sRGB transfer (13), BT.709 matrix, full range: what the host sends. */
    private val config = StreamConfig(1, StreamConfig.CODEC_HEVC, 2800, 1840, 1400, 920, 60, 50000, 1, 13, 1, 1)
    private val factory = FakeDecoderFactory()
    private val env = TestDecoderEnv()
    private var renderer: VideoRenderer? = null

    private fun start(config: StreamConfig = this.config, colors: ColorOverrides = ColorOverrides.AUTO): VideoRenderer {
        val r = VideoRenderer(config, onKeyframeRequest = {}, codecFactory = factory, env = env,
            restartDelaysMs = longArrayOf(60_000, 60_000, 60_000), decoderTuning = DecoderLatencyKnobs.STANDARD,
            colorOverrides = colors)
        renderer = r
        r.attachTarget(Any())
        return r
    }

    @After fun tearDown() { renderer?.detachSurface() }

    private fun keys(): List<Pair<String, Int>> = factory.codecs.single().format!!.integers.map { it.key to it.value }

    /** Literal key names on purpose: the pre-T-231 format of the app default (T-222 `oprate=max`), byte for byte. */
    private val todayHevc60 = listOf(
        "priority" to 0,
        "max-input-size" to 2800 * 1840 * 3 / 2,
        "frame-rate" to 60,
        "operating-rate" to 32767,
        "color-standard" to 1,
        "color-transfer" to 3,
        "color-range" to 1,
        "low-latency" to 1,
    )

    private fun configured(colors: ColorOverrides, config: StreamConfig = this.config): List<Pair<String, Int>> {
        start(config, colors)
        assertTrue(env.awaitLines("codec_start"))
        return keys()
    }

    // --- parsing ---

    @Test fun absentOrUnknownValuesAreAuto() {
        assertEquals(ColorOverrides.AUTO, ColorOverrides.parse(null, null, null))
        assertEquals(ColorOverrides.AUTO, ColorOverrides.parse("bogus", "", "pq"))
        assertEquals(ColorOverrides.AUTO, ColorOverrides.parse("auto", "auto", "auto"))
    }

    @Test fun valuesAreTrimmedAndCaseInsensitive() {
        val c = ColorOverrides.parse(" LIMITED ", "Bt601", "SDR_Video")
        assertEquals("limited", c.range.id)
        assertEquals("bt601", c.standard.id)
        assertEquals("sdr_video", c.transfer.id)
    }

    @Test fun idSetsAreTheDocumentedValues() {
        assertEquals(setOf("auto", "full", "limited", "unset"), ColorOverrides.RANGE_IDS)
        assertEquals(setOf("auto", "bt709", "bt601", "unset"), ColorOverrides.STANDARD_IDS)
        assertEquals(setOf("auto", "srgb", "sdr_video", "unset"), ColorOverrides.TRANSFER_IDS)
    }

    @Test fun eachValueResolvesToItsKeyValue() {
        fun r(v: String) = ColorOverrides.parse(v, null, null).range(config)
        fun s(v: String) = ColorOverrides.parse(null, v, null).standard(config)
        fun t(v: String) = ColorOverrides.parse(null, null, v).transfer(config)
        assertEquals(1, r("auto")); assertEquals(1, r("full")); assertEquals(2, r("limited")); assertNull(r("unset"))
        assertEquals(1, s("auto")); assertEquals(1, s("bt709")); assertEquals(4, s("bt601")); assertNull(s("unset"))
        assertEquals(3, t("auto")); assertEquals(2, t("srgb")); assertEquals(3, t("sdr_video")); assertNull(t("unset"))
    }

    @Test fun autoFollowsTheStreamConfig() {
        val limited601 = config.copy(matrix = 6, transfer = 1, fullRange = 0)
        assertEquals(2, ColorOverrides.AUTO.range(limited601))
        assertEquals(4, ColorOverrides.AUTO.standard(limited601))
        assertEquals(3, ColorOverrides.AUTO.transfer(limited601))
        val unknown = config.copy(matrix = 0, transfer = 2)
        assertNull(ColorOverrides.AUTO.standard(unknown))
        assertNull(ColorOverrides.AUTO.transfer(unknown))
        // a fixed knob ignores the config
        assertEquals(1, ColorOverrides.parse("full", "bt709", "srgb").range(limited601))
        assertEquals(1, ColorOverrides.parse("full", "bt709", "srgb").standard(unknown))
        assertEquals(2, ColorOverrides.parse("full", "bt709", "srgb").transfer(unknown))
    }

    // --- the decoder format ---

    /** Acceptance: without the knobs the decoder gets the pre-T-231 keys, values and order. */
    @Test fun withoutTheKnobsTheFormatIsTodays() {
        assertEquals(todayHevc60, configured(ColorOverrides.AUTO))
    }

    @Test fun withoutTheKnobsALimitedStreamIsTodays() {
        val c = config.copy(matrix = 6, transfer = 1, fullRange = 0)
        assertEquals(
            todayHevc60.map {
                when (it.first) {
                    "color-standard" -> it.first to 4
                    "color-range" -> it.first to 2
                    else -> it
                }
            },
            configured(ColorOverrides.AUTO, c),
        )
    }

    @Test fun withoutTheKnobsAnUnknownMatrixAndTransferStayUnset() {
        val got = configured(ColorOverrides.AUTO, config.copy(matrix = 0, transfer = 2))
        assertEquals(todayHevc60.filter { it.first != "color-standard" && it.first != "color-transfer" }, got)
    }

    @Test fun rangeLimitedReplacesTheValueInPlace() {
        assertEquals(todayHevc60.map { if (it.first == "color-range") it.first to 2 else it },
            configured(ColorOverrides.parse("limited", null, null)))
    }

    @Test fun rangeUnsetLeavesTheKeyOut() {
        assertEquals(todayHevc60.filter { it.first != "color-range" }, configured(ColorOverrides.parse("unset", null, null)))
    }

    @Test fun standardBt601ReplacesTheValueInPlace() {
        assertEquals(todayHevc60.map { if (it.first == "color-standard") it.first to 4 else it },
            configured(ColorOverrides.parse(null, "bt601", null)))
    }

    @Test fun transferSrgbReplacesTheValueInPlace() {
        assertEquals(todayHevc60.map { if (it.first == "color-transfer") it.first to 2 else it },
            configured(ColorOverrides.parse(null, null, "srgb")))
    }

    @Test fun allUnsetLeavesEveryColourKeyOut() {
        val got = configured(ColorOverrides.parse("unset", "unset", "unset"))
        assertEquals(todayHevc60.filter { !it.first.startsWith("color-") }, got)
    }

    @Test fun aFixedStandardIsPutEvenWhenTheConfigHasNone() {
        val got = configured(ColorOverrides.parse(null, "bt709", "sdr_video"), config.copy(matrix = 0, transfer = 2))
        assertEquals(todayHevc60, got)
    }

    /** The T-217 fallback format keeps the colour knob: only the latency keys fall back. */
    @Test fun theLatencyFallbackKeepsTheColourKnob() {
        factory.failStarts = 1
        start(colors = ColorOverrides.parse("limited", null, "unset"))
        assertTrue(env.awaitLines("codec_start"))
        assertEquals(2, factory.createCalls)
        val fallback = factory.codecs[1].format!!.integers
        assertEquals(2, fallback["color-range"])
        assertFalse(fallback.containsKey("color-transfer"))
        assertEquals(60, fallback["operating-rate"])
    }

    // --- ev=decoder_output_format ---

    private class View(
        val ints: Map<String, Int> = emptyMap(),
        val bufs: Map<String, ByteArray> = emptyMap(),
    ) : DecoderCodec.FormatView {
        override fun containsKey(key: String) = key in ints || key in bufs
        override fun getInteger(key: String) = ints[key] ?: throw NullPointerException(key)
        override fun getFloat(key: String): Float = throw ClassCastException(key)
        override fun getByteBuffer(key: String) = bufs[key]?.let { java.nio.ByteBuffer.wrap(it) }
    }

    @Test fun reportFieldsWithEverythingUnset() {
        assertEquals(
            "range=unset standard=unset transfer=unset hdr_static_info=unset req_range=unset req_standard=unset req_transfer=unset",
            OutputFormatReport.fields(View(), emptyMap()),
        )
        assertEquals(
            "range=unset standard=unset transfer=unset hdr_static_info=unset req_range=unset req_standard=unset req_transfer=unset",
            OutputFormatReport.fields(View(), null),
        )
    }

    @Test fun reportFieldsWithColourKeysAndHdrInfo() {
        val hdr = ByteArray(25) { it.toByte() }.also { it[24] = 0xff.toByte() }
        val view = View(mapOf("color-range" to 1, "color-standard" to 1, "color-transfer" to 3), mapOf("hdr-static-info" to hdr))
        val f = OutputFormatReport.fields(view, mapOf("color-range" to 2, "color-standard" to 1))
        assertEquals(
            "range=1 standard=1 transfer=3 hdr_static_info=000102030405060708090a0b0c0d0e0f1011121314151617ff " +
                "req_range=2 req_standard=1 req_transfer=unset",
            f,
        )
    }

    @Test fun reportDoesNotMoveTheFormatsBuffer() {
        val buf = java.nio.ByteBuffer.wrap(byteArrayOf(1, 2, 3))
        val view = object : DecoderCodec.FormatView {
            override fun containsKey(key: String) = key == "hdr-static-info"
            override fun getInteger(key: String): Int = throw NullPointerException(key)
            override fun getFloat(key: String): Float = throw ClassCastException(key)
            override fun getByteBuffer(key: String) = buf
        }
        assertTrue(OutputFormatReport.fields(view, null).contains(" hdr_static_info=010203 "))
        assertEquals(0, buf.position())
        assertTrue(OutputFormatReport.fields(view, null).contains(" hdr_static_info=010203 "))
    }

    @Test fun reportBoundsLongHdrInfoAndMarksOddOnes() {
        val long = View(bufs = mapOf("hdr-static-info" to ByteArray(70)))
        assertTrue(OutputFormatReport.fields(long, null).contains(" hdr_static_info=${"00".repeat(64)}+6 "))
        val empty = View(bufs = mapOf("hdr-static-info" to ByteArray(0)))
        assertTrue(OutputFormatReport.fields(empty, null).contains(" hdr_static_info=empty "))
        val noBuffer = object : DecoderCodec.FormatView { // a view that cannot read buffers (default null)
            override fun containsKey(key: String) = key == "hdr-static-info"
            override fun getInteger(key: String): Int = throw NullPointerException(key)
            override fun getFloat(key: String): Float = throw ClassCastException(key)
        }
        assertTrue(OutputFormatReport.fields(noBuffer, null).contains(" hdr_static_info=? "))
        val badInt = View(ints = mapOf("color-range" to 1)).let { v ->
            object : DecoderCodec.FormatView by v {
                override fun getInteger(key: String): Int = throw ClassCastException(key)
            }
        }
        assertTrue(OutputFormatReport.fields(badInt, null).startsWith("range=? standard=unset "))
    }

    @Test fun logGateSkipsRepeatsAndIsBounded() {
        val g = OutputFormatLogGate()
        assertTrue(g.take("a"))
        assertFalse(g.take("a"))
        assertTrue(g.take("b"))
        assertTrue(g.take("a"))
        var taken = 3
        for (i in 0 until 40) if (g.take("x$i")) taken++
        assertEquals(OutputFormatLogGate.MAX_LINES, taken)
    }

    @Test fun anOutputFormatChangeIsLoggedWithTheRequestedKeys() {
        factory.outputFormatInts = mapOf("color-range" to 1, "color-standard" to 1, "color-transfer" to 3)
        factory.outputFormatChanges = 1
        start(colors = ColorOverrides.parse("limited", null, "unset"))
        assertTrue(env.awaitLines("decoder_output_format"))
        val line = env.lines("decoder_output_format").single()
        assertTrue(line, line.contains(" I decoder ev=decoder_output_format gen=1 range=1 standard=1 transfer=3 " +
            "hdr_static_info=unset req_range=2 req_standard=1 req_transfer=unset"))
        assertTrue(line, line.startsWith("MB/decoder "))
        // The pre-T-231 line is still there, once.
        assertTrue(env.awaitLines("output_format"))
    }

    @Test fun eachFormatChangeWithNewFieldsIsLoggedAndRepeatsAreNot() {
        factory.outputFormatInts = mapOf("color-range" to 1)
        factory.outputFormatChanges = 1
        start()
        assertTrue(env.awaitLines("decoder_output_format"))
        factory.outputFormatChanges = 1 // same fields: not repeated
        assertTrue(factory.await { outputFormatChanges == 0 && silentOutputPolls > 0 })
        val polls = factory.silentOutputPolls
        assertTrue(factory.await { silentOutputPolls > polls + 1 }) // the drain that saw the change has finished
        assertEquals(1, env.lines("decoder_output_format").size)
        factory.outputFormatInts = mapOf("color-range" to 2)
        factory.outputFormatChanges = 1
        assertTrue(env.awaitLines("decoder_output_format", count = 2))
        assertTrue(env.lines("decoder_output_format")[1].contains(" range=2 "))
        assertEquals(1, env.lines("output_format").size)
    }
}
