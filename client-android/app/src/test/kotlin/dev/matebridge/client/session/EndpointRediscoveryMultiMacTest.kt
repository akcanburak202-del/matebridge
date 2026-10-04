package dev.matebridge.client.session

import dev.matebridge.client.session.EndpointRediscovery.Pick
import dev.matebridge.client.session.EndpointRediscovery.Verdict
import dev.matebridge.client.session.SessionUi.Cause
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** T-229: T-227's rediscovery with more than one paired Mac on the LAN (Codex T-227d, both P2 sequences). */
class EndpointRediscoveryMultiMacTest {
    private val wifi = Endpoint("192.168.1.107", 47001) // Mac A's old address
    private val ethernet = Endpoint("192.168.1.106", 47001) // Mac A's new address
    private val macBEp = Endpoint("192.168.1.50", 47001) // paired Mac B (its port may be blocked)
    private val macA = HostTag.of(ByteArray(16) { 1 })!!
    private val macB = HostTag.of(ByteArray(16) { 2 })!!

    private val r = EndpointRediscovery()
    private var now = 100_000L
    private var current: Endpoint? = null
    private var last: SessionUi? = null

    private fun ui(s: SessionUi, advanceMs: Long = 0): Verdict {
        now += advanceMs
        last = s
        return r.onUi(s, current, now)
    }

    private fun restart(advanceMs: Long = 0): Boolean {
        now += advanceMs
        return r.shouldRestart(now, true)
    }

    private fun discovered(ep: Endpoint): Pick = r.onDiscovered(ep, current, last)

    private fun connected(tag: HostTag?) = SessionUi.Connected("Mac", 0, tag)
    private fun failed() = SessionUi.Disconnected(Cause.CONNECT_FAILED, 2000)

    private fun connectTo(ep: Endpoint) {
        current = ep
        ui(SessionUi.Connecting(ep))
    }

    /** Streaming on [ep] with [tag], then the address drops and one retry fails (an episode is due). */
    private fun establishAndDrop(ep: Endpoint = wifi, tag: HostTag = macA) {
        connectTo(ep)
        ui(connected(tag))
        dropAgain(ep)
    }

    private fun dropAgain(ep: Endpoint) {
        ui(SessionUi.Disconnected(Cause.LOST, 1000), advanceMs = 10)
        ui(SessionUi.Connecting(ep), advanceMs = 1000)
        ui(failed(), advanceMs = 300)
    }

    // --- P2 #1: a later discovery result must not starve the candidate being tried ---

    @Test fun aLaterResultWaitsWhileTheRightHostIsTried() {
        establishAndDrop()
        assertTrue(restart())
        assertEquals(Pick.CONNECT, discovered(ethernet)) // Mac A resolves first
        connectTo(ethernet)
        assertEquals(Pick.QUEUED, discovered(macBEp)) // Mac B second: it no longer replaces A
        assertEquals(ethernet, r.candidate)
        assertEquals(Verdict.Accepted(wifi, ethernet), ui(connected(macA)))
        assertFalse(r.active)
        assertNull(r.nextQueued()) // the episode ended: the queue is gone
    }

    @Test fun anUnreachableCandidateHandsOverToTheQueuedOneNotToTheOldAddress() {
        establishAndDrop()
        assertTrue(restart())
        assertEquals(Pick.CONNECT, discovered(macBEp)) // Mac B (port blocked) resolves first
        connectTo(macBEp)
        assertEquals(Pick.QUEUED, discovered(ethernet))
        assertEquals(Verdict.Unreachable(wifi, macBEp), ui(failed()))
        assertEquals(ethernet, r.nextQueued())
        assertEquals(ethernet, r.candidate)
        connectTo(ethernet)
        assertEquals(Verdict.Accepted(wifi, ethernet), ui(connected(macA)))
    }

    @Test fun aFreshAddressReplacesACandidateThatWasAlreadyUnreachable() {
        establishAndDrop()
        assertTrue(restart())
        discovered(macBEp)
        connectTo(macBEp)
        assertEquals(Verdict.Unreachable(wifi, macBEp), ui(failed()))
        assertNull(r.nextQueued()) // nothing else found: back to the old address
        current = wifi
        ui(SessionUi.Connecting(wifi))
        ui(failed())
        ui(SessionUi.Connecting(wifi), advanceMs = 1000)
        ui(failed(), advanceMs = 300)
        assertTrue(restart(advanceMs = 8_000))
        assertEquals(Pick.CONNECT, discovered(macBEp)) // nothing else running: still tried
        connectTo(macBEp)
        assertEquals(Pick.CONNECT, discovered(ethernet)) // fresh beats the address that did not answer before
        assertEquals(ethernet, r.candidate)
        connectTo(ethernet)
        assertEquals(Verdict.Accepted(wifi, ethernet), ui(connected(macA)))
    }

    @Test fun freshQueuedAddressesGoBeforeUnreachableOnes() {
        val c = Endpoint("192.168.1.60", 47001)
        val d = Endpoint("192.168.1.61", 47001)
        establishAndDrop()
        assertTrue(restart())
        discovered(macBEp)
        connectTo(macBEp)
        ui(failed()) // B unreachable
        assertNull(r.nextQueued())
        current = wifi
        ui(SessionUi.Connecting(wifi))
        ui(failed())
        ui(SessionUi.Connecting(wifi), advanceMs = 1000)
        ui(failed(), advanceMs = 300)
        assertTrue(restart(advanceMs = 8_000))
        discovered(macBEp)
        connectTo(macBEp)
        assertEquals(Pick.CONNECT, discovered(c)) // B goes back to the queue
        connectTo(c)
        assertEquals(Pick.QUEUED, discovered(d))
        assertEquals(Verdict.Unreachable(wifi, c), ui(failed()))
        assertEquals(d, r.nextQueued()) // fresh d before unreachable B
        r.forgetCandidate(d)
        assertEquals(macBEp, r.nextQueued())
    }

