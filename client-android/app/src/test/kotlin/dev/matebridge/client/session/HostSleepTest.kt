package dev.matebridge.client.session

import dev.matebridge.client.session.WolRefresh.Result
import dev.matebridge.client.session.WolRefresh.Step
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class HostSleepGateTest {
    private val g = HostSleepGate()
    private val sleep = SessionUi.Failed(SessionUi.Cause.HOST_SLEEP)

    @Test fun hostSleepByeEntersSleepOnce() {
        assertTrue(g.allowsAuto)
        assertTrue(g.onUi(sleep))
        assertTrue(g.asleep)
        assertFalse(g.allowsAuto)
        assertFalse(g.onUi(sleep)) // already asleep: no second entry
    }

    @Test fun otherStatesDoNotSleepOrWake() {
        val others = listOf(
            SessionUi.Idle, SessionUi.Searching, SessionUi.Connecting(Endpoint("10.0.0.5", 7420)),
            SessionUi.Connected("Mac", 0), SessionUi.AwaitingApproval("Mac"),
            SessionUi.Disconnected(SessionUi.Cause.HOST_CLOSED, 1000), SessionUi.Disconnected(SessionUi.Cause.LOST, 1000),
            SessionUi.Failed(SessionUi.Cause.REJECTED),
        )
        for (s in others) assertFalse(g.onUi(s))
        assertFalse(g.asleep)
        g.onUi(sleep)
        for (s in others) g.onUi(s) // only a user action or the foreground clears it
        assertTrue(g.asleep)
    }

    @Test fun clearReturnsToNormal() {
        assertFalse(g.clear()) // not asleep: nothing to clear
        g.onUi(sleep)
        assertTrue(g.clear()) // foreground / Bağlan / Mac'i uyandır
        assertFalse(g.asleep)
        assertTrue(g.allowsAuto)
        assertTrue(g.onUi(sleep)) // the next BYE(HOST_SLEEP) puts it to sleep again
    }
}

class WolRefreshTest {
    private val r = WolRefresh()
    private var now = 5_000L
    private val wol = "aa:bb:cc:dd:ee:01"

    @Test fun startsOnceWhenConnectedOnUsb() {
        assertEquals(Step.None, r.onSession(false, now) { true }) // Wi-Fi session or not connected: nothing
        assertEquals(Step.Start, r.onSession(true, now) { true })
        assertTrue(r.running)
        assertEquals(Step.None, r.onSession(true, now) { true })
        assertEquals(Step.Finish(Result.STORED), r.onTxt(wol))
        assertFalse(r.running)
        assertEquals(Step.None, r.onSession(true, now + 60_000) { true }) // once per start
    }

    @Test fun noWifiFinishesAtOnceWithoutDiscovery() {
        var asked = 0
        assertEquals(Step.None, r.onSession(false, now) { asked++; false })
        assertEquals(0, asked) // Wi-Fi is checked only when a refresh is due
        assertEquals(Step.Finish(Result.NO_WIFI), r.onSession(true, now) { asked++; false })
        assertFalse(r.running)
        assertEquals(Step.None, r.onSession(true, now) { true })
    }

    @Test fun timesOutAsNone() {
        r.onSession(true, now) { true }
        assertEquals(Step.None, r.tick(now + WolRefresh.DURATION_MS - 1))
        assertEquals(Step.Finish(Result.NONE), r.tick(now + WolRefresh.DURATION_MS))
        assertEquals(Step.None, r.tick(now + 2 * WolRefresh.DURATION_MS))
    }

    @Test fun unusableTxtDoesNotFinish() {
        r.onSession(true, now) { true }
        assertEquals(Step.None, r.onTxt(null))
        assertEquals(Step.None, r.onTxt("zz:zz"))
        assertTrue(r.running)
        assertEquals(Step.Finish(Result.STORED), r.onTxt("x, $wol"))
    }

    @Test fun txtOutsideARefreshIsIgnored() {
        assertEquals(Step.None, r.onTxt(wol))
    }

    @Test fun cancelAndResetAllowANewRunOnTheNextStart() {
        assertEquals(Step.None, r.cancel())
        r.onSession(true, now) { true }
        assertEquals(Step.Finish(Result.CANCELLED), r.cancel())
        assertEquals(Step.None, r.onSession(true, now) { true }) // done for this start
        r.reset()
        assertEquals(Step.Start, r.onSession(true, now) { true })
    }

    @Test fun resetDoesNotDisturbARunningRefresh() {
        r.onSession(true, now) { true }
        r.reset()
        assertTrue(r.running)
        assertEquals(Step.None, r.onSession(true, now) { true })
    }
}
