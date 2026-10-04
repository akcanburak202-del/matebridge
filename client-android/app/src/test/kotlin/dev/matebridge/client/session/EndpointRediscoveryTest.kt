package dev.matebridge.client.session

import dev.matebridge.client.session.EndpointRediscovery.Pick
import dev.matebridge.client.session.EndpointRediscovery.Verdict
import dev.matebridge.client.session.SessionUi.Cause
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class EndpointRediscoveryTest {
    private val wifi = Endpoint("192.168.1.107", 47001)
    private val ethernet = Endpoint("192.168.1.106", 47001)
    private val other = Endpoint("192.168.1.50", 47001)
    private val macA = HostTag.of(ByteArray(16) { 1 })!!
    private val macB = HostTag.of(ByteArray(16) { 2 })!!

    private val r = EndpointRediscovery()
    private var now = 100_000L

    /** The app's session endpoint and last rendered state, as MainActivity keeps them. */
    private var current: Endpoint? = null
    private var last: SessionUi? = null

    private fun ui(s: SessionUi, advanceMs: Long = 0): Verdict {
        now += advanceMs
        last = s
        return r.onUi(s, current, now)
    }

    private fun restart(advanceMs: Long = 0, eligible: Boolean = true): Boolean {
        now += advanceMs
        return r.shouldRestart(now, eligible)
    }

    private fun connected(tag: HostTag? = macA) = SessionUi.Connected("Mac", 0, tag)
    private fun lost(retry: Long = 1000) = SessionUi.Disconnected(Cause.LOST, retry)
    private fun failed(retry: Long = 2000) = SessionUi.Disconnected(Cause.CONNECT_FAILED, retry)

    /** A streaming session on the Wi-Fi address of Mac A. */
    private fun establish() {
        current = wifi
        ui(SessionUi.Connecting(wifi))
        ui(connected())
    }

    /** The Mac's Wi-Fi went away: the session drops and one retry of the stored address fails. */
    private fun dropAndFailOnce() {
        ui(lost(), advanceMs = 10)
        ui(SessionUi.Connecting(wifi), advanceMs = 1000)
        ui(failed(), advanceMs = 300) // EHOSTUNREACH: well before the 4 s threshold
    }

    /** What MainActivity does on a CONNECT pick: switch the session to the candidate. */
    private fun connectTo(ep: Endpoint) {
        current = ep
        ui(SessionUi.Connecting(ep))
    }

    @Test fun twoFailuresOfTheStoredAddressRestartDiscovery() {
        establish()
        ui(lost())
        assertFalse(restart())
        ui(SessionUi.Connecting(wifi), advanceMs = 1000)
        assertFalse(restart())
        ui(failed(), advanceMs = 300)
        assertTrue(restart())
        assertTrue(r.active)
        assertEquals(EndpointRediscovery.REASON_CONNECT_FAILED, r.restartReason())
        assertEquals(wifi, r.old)
    }

    @Test fun beingDownForFourSecondsRestartsDiscoveryEvenWithOneFailure() {
        establish()
        ui(lost())
        ui(SessionUi.Connecting(wifi), advanceMs = 1000) // a connect to a vanished address may hang for 5 s
        assertFalse(restart(advanceMs = 2_900))
        assertTrue(restart(advanceMs = 100))
        assertEquals(EndpointRediscovery.REASON_DOWN_TIME, r.restartReason())
    }

    @Test fun repeatedRenderOfOneDropCountsOnce() {
        establish()
        ui(lost())
        ui(lost())
        ui(lost())
        assertEquals(1, r.failures)
        assertFalse(restart())
    }

    @Test fun newAddressForTheSameHostIsConnectedAndAccepted() {
        establish()
        dropAndFailOnce()
        assertTrue(restart())
        // NSD reports the Mac on Ethernet while the session waits to retry the stored address.
        assertEquals(Pick.CONNECT, r.onDiscovered(ethernet, current, last))
        connectTo(ethernet)
        assertEquals(Verdict.None, ui(connected(tag = null))) // not authenticated yet: no verdict
        val v = ui(connected())
        assertEquals(Verdict.Accepted(wifi, ethernet), v)
        assertFalse(r.active)
        assertNull(r.candidate)
        assertEquals("result=accepted old=*.107 new=*.106", EndpointRediscovery.resultFields(v))
    }

    @Test fun newAddressFoundWhileStillConnectingToTheOldOneIsNotLost() {
        establish()
        dropAndFailOnce()
        assertTrue(restart())
        ui(SessionUi.Connecting(wifi), advanceMs = 2000) // the next retry of the stored address is running
        assertEquals(Pick.CONNECT, r.onDiscovered(ethernet, current, last))
    }

    @Test fun noResultKeepsRetryingTheStoredAddressAndRestartsWithGrowingGaps() {
        establish()
        dropAndFailOnce()
        assertTrue(restart())
        // Nothing found: the session machine keeps retrying the stored address (rediscovery never changes current).
        val gaps = mutableListOf<Long>()
        var lastAt = now
        repeat(5) {
            var t = 0L
            while (!restart(advanceMs = 100)) {
                t += 100
                ui(SessionUi.Connecting(wifi))
                ui(failed(5000))
                assertTrue(t < 60_000)
            }
            gaps += now - lastAt
            lastAt = now
        }
        assertEquals(listOf(8_000L, 16_000L, 30_000L, 30_000L, 30_000L), gaps)
        assertEquals(wifi, current)
        assertEquals(6, r.restarts)
    }

    @Test fun sameAddressRediscoveredIsLeftToTheUsualRules() {
        establish()
        dropAndFailOnce()
        assertTrue(restart())
        assertEquals(Pick.DEFAULT, r.onDiscovered(wifi, current, last))
        assertNull(r.candidate)
    }

    @Test fun anotherPairedHostIsNotAcceptedAndIsSkippedAfterwards() {
        establish()
        dropAndFailOnce()
        assertTrue(restart())
        assertEquals(Pick.CONNECT, r.onDiscovered(other, current, last))
        connectTo(other)
        // The machine's host gate refused it before its HELLO_ACK (WrongHostGateTest).
        val v = ui(SessionUi.Failed(Cause.WRONG_HOST))
        assertEquals(Verdict.Foreign(wifi, other), v)
        assertTrue(r.isSkipped(other))
        assertEquals("result=foreign old=*.107 new=*.50", EndpointRediscovery.resultFields(v))
        // The caller goes back to the stored address; the foreign one is never picked again in this episode.
        current = wifi
        ui(SessionUi.Connecting(wifi))
        ui(failed())
        assertEquals(Pick.SKIP, r.onDiscovered(other, current, last))
        // The real Mac shows up on Ethernet later: still accepted.
        assertEquals(Pick.CONNECT, r.onDiscovered(ethernet, current, last))
        connectTo(ethernet)
        assertEquals(Verdict.Accepted(wifi, ethernet), ui(connected()))
    }

    @Test fun aConnectedOtherHostIsStillForeign() {
        // Defence in depth behind the machine's gate: an authenticated session of another host is never accepted.
        establish()
        dropAndFailOnce()
        assertTrue(restart())
        r.onDiscovered(other, current, last)
        connectTo(other)
        assertEquals(Verdict.Foreign(wifi, other), ui(connected(tag = macB)))
        assertEquals(Pick.SKIP, r.onDiscovered(other, wifi, failed()))
    }

    @Test fun ourOwnHostAskingToPairAgainAtTheNewAddressIsNotForeign() {
        // Past the gate a PAIRING answer claims our host's id (the Mac forgot the tablet): the usual prompt, no verdict.
        establish()
        dropAndFailOnce()
        assertTrue(restart())
        r.onDiscovered(ethernet, current, last)
        connectTo(ethernet)
        assertEquals(Verdict.None, ui(SessionUi.PairingNeedsUser("Mac", rePair = true, hostTag = macA)))
        assertNull(r.candidate)
        assertFalse(r.isSkipped(ethernet))
    }

    @Test fun expectedHostIsTheLastAuthenticatedHostOnlyDuringAnEpisode() {
        assertNull(r.expectedHost())
        establish()
        assertNull(r.expectedHost()) // no episode: ordinary starts are not gated
        dropAndFailOnce()
        assertNull(r.expectedHost())
        assertTrue(restart())
        assertEquals(macA, r.expectedHost())
        r.onDiscovered(ethernet, current, last)
        connectTo(ethernet)
        ui(connected())
        assertNull(r.expectedHost())
    }

    @Test fun aLateConnectedOfTheOldSessionDoesNotEndTheEpisode() {
        // Review #2: the old address's retry connected, but its Connected renders after the switch to the candidate.
        establish()
        dropAndFailOnce()
        assertTrue(restart())
        ui(SessionUi.Connecting(wifi))
        assertEquals(Pick.CONNECT, r.onDiscovered(ethernet, current, last))
        current = ethernet
        assertEquals(Verdict.None, ui(connected()))
        assertTrue(r.active)
        assertEquals(ethernet, r.candidate)
        assertEquals(macA, r.expectedHost())
        ui(SessionUi.Connecting(ethernet))
        assertEquals(Verdict.Foreign(wifi, ethernet), ui(connected(tag = macB)))
    }

    @Test fun storedTrustInsteadOfConnectingDropsTheCandidate() {
        establish()
        dropAndFailOnce()
        assertTrue(restart())
        r.onDiscovered(ethernet, current, last)
        current = ethernet
        assertEquals(Verdict.None, ui(SessionUi.StoredTrust(code = "123456", confirmed = false)))
        assertNull(r.candidate)
    }

    @Test fun aWrongHostAtTheOldAddressItselfDoesNotLoop() {
        establish()
        dropAndFailOnce()
        assertTrue(restart())
        ui(SessionUi.Connecting(wifi))
        assertEquals(Verdict.None, ui(SessionUi.Failed(Cause.WRONG_HOST)))
        assertTrue(r.isSkipped(wifi))
    }

    @Test fun forgetCandidateDropsOnlyThatCandidate() {
        establish()
        dropAndFailOnce()
        assertTrue(restart())
        r.onDiscovered(ethernet, current, last)
        r.forgetCandidate(other)
        assertEquals(ethernet, r.candidate)
        r.forgetCandidate(ethernet)
        assertNull(r.candidate)
    }

    @Test fun aTerminalFailureAtTheCandidateIsForeign() {
        establish()
        dropAndFailOnce()
        assertTrue(restart())
        r.onDiscovered(other, current, last)
        connectTo(other)
        assertEquals(Verdict.Foreign(wifi, other), ui(SessionUi.Failed(Cause.KEY_MISMATCH)))
    }

    @Test fun unreachableCandidateSendsTheCallerBackAndMayBeOfferedAgain() {
        establish()
        dropAndFailOnce()
        assertTrue(restart())
        r.onDiscovered(ethernet, current, last)
        connectTo(ethernet)
        val v = ui(failed())
        assertEquals(Verdict.Unreachable(wifi, ethernet), v)
        assertEquals("result=unreachable old=*.107 new=*.106", EndpointRediscovery.resultFields(v))
        current = wifi
        ui(SessionUi.Connecting(wifi))
        ui(failed())
        assertEquals(Pick.CONNECT, r.onDiscovered(ethernet, current, last))
    }

    @Test fun aLateStateOfTheOldSessionSettlesNothingAboutTheCandidate() {
        establish()
        dropAndFailOnce()
        assertTrue(restart())
        ui(SessionUi.Connecting(wifi))
        r.onDiscovered(ethernet, current, last)
        current = ethernet // MainActivity switched; the old connect's failure is rendered before the new Connecting
        assertEquals(Verdict.None, ui(failed()))
        assertEquals(ethernet, r.candidate)
        ui(SessionUi.Connecting(ethernet))
        assertEquals(Verdict.Accepted(wifi, ethernet), ui(connected()))
    }

    @Test fun firstHostEverSeenIsAcceptedWithoutAKnownIdentity() {
        // No authenticated session yet in this process (e.g. it dropped before the host proved itself).
        current = wifi
        ui(SessionUi.Connecting(wifi))
        ui(failed())
        ui(SessionUi.Connecting(wifi))
        ui(failed())
        assertTrue(restart())
        r.onDiscovered(ethernet, current, last)
        connectTo(ethernet)
        assertEquals(Verdict.Accepted(wifi, ethernet), ui(connected(tag = macB)))
    }

    @Test fun noRestartWhenNotEligible() {
        establish()
        dropAndFailOnce()
        assertFalse(restart(eligible = false)) // USB, a typed address, "Bağlantıyı kes", HOST_SLEEP
        assertFalse(r.active)
        assertEquals(Pick.DEFAULT, r.onDiscovered(ethernet, current, last))
    }

    @Test fun noRestartWhileConnectedOrWithoutFailures() {
        establish()
        assertFalse(restart(advanceMs = 60_000))
        ui(SessionUi.Searching)
        assertFalse(restart(advanceMs = 60_000))
    }

    @Test fun noCandidateWhileConnectedOrPrompting() {
        establish()
        dropAndFailOnce()
        assertTrue(restart())
        assertEquals(Pick.DEFAULT, r.onDiscovered(ethernet, current, SessionUi.Connected("Mac", 0, macA)))
        assertEquals(Pick.DEFAULT, r.onDiscovered(ethernet, current, SessionUi.PairingNeedsUser("Mac", rePair = false)))
        assertEquals(Pick.DEFAULT, r.onDiscovered(ethernet, null, failed()))
    }

    @Test fun theOldAddressComingBackEndsTheEpisode() {
        establish()
        dropAndFailOnce()
        assertTrue(restart())
        ui(SessionUi.Connecting(wifi))
        ui(connected())
        assertFalse(r.active)
        assertEquals(Pick.DEFAULT, r.onDiscovered(ethernet, current, last))
    }

    @Test fun noRestartWhileACandidateIsBeingTried() {
        establish()
        dropAndFailOnce()
        assertTrue(restart())
        r.onDiscovered(ethernet, current, last)
        connectTo(ethernet)
        assertFalse(restart(advanceMs = 60_000))
    }

    @Test fun resetForgetsTheEpisodeButKeepsTheIdentity() {
        establish()
        dropAndFailOnce()
        assertTrue(restart())
        r.reset()
        assertFalse(r.active)
        assertFalse(restart())
        // Identity survives: another Mac at a new address is still refused in a later episode.
        dropAndFailOnce()
        assertTrue(restart())
        assertEquals(macA, r.expectedHost())
        r.onDiscovered(other, current, last)
        connectTo(other)
        assertEquals(Verdict.Foreign(wifi, other), ui(connected(tag = macB)))
    }

    @Test fun aWakeAttemptFailureCountsLikeAnyDrop() {
        // T-134: a failed direct wake attempt renders Disconnected(retryInMs = 0); rediscovery only adds restarts.
        current = wifi
        ui(SessionUi.Connecting(wifi))
        ui(SessionUi.Disconnected(Cause.CONNECT_FAILED, 0))
        ui(SessionUi.Connecting(wifi))
        ui(SessionUi.Disconnected(Cause.CONNECT_FAILED, 0))
        assertTrue(restart())
        assertEquals(wifi, current) // never changes the wake target or the session's endpoint
    }

    @Test fun octetKeepsOnlyTheLastIpv4Octet() {
        assertEquals("*.107", EndpointRediscovery.octet(wifi))
        assertEquals("*", EndpointRediscovery.octet(Endpoint("mac.local", 47001)))
        assertEquals("*", EndpointRediscovery.octet(Endpoint("1.2.3", 47001)))
        assertEquals("-", EndpointRediscovery.octet(null))
        assertNull(EndpointRediscovery.resultFields(Verdict.None))
    }
}
