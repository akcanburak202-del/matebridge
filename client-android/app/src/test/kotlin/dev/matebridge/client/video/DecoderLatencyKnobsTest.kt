package dev.matebridge.client.video

import dev.matebridge.client.protocol.StreamConfig
import dev.matebridge.client.video.DecoderLatencyKnobs.Companion.HISI_RDY
import dev.matebridge.client.video.DecoderLatencyKnobs.Companion.HISI_REQ
import dev.matebridge.client.video.DecoderLatencyKnobs.LowLat
import dev.matebridge.client.video.DecoderLatencyKnobs.OpRate
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** T-217: the decoder format of [VideoRenderer.createCodec] with and without the decoder latency knobs. */
class DecoderLatencyKnobsTest {
    private val config = StreamConfig(1, StreamConfig.CODEC_HEVC, 2800, 1840, 1400, 920, 60, 50000, 1, 13, 1, 1)
    private val factory = FakeDecoderFactory()
    private val env = TestDecoderEnv()
    private var renderer: VideoRenderer? = null

    private fun start(
        config: StreamConfig = this.config,
        tuning: DecoderLatencyKnobs = DecoderLatencyKnobs.DEFAULT,
    ): VideoRenderer {
        // A long restart backoff: every codec created in a test is createCodec's own (detach ends the wait at once).
        val r = VideoRenderer(config, onKeyframeRequest = {}, codecFactory = factory, env = env,
            restartDelaysMs = longArrayOf(60_000, 60_000, 60_000), decoderTuning = tuning)
        renderer = r
        r.attachTarget(Any())
        return r
    }

    @After fun tearDown() { renderer?.detachSurface() }

    /** Key/value pairs of the format given to [codec]'s configure, in insertion order. */
    private fun keys(codec: FakeDecoderFactory.Codec): List<Pair<String, Int>> =
        codec.format!!.integers.map { it.key to it.value }

    /** Literal key names on purpose: this is the pre-T-217 format, byte for byte. */
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

    private val allFour = listOf(
        "vendor.hisi-ext-low-latency-video-dec.video-scene-for-low-latency-req" to 1,
        "vendor.hisi-ext-low-latency-video-dec.video-scene-for-low-latency-rdy" to -1,
        "vdec-lowlatency" to 1,
        "low-latency" to 1,
    )

    // --- default: today's format ---

    @Test fun withoutTheKnobTheFormatIsTodays() {
        start()
        assertTrue(env.awaitLines("codec_start"))
        assertEquals(1, factory.createCalls)
        assertEquals(todayHevc60, keys(factory.codecs.single()))
        assertTrue(env.lines("codec_start").single().contains(" lowlat=off oprate=fps accepted "))
    }

    @Test fun withoutTheKnobAndWithoutLowLatencyFeatureTheFormatIsTodays() {
        factory.lowLatency = false
        start(config.copy(fps = 0))
        assertTrue(env.awaitLines("codec_start"))
        assertEquals(
            listOf("priority" to 0, "max-input-size" to 2800 * 1840 * 3 / 2, "color-standard" to 1,
                "color-transfer" to 3, "color-range" to 1),
            keys(factory.codecs.single()),
        )
    }

    @Test fun anExplicitOffAndFpsIsTheDefault() {
        start(tuning = DecoderLatencyKnobs.parse("off", "fps"))
        assertTrue(env.awaitLines("codec_start"))
        assertEquals(todayHevc60, keys(factory.codecs.single()))
    }

    @Test fun withoutTheKnobAConfigureFailureIsNotRetried() {
        factory.failConfigure = true
        start()
        assertTrue(env.awaitLines("decode_error"))
        assertEquals(1, factory.createCalls)
        assertEquals(listOf("create#1", "configure#1", "release#1>", "release#1<"), factory.events)
        assertEquals(0, env.lines("dec_lowlat_rejected").size)
    }

    // --- knob on ---

