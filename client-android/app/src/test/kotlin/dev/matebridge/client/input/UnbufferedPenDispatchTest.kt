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

    private fun policy(sdk: Int) = UnbufferedPenDispatch(
        sdk,
        UnbufferedPenDispatch.Backend { on ->
            if (throwing) throw IllegalStateException("boom")
            if (!attached) false else { calls += on; true }
        },
        onEvent = { ev, f -> events += "$ev $f" },
    )

    @Test fun apiLevelPicksThePath() {
        assertEquals(UnbufferedPenDispatch.Path.SOURCE, policy(31).path)
        assertEquals(UnbufferedPenDispatch.Path.SOURCE, policy(30).path)
        assertEquals(UnbufferedPenDispatch.Path.PER_GESTURE, policy(29).path)
    }

    @Test fun theSourceRequestIsMadeOnceWhileCaptureIsActiveAndTheChosenPathIsLoggedOnce() {
        val p = policy(31)
        p.sync(true)
        p.sync(true)
        p.sync(true)
        assertEquals(listOf(true), calls)
        assertEquals(listOf("unbuffered path=source"), events)
        assertFalse(p.wantsPerGestureRequest())
    }

    @Test fun theRequestIsClearedWhenCaptureIsNotActiveAndNeverMadeForAnInactivePanel() {
        val p = policy(31)
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
        val p = policy(31)
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
        val p = policy(31)
        p.sync(true)
        p.reapplyOnNextSync()
        p.sync(true)
        p.sync(true)
        assertEquals(listOf(true, true), calls)
        assertEquals(1, events.size)
    }

    @Test fun reapplyingWhileInactiveDoesNothing() {
        val p = policy(31)
        p.sync(true)
        p.sync(false)
        p.reapplyOnNextSync()
        p.sync(false)
        assertEquals(listOf(true, false), calls)
    }

    @Test fun aFailingPlatformCallIsLoggedOnceAndNeverRetried() {
        val p = policy(31)
        throwing = true
        p.sync(true)
        p.sync(true)
        p.sync(false)
        throwing = false
        p.sync(true)
        assertEquals(UnbufferedPenDispatch.Path.FAILED, p.path)
        assertTrue(calls.isEmpty())
        assertEquals(listOf("unbuffered path=failed err=IllegalStateException"), events)
        assertFalse(p.wantsPerGestureRequest())
    }

    @Test fun onOldApisTheRequestIsPerPenDownAndTheBackendIsNeverUsed() {
        val p = policy(29)
        assertFalse(p.wantsPerGestureRequest()) // capture not active
        p.sync(true)
        assertTrue(p.wantsPerGestureRequest())
        p.sync(true)
        p.sync(false)
        assertFalse(p.wantsPerGestureRequest())
        p.sync(true)
        assertTrue(calls.isEmpty())
        assertEquals(listOf("unbuffered path=per_gesture"), events)
    }
}
