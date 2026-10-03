package dev.matebridge.client.session

import dev.matebridge.client.session.WakeConnect.Step
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
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

    /** Asserts [s] is attempt number [n] (within its episode) to the target; returns its tag. */
    private fun attempt(n: Int, s: Step): WakeTag {
        assertTrue("expected attempt $n, got $s", s is Step.Attempt)
        s as Step.Attempt
        assertEquals(n, s.n)
        assertEquals(target, s.endpoint)
        return s.tag
    }

    private fun fail(tag: WakeTag? = w.inFlight, advanceMs: Long = 0) {
        now += advanceMs
        assertNull(w.onResult(tag!!, false, now))
        idle = true // the machine reports Disconnected(CONNECT_FAILED, 0)
    }

    @Test fun nothingOutsideAnEpisode() {
        repeat(100) { assertEquals(Step.None, step(episode = false, advanceMs = 250)) }
        assertEquals(0, w.attempts)
    }

    @Test fun firstAttemptAtOnceWhenTheEpisodeStarts() {
        val t = attempt(1, step())
        assertEquals(t, w.inFlight)
    }

    @Test fun noAttemptWithoutTargetOrWithTheWrongTransport() {
        assertEquals(Step.None, step(tgt = null))
        assertEquals(Step.None, step(transportOk = false))
        attempt(1, step())
    }

    @Test fun oneAttemptAtATimeThenTwoSecondsAfterAFailure() {
        attempt(1, step())
        // the connect runs (up to its 3 s timeout): no second attempt meanwhile
        for (i in 0 until 11) assertEquals(Step.None, step(advanceMs = 250))
        fail(advanceMs = 250) // failed after 3 s
        assertEquals(Step.None, step(advanceMs = 1_000))
        assertEquals(Step.None, step(advanceMs = 750))
        attempt(2, step(advanceMs = 250)) // 2 s after the failure
        fail(advanceMs = 100) // refused at once
        assertEquals(Step.None, step(advanceMs = 1_999))
        attempt(3, step(advanceMs = 1))
    }

    @Test fun attemptsCoverTheTwentySecondEpisode() {
        // every connect times out after 3 s: an attempt about every 5 s through the episode
        val starts = ArrayList<Long>()
        val t0 = now
        var t = 0L
        while (t <= WakePlanner.EPISODE_MS) {
            val s = step(advanceMs = 250)
            if (s is Step.Attempt) starts += now - t0
            if (w.inFlight != null && now - t0 - starts.last() >= WakeConnect.CONNECT_TIMEOUT_MS) fail()
            t += 250
        }
        assertEquals(listOf(250L, 5_250L, 10_250L, 15_250L, 20_250L), starts)
    }

    @Test fun tagsAreUniqueAcrossEpisodes() {
        val a = attempt(1, step())
        fail()
        assertEquals(Step.Release, step(episode = false))
        val b = attempt(1, step(advanceMs = 30_000)) // a new episode numbers from 1 ...
        assertNotEquals(a, b) // ... but its identity is new
        assertNotEquals(a.id, b.id)
    }

    @Test fun connectedAttemptIsAdoptedAndEndsTheAttempts() {
        val t = attempt(1, step())
        assertEquals(target, w.onResult(t, true, now))
        assertNull(w.owned)
        assertTrue(w.settled)
        idle = true // even if the session then drops, no more direct attempts in this episode
        for (i in 0 until 40) assertEquals(Step.None, step(advanceMs = 250))
        // and the episode end does not release an adopted session
        assertEquals(Step.None, step(episode = false))
        assertEquals(target, current)
    }

    @Test fun resultForAnotherAttemptIsIgnored() {
        val t = attempt(1, step())
        assertNull(w.onResult(WakeTag(t.id + 5, 1), true, now)) // same number, other identity
        assertEquals(t, w.inFlight)
        assertFalse(w.settled)
    }

    @Test fun lostResultIsGivenUpAfterTheStaleTime() {
        val t = attempt(1, step())
        idle = true
        assertEquals(Step.None, step(advanceMs = WakeConnect.STALE_MS - 1))
        val t2 = attempt(2, step(advanceMs = 1))
        // the lost result turning up late is not taken for the new attempt
        assertNull(w.onResult(t, true, now))
        assertEquals(t2, w.inFlight)
        assertFalse(w.settled)
    }

    @Test fun episodeEndReleasesOurFailedAttempt() {
        attempt(1, step())
        fail(advanceMs = 3_000)
        assertEquals(Step.Release, step(episode = false))
        assertNull(current)
        assertEquals(Step.None, step(episode = false))
    }

    @Test fun episodeEndWaitsForTheAttemptInFlight() {
        attempt(1, step())
        assertEquals(Step.None, step(episode = false, advanceMs = 500)) // still connecting: not released
        assertEquals(target, current)
        fail(advanceMs = 1_000)
        assertEquals(Step.Release, step(episode = false))
        assertNull(current)
    }

    @Test fun lateSuccessAfterTheEpisodeIsAdopted() {
        val t = attempt(1, step())
        assertEquals(Step.None, step(episode = false, advanceMs = 500))
        assertEquals(target, w.onResult(t, true, now))
        assertEquals(Step.None, step(episode = false))
        assertEquals(target, current)
    }

    @Test fun newEpisodeNumbersFromOne() {
        attempt(1, step())
        fail()
        attempt(2, step(advanceMs = 2_000))
        fail()
        assertEquals(Step.Release, step(episode = false))
        attempt(1, step(advanceMs = 30_000))
    }

    // ---- a result from an ended episode never steers the next one (review P2) ----

    @Test fun lateSuccessFromAnEndedEpisodeDoesNotSettleTheNextOne() {
        val old = attempt(1, step())
        assertEquals(Step.None, step(episode = false, advanceMs = 500)) // e.g. background: the episode stops
        current = null // onStart forgets the endpoint; the controller closed the attempt
        idle = true
        assertEquals(Step.None, step(advanceMs = 1_000)) // new episode: waits for the old connect's outcome
        assertNull(w.onResult(old, true, now)) // its late "connected": not ours (the session is gone), not settling
        assertFalse(w.settled)
        val t = attempt(1, step()) // the new episode attempts at once
        assertEquals(t, w.inFlight)
        fail()
        attempt(2, step(advanceMs = 2_000)) // and keeps going
    }

    @Test fun lateFailureFromAnEndedEpisodeDoesNotDelayTheNextOne() {
        val old = attempt(1, step())
        assertEquals(Step.None, step(episode = false, advanceMs = 500))
        assertEquals(Step.None, step(advanceMs = 500)) // new episode, the old connect still running
        fail(old) // it fails now: no 2 s gap charged to the new episode
        attempt(1, step())
    }

    @Test fun lateSuccessFromAnEndedEpisodeStillAdoptsItsLiveSession() {
        val old = attempt(1, step())
        assertEquals(Step.None, step(episode = false, advanceMs = 500))
        assertEquals(Step.None, step(advanceMs = 500)) // new episode; our attempt still holds the (connecting) session
        assertEquals(target, w.onResult(old, true, now)) // it connected: an ordinary session now
        assertFalse(w.settled) // not counted for the new episode ...
        assertEquals(Step.None, step(advanceMs = 2_000)) // ... yet no attempt replaces that live session
        assertNull(w.owned)
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
        attempt(1, step())
        assertTrue(w.onDiscovered(current, disconnected = false)) // replaces ours (the start closes it first)
        assertNull(w.owned)
        current = Endpoint("192.168.1.107", 47001)
        fail() // the replaced attempt's connect ends with an error
        for (i in 0 until 40) assertEquals(Step.None, step(advanceMs = 250))
        assertEquals(Step.None, step(episode = false)) // and it is not ours to release
        assertEquals(Endpoint("192.168.1.107", 47001), current)
    }

    @Test fun discoveryAfterAFailedAttemptConnects() {
        attempt(1, step())
        fail()
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

    @Test fun aPickPromptFreesTheSlotForAnotherDiscoveredMac() { // T-151: one impostor cannot park the tablet
        current = Endpoint("192.168.1.66", 47001) // answered PAIRING to an automatic connect: no connection any more
        assertFalse(w.onDiscovered(current, disconnected = false, atPairPrompt = false))
        assertTrue(w.onDiscovered(current, disconnected = false, atPairPrompt = true))
    }

    @Test fun takenOverSessionIsNotOurs() {
        attempt(1, step())
        fail()
        current = ConnectMode.usbEndpoint // AUTO switched to USB meanwhile
        assertEquals(Step.None, step(advanceMs = 2_000))
        assertNull(w.owned)
        assertEquals(Step.None, step(episode = false))
        assertEquals(ConnectMode.usbEndpoint, current)
    }

    @Test fun ordinaryStartToTheSameAddressIsNotOurs() {
        attempt(1, step())
        fail()
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
        attempt(1, w.update(t, planner.active, target, null, true, true))
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
