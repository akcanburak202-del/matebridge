package dev.matebridge.client.session

import dev.matebridge.client.session.WakeConnect.Step
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.IOException
import java.net.ConnectException
import java.net.NoRouteToHostException
import java.net.SocketException
import java.net.SocketTimeoutException

class WakeConnectTest {
    private val target = Endpoint("192.168.1.106", 47001)
    private val w = WakeConnect()
    private var now = 10_000L

    /** The app's session endpoint, as MainActivity keeps it (set on an attempt, cleared on a release). */
    private var current: Endpoint? = null
    private var idle = true

    private fun step(episode: Boolean = true, advanceMs: Long = 0, transportOk: Boolean = true, tgt: Endpoint? = target): Step {
        now += advanceMs
        val s = w.update(now, episode, tgt, current, transportOk, idle)
        when (s) {
            is Step.Attempt -> { current = s.endpoint; idle = false }
            Step.Release -> current = null
            Step.None -> Unit
        }
        return s
    }

    private fun fail(n: Int, advanceMs: Long = 0) {
        now += advanceMs
        assertNull(w.onResult(n, false, now))
        idle = true // the machine reports Disconnected(CONNECT_FAILED, 0)
    }

    @Test fun nothingOutsideAnEpisode() {
        repeat(100) { assertEquals(Step.None, step(episode = false, advanceMs = 250)) }
        assertEquals(0, w.attempts)
    }

    @Test fun firstAttemptAtOnceWhenTheEpisodeStarts() {
        assertEquals(Step.Attempt(1, target), step())
        assertEquals(1, w.inFlight)
    }

    @Test fun noAttemptWithoutTargetOrWithTheWrongTransport() {
        assertEquals(Step.None, step(tgt = null))
        assertEquals(Step.None, step(transportOk = false))
        assertEquals(Step.Attempt(1, target), step())
    }

    @Test fun oneAttemptAtATimeThenTwoSecondsAfterAFailure() {
        assertEquals(Step.Attempt(1, target), step())
        // the connect runs (up to its 3 s timeout): no second attempt meanwhile
        for (i in 0 until 11) assertEquals(Step.None, step(advanceMs = 250))
        fail(1, advanceMs = 250) // failed after 3 s
        assertEquals(Step.None, step(advanceMs = 1_000))
        assertEquals(Step.None, step(advanceMs = 750))
        assertEquals(Step.Attempt(2, target), step(advanceMs = 250)) // 2 s after the failure
        fail(2, advanceMs = 100) // refused at once
        assertEquals(Step.None, step(advanceMs = 1_999))
        assertEquals(Step.Attempt(3, target), step(advanceMs = 1))
    }

    @Test fun attemptsCoverTheTwentySecondEpisode() {
        // every connect times out after 3 s: an attempt about every 5 s through the episode
        val starts = ArrayList<Long>()
        val t0 = now
        var t = 0L
        while (t <= WakePlanner.EPISODE_MS) {
            val s = step(advanceMs = 250)
            if (s is Step.Attempt) starts += now - t0
            if (w.inFlight != 0 && now - t0 - starts.last() >= WakeConnect.CONNECT_TIMEOUT_MS) fail(w.inFlight)
            t += 250
        }
        assertEquals(listOf(250L, 5_250L, 10_250L, 15_250L, 20_250L), starts)
    }

    @Test fun connectedAttemptIsAdoptedAndEndsTheAttempts() {
        assertEquals(Step.Attempt(1, target), step())
        assertEquals(target, w.onResult(1, true, now))
        assertNull(w.owned)
        assertTrue(w.settled)
        idle = true // even if the session then drops, no more direct attempts in this episode
        for (i in 0 until 40) assertEquals(Step.None, step(advanceMs = 250))
        // and the episode end does not release an adopted session
        assertEquals(Step.None, step(episode = false))
        assertEquals(target, current)
    }

    @Test fun staleResultIsIgnored() {
        assertEquals(Step.Attempt(1, target), step())
        assertNull(w.onResult(7, true, now))
        assertEquals(1, w.inFlight)
        assertNull(w.onResult(0, false, now))
        assertEquals(1, w.inFlight)
    }

    @Test fun lostResultIsGivenUpAfterTheStaleTime() {
        assertEquals(Step.Attempt(1, target), step())
        idle = true
        assertEquals(Step.None, step(advanceMs = WakeConnect.STALE_MS - 1))
        assertEquals(Step.Attempt(2, target), step(advanceMs = 1))
    }

    @Test fun episodeEndReleasesOurFailedAttempt() {
        assertEquals(Step.Attempt(1, target), step())
        fail(1, advanceMs = 3_000)
        assertEquals(Step.Release, step(episode = false))
        assertNull(current)
        assertEquals(Step.None, step(episode = false))
    }

    @Test fun episodeEndWaitsForTheAttemptInFlight() {
        assertEquals(Step.Attempt(1, target), step())
        assertEquals(Step.None, step(episode = false, advanceMs = 500)) // still connecting: not released
        assertEquals(target, current)
        fail(1, advanceMs = 1_000)
        assertEquals(Step.Release, step(episode = false))
        assertNull(current)
    }

    @Test fun lateSuccessAfterTheEpisodeIsAdopted() {
        assertEquals(Step.Attempt(1, target), step())
        assertEquals(Step.None, step(episode = false, advanceMs = 500))
        assertEquals(target, w.onResult(1, true, now))
        assertEquals(Step.None, step(episode = false))
        assertEquals(target, current)
    }

