package dev.matebridge.client.input

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class UnbufferedPenDispatchTest {
    private val calls = ArrayList<Boolean>()
    private val events = ArrayList<String>()
    private var attached = true
    private var throwing = false

    private fun policy() = UnbufferedPenDispatch(
        UnbufferedPenDispatch.Backend { on ->
            if (throwing) throw IllegalStateException("boom")
            if (!attached) false else { calls += on; true }
        },
        onEvent = { ev, f -> events += "$ev $f" },
    )

    @Test fun theSourceRequestIsMadeOnceWhileCaptureIsActiveAndTheChosenPathIsLoggedOnce() {
        val p = policy()
        p.sync(true)
        p.sync(true)
        p.sync(true)
        assertEquals(listOf(true), calls)
        assertEquals(listOf("unbuffered path=source sources=stylus"), events)
    }

    @Test fun theRequestIsClearedWhenCaptureIsNotActiveAndNeverMadeForAnInactivePanel() {
        val p = policy()
        p.sync(false)
        p.sync(false)
        assertTrue(calls.isEmpty()) // panel shown from the start: nothing to ask for, nothing to clear
        assertTrue(events.isEmpty())
        p.sync(true)
        p.sync(false)
        p.sync(false)
        assertEquals(listOf(true, false), calls)
        p.sync(true)
        assertEquals(listOf(true, false, true), calls)
        assertEquals(1, events.size) // logged once for the whole run
    }

    @Test fun anUnattachedViewIsRetriedUntilTheRequestCanBeApplied() {
        val p = policy()
        attached = false
        p.sync(true)
        p.sync(true)
        assertTrue(calls.isEmpty())
        assertTrue(events.isEmpty()) // not applied yet, so not claimed
        attached = true
        p.sync(true)
        assertEquals(listOf(true), calls)
        assertEquals(1, events.size)
    }

    @Test fun aNewWindowOrRegainedFocusRequestsAgainOnTheNextSync() {
        val p = policy()
        p.sync(true)
        p.reapplyOnNextSync()
        p.sync(true)
        p.sync(true)
        assertEquals(listOf(true, true), calls)
        assertEquals(1, events.size)
    }

    @Test fun aRequestThatMayBeInForceIsClearedEvenWhenAnInvalidationCameFirst() {
        // Capture active, focus returns (invalidation), the session drops before the next active sync: the panel is
        // shown again and must not inherit unbuffered input.
        val p = policy()
        p.sync(true)
        p.reapplyOnNextSync()
        p.sync(false)
        assertEquals(listOf(true, false), calls)
        p.sync(false)
        assertEquals(listOf(true, false), calls) // cleared once, nothing left to clear
        p.sync(true)
        assertEquals(listOf(true, false, true), calls)
    }

    @Test fun afterAnInvalidationTheNextActiveSyncAssertsAgainAndTheClearStillFollows() {
        val p = policy()
        p.sync(true)
        p.reapplyOnNextSync()
        p.sync(true)
        p.sync(true)
        assertEquals(listOf(true, true), calls)
        p.sync(false)
        assertEquals(listOf(true, true, false), calls)
    }

    @Test fun aClearThatCouldNotBeAppliedIsRetriedAndTheRequestIsNotForgotten() {
        val p = policy()
        p.sync(true)
        attached = false
        p.sync(false)
        p.sync(false)
        assertEquals(listOf(true), calls) // still believed in force
        attached = true
        p.sync(false)
        assertEquals(listOf(true, false), calls)
    }

    @Test fun reapplyingWhileInactiveDoesNothing() {
        val p = policy()
        p.sync(true)
        p.sync(false)
        p.reapplyOnNextSync()
        p.sync(false)
        assertEquals(listOf(true, false), calls)
    }

    @Test fun aFailingPlatformCallIsLoggedOnceAndNeverRetried() {
        val p = policy()
        throwing = true
        p.sync(true)
        p.sync(true)
        p.sync(false)
        throwing = false
        p.sync(true)
        assertEquals(UnbufferedPenDispatch.Path.FAILED, p.path)
        assertTrue(calls.isEmpty())
        assertEquals(listOf("unbuffered path=failed err=IllegalStateException"), events)
    }
}
