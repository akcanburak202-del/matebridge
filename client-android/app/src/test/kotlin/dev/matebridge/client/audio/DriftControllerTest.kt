package dev.matebridge.client.audio

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class DriftControllerTest {
    /** One 1 s window of 96-frame bursts, every burst leaving [remaining] frames. */
    private fun window(d: DriftController, remaining: Int): DriftController.Decision {
        var last: DriftController.Decision = DriftController.Decision.None
        repeat(500) { last = d.onBurst(remaining, 96) }
        return last
    }

    @Test fun refillCoversABurstPlusFadeReserve() {
        val d = DriftController()
        // 5 ms target + 10 ms span with small bursts
        assertEquals(240 + 480, d.refillThresholdFrames(96, 144))
        // a 20 ms native burst: target + burst + fade-out reserve
        assertEquals(240 + 960 + 144, d.refillThresholdFrames(960, 144))
        // never above the max refill level
        assertEquals(d.maxRefillFrames, d.refillThresholdFrames(20_000, 144))
    }

    @Test fun avFloorRisesAtMostTenMsPerWindowAndFallsAtOnce() {
        val d = DriftController()
        window(d, 480)
        assertTrue(d.onAvOffset(-100_000))
        assertEquals(480, d.avFloorFrames)
        assertTrue(d.onAvOffset(-100_000))
        assertEquals(960, d.avFloorFrames)
        assertTrue(d.onAvOffset(+100_000)) // late: down at once (clamped at 0)
        assertEquals(0, d.avFloorFrames)
    }

    @Test fun rebufferOnlyBeyondSixtyMs() {
        val d = DriftController()
        window(d, 480)
        repeat(5) { d.onAvOffset(-200_000) } // +50 ms
        assertEquals(DriftController.Decision.None, window(d, 480)) // 40 ms short: the PI slews
        val e = DriftController()
        window(e, 480)
        repeat(8) { e.onAvOffset(-200_000) } // +80 ms
        assertEquals(DriftController.Decision.Rebuffer, window(e, 480)) // 70 ms short
        assertEquals(1L, e.rebuffers)
    }

    @Test fun safetyDecaysSlowlyAfterAnUnderrun() {
        val d = DriftController()
        d.onUnderrun()
        assertEquals(480, d.safetyFrames)
        repeat(DriftController.DECAY_WINDOWS - 1) { window(d, 480) }
        assertEquals(480, d.safetyFrames) // a minute without underrun before the first step down
        window(d, 480)
        assertEquals(480 - 48, d.safetyFrames)
        repeat(20 * DriftController.DECAY_WINDOWS) { window(d, 480) }
        assertEquals(240, d.safetyFrames) // never below the minimum
    }

    @Test fun safetyGrowsPerUnderrunUpToForty() {
        val d = DriftController()
        repeat(20) { d.onUnderrun() }
        assertEquals(40 * 48, d.safetyFrames)
    }
}
