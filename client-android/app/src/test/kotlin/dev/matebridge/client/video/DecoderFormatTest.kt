package dev.matebridge.client.video

import dev.matebridge.client.protocol.StreamConfig
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The decoder format of [VideoRenderer.createCodec]: `operating-rate=max` (T-222) and the one-shot fallback to the
 * stream-fps format when configure/start fails (T-217). T-300 removed the `dec_lowlat`/`dec_oprate` variants.
 */
class DecoderFormatTest {
    private val config = StreamConfig(1, StreamConfig.CODEC_HEVC, 2800, 1840, 1400, 920, 60, 50000, 1, 13, 1, 1)
    private val factory = FakeDecoderFactory()
    private val env = TestDecoderEnv()
    private var renderer: VideoRenderer? = null

    private fun start(config: StreamConfig = this.config): VideoRenderer {
        // A long restart backoff: every codec created in a test is createCodec's own (detach ends the wait at once).
        val r = VideoRenderer(config, onKeyframeRequest = {}, codecFactory = factory, env = env,
            restartDelaysMs = longArrayOf(60_000, 60_000, 60_000))
        renderer = r
        r.attachTarget(Any())
        return r
    }

    @After fun tearDown() { renderer?.detachSurface() }

    /** Key/value pairs of the format given to [codec]'s configure, in insertion order. */
    private fun keys(codec: FakeDecoderFactory.Codec): List<Pair<String, Int>> =
        codec.format!!.integers.map { it.key to it.value }

    /** Literal key names on purpose: this is the pre-T-217 format (`dec_oprate=fps`, the fallback), byte for byte. */
    private val todayHevc60 = listOf(
        "priority" to 0,
        "max-input-size" to 2800 * 1840 * 3 / 2,
        "frame-rate" to 60,
        "operating-rate" to 60,
        "color-standard" to 1,
        "color-transfer" to 3,
        "color-range" to 1,
        "low-latency" to 1,
    )

    /** T-222: the app default, the pre-T-217 format with the operating rate replaced in place by 32767. */
    private val standardHevc60 = todayHevc60.map { if (it.first == "operating-rate") it.first to 32767 else it }

    private val HISI_REQ = "vendor.hisi-ext-low-latency-video-dec.video-scene-for-low-latency-req"

    // --- T-222 default: oprate=max ---

    /** The T-217 "default unchanged" lock, repinned by T-222: without the knob the operating rate is 32767. */
    @Test fun withoutTheKnobTheOperatingRateIsMax() {
        start()
        assertTrue(env.awaitLines("codec_start"))
        assertEquals(1, factory.createCalls)
        assertEquals(standardHevc60, keys(factory.codecs.single()))
        val line = env.lines("codec_start").single()
        assertTrue(line, line.contains(" requested_rate=32767 "))
        assertTrue(line, line.contains(" lowlat=off oprate=max accepted "))
    }

    @Test fun withoutTheKnobAndWithoutFpsTheOperatingRateIsStillMax() {
        factory.lowLatency = false
        start(config.copy(fps = 0))
        assertTrue(env.awaitLines("codec_start"))
        assertEquals(
            listOf("priority" to 0, "max-input-size" to 2800 * 1840 * 3 / 2, "operating-rate" to 32767,
                "color-standard" to 1, "color-transfer" to 3, "color-range" to 1),
            keys(factory.codecs.single()),
        )
    }

    @Test fun aFailingDefaultFallsBackOnceToTheStreamFpsFormat() {
        factory.failStarts = 1
        start()
        assertTrue(env.awaitLines("codec_start"))
        assertEquals(2, factory.createCalls)
        assertEquals(standardHevc60, factory.configureFormats[0].map { it.key to it.value })
        assertEquals(todayHevc60, keys(factory.codecs[1]))
        val w = env.lines("dec_lowlat_rejected").single()
        assertTrue(w, w.contains(" W decoder ev=dec_lowlat_rejected lowlat=off oprate=max keys=operating-rate " +
            "err=IllegalStateException"))
        val line = env.lines("codec_start").single()
        assertTrue(line, line.contains(" requested_rate=60 "))
        assertTrue(line, line.contains(" lowlat=off oprate=rejected accepted "))
        assertEquals(0, env.lines("decode_error").size)
    }

    @Test fun aFailingConfigureRetriesOnceOnAFreshCodecThenIsADecodeError() {
        factory.failConfigure = true
        start()
        assertTrue(env.awaitLines("decode_error"))
        assertEquals(2, factory.createCalls)
        assertEquals(
            listOf("create#1", "configure#1", "release#1>", "release#1<", "create#2", "configure#2", "release#2>", "release#2<"),
            factory.events,
        )
        assertEquals(1, env.lines("dec_lowlat_rejected").size)
        assertEquals(0, env.lines("codec_start").size)
    }

    @Test fun withoutFpsAndWithoutLowLatencyFeatureTheFallbackLeavesTheRateUnset() {
        factory.lowLatency = false
        factory.failStarts = 1
        start(config.copy(fps = 0))
        assertTrue(env.awaitLines("codec_start"))
        assertEquals(
            listOf("priority" to 0, "max-input-size" to 2800 * 1840 * 3 / 2, "color-standard" to 1,
                "color-transfer" to 3, "color-range" to 1),
            keys(factory.codecs[1]),
        )
    }

    // --- vendor parameters ---

    @Test fun vendorParametersAreLoggedOncePerComponentNamesOnly() {
        factory.vendorParameters = listOf(HISI_REQ, "vendor.x has space", "vdec-lowlatency")
        val r = start()
        assertTrue(env.awaitLines("codec_start"))
        r.reconfigure(config)
        assertTrue(env.awaitLines("codec_start", count = 2))
        val line = env.lines("vendor_params").single()
        assertTrue(line, line.endsWith(" I decoder ev=vendor_params name=fake.decoder count=3 keys=$HISI_REQ,vdec-lowlatency more=1"))
    }

    @Test fun unknownVendorParametersSaySo() {
        start()
        assertTrue(env.awaitLines("vendor_params"))
        assertTrue(env.lines("vendor_params").single().endsWith(" name=fake.decoder count=? keys=unavailable"))
    }

    // --- pure ---

    @Test fun operatingRatePolicy() {
        assertEquals(60, OperatingRate.resolve(60))
        org.junit.Assert.assertNull(OperatingRate.resolve(0))
        assertEquals(32767, OperatingRate.MAX)
    }

    @Test fun vendorParamsFieldsHandleEmptyAndLongLists() {
        assertEquals("count=0 keys=-", VendorParams.fields(emptyList()))
        val many = (1..70).map { "vendor.k$it" }
        val f = VendorParams.fields(many)
        assertTrue(f, f.startsWith("count=70 keys=vendor.k1,"))
        assertTrue(f, f.endsWith(",vendor.k64 more=6"))
    }
}
