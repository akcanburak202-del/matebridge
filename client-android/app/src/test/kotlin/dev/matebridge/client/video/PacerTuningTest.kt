package dev.matebridge.client.video

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** T-251: pacer dev knobs: cap scaling, feedback pin, diagnostics fields, trace level column. */
class PacerTuningTest {
    private val ms = 1_000_000L

    @Test fun standardCapsAreTheBuiltInOnes() {
        val t = PacerTuning.STANDARD
        assertEquals(2L, t.capHalfFor(1))
        assertEquals(AdaptivePacer.MAX_D_HALF_PERIODS, t.capHalfFor(2))
        assertEquals(0L, t.boundExtraHalf(1))
        assertEquals(0L, t.boundExtraHalf(2))
        assertEquals("-", t.logFields())
    }

    @Test fun capOverrideAppliesToBothCadencesAndWidensBoundsOnlyUpward() {
        val t = PacerTuning.parse(4, true)
        assertEquals(4L, t.capHalfFor(1)); assertEquals(4L, t.capHalfFor(2))
        assertEquals(2L, t.boundExtraHalf(1)); assertEquals(1L, t.boundExtraHalf(2))
        val lower = PacerTuning.parse(1, true)
        assertEquals(0L, lower.boundExtraHalf(1)); assertEquals(0L, lower.boundExtraHalf(2))
        assertEquals("pace_dcap_half:4", t.logFields())
        assertEquals("pace_dcap_half:3;pace_feedback:0", PacerTuning.parse(3, false).logFields())
        assertEquals(PacerTuning.STANDARD, PacerTuning.parse(0, true))
        assertEquals(PacerTuning.MAX_CAP_HALF, PacerTuning.parse(100, true).dCapHalf)
    }

    private fun runJittery(tuning: PacerTuning): AdaptivePacer {
        val clk = VsyncClock(120f).also { it.onVsync(0); it.setDisplayTiming(0, 6 * ms) }
        val period = clk.grid().periodNs
        val p = AdaptivePacer(clk, period, tuning)
        var v = 0L
        // Heavy jitter: every 4th frame arrives 10 ms late, so the p99 jitter far exceeds one period.
        for (i in 0 until 200) {
            val cap = i * period
            val ready = 50 * ms + cap + if (i % 4 == 3) 10 * ms else 0L
            while (v + period <= ready) { v += period; clk.onVsync(v) }
            p.schedule(cap / 1000, ready)
        }
        return p
    }

    @Test fun dIsCappedByTheConfiguredCap() {
        val period = 1_000_000_000L / 120
        val std = runJittery(PacerTuning.STANDARD)
        assertTrue(std.lastDNs <= period + 1_000)
        assertEquals(period.toDouble(), std.lastCapNs.toDouble(), 1_000.0)
        val wide = runJittery(PacerTuning.parse(4, true))
        assertEquals(2.0 * period, wide.lastCapNs.toDouble(), 1_000.0)
        assertTrue(wide.lastDNs > std.lastDNs)
        assertTrue(wide.lastDNs <= 2 * period + 1_000)
        val narrow = runJittery(PacerTuning.parse(1, true))
        assertTrue(narrow.lastDNs <= period / 2 + 1_000)
    }

    @Test fun feedbackOffPinsLevelAtZero() {
        val clk = VsyncClock(120f).also { it.onVsync(0) }
        val on = AdaptivePacer(clk, 8_333_333L)
        val off = AdaptivePacer(clk, 8_333_333L, PacerTuning(feedback = false))
        repeat(10) { on.onSkipWindow(10.0); off.onSkipWindow(10.0) }
        assertEquals(1, on.level)
        assertEquals(0, off.level)
    }

    @Test fun diagFieldsAndNoneLine() {
        val d = PacerDiag(1, 2_500, 4_166, 8_333)
        assertEquals("fb_level=1 d_jitter_us=2500 d_extra_us=4166 d_cap_us=8333", d.logFields())
        assertTrue(PacerDiag.NONE.startsWith("fb_level=-"))
        val p = runJittery(PacerTuning.STANDARD)
        assertEquals(p.level, p.diag().level)
        assertEquals(p.lastJitterNs / 1000, p.diag().jitterUs)
    }

    @Test fun traceCarriesLevelColumnLast() {
        val t = PaceTrace(4)
        val probe = PaceProbe().also { it.level = 2 }
        t.record(1, 10, 100, probe, 0, false, false, 0)
        t.record(2, 20, 200, null, 0, false, false, 0)
        val lines = StringBuilder().also { t.writeCsv(it) }.toString().trim().split("\n")
        assertTrue(lines[0].endsWith(",level"))
        assertEquals("2", lines[1].split(",").last())
        assertEquals("0", lines[2].split(",").last())
        assertEquals(PaceTrace.CSV_COLS, lines[1].split(",").size)
    }
}
