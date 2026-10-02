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

    // T-118: a span inflated by a stall's descent does not raise the refill level beyond two packets.
    @Test fun refillSpanIsCappedAtTwentyMs() {
        val d = DriftController()
        var level = 80 * 48
        repeat(500) { d.onBurst(level, 96); level -= 5 } // one window falling ~52 ms
        assertTrue(d.lastSpanFrames > 40 * 48)
        assertEquals(20 * 48, d.refillSpanFrames)
        assertEquals(d.targetFrames + 20 * 48, d.refillThresholdFrames(96, 144))
    }

    // T-118 (b): clean playback brings 40 ms down to the AAudio floor (20 ms) in 100 s, within the ~2 min asked for.
    @Test fun fortyDecaysToTwentyWithinTwoMinutesOfCleanPlayback() {
        val d = DriftController()
        d.resetSafety(initialMs = 40, floorMs = 20)
        var windows = 0
        while (d.safetyFrames > 20 * 48) { window(d, d.targetFrames); windows++ }
        assertEquals(100, windows)
        assertTrue("$windows s", windows <= 120)
        repeat(1_000) { window(d, d.targetFrames) }
        assertEquals(20 * 48, d.safetyFrames) // the floor holds
    }

    // T-118 (c): one underrun adds 5 ms, which clean playback takes back in 25 s.
    @Test fun oneUnderrunAddsFiveThenShrinksAgain() {
        val d = DriftController()
        d.resetSafety(initialMs = 20, floorMs = 20)
        repeat(3) { window(d, d.targetFrames) }
        d.onUnderrun()
        assertEquals(25 * 48, d.safetyFrames)
        repeat(DriftController.DECAY_WINDOWS - 1) { window(d, d.targetFrames) }
        assertEquals(25 * 48, d.safetyFrames) // the clean count restarted at the underrun
        window(d, d.targetFrames)
        assertEquals(24 * 48, d.safetyFrames)
        repeat(4 * DriftController.DECAY_WINDOWS) { window(d, d.targetFrames) }
        assertEquals(20 * 48, d.safetyFrames)
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

    @Test fun safetyDecaysAfterAnUnderrun() {
        val d = DriftController()
        d.onUnderrun()
        assertEquals(480, d.safetyFrames)
        repeat(DriftController.DECAY_WINDOWS - 1) { window(d, 480) }
        assertEquals(480, d.safetyFrames) // DECAY_WINDOWS clean windows before the first step down
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

    @Test fun resetSafetySetsStartAndDecayFloor() {
        val d = DriftController()
        d.resetSafety(initialMs = 30, floorMs = 20)
        assertEquals(30 * 48, d.safetyFrames)
        assertEquals(30 * 48, d.targetFrames)
        repeat(DriftController.DECAY_WINDOWS) { window(d, 30 * 48) }
        assertEquals(29 * 48, d.safetyFrames) // the decay rule is the same as without a reset
        repeat(20 * DriftController.DECAY_WINDOWS) { window(d, 30 * 48) }
        assertEquals(20 * 48, d.safetyFrames) // ...down to the floor only
        d.onUnderrun()
        assertEquals(25 * 48, d.safetyFrames) // underruns still add 5 ms
        repeat(10) { d.onUnderrun() }
        assertEquals(40 * 48, d.safetyFrames) // capped at 40 ms
    }

    @Test fun resetSafetyClampsAndNeverStartsBelowTheFloor() {
        val d = DriftController()
        d.resetSafety(initialMs = 10, floorMs = 20)
        assertEquals(20 * 48, d.safetyFrames)
        d.resetSafety(initialMs = 90, floorMs = 1)
        assertEquals(DriftController.SAFETY_MAX_MS * 48, d.safetyFrames)
        repeat(100 * DriftController.DECAY_WINDOWS) { window(d, 480) }
        assertEquals(DriftController.SAFETY_MIN_MS * 48, d.safetyFrames)
    }
}
