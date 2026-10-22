package dev.matebridge.client.session

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** T-362 (decision 0042): path choice, "no connect at start", Durdur, the local path never reaching a Tailscale address. */
class ConnectPathTest {
    private val ts = Endpoint("100.77.121.48", 47001)

    private class MapKv : KeyValueStore {
        val map = LinkedHashMap<String, String>()
        override fun getString(key: String) = map[key]
        override fun putString(key: String, value: String) { map[key] = value }
        override fun remove(key: String) { map.remove(key) }
    }

    // ---- plan ----

    @Test fun localPlanIgnoresAnyTailscaleAddress() {
        for (saver in listOf(false, true)) {
            assertEquals(ConnectPlan.Local, ConnectPlanner.plan(ConnectChoice(ConnectPath.LOCAL, saver), ts))
        }
        assertEquals(ConnectPlan.Local, ConnectPlanner.plan(ConnectChoice.DEFAULT, null))
    }

    @Test fun tailscaleWithSaverIsTheRemoteSession() {
        assertEquals(ConnectPlan.Tailscale(ts, saver = true), ConnectPlanner.plan(ConnectChoice(ConnectPath.TAILSCALE, true), ts))
    }

    @Test fun tailscaleWithoutSaverIsANormalSessionToTheSameAddress() {
        assertEquals(ConnectPlan.Tailscale(ts, saver = false), ConnectPlanner.plan(ConnectChoice(ConnectPath.TAILSCALE, false), ts))
    }

    @Test fun tailscaleWithoutAnAddressAsksForIt() {
        assertEquals(ConnectPlan.NeedAddress, ConnectPlanner.plan(ConnectChoice(ConnectPath.TAILSCALE, true), null))
        assertEquals(ConnectPlan.NeedAddress, ConnectPlanner.plan(ConnectChoice(ConnectPath.TAILSCALE, false), null))
    }

    @Test fun wakeAndSaverBelongToTheirPaths() {
        assertTrue(ConnectPlanner.allowsWake(ConnectChoice(ConnectPath.LOCAL, false)))
        assertFalse(ConnectPlanner.allowsWake(ConnectChoice(ConnectPath.TAILSCALE, false)))
        assertFalse(ConnectPlanner.showsSaver(ConnectChoice(ConnectPath.LOCAL, true)))
        assertTrue(ConnectPlanner.showsSaver(ConnectChoice(ConnectPath.TAILSCALE, false)))
    }

    // ---- the choice is remembered; reset clears it, the address stays ----

    @Test fun choiceDefaultsToLocalAndRoundTrips() {
        val s = Settings(MapKv())
        assertEquals(ConnectChoice(ConnectPath.LOCAL, false), s.connectChoice())
        s.setConnectChoice(ConnectChoice(ConnectPath.TAILSCALE, true))
        assertEquals(ConnectChoice(ConnectPath.TAILSCALE, true), s.connectChoice())
        s.setConnectChoice(ConnectChoice(ConnectPath.TAILSCALE, false))
        assertEquals(ConnectChoice(ConnectPath.TAILSCALE, false), s.connectChoice())
    }

    @Test fun garbledPathFallsBackToLocal() {
        val kv = MapKv()
        kv.putString("connect_path", "wifi")
        assertEquals(ConnectPath.LOCAL, Settings(kv).connectChoice().path)
    }

    @Test fun resetClearsTheChoiceButKeepsTheTailscaleAddress() {
        val s = Settings(MapKv())
        s.saveRemoteEndpoint(Endpoint("mac.ts.net", 47001))
        s.setConnectChoice(ConnectChoice(ConnectPath.TAILSCALE, true))
        s.resetToDefaults()
        assertEquals(ConnectChoice.DEFAULT, s.connectChoice())
        assertEquals(Endpoint("mac.ts.net", 47001), s.tailscaleEndpoint())
    }

    // ---- no connect at start; Durdur ----

    @Test fun aFreshProcessWaits() {
        assertTrue(ConnectGate().waitingOnStart())
    }

    @Test fun afterBaglanTheBackgroundReturnReconnects() {
        val g = ConnectGate()
        g.onConnectPressed()
        assertFalse(g.waitingOnStart()) // onStart after the app went to the background and back
        assertFalse(g.waitingOnStart())
    }

    @Test fun afterDurdurOrBaglantiyiKesTheNextStartWaits() {
        val g = ConnectGate()
        g.onConnectPressed()
        g.onStopped()
        assertTrue(g.waitingOnStart())
        g.onConnectPressed()
        assertFalse(g.waitingOnStart())
    }

    @Test fun durdurShowsOnlyWhileAnAttemptRuns() {
        val running = listOf(SessionUi.Searching, SessionUi.Connecting(ts), SessionUi.Disconnected(SessionUi.Cause.LOST, 3000))
        for (ui in running) {
            assertTrue("$ui", ConnectButton.isStop(true, ui))
            assertFalse("$ui waiting", ConnectButton.isStop(false, ui)) // never before "Bağlan"
        }
        assertFalse(ConnectButton.isStop(true, SessionUi.Idle))
        assertFalse(ConnectButton.isStop(true, SessionUi.Failed(SessionUi.Cause.KEY_MISMATCH)))
        assertFalse(ConnectButton.isStop(true, SessionUi.Connected("Mac", 3)))
    }

    // ---- the local path never goes to a Tailscale or typed address ----

    @Test fun tailscaleAddressesAreRecognised() {
        for (h in listOf("100.64.0.1", "100.77.121.48", "100.127.255.254", "mac.tail1234.ts.net", "Mac.Tail1234.TS.NET.")) {
            assertTrue(h, WifiMemory.isTailscaleAddress(h))
        }
        for (h in listOf("100.63.255.255", "100.128.0.1", "192.168.1.106", "10.0.0.5", "127.0.0.1", "mac.local", "100.64.0")) {
            assertFalse(h, WifiMemory.isTailscaleAddress(h))
        }
    }