    @Test fun theQueueIsBoundedAndSkipsWhatTheCallerRejects() {
        val eps = (1..6).map { Endpoint("192.168.1.${10 + it}", 47001) }
        establishAndDrop()
        assertTrue(restart())
        assertEquals(Pick.CONNECT, discovered(eps[0]))
        connectTo(eps[0])
        eps.drop(1).forEach { assertEquals(Pick.QUEUED, discovered(it)) }
        assertEquals(Pick.QUEUED, discovered(eps[1])) // a repeat is not queued twice
        assertEquals(Verdict.Unreachable(wifi, eps[0]), ui(failed()))
        assertEquals(eps[2], r.nextQueued { it != eps[1] }) // e.g. eps[1] answered PAIRING (T-151): dropped
        r.forgetCandidate(eps[2])
        assertEquals(eps[3], r.nextQueued())
        r.forgetCandidate(eps[3])
        assertEquals(eps[4], r.nextQueued())
        r.forgetCandidate(eps[4])
        assertNull(r.nextQueued()) // only MAX_QUEUE were kept: eps[5] was dropped
        assertEquals(4, EndpointRediscovery.MAX_QUEUE)
    }

    @Test fun aQueuedAddressRefusedAsAnotherHostIsNotTriedAgain() {
        establishAndDrop()
        assertTrue(restart())
        discovered(ethernet)
        connectTo(ethernet)
        discovered(macBEp)
        assertEquals(Verdict.Unreachable(wifi, ethernet), ui(failed()))
        assertEquals(macBEp, r.nextQueued())
        connectTo(macBEp)
        assertEquals(Verdict.Foreign(wifi, macBEp), ui(SessionUi.Failed(Cause.WRONG_HOST, macBEp)))
        assertNull(r.nextQueued())
        assertEquals(Pick.SKIP, discovered(macBEp))
    }

    // --- P2 #2: the user's pick must not inherit the previous host's identity gate ---

    @Test fun aUserPickedOtherMacIsNotRefusedByALaterEpisode() {
        establishAndDrop() // Mac A was the last authenticated host
        // Discovery shows Mac B; the user taps "Bağlan" (CONNECT_BUTTON: not user-initiated for pairing).
        r.onUserStart(macBEp)
        current = macBEp
        ui(SessionUi.Connecting(macBEp))
        ui(failed(), advanceMs = 300)
        ui(SessionUi.Connecting(macBEp), advanceMs = 1000)
        ui(failed(), advanceMs = 300) // B's first attempts fail
        assertTrue(restart()) // a new episode for B's address
        assertEquals(macBEp, r.old)
        assertNull(r.expectedHost()) // no ExpectHost(A): B is not refused as WRONG_HOST
        ui(SessionUi.Connecting(macBEp))
        assertEquals(Verdict.None, ui(connected(macB)))
        assertFalse(r.active)
        dropAgain(macBEp)
        assertTrue(restart())
        assertEquals(macB, r.expectedHost()) // B's identity is the remembered one now
    }

    @Test fun aLateConnectedOfTheSupersededSessionIsNotLearntForTheUserPick() {
        // Codex T-229: Mac A finishes reconnecting while the user starts Mac B; A's Connected renders before B's
        // Connecting (the controller hops threads), with currentEndpoint already B.
        establishAndDrop()
        ui(SessionUi.Connecting(wifi))
        r.onUserStart(macBEp)
        current = macBEp
        assertEquals(Verdict.None, ui(connected(macA))) // late: must not learn A as B's identity
        ui(SessionUi.Disconnected(Cause.LOST, 1000)) // a late drop of A's session counts nothing for B either
        assertEquals(0, r.failures)
        ui(SessionUi.Connecting(macBEp))
        ui(failed(), advanceMs = 300)
        ui(SessionUi.Connecting(macBEp), advanceMs = 1000)
        ui(failed(), advanceMs = 300)
        assertTrue(restart())
        assertEquals(macBEp, r.old)
        assertNull(r.expectedHost()) // no ExpectHost(A): B is not refused as WRONG_HOST
        ui(SessionUi.Connecting(macBEp))
        assertEquals(Verdict.None, ui(connected(macB)))
        dropAgain(macBEp)
        assertTrue(restart())
        assertEquals(macB, r.expectedHost())
    }

    @Test fun aUserStartEndedByItsOwnFailureReleasesTheBarrier() {
        establishAndDrop()
        r.onUserStart(macBEp)
        current = macBEp
        assertEquals(Verdict.None, ui(SessionUi.Failed(Cause.KEY_MISMATCH, macBEp))) // a latch, no Connecting
        ui(SessionUi.Connecting(macBEp))
        assertEquals(Verdict.None, ui(connected(macB)))
        dropAgain(macBEp)
        assertTrue(restart())
        assertEquals(macB, r.expectedHost())
    }

    @Test fun aUserStartAtTheSameAddressKeepsTheIdentity() {
        establishAndDrop()
        r.onUserStart(wifi)
        ui(SessionUi.Connecting(wifi))
        ui(failed())
        ui(SessionUi.Connecting(wifi), advanceMs = 1000)
        ui(failed(), advanceMs = 300)
        assertTrue(restart())
        assertEquals(macA, r.expectedHost())
    }
}