    @Test fun newEpisodeNumbersFromOne() {
        assertEquals(Step.Attempt(1, target), step())
        fail(1)
        assertEquals(Step.Attempt(2, target), step(advanceMs = 2_000))
        fail(2)
        assertEquals(Step.Release, step(episode = false))
        assertEquals(Step.Attempt(1, target), step(advanceMs = 30_000))
    }

    // ---- race with discovery: whichever finds the Mac first, one connection ----

    @Test fun discoveryBeforeAnyAttemptKeepsItsSession() {
        assertTrue(w.onDiscovered(current, disconnected = false)) // nothing chosen yet: connect to it
        current = Endpoint("192.168.1.106", 47001)
        idle = false
        assertEquals(Step.None, step()) // someone else's session: no direct attempt
        idle = true // even while that session waits to retry
        assertEquals(Step.None, step(advanceMs = 5_000))
        assertEquals(0, w.attempts)
    }

    @Test fun discoveryReplacesAnAttemptInFlightAndStopsTheAttempts() {
        assertEquals(Step.Attempt(1, target), step())
        assertTrue(w.onDiscovered(current, disconnected = false)) // replaces ours (the start closes it first)
        assertNull(w.owned)
        current = Endpoint("192.168.1.107", 47001)
        fail(1) // the replaced attempt's connect ends with an error
        for (i in 0 until 40) assertEquals(Step.None, step(advanceMs = 250))
        assertEquals(Step.None, step(episode = false)) // and it is not ours to release
        assertEquals(Endpoint("192.168.1.107", 47001), current)
    }

    @Test fun discoveryAfterAFailedAttemptConnects() {
        assertEquals(Step.Attempt(1, target), step())
        fail(1)
        assertTrue(w.onDiscovered(current, disconnected = true))
        current = target // discovery connects (same address): an ordinary session now
        idle = false
        for (i in 0 until 20) assertEquals(Step.None, step(advanceMs = 250))
    }

    @Test fun discoveryIgnoredWhileAnotherSessionIsConnecting() {
        current = Endpoint("127.0.0.1", 47001)
        assertFalse(w.onDiscovered(current, disconnected = false))
        assertTrue(w.onDiscovered(current, disconnected = true))
    }

    @Test fun takenOverSessionIsNotOurs() {
        assertEquals(Step.Attempt(1, target), step())
        fail(1)
        current = ConnectMode.usbEndpoint // AUTO switched to USB meanwhile
        assertEquals(Step.None, step(advanceMs = 2_000))
        assertNull(w.owned)
        assertEquals(Step.None, step(episode = false))
        assertEquals(ConnectMode.usbEndpoint, current)
    }

    @Test fun ordinaryStartToTheSameAddressIsNotOurs() {
        assertEquals(Step.Attempt(1, target), step())
        fail(1)
        w.disown() // "Bağlan" restarted the same endpoint the usual way (normal retries)
        assertEquals(Step.None, step(advanceMs = 2_000)) // not free: no attempt replaces it
        assertEquals(Step.None, step(episode = false)) // and the episode end does not release it
        assertEquals(target, current)
    }

    // ---- host sleep: silence ----

    @Test fun hostSleepMeansNoEpisodeAndSoNoAttempt() {
        val planner = WakePlanner()
        var t = 0L
        repeat(400) {
            t += 250
            planner.update(t, foreground = true, userOff = false, reached = false, hasWol = true, hostAsleep = true)
            assertFalse(planner.active)
            assertEquals(Step.None, w.update(t, planner.active, target, null, true, true))
        }
        assertEquals(0, w.attempts)
        // the user acts ("Bağlan" / "Mac'i uyandır"): a manual episode, and the first attempt at once
        planner.manual(t, reached = false, hasWol = true)
        assertTrue(planner.active)
        assertEquals(Step.Attempt(1, target), w.update(t, planner.active, target, null, true, true))
    }

    // ---- transport and result classification ----

    @Test fun transportRule() {
        assertTrue(WakeConnect.transportAllows(TransportMode.WIFI, onUsb = false, autoBusy = false))
        assertTrue(WakeConnect.transportAllows(TransportMode.AUTO, onUsb = false, autoBusy = false))
        assertFalse(WakeConnect.transportAllows(TransportMode.AUTO, onUsb = false, autoBusy = true))
        assertFalse(WakeConnect.transportAllows(TransportMode.AUTO, onUsb = true, autoBusy = false))
        assertFalse(WakeConnect.transportAllows(TransportMode.USB, onUsb = false, autoBusy = false))
    }

    @Test fun classify() {
        assertEquals("ok", WakeConnect.classify(null))
        assertEquals("timeout", WakeConnect.classify(SocketTimeoutException("connect timed out")))
        assertEquals(
            "refused",
            WakeConnect.classify(ConnectException("failed to connect to /192.168.1.106 (port 47001): connect failed: ECONNREFUSED (Connection refused)")),
        )
        assertEquals("refused", WakeConnect.classify(ConnectException("Connection refused")))
        assertEquals("error", WakeConnect.classify(ConnectException("connect failed: ENETUNREACH (Network is unreachable)")))
        assertEquals("error", WakeConnect.classify(NoRouteToHostException("EHOSTUNREACH")))
        assertEquals("error", WakeConnect.classify(SocketException("Socket closed")))
        assertEquals("error", WakeConnect.classify(WakeConnect.NoWifiException()))
        assertEquals("no_wifi", WakeConnect.errName(WakeConnect.NoWifiException()))
        assertEquals("SocketException", WakeConnect.errName(SocketException("Socket closed")))
        assertEquals("IOException", WakeConnect.errName(IOException("x")))
    }
}