    @Test fun allPutsTheFourKeysAfterTodaysFormat() {
        start(tuning = DecoderLatencyKnobs(LowLat.ALL))
        assertTrue(env.awaitLines("codec_start"))
        // `low-latency` was already set (feature supported): it keeps its place and value.
        assertEquals(todayHevc60 + allFour.dropLast(1), keys(factory.codecs.single()))
        assertEquals(allFour.toSet(), keys(factory.codecs.single()).filter { it in allFour }.toSet())
        assertTrue(env.lines("codec_start").single().contains(" lowlat=all oprate=fps accepted "))
    }

    @Test fun vdecSetsLowLatencyEvenWithoutTheFeature() {
        factory.lowLatency = false
        start(tuning = DecoderLatencyKnobs(LowLat.VDEC))
        assertTrue(env.awaitLines("codec_start"))
        val k = keys(factory.codecs.single())
        assertEquals(listOf("vdec-lowlatency" to 1, "low-latency" to 1), k.takeLast(2))
        assertFalse(k.any { it.first.startsWith("vendor.") })
    }

    @Test fun hisiSetsOnlyTheVendorPair() {
        start(tuning = DecoderLatencyKnobs(LowLat.HISI))
        assertTrue(env.awaitLines("codec_start"))
        assertEquals(todayHevc60 + listOf(HISI_REQ to 1, HISI_RDY to -1), keys(factory.codecs.single()))
    }

    @Test fun operatingRateMaxReplacesTheStreamFpsInPlace() {
        start(tuning = DecoderLatencyKnobs(opRate = OpRate.MAX))
        assertTrue(env.awaitLines("codec_start"))
        assertEquals(todayHevc60.map { if (it.first == "operating-rate") it.first to 32767 else it }, keys(factory.codecs.single()))
        val line = env.lines("codec_start").single()
        assertTrue(line, line.contains(" requested_rate=32767 "))
        assertTrue(line, line.contains(" lowlat=off oprate=max accepted "))
    }

    @Test fun aRejectedConfigureRetriesOnceWithoutTheKeysOnAFreshCodec() {
        factory.rejectKeys = setOf(HISI_REQ)
        start(tuning = DecoderLatencyKnobs(LowLat.ALL, OpRate.MAX))
        assertTrue(env.awaitLines("codec_start"))
        assertEquals(
            listOf("create#1", "configure#1", "release#1>", "release#1<", "create#2", "configure#2", "start#2"),
            factory.events.take(7),
        )
        assertEquals(2, factory.configureFormats.size)
        assertEquals(todayHevc60, factory.configureFormats[1].map { it.key to it.value })
        assertEquals(todayHevc60, keys(factory.codecs[1]))
        val w = env.lines("dec_lowlat_rejected").single()
        assertTrue(w, w.contains(" W decoder ev=dec_lowlat_rejected lowlat=all oprate=max keys=$HISI_REQ,$HISI_RDY," +
            "vdec-lowlatency,low-latency,operating-rate err=IllegalArgumentException"))
        val line = env.lines("codec_start").single()
        assertTrue(line, line.contains(" requested_rate=60 "))
        assertTrue(line, line.contains(" lowlat=rejected oprate=rejected accepted "))
        assertEquals(0, env.lines("decode_error").size)
    }

    @Test fun aRejectedLowLatKeepsTheDefaultOprateFieldAsFps() {
        factory.rejectKeys = setOf("vdec-lowlatency")
        start(tuning = DecoderLatencyKnobs(LowLat.VDEC))
        assertTrue(env.awaitLines("codec_start"))
        assertTrue(env.lines("codec_start").single().contains(" lowlat=rejected oprate=fps accepted "))
    }

    @Test fun aFailingRetryIsADecodeErrorAndNotRetriedAgain() {
        factory.failConfigure = true
        start(tuning = DecoderLatencyKnobs(LowLat.ALL))
        assertTrue(env.awaitLines("decode_error"))
        assertEquals(2, factory.createCalls)
        assertEquals(
            listOf("create#1", "configure#1", "release#1>", "release#1<", "create#2", "configure#2", "release#2>", "release#2<"),
            factory.events,
        )
        assertEquals(1, env.lines("dec_lowlat_rejected").size)
        assertEquals(0, env.lines("codec_start").size)
    }

