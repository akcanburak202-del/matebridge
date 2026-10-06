package dev.matebridge.client.audio

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** T-287: the idle-pause rules ([IdlePause]) and the first-sound stamp ([FirstSoundTimer]). */
class IdlePauseTest {
    private val after = IdlePause.AFTER_FRAMES

    @Test fun pausesOnlyAfterTenSecondsOfSilenceWhilePriming() {
        val p = IdlePause(IdlePause.Mode.PAUSE)
        assertEquals(10 * 48_000L, after)
        assertFalse(p.shouldPause(priming = true, framesSinceLastPacket = after - 1, canPause = true))
        assertTrue(p.shouldPause(priming = true, framesSinceLastPacket = after, canPause = true))
        assertFalse("playing audio is never paused", p.shouldPause(priming = false, framesSinceLastPacket = after * 3, canPause = true))
    }

    @Test fun outputsThatCannotPauseAreNeverPaused() {
        val p = IdlePause(IdlePause.Mode.PAUSE)
        assertFalse(p.shouldPause(priming = true, framesSinceLastPacket = after * 3, canPause = false))
    }

    @Test fun offModeNeverPauses() {
        val p = IdlePause(IdlePause.Mode.OFF)
        assertFalse(p.enabled)
        assertFalse(p.shouldPause(priming = true, framesSinceLastPacket = after * 3, canPause = true))
    }

    @Test fun stopModePausesLikePauseMode() {
        val p = IdlePause(IdlePause.Mode.STOP)
        assertTrue(p.shouldPause(priming = true, framesSinceLastPacket = after, canPause = true))
    }

    @Test fun noSecondPauseBeforeABurstWasRenderedAfterAResume() {
        // The core still holds the old "frames since the last packet" until it renders once.
        val p = IdlePause(IdlePause.Mode.PAUSE)
        p.onPaused()
        p.onResumed()
        assertFalse(p.shouldPause(priming = true, framesSinceLastPacket = after + 5, canPause = true))
        p.onRendered()
        assertTrue(p.shouldPause(priming = true, framesSinceLastPacket = after, canPause = true))
        assertEquals(1L, p.pauses)
    }

    @Test fun aNewOutputClearsTheSettlingState() {
        val p = IdlePause(IdlePause.Mode.PAUSE)
        p.onResumed()
        p.onNewOutput()
        assertTrue(p.shouldPause(priming = true, framesSinceLastPacket = after, canPause = true))
    }

    @Test fun aFailureTurnsPausingOffForTheStream() {
        val p = IdlePause(IdlePause.Mode.PAUSE)
        p.disable("pause_failed")
        p.disable("resume_failed") // the first reason stays
        assertEquals("pause_failed", p.disabledReason)
        assertFalse(p.enabled)
        assertFalse(p.shouldPause(priming = true, framesSinceLastPacket = after * 3, canPause = true))
        p.onNewOutput()
        assertFalse("a rebuild does not re-enable it", p.shouldPause(priming = true, framesSinceLastPacket = after * 3, canPause = true))
    }

    @Test fun launchSwitchResolves() {
        assertEquals(IdlePause.Resolved(IdlePause.Mode.PAUSE, false), IdlePause.resolve(null))
        assertEquals(IdlePause.Resolved(IdlePause.Mode.OFF, false), IdlePause.resolve("off"))
        assertEquals(IdlePause.Resolved(IdlePause.Mode.PAUSE, false), IdlePause.resolve("PAUSE"))
        assertEquals(IdlePause.Resolved(IdlePause.Mode.STOP, false), IdlePause.resolve(" stop "))
        assertEquals(IdlePause.Resolved(IdlePause.DEFAULT, true), IdlePause.resolve("later"))
        assertEquals(IdlePause.Mode.PAUSE, IdlePause.DEFAULT)
    }

    @Test fun firstPacketOfAStreamIsStamped() {
        val t = FirstSoundTimer()
        assertEquals(0L, t.peek())
        t.onPacket(1_000)
        assertEquals(1_000L, t.peek())
        assertEquals(1_000L, t.take())
        assertEquals(0L, t.take())
    }

    @Test fun packetsWithinAGapThresholdAreNotStamped() {
        val t = FirstSoundTimer(gapNs = 400)
        t.onPacket(1_000)
        t.take()
        t.onPacket(1_010)
        t.onPacket(1_399) // 389 after the previous one
        assertEquals(0L, t.peek())
    }

    @Test fun thePacketAfterAGapIsStampedAndNotOverwritten() {
        val t = FirstSoundTimer(gapNs = 400)
        t.onPacket(1_000)
        t.take()
        t.onPacket(2_000) // gap
        t.onPacket(2_010)
        t.onPacket(3_000) // another gap before the first stamp was taken: the older one stays
        assertEquals(2_000L, t.peek())
        assertEquals(2_000L, t.take())
        t.onPacket(4_000)
        assertEquals(4_000L, t.take())
    }
}
