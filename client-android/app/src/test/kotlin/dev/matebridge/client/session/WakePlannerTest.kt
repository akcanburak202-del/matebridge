package dev.matebridge.client.session

import dev.matebridge.client.session.WakePlanner.Companion.COOLDOWN_MS
import dev.matebridge.client.session.WakePlanner.Companion.EPISODE_MS
import dev.matebridge.client.session.WakePlanner.Companion.GRACE_MS
import dev.matebridge.client.session.WakePlanner.Companion.INTERVAL_MS
import dev.matebridge.client.session.WakePlanner.Step
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class WakePlannerTest {
    private val p = WakePlanner()
    private var now = 10_000L

    private fun tick(
        advance: Long = 0, foreground: Boolean = true, userOff: Boolean = false, reached: Boolean = false, hasWol: Boolean = true,
        asleep: Boolean = false,
    ): List<Step> {
        now += advance
        return p.update(now, foreground, userOff, reached, hasWol, asleep)
    }

    /** Ticks every [stepMs] for [durationMs] (not reached, foreground); returns all steps. */
    private fun run(durationMs: Long, stepMs: Long = 250): List<Step> {
        val out = ArrayList<Step>()
        var t = 0L
        while (t < durationMs) { out += tick(stepMs); t += stepMs }
        return out
    }

    private fun startEpisode() {
        tick()
        tick(GRACE_MS)
        assertTrue(p.active)
    }

    @Test fun startsAfterGrace() {
        assertTrue(tick().isEmpty())
        assertTrue(tick(GRACE_MS - 1).isEmpty())
        assertEquals(listOf(Step.Start(WakePlanner.REASON_AUTO), Step.Send), tick(1))
        assertTrue(p.active)
    }

    @Test fun noEpisodeWithoutStoredAddresses() {
        tick(hasWol = false)
        assertTrue(tick(GRACE_MS * 10, hasWol = false).isEmpty())
        assertFalse(p.active)
    }

    @Test fun sendsEverySecond() {
        startEpisode()
        assertTrue(tick(INTERVAL_MS - 1).isEmpty())
        assertEquals(listOf(Step.Send), tick(1))
        assertTrue(tick(500).isEmpty())
        assertEquals(listOf(Step.Send), tick(500))
    }

    @Test fun episodeEndsAfterTwentySeconds() {
        startEpisode()
        val steps = run(EPISODE_MS)
        assertEquals(Step.Stop(WakePlanner.REASON_TIMEOUT), steps.last())
        assertEquals(19, steps.count { it == Step.Send }) // + the one with Start = 20 in 20 s
        assertFalse(p.active)
    }

    @Test fun cooldownOfThirtySecondsAfterTimeout() {
        startEpisode()
        run(EPISODE_MS)
        assertFalse(p.active)
        assertTrue(run(COOLDOWN_MS - 250).none { it is Step.Start })
        assertEquals(listOf(Step.Start(WakePlanner.REASON_AUTO), Step.Send), tick(250))
    }

    @Test fun reachingHostStopsAtOnce() {
        startEpisode()
        assertEquals(listOf(Step.Stop(WakePlanner.REASON_CONNECTED)), tick(300, reached = true))
        assertFalse(p.active)
        assertTrue(tick(10_000, reached = true).isEmpty())
    }

    @Test fun lossAfterConnectStartsAgainAfterGraceNotCooldown() {
        startEpisode()
        run(EPISODE_MS) // timeout -> cooldown
        tick(1000, reached = true) // connected: cooldown cleared
        assertTrue(tick(100).isEmpty()) // lost again
        assertTrue(tick(GRACE_MS - 1).isEmpty())
        assertEquals(Step.Start(WakePlanner.REASON_AUTO), tick(1).first())
    }

    @Test fun backgroundStopsAndNeverSends() {
        startEpisode()
        assertEquals(listOf(Step.Stop(WakePlanner.REASON_BACKGROUND)), tick(100, foreground = false))
        for (i in 0 until 200) assertTrue(tick(250, foreground = false).isEmpty())
        assertFalse(p.active)
    }

    @Test fun returningToForegroundClearsCooldownAndUsesGrace() {
        startEpisode()
        run(EPISODE_MS) // timeout -> cooldown 30 s
        tick(1000, foreground = false)
        assertTrue(tick(1000).isEmpty()) // back: grace starts now
        assertTrue(tick(GRACE_MS - 1).isEmpty())
        assertEquals(Step.Start(WakePlanner.REASON_AUTO), tick(1).first())
    }

    @Test fun userDisconnectStopsAndBlocksAutomaticEpisodes() {
        startEpisode()
        assertEquals(listOf(Step.Stop(WakePlanner.REASON_USER)), tick(100, userOff = true))
        for (i in 0 until 200) assertTrue(tick(250, userOff = true).isEmpty())
        assertFalse(p.active)
    }

    @Test fun hostAsleepStopsAndBlocksAutomaticEpisodes() {
        startEpisode()
        assertEquals(listOf(Step.Stop(WakePlanner.REASON_HOST_SLEEP)), tick(100, asleep = true))
        for (i in 0 until 400) assertTrue(tick(250, asleep = true).isEmpty()) // way past grace and cooldown
        assertFalse(p.active)
        // Cleared (user action / foreground): the normal grace applies again.
        assertTrue(tick(250).isEmpty())
        assertTrue(tick(GRACE_MS - 1).isEmpty())
        assertEquals(Step.Start(WakePlanner.REASON_AUTO), tick(1).first())
    }

    @Test fun manualStartsDuringCooldown() {
        startEpisode()
        run(EPISODE_MS)
        tick(1000)
        assertEquals(listOf(Step.Start(WakePlanner.REASON_MANUAL), Step.Send), p.manual(now, reached = false, hasWol = true))
        assertTrue(p.active)
        assertTrue(tick(INTERVAL_MS - 1).isEmpty())
        assertEquals(listOf(Step.Send), tick(1))
    }

    @Test fun manualStartsBeforeGrace() {
        tick()
        assertEquals(listOf(Step.Start(WakePlanner.REASON_MANUAL), Step.Send), p.manual(now, reached = false, hasWol = true))
    }

    @Test fun manualExtendsRunningEpisode() {
        startEpisode()
        run(EPISODE_MS - 1000)
        assertTrue(p.active)
        assertEquals(listOf(Step.Send), p.manual(now, reached = false, hasWol = true))
        val steps = run(EPISODE_MS - 250)
        assertTrue(steps.none { it is Step.Stop })
        assertEquals(Step.Stop(WakePlanner.REASON_TIMEOUT), tick(250).single())
    }

    @Test fun manualIgnoredWhenReachedOrNoAddresses() {
        tick()
        assertTrue(p.manual(now, reached = true, hasWol = true).isEmpty())
        assertTrue(p.manual(now, reached = false, hasWol = false).isEmpty())
        assertFalse(p.active)
    }

    @Test fun reachedStates() {
        val ep = Endpoint("10.0.0.5", 47001)
        assertTrue(WakePlanner.reached(SessionUi.Connected("Mac", 0)))
        assertTrue(WakePlanner.reached(SessionUi.AwaitingApproval("Mac")))
        assertTrue(WakePlanner.reached(SessionUi.Failed(SessionUi.Cause.REJECTED)))
        // The host answered, then the session machine retries (SessionMachine.lose): awake.
        assertTrue(WakePlanner.reached(SessionUi.Disconnected(SessionUi.Cause.BUSY, 5000)))
        assertTrue(WakePlanner.reached(SessionUi.Disconnected(SessionUi.Cause.HOST_CLOSED, 1000)))
        assertTrue(WakePlanner.reached(SessionUi.Disconnected(SessionUi.Cause.PROTOCOL_ERROR, 1000)))
        // No answer: what a sleeping Mac looks like.
        assertFalse(WakePlanner.reached(SessionUi.Disconnected(SessionUi.Cause.CONNECT_FAILED, 1000)))
        assertFalse(WakePlanner.reached(SessionUi.Disconnected(SessionUi.Cause.LOST, 1000)))
        assertFalse(WakePlanner.reached(SessionUi.Searching))
        assertFalse(WakePlanner.reached(SessionUi.Idle))
        assertFalse(WakePlanner.reached(SessionUi.Connecting(ep)))
    }

    @Test fun busyHostStopsEpisodeAndStartsNone() {
        val busy = WakePlanner.reached(SessionUi.Disconnected(SessionUi.Cause.BUSY, 5000))
        startEpisode()
        assertEquals(listOf(Step.Stop(WakePlanner.REASON_CONNECTED)), tick(500, reached = busy))
        for (i in 0 until 100) assertTrue(tick(250, reached = busy).isEmpty())
        assertFalse(p.active)
    }

    // ---- home network ----

    private fun tickSkip(advance: Long, skip: String?, counter: IntArray? = null): List<Step> {
        now += advance
        return p.update(now, true, false, false, true) { counter?.let { it[0]++ }; skip }
    }

    @Test fun offHomeNetworkSkipsOnceAndRechecks() {
        val calls = IntArray(1)
        tickSkip(0, "other_network", calls)
        assertEquals(0, calls[0]) // not due yet: not even asked
        assertEquals(listOf(Step.Skip("other_network")), tickSkip(GRACE_MS, "other_network", calls))
        assertEquals(1, calls[0])
        val later = ArrayList<Step>()
        for (i in 0 until 40) later += tickSkip(250, "other_network", calls) // 10 s
        assertTrue(later.isEmpty()) // same reason: logged once
        assertEquals(3, calls[0]) // rechecked every SKIP_RECHECK_MS (5 s)
        assertFalse(p.active)
    }

    @Test fun reachingHomeNetworkStartsOnNextRecheck() {
        tickSkip(0, "other_network")
        assertEquals(listOf(Step.Skip("other_network")), tickSkip(GRACE_MS, "other_network"))
        assertTrue(tickSkip(WakePlanner.SKIP_RECHECK_MS - 1, null).isEmpty())
        assertEquals(listOf(Step.Start(WakePlanner.REASON_AUTO), Step.Send), tickSkip(1, null))
    }

    @Test fun skipReasonChangeIsLoggedAgain() {
        tickSkip(0, "no_wifi")
        assertEquals(listOf(Step.Skip("no_wifi")), tickSkip(GRACE_MS, "no_wifi"))
        assertEquals(listOf(Step.Skip("other_network")), tickSkip(WakePlanner.SKIP_RECHECK_MS, "other_network"))
    }

    @Test fun manualIgnoresHomeNetwork() {
        tickSkip(0, "other_network")
        tickSkip(GRACE_MS, "other_network")
        assertEquals(listOf(Step.Start(WakePlanner.REASON_MANUAL), Step.Send), p.manual(now, reached = false, hasWol = true))
        assertTrue(p.active)
    }
}