    @Test fun aFailingStartOfTheTunedCodecAlsoFallsBack() {
        factory.failStarts = 1
        start(tuning = DecoderLatencyKnobs(LowLat.HISI))
        assertTrue(env.awaitLines("codec_start"))
        assertEquals(
            listOf("create#1", "configure#1", "start#1", "release#1>", "release#1<", "create#2", "configure#2", "start#2"),
            factory.events.take(8),
        )
        assertEquals(todayHevc60, keys(factory.codecs[1]))
        assertTrue(env.lines("dec_lowlat_rejected").single().endsWith(" err=IllegalStateException"))
    }

    /**
     * The launch-extras chain MainActivity uses (`DevKnobs.parse` → `decoderLatency` → `VideoRenderer(decoderTuning=)`):
     * with `dev` the keys reach the codec, without it the format stays today's.
     */
    @Test fun launchExtrasReachTheCodecOnlyWithDev() {
        class Extras(private val m: Map<String, Any>) : dev.matebridge.client.session.LaunchExtras {
            override fun has(key: String) = key in m
            override fun int(key: String, default: Int) = m[key] as? Int ?: default
            override fun bool(key: String, default: Boolean) = m[key] as? Boolean ?: default
            override fun string(key: String): String? = m[key] as? String
        }
        val withDev = dev.matebridge.client.session.DevKnobs.parse(
            Extras(mapOf("dev" to true, "dec_lowlat" to "hisi", "dec_oprate" to "max")))
        start(tuning = withDev.decoderLatency)
        assertTrue(env.awaitLines("codec_start"))
        assertEquals(
            todayHevc60.map { if (it.first == "operating-rate") it.first to 32767 else it } +
                listOf(HISI_REQ to 1, HISI_RDY to -1),
            keys(factory.codecs.single()),
        )
        assertTrue(env.lines("codec_start").single().contains(" lowlat=hisi oprate=max accepted "))

        val noDev = dev.matebridge.client.session.DevKnobs.parse(Extras(mapOf("dec_lowlat" to "hisi", "dec_oprate" to "max")))
        assertEquals(DecoderLatencyKnobs.DEFAULT, noDev.decoderLatency)
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

    @Test fun parseTakesKnownIdsAndKeepsTheDefaultOtherwise() {
        assertEquals(DecoderLatencyKnobs.DEFAULT, DecoderLatencyKnobs.parse(null, null))
        assertEquals(DecoderLatencyKnobs(LowLat.ALL, OpRate.MAX), DecoderLatencyKnobs.parse(" ALL ", "max"))
        assertEquals(DecoderLatencyKnobs(LowLat.HISI), DecoderLatencyKnobs.parse("hisi", "bogus"))
        assertEquals(DecoderLatencyKnobs.DEFAULT, DecoderLatencyKnobs.parse("10.0.0.1", ""))
        assertTrue(DecoderLatencyKnobs.parse("off", "fps").isDefault)
    }

    @Test fun defaultAddsNothingAndKeepsTheStreamFpsRate() {
        val d = DecoderLatencyKnobs.DEFAULT
        assertEquals(emptyList<Pair<String, Int>>(), d.extraKeys)
        assertEquals(emptyList<String>(), d.changedKeys())
        assertEquals(OperatingRate.resolve(60), d.operatingRate(60))
        assertNull(d.operatingRate(0))
        assertEquals(32767, DecoderLatencyKnobs(opRate = OpRate.MAX).operatingRate(0))
    }

    @Test fun vendorParamsFieldsHandleEmptyAndLongLists() {
        assertEquals("count=0 keys=-", VendorParams.fields(emptyList()))
        val many = (1..70).map { "vendor.k$it" }
        val f = VendorParams.fields(many)
        assertTrue(f, f.startsWith("count=70 keys=vendor.k1,"))
        assertTrue(f, f.endsWith(",vendor.k64 more=6"))
    }
}
