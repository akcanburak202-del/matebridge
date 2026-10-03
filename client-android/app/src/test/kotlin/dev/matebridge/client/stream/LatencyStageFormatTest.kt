package dev.matebridge.client.stream

import dev.matebridge.client.video.IntervalSummary
import dev.matebridge.client.video.VideoStats
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** T-168: signed clock latency and the stage fields / overlay labels. */
class LatencyStageFormatTest {
    @Test fun signedLatencyIsNotClampedAndTheUncertaintyIsHalfTheBestRtt() {
        val c = ClockSync()
        assertNull(c.latencySignedUs(1, 2))
        assertNull(c.uncertaintyUs())
        c.onPong(0, 1_000 + 10_000_000, 2_000) // offset 10_000_000, rtt 2 ms
        c.onPong(10_000, 11_000 + 10_000_000, 18_000) // rtt 8 ms: not the best
        assertEquals(30_000L, c.latencySignedUs(10_100_000, 130_000))
        assertEquals(-370_000L, c.latencySignedUs(10_500_000, 130_000))
        assertEquals(0L, c.latencyUs(10_500_000, 130_000)) // the u32 view still clamps
        assertEquals(1_000L, c.uncertaintyUs())
    }

    @Test fun negativeAverageIsClampedOnlyOnTheWire() {
        val snap = VideoStats.Snapshot(1, 1, 1, 0, 0, 0)
        assertEquals(0L, StatsFormat.toMessage(snap, 1000, -5_000).latencyAvgUs)
    }

    private val full = IntervalSummary(10, 11_000, 14_000, 15_000, 0, maxUs = 16_000)

    @Test fun stageFieldsShowDashesWhenEmptyOrUnavailable() {
        assertEquals("cap_rel_p50_us=11000 cap_rel_p95_us=14000 cap_rel_p99_us=15000 cap_rel_max_us=16000",
            StatsFormat.stageFields("cap_rel", full))
        assertEquals("ready_slot_p50_us=- ready_slot_p95_us=- ready_slot_p99_us=-",
            StatsFormat.stageFields("ready_slot", IntervalSummary.EMPTY, withMax = false))
        assertEquals("cap_cb_p50_us=- cap_cb_p95_us=- cap_cb_p99_us=- cap_cb_max_us=-",
            StatsFormat.stageFields("cap_cb", full, available = false))
        val neg = IntervalSummary(2, -3_000, -1_000, -1_000, 0, maxUs = -1_000)
        assertEquals("cap_dec_p50_us=-3000 cap_dec_p95_us=-1000 cap_dec_p99_us=-1000 cap_dec_max_us=-1000",
            StatsFormat.stageFields("cap_dec", neg))
    }

    @Test fun latencyStageFieldsListEveryStage() {
        val s = VideoStats.Snapshot(60, 60, 58, 2, 4_000, 1_000, 11_000,
            capDec = full, readySlot = full, capRel = full, capCb = full, latNeg = 3, discarded = 2, renderCbMissing = 1)
        val f = StatsFormat.latencyStageFields(s, codecCallbacks = true, clockUncUs = 2_300)
        assertEquals(
            "cap_dec_p50_us=11000 cap_dec_p95_us=14000 cap_dec_p99_us=15000 cap_dec_max_us=16000 " +
                "ready_slot_p50_us=11000 ready_slot_p95_us=14000 ready_slot_p99_us=15000 " +
                "cap_rel_p50_us=11000 cap_rel_p95_us=14000 cap_rel_p99_us=15000 cap_rel_max_us=16000 " +
                "cap_cb_p50_us=11000 cap_cb_p95_us=14000 cap_cb_p99_us=15000 cap_cb_max_us=16000 " +
                "render_cb_missing=1 discarded=2 lat_neg=3 clock_unc_us=2300",
            f,
        )
        val gl = StatsFormat.latencyStageFields(s, codecCallbacks = false, clockUncUs = null)
        assertTrue(gl, gl.contains("cap_cb_p50_us=- ") && gl.contains("cap_cb_max_us=- render_cb_missing=- "))
        assertTrue(gl, gl.endsWith(" clock_unc_us=-"))
    }

    @Test fun overlaySaysCaptureToDecodeAndShowsReadyToSlotAndClock() {
        val s = VideoStats.Snapshot(60, 60, 60, 0, 4_000, 1_000, 11_000,
            readySlot = IntervalSummary(60, 14_200, 16_000, 16_500, 0))
        val text = StatsFormat.overlay(s, 1000, 11_000, null, clockUncUs = 2_300)
        assertTrue(text, text.contains("Yak→çöz 11 ms"))
        assertTrue(text, !text.contains("Gecikme"))
        assertTrue(text, text.contains("\nHazır→slot p50 14.2 ms | saat ±2.3 ms\n"))
        val empty = StatsFormat.overlay(VideoStats.Snapshot(0, 0, 0, 0, 0, 0), 1000, null)
        assertTrue(empty, empty.contains("Hazır→slot p50 - | saat ±?"))
    }
}
