package dev.matebridge.client.video

import dev.matebridge.client.protocol.StreamConfig
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** T-238 (decision 0032): an HDR10 STREAM_CONFIG gives the decoder BT.2020 / ST 2084 / limited; SDR stays byte-identical. */
class Hdr10DecoderFormatTest {
    /** What the host sends today (SDR): HEVC 2800x1840 @ 60, BT.709 / sRGB / BT.709, full range. */
    private val sdr = StreamConfig(1, StreamConfig.CODEC_HEVC, 2800, 1840, 1400, 920, 60, 50000, 1, 13, 1, 1)
    /** The same stream with HDR10 applied (PROTOCOL.md 0x03): 9 / 16 / 9, limited range. */
    private val hdr = sdr.copy(colorPrimaries = 9, transfer = 16, matrix = 9, fullRange = 0)

    private val factory = FakeDecoderFactory()
    private val env = TestDecoderEnv()
    private var renderer: VideoRenderer? = null

    @After fun tearDown() { renderer?.detachSurface() }

    private fun configured(config: StreamConfig): List<Pair<String, Int>> {
        val r = VideoRenderer(config, onKeyframeRequest = {}, codecFactory = factory, env = env,
            restartDelaysMs = longArrayOf(60_000, 60_000, 60_000))
        renderer = r
        r.attachTarget(Any())
        assertTrue(env.awaitLines("codec_start"))
        return factory.codecs.single().format!!.integers.map { it.key to it.value }
    }

    /** Literal key names: the app default's SDR format (T-231 `todayHevc60`), byte for byte. */
    private val sdrKeys = listOf(
        "priority" to 0,
        "max-input-size" to 2800 * 1840 * 3 / 2,
        "frame-rate" to 60,
        "operating-rate" to 32767,
        "color-standard" to 1,
        "color-transfer" to 3,
        "color-range" to 1,
        "low-latency" to 1,
    )

    @Test fun sdrFormatIsUnchanged() {
        assertEquals(sdrKeys, configured(sdr))
        assertTrue(env.lines("color_unsupported").isEmpty())
    }

    @Test fun hdr10GetsBt2020St2084Limited() {
        val got = configured(hdr)
        // MediaFormat.COLOR_STANDARD_BT2020 = 6, COLOR_TRANSFER_ST2084 = 6, COLOR_RANGE_LIMITED = 2; nothing else changes.
        assertEquals(
            sdrKeys.map {
                when (it.first) {
                    "color-standard" -> it.first to 6
                    "color-transfer" -> it.first to 6
                    "color-range" -> it.first to 2
                    else -> it
                }
            },
            got,
        )
        // No KEY_HDR_STATIC_INFO or profile key: the decoder reads the SEI and the SPS (hdr-probe 2026-10-05).
        assertFalse(got.any { it.first == "profile" })
        // BT.2020 primaries ride on the BT.2020 standard: no `color_unsupported` warning.
        assertTrue(env.lines("color_unsupported").isEmpty())
    }

    @Test fun displayP3IsStillReportedAsUntagged() {
        configured(sdr.copy(colorPrimaries = 12))
        assertEquals(1, env.lines("color_unsupported").size)
    }

    @Test fun mappingCodes() {
        assertEquals(ColorMapping.STANDARD_BT2020, ColorMapping.standard(StreamConfig.MATRIX_BT2020_NCL))
        assertEquals(ColorMapping.TRANSFER_ST2084, ColorMapping.transfer(StreamConfig.TRANSFER_PQ))
        assertEquals(ColorMapping.RANGE_LIMITED, ColorMapping.range(0))
        assertTrue(ColorMapping.primariesConveyed(1, 1))
        assertTrue(ColorMapping.primariesConveyed(StreamConfig.PRIMARIES_BT2020, StreamConfig.MATRIX_BT2020_NCL))
        assertFalse(ColorMapping.primariesConveyed(StreamConfig.PRIMARIES_BT2020, 1)) // BT.2020 primaries with a 709 matrix
        assertFalse(ColorMapping.primariesConveyed(12, 1)) // Display P3
    }
}