    @Test fun lastWifiEndpointNeverComesFromTailscaleOrTypedOrPinnedStarts() {
        val lan = Endpoint("192.168.1.106", 47001)
        assertTrue(WifiMemory.mayRemember(ConnectOrigin.DISCOVERY, lan, pinnedSession = false))
        assertTrue(WifiMemory.mayRemember(ConnectOrigin.PAIR, lan, pinnedSession = false))
        assertFalse(WifiMemory.mayRemember(ConnectOrigin.REMOTE, lan, pinnedSession = false))
        assertFalse(WifiMemory.mayRemember(ConnectOrigin.TAILSCALE, lan, pinnedSession = false))
        assertFalse(WifiMemory.mayRemember(ConnectOrigin.TYPED_ADDRESS, lan, pinnedSession = false))
        assertFalse(WifiMemory.mayRemember(ConnectOrigin.DISCOVERY, lan, pinnedSession = true))
        // whatever the origin (a stored-prompt retry, "Bağlan" on the current endpoint), a 100.x address is never kept
        for (o in ConnectOrigin.entries) {
            assertFalse(o.name, WifiMemory.mayRemember(o, ts, pinnedSession = false))
            assertFalse(o.name, WifiMemory.mayRemember(o, Endpoint("mac.ts.net", 47001), pinnedSession = false))
        }
    }

    @Test fun tailscaleOriginNeverPairsAndIsNotAutomatic() {
        assertFalse(ConnectOrigin.TAILSCALE.userInitiated)
        assertFalse(ConnectOrigin.TAILSCALE.automatic)
        assertFalse(ConnectOrigin.TAILSCALE.clearsGate)
    }

    // ---- migration (decision 0042 section 7) ----

    @Test fun oldAddressInCgnatBecomesTheTailscaleAddressWhenEmpty() {
        assertEquals(TailscaleMigration.Result(ts), TailscaleMigration.migrate(ts, null))
    }

    @Test fun oldAddressIsDroppedWhenTailscaleAddressExistsOrItIsNotCgnat() {
        assertEquals(TailscaleMigration.Result(null), TailscaleMigration.migrate(ts, Endpoint("mac.ts.net", 47001)))
        assertEquals(TailscaleMigration.Result(null), TailscaleMigration.migrate(Endpoint("192.168.1.20", 47001), null))
        assertEquals(TailscaleMigration.Result(null), TailscaleMigration.migrate(null, null))
    }

    @Test fun migrationRunsOnceThroughSettings() {
        val kv = MapKv()
        val s = Settings(kv)
        s.saveEndpoint(ts)
        assertTrue(s.migrateManualEndpoint())
        assertEquals(ts, s.tailscaleEndpoint())
        assertNull(s.lastEndpoint()) // the manual key is gone
        assertFalse(s.migrateManualEndpoint()) // second run: nothing to do
        s.saveRemoteEndpoint(Endpoint("other.ts.net", 47001))
        assertEquals(Endpoint("other.ts.net", 47001), s.tailscaleEndpoint()) // not touched again
    }

    @Test fun migrationDropsALanAddressWithoutTouchingTheTailscaleOne() {
        val kv = MapKv()
        val s = Settings(kv)
        s.saveEndpoint(Endpoint("192.168.1.20", 47001))
        s.saveRemoteEndpoint(Endpoint("mac.ts.net", 47001))
        assertTrue(s.migrateManualEndpoint())
        assertNull(s.lastEndpoint())
        assertEquals(Endpoint("mac.ts.net", 47001), s.tailscaleEndpoint())
    }

    @Test fun startIntentMapsProfilesToRetryWithoutTouchingPairing() {
        assertTrue(StartIntent.retry(ConnectOrigin.TAILSCALE))
        assertTrue(StartIntent.retry(ConnectOrigin.REMOTE))
        assertFalse(StartIntent.retry(ConnectOrigin.DISCOVERY))
        assertFalse(StartIntent.retry(ConnectOrigin.STORED_CONNECT))
        assertFalse(ConnectOrigin.TAILSCALE.userInitiated) // retry intent is not permission to pair
    }

    @Test fun localAttemptsNeverTargetATailscaleAddress() {
        val lan = Endpoint("192.168.1.106", 47001)
        for (o in ConnectOrigin.entries) {
            assertTrue(o.name, LocalPath.allows(lan, o))
            assertTrue(o.name, LocalPath.allows(ConnectMode.usbEndpoint, o))
            if (o != ConnectOrigin.REMOTE && o != ConnectOrigin.TAILSCALE) {
                assertFalse(o.name, LocalPath.allows(ts, o))
                assertFalse(o.name, LocalPath.allows(Endpoint("mac.tail1.ts.net", 47001), o))
            }
        }
        assertTrue(LocalPath.allows(ts, ConnectOrigin.TAILSCALE))
        assertTrue(LocalPath.allows(ts, ConnectOrigin.REMOTE))
        assertNull(LocalPath.wakeTarget(ts))
        assertEquals(lan, LocalPath.wakeTarget(lan))
        assertNull(LocalPath.wakeTarget(null))
    }

    @Test fun aChangedChoiceStopsARunningAttemptOnlyWhenEngaged() {
        val a = ConnectChoice(ConnectPath.TAILSCALE, true)
        val b = ConnectChoice.DEFAULT
        assertTrue(ChoiceChange.needsStop(true, a, b))
        assertFalse(ChoiceChange.needsStop(false, a, b))
        assertFalse(ChoiceChange.needsStop(true, b, b)) // reset with nothing to change
    }
}
