package dev.matebridge.client.session

import dev.matebridge.client.files.FilesServerScope
import dev.matebridge.client.files.FilesTunnelPlan
import dev.matebridge.client.protocol.Bye
import dev.matebridge.client.protocol.Bytes
import dev.matebridge.client.protocol.FilesInfo
import dev.matebridge.client.protocol.FilesNet
import dev.matebridge.client.protocol.Hello
import dev.matebridge.client.protocol.HelloAck
import dev.matebridge.client.protocol.Message
import dev.matebridge.client.protocol.StreamConfig
import dev.matebridge.client.session.SessionMachine.Action
import dev.matebridge.client.session.SessionMachine.Event
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * T-269 (decision 0035): the machine turns the Mac's `FILES_NET` and the tablet's own `FILES_INFO` into the file tunnel
 * the session wants ([Action.FilesTunnel]), and takes it away with every end of the session. Every accepted OPEN gets a
 * request id (1, 2, ... per machine); a server's FILES_INFO carries the id of the request it was started for, and only a
 * matching one arms or clears the live request.
 */
class FilesNetMachineTest {
    private val hello = Hello(1, Bytes(ByteArray(16)), 2800, 1840, 360, 144, 0x1FFF, "MatePad")
    private val wifi = Endpoint("192.168.1.20", 47001)
    private val usb = ConnectMode.usbEndpoint
    private var now = 1_000_000L
    private val open = FilesNet(FilesNet.STATE_OPEN, 47003, 2, 12)
    private val close = FilesNet(FilesNet.STATE_CLOSE, 0, 0, 0)
    private val ready = FilesInfo(FilesInfo.STATE_READY, 40123, "0123456789abcdef0123456789abcdef")

    private fun machine() = SessionMachine(hello, initialFiles = FilesInfo.OFF)

    private fun SessionMachine.step(e: Event): List<Action> { now += 1000; return handle(e, now) }

    private fun SessionMachine.accepted(ep: Endpoint = wifi, session: Long = 77): Int {
        val gen = step(Event.Start(ep)).filterIsInstance<Action.OpenControl>().single().gen
        step(Event.ControlOpened(gen))
        step(Event.Received(gen, HelloAck(1, HelloAck.ACCEPTED, session, 47002, "Mac")))
        return gen
    }

    /** A Wi-Fi server of generation [gen] started for open request [req]. */
    private fun wifi(gen: Int, req: Int = 1) = FilesServerScope(true, gen, req)

    /** What a stop of the server of request [req] (or an idle publish) publishes: no server, only the request it ends. */
    private fun ends(req: Int) = FilesServerScope(false, -1, req)

    private fun List<Action>.plans() = filterIsInstance<Action.FilesTunnel>().map { it.plan }
    private fun List<Action>.nets() = filterIsInstance<Action.FilesNetReceived>()
    private fun sent(a: List<Action>) = a.filterIsInstance<Action.Send>().map { it.msg }

    private fun plan(
        gen: Int, port: Int = 47003, pool: Int = 2, max: Int = 12, dav: Int = 40123, session: Long = 77, req: Int = 1,
    ) = FilesTunnelPlan(gen, wifi.host, port, pool, max, dav, session, req)

    /** OPEN delivered, its server READY: the usual live share of request 1. */
    private fun SessionMachine.live(gen: Int) {
        step(Event.Received(gen, open)); step(Event.SetFiles(ready, wifi(gen)))
    }

    @Test fun openThenReadyOpensTheTunnelAndTheListenerHearsTheRequest() {
        val m = machine()
        val gen = m.accepted()
        val a = m.step(Event.Received(gen, open))
        assertEquals(listOf(Action.FilesNetReceived(open, gen, 1)), a.nets())
        assertTrue(a.plans().isEmpty()) // the server is not READY yet: no tunnel
        assertEquals(listOf<FilesTunnelPlan?>(plan(gen)), m.step(Event.SetFiles(ready, wifi(gen))).plans())
    }

    @Test fun aReadyOfAnotherRequestNeverArmsTheLiveOne() {
        val m = machine()
        val gen = m.accepted()
        m.step(Event.Received(gen, open)) // request 1
        assertTrue(m.step(Event.SetFiles(ready, wifi(gen, req = 0))).plans().isEmpty()) // no request at all
        assertTrue(m.step(Event.SetFiles(ready, wifi(gen, req = 7))).plans().isEmpty()) // some other request
        assertEquals(listOf<FilesTunnelPlan?>(plan(gen)), m.step(Event.SetFiles(ready, wifi(gen, req = 1))).plans())
    }

    @Test fun anOpenThatFindsTheTabletOffIsAnsweredWithOffAgain() {
        val m = machine() // FILES_INFO state is OFF (sharing off / no permission)
        val gen = m.accepted()
        val a = m.step(Event.Received(gen, open))
        assertEquals(listOf<Message>(FilesInfo.OFF), sent(a))
        // STANDBY and READY answer themselves: the server starts and publishes READY
        m.step(Event.SetFiles(FilesInfo.STANDBY, ends(0)))
        assertTrue(sent(m.step(Event.Received(gen, open.copy(port = 47010)))).isEmpty())
    }

    @Test fun aSharingToggleMakesTheSamePortOpenANewRequestButARepeatDuringALiveShareStaysANoOp() {
        val m = machine()
        val gen = m.accepted()
        m.live(gen)
        // a true repeat while the share is live: nothing
        val repeat = m.step(Event.Received(gen, open))
        assertTrue(repeat.plans().isEmpty() && repeat.nets().isEmpty())
        // the user switches sharing off on the tablet: the server of request 1 stops (OFF for request 1): the tunnel goes
        assertEquals(listOf<FilesTunnelPlan?>(null), m.step(Event.SetFiles(FilesInfo.OFF, ends(1))).plans())
        // ... and on again: STANDBY; the Mac tore down on OFF and sends a fresh OPEN on the SAME port: a NEW request
        m.step(Event.SetFiles(FilesInfo.STANDBY, ends(0)))
        val fresh = m.step(Event.Received(gen, open))
        assertEquals(listOf(Action.FilesNetReceived(open, gen, 2)), fresh.nets()) // delivered: the UI starts the server again
        assertEquals(
            listOf<FilesTunnelPlan?>(plan(gen, dav = 40555, req = 2)),
            m.step(Event.SetFiles(ready.copy(port = 40555), wifi(gen, req = 2))).plans(),
        )
        // and the live share is idempotent again
        assertTrue(m.step(Event.Received(gen, open)).nets().isEmpty())
    }

    @Test fun sharingSwitchedOffWhileOnlyWaitingForgetsThatRequestThroughTheUi() {
        val m = machine()
        val gen = m.accepted()
        m.step(Event.Received(gen, open)) // request 1, no server yet (sharing was off)
        // the UI drops the request it held (no server, nothing to publish about): the next OPEN is new
        assertTrue(m.step(Event.ForgetFilesNet(1)).plans().isEmpty())
        assertEquals(listOf(Action.FilesNetReceived(open, gen, 2)), m.step(Event.Received(gen, open)).nets())
        // a forget for an older request never touches the newer one
        m.step(Event.ForgetFilesNet(1))
        assertTrue(m.step(Event.Received(gen, open)).nets().isEmpty()) // request 2 is still live: a repeat
    }

    @Test fun aServerThatStoppedOnItsOwnAlsoMakesTheNextOpenNew() {
        val m = machine()
        val gen = m.accepted()
        m.live(gen)
        m.step(Event.SetFiles(FilesInfo.OFF, ends(1))) // the server failed / was stopped (OFF is published)
        assertEquals(listOf(Action.FilesNetReceived(open, gen, 2)), m.step(Event.Received(gen, open)).nets())
    }

    @Test fun ejectAndImmediateReopenWithTheUisDelayedTeardownBeforeTheNewOpen() {
        val m = machine()
        val gen = m.accepted()
        m.live(gen)
        m.step(Event.Received(gen, close)) // the Mac ejects (request 1 ends)
        // the UI's delayed stop of the OLD server publishes STANDBY for request 1 (before the new OPEN reaches the machine)
        m.step(Event.SetFiles(FilesInfo.STANDBY, ends(1)))
        m.step(Event.Received(gen, open)) // request 2
        assertEquals(
            listOf<FilesTunnelPlan?>(plan(gen, dav = 40777, req = 2)),
            m.step(Event.SetFiles(ready.copy(port = 40777), wifi(gen, req = 2))).plans(),
        )
    }

    @Test fun ejectAndImmediateReopenWithTheUisDelayedTeardownAfterTheNewOpen() {
        val m = machine()
        val gen = m.accepted()
        m.live(gen)
        m.step(Event.Received(gen, close)) // eject
        m.step(Event.Received(gen, open)) // immediate reopen on the same port: request 2
        // the UI was busy: only now does the OLD server's teardown arrive (STANDBY for request 1) ...
        val late = m.step(Event.SetFiles(FilesInfo.STANDBY, ends(1)))
        assertTrue(late.plans().isEmpty())
        // ... it must NOT clear request 2: the replacement server's READY still creates the tunnel
        assertEquals(
            listOf<FilesTunnelPlan?>(plan(gen, dav = 40888, req = 2)),
            m.step(Event.SetFiles(ready.copy(port = 40888), wifi(gen, req = 2))).plans(),
        )
        // and a delayed READY of the OLD server (request 1) never creates a tunnel for request 2
        val m2 = machine()
        val g2 = m2.accepted()
        m2.live(g2)
        m2.step(Event.Received(g2, close)); m2.step(Event.Received(g2, open))
        assertTrue(m2.step(Event.SetFiles(ready, wifi(g2, req = 1))).plans().isEmpty())
    }

    @Test fun closeClosesTheTunnelOnceAndIsForwardedAsClose() {
        val m = machine()
        val gen = m.accepted()
        m.live(gen)
        val a = m.step(Event.Received(gen, close))
        assertEquals(listOf<FilesTunnelPlan?>(null), a.plans())
        assertEquals(listOf(Action.FilesNetReceived(close, gen, 0)), a.nets())
        assertTrue(m.step(Event.Received(gen, close)).plans().isEmpty()) // nothing more to close
    }

    @Test fun theServerStoppingTakesTheTunnelAwayAndANewRequestReopensIt() {
        val m = machine()
        val gen = m.accepted()
        m.live(gen)
        assertEquals(listOf<FilesTunnelPlan?>(null), m.step(Event.SetFiles(FilesInfo.OFF, ends(1))).plans())
        // OFF ended the request (the Mac tore down on it): the next OPEN is request 2
        m.step(Event.Received(gen, open))
        val tok = "ffffffffffffffffffffffffffffffff"
        assertEquals(
            listOf<FilesTunnelPlan?>(plan(gen, dav = 40999, req = 2)),
            m.step(Event.SetFiles(ready.copy(port = 40999, token = tok), wifi(gen, req = 2))).plans(),
        )
        // a new token on the same port is no change for the tunnel (the HTTP traffic carries the token, not the tunnel)
        assertTrue(m.step(Event.SetFiles(ready.copy(port = 40999, token = "00000000000000000000000000000000"), wifi(gen, req = 2))).plans().isEmpty())
        // STANDBY of that request is "server off" as well
        assertEquals(listOf<FilesTunnelPlan?>(null), m.step(Event.SetFiles(FilesInfo.STANDBY, ends(2))).plans())
    }

    @Test fun aRepeatedOpenOnTheSamePortChangesNothingEvenWithOtherPoolAndMax() {
        val m = machine()
        val gen = m.accepted()
        m.live(gen)
        // PROTOCOL 0x0A: same port = nothing changes; live connections (and copies on them) are never torn down
        for (again in listOf(open, open.copy(pool = 4, max = 16), open.copy(pool = 1, max = 1))) {
            val a = m.step(Event.Received(gen, again))
            assertTrue(a.plans().isEmpty() && a.nets().isEmpty() && a.filterIsInstance<Action.Send>().isEmpty())
        }
        // after a CLOSE the same port is a fresh open (request 2) with the new sizes
        m.step(Event.Received(gen, close))
        m.step(Event.Received(gen, open.copy(pool = 4, max = 16)))
        assertEquals(
            listOf<FilesTunnelPlan?>(plan(gen, pool = 4, max = 16, req = 2)),
            m.step(Event.SetFiles(ready, wifi(gen, req = 2))).plans(),
        )
    }

    @Test fun anotherListenerPortReplacesThePlanAsANewRequest() {
        val m = machine()
        val gen = m.accepted()
        m.live(gen)
        assertTrue(m.step(Event.Received(gen, open)).plans().isEmpty())
        val a = m.step(Event.Received(gen, open.copy(port = 47004))) // request 2, the old server (request 1) still READY
        assertEquals(listOf(Action.FilesNetReceived(open.copy(port = 47004), gen, 2)), a.nets())
        assertTrue(a.plans().isEmpty() || a.plans() == listOf<FilesTunnelPlan?>(null)) // the old server serves request 1 only
        assertEquals(
            listOf<FilesTunnelPlan?>(plan(gen, port = 47004, req = 2)),
            m.step(Event.SetFiles(ready, wifi(gen, req = 2))).plans(), // the same server (same token), re-tagged
        )
    }

    @Test fun aDifferentPortOpenDuringALiveShareKeepsTheServerPublishesNoOffOrStandbyAndTargetsTheNewPort() {
        // The real chain: machine -> (gate, lifecycle) -> scoped FILES_INFO -> machine
        val m = machine()
        val gen = m.accepted()
        val published = mutableListOf<Pair<FilesInfo, FilesServerScope>>()
        val plans = mutableListOf<FilesTunnelPlan?>()
        var events: dev.matebridge.client.files.FilesLifecycle.Events? = null
        var stops = 0
        val lc = dev.matebridge.client.files.FilesLifecycle<dev.matebridge.client.files.FilesLifecycle.Server>(
            factory = { _, ev, _ ->
                events = ev
                object : dev.matebridge.client.files.FilesLifecycle.Server {
                    override fun start() {}
                    override fun stop() { stops++ }
                }
            },
            newToken = { "0123456789abcdef0123456789abcdef" },
            publish = { },
            onStatus = { },
            log = { _, _, _ -> },
            publishScoped = { info, scope ->
                published += info to scope
                plans += m.step(Event.SetFiles(info, scope)).plans()
            },
        )
        val gate = dev.matebridge.client.files.FilesSessionGate()
        gate.onConnectionGen(gen, Transport.WIFI); gate.onUi(true); gate.onConfigApplied()
        fun sync() = lc.sync(true, true, true, true, Transport.WIFI, gate.netOpen, gate.generation, gate.netRequestId)
        fun deliver(a: List<Action>) {
            for (n in a.nets()) gate.onFilesNet(n.gen, n.msg, n.requestId)
            sync()
        }
        sync() // STANDBY
        deliver(m.step(Event.Received(gen, open))) // live share on 47003 (request 1)
        events!!.onListening(41000)
        assertEquals(listOf<FilesTunnelPlan?>(plan(gen, dav = 41000, req = 1)), plans.filterNotNull())
        val before = published.size
        // the Mac reopens on ANOTHER port while the share is live (request 2): only the file connections are replaced
        deliver(m.step(Event.Received(gen, open.copy(port = 47004))))
        val after = published.drop(before)
        assertTrue("nothing but READY is published: $after", after.isNotEmpty() && after.all { it.first.ready })
        assertEquals(FilesServerScope(true, gen, 2), after.last().second)
        assertEquals(0, stops) // the server was never stopped (same token, same port)
        assertEquals(plan(gen, port = 47004, dav = 41000, req = 2), plans.last())
    }

    @Test fun poolAndMaxAreClampedAndAPortlessOpenIsIgnored() {
        val m = machine()
        val gen = m.accepted()
        val a = m.step(Event.Received(gen, FilesNet(FilesNet.STATE_OPEN, 47003, 0, 200)))
        assertEquals(FilesNet(FilesNet.STATE_OPEN, 47003, 1, 16), a.nets().single().msg)
        assertEquals(listOf<FilesTunnelPlan?>(plan(gen, pool = 1, max = 16)), m.step(Event.SetFiles(ready, wifi(gen))).plans())
        val b = m.step(Event.Received(gen, FilesNet(FilesNet.STATE_OPEN, 47004, 9, 3)))
        assertEquals(FilesNet(FilesNet.STATE_OPEN, 47004, 4, 4), b.nets().single().msg)
        val c = m.step(Event.Received(gen, FilesNet(FilesNet.STATE_OPEN, 0, 2, 12)))
        assertTrue(c.plans().isEmpty() && c.nets().isEmpty()) // no port: ignored, the earlier open stands
    }

    @Test fun anUnknownStateIsClose() {
        val m = machine()
        val gen = m.accepted()
        m.live(gen)
        val a = m.step(Event.Received(gen, FilesNet(9, 47003, 2, 12)))
        assertEquals(listOf<FilesTunnelPlan?>(null), a.plans())
        assertFalse(a.nets().single().msg.isOpen)
    }

    @Test fun neverOnUsbAndNeverBeforeTheSessionIsAccepted() {
        val usbM = machine()
        val usbGen = usbM.accepted(usb)
        usbM.step(Event.SetFiles(ready, FilesServerScope(false, usbGen)))
        val a = usbM.step(Event.Received(usbGen, open))
        assertTrue(a.nets().isEmpty() && a.plans().isEmpty())

        val m = machine()
        val gen = m.step(Event.Start(wifi)).filterIsInstance<Action.OpenControl>().single().gen
        m.step(Event.ControlOpened(gen))
        // awaiting the first ack: not accepted, FILES_NET is not delivered
        val b = m.step(Event.Received(gen, open))
        assertTrue(b.nets().isEmpty() && b.plans().isEmpty())
    }

    @Test fun everyEndOfTheSessionTakesTheTunnelAwayExactlyOnce() {
        val ends = listOf<Pair<String, (SessionMachine, Int) -> List<Action>>>(
            "stop" to { m, _ -> m.step(Event.Stop) },
            "host closed" to { m, g -> m.step(Event.ControlClosed(g)) },
            "protocol error" to { m, g -> m.step(Event.ProtocolError(g)) },
            "bye normal" to { m, g -> m.step(Event.Received(g, Bye(Bye.NORMAL))) },
            "bye host sleep" to { m, g -> m.step(Event.Received(g, Bye(Bye.HOST_SLEEP))) },
            "bye superseded" to { m, g -> m.step(Event.Received(g, Bye(Bye.SUPERSEDED))) },
            "restart" to { m, _ -> m.step(Event.Start(wifi)) }, // a new start while accepted: BYE and a fresh connection
        )
        for ((name, end) in ends) {
            val m = machine()
            val gen = m.accepted()
            m.live(gen)
            assertEquals("$name: tunnel closed exactly once", listOf<FilesTunnelPlan?>(null), end(m, gen).plans())
        }
    }

    @Test fun aNewSessionStartsWithoutTheOldOpenRequestEvenThoughTheServerIsStillReady() {
        val m = machine()
        val gen = m.accepted()
        m.live(gen)
        m.step(Event.Stop)
        val gen2 = m.accepted(session = 78)
        // the old server's READY (request 1, generation gen) arrives late: stale, no tunnel for anything
        assertTrue(m.step(Event.SetFiles(ready.copy(token = "ffffffffffffffffffffffffffffffff"), wifi(gen))).plans().isEmpty())
        // the new session's OPEN is request 2; the old READY cannot arm it
        assertTrue(m.step(Event.Received(gen2, open)).plans().isEmpty())
        assertEquals(listOf<FilesTunnelPlan?>(plan(gen2, session = 78, req = 2)), m.step(Event.SetFiles(ready, wifi(gen2, req = 2))).plans())
        // an automatic reconnect after a loss is a new session as well
        m.step(Event.ControlClosed(gen2))
        val retry = m.handle(Event.Tick(0), now + SessionMachine.BACKOFF_MAX_US + 1).filterIsInstance<Action.OpenControl>().single().gen
        m.step(Event.ControlOpened(retry))
        val acc = m.step(Event.Received(retry, HelloAck(1, HelloAck.ACCEPTED, 79, 47002, "Mac")))
        assertTrue(acc.plans().isEmpty())
    }

    @Test fun aSessionLostByHeartbeatTakesTheTunnelAway() {
        val m = machine()
        val gen = m.accepted()
        m.live(gen)
        val a = m.handle(Event.Tick(0), now + SessionMachine.PONG_TIMEOUT_US + 1)
        assertEquals(listOf<FilesTunnelPlan?>(null), a.plans())
        assertTrue(a.any { it is Action.CloseControl })
    }

    @Test fun anOldGenerationsFilesNetIsIgnored() {
        val m = machine()
        val gen = m.accepted()
        m.step(Event.SetFiles(FilesInfo.STANDBY, ends(0)))
        val a = m.step(Event.Received(gen + 50, open))
        assertTrue(a.nets().isEmpty() && a.plans().isEmpty())
    }

    @Test fun migrationToUsbEndsTheWifiTunnel() {
        val m = machine()
        val gen = m.accepted()
        m.live(gen)
        val cand = m.step(Event.Migrate(usb)).filterIsInstance<Action.OpenCandidate>().single().gen
        m.step(Event.ControlOpened(cand))
        m.step(Event.Received(cand, HelloAck(1, HelloAck.ACCEPTED, 78, 47002, "Mac"))) // proof PING on the candidate
        // the Wi-Fi tunnel stays while the proof is pending (the old session still carries everything)
        val r = m.step(Event.Received(cand, StreamConfig(2, 1, 2800, 1840, 1400, 920, 60, 20000, 1, 1, 1, 1)))
        assertEquals(listOf<FilesTunnelPlan?>(null), r.plans())
        assertTrue(r.any { it is Action.PromoteCandidate })
    }

    @Test fun aPreviousSessionsReadyIsNeverRepublishedOnANewSession() {
        val m = machine()
        val gen = m.accepted()
        m.live(gen)
        m.step(Event.Stop) // the UI has not stopped the old server yet (slow UI thread)
        val g = m.step(Event.Start(wifi)).filterIsInstance<Action.OpenControl>().single().gen
        m.step(Event.ControlOpened(g))
        val acc = m.step(Event.Received(g, HelloAck(1, HelloAck.ACCEPTED, 78, 47002, "Mac")))
        assertEquals(FilesInfo.OFF, acc.filterIsInstance<Action.Send>().map { it.msg }.filterIsInstance<FilesInfo>().single())
        assertTrue(acc.filterIsInstance<Action.Send>().none { (it.msg as? FilesInfo)?.ready == true })
        // and the Mac's OPEN of the new session (request 2) cannot arm the old server
        assertTrue(m.step(Event.Received(g, open)).plans().isEmpty())
        // only this session's own Wi-Fi server for that request counts
        assertEquals(listOf<FilesTunnelPlan?>(plan(g, session = 78, req = 2)), m.step(Event.SetFiles(ready, wifi(g, req = 2))).plans())
    }

    @Test fun aStaleReadyArrivingLateIsAnnouncedAsOffAndNeverTunnelled() {
        val m = machine()
        val old = m.accepted()
        m.step(Event.Stop)
        val g = m.accepted(session = 78)
        m.step(Event.Received(g, open))
        val a = m.step(Event.SetFiles(ready, wifi(old)))
        assertTrue(a.plans().isEmpty())
        assertEquals(listOf<Message>(FilesInfo.OFF), sent(a))
    }

    @Test fun aUsbScopeServerIsNeverTunnelledOverWifiEvenInTheSameGeneration() {
        val m = machine()
        val gen = m.accepted()
        m.step(Event.Received(gen, open))
        // a server started for the USB scope (whole storage possible) that claims READY on this very generation and request
        val a = m.step(Event.SetFiles(ready, FilesServerScope(false, gen, 1)))
        assertTrue(a.plans().isEmpty())
    }

    @Test fun usbToWifiMigrationNeverCarriesTheUsbServersReadyAcrossAndTheTunnelWaitsForTheWifiServer() {
        val m = machine()
        val usbGen = m.accepted(usb)
        m.step(Event.SetFiles(ready, FilesServerScope(false, usbGen))) // the USB server is READY and announced
        val cand = m.step(Event.Migrate(wifi)).filterIsInstance<Action.OpenCandidate>().single().gen
        m.step(Event.ControlOpened(cand))
        m.step(Event.Received(cand, HelloAck(1, HelloAck.ACCEPTED, 78, 47002, "Mac")))
        val r = m.step(Event.Received(cand, StreamConfig(2, 1, 2800, 1840, 1400, 920, 60, 20000, 1, 1, 1, 1)))
        assertTrue(r.any { it is Action.PromoteCandidate })
        // the new Wi-Fi session starts with OFF, not the USB server's READY and token
        val fi = r.filterIsInstance<Action.Send>().map { it.msg }.filterIsInstance<FilesInfo>()
        assertEquals(listOf(FilesInfo.OFF), fi)
        // the slow UI has not stopped the USB server; the Mac's early OPEN must not reach it
        assertTrue(m.step(Event.Received(cand, open)).plans().isEmpty())
        assertTrue(m.step(Event.SetFiles(ready, FilesServerScope(false, usbGen))).plans().isEmpty())
        // the Wi-Fi server this session started for that request (Wi-Fi scope, this generation) is what the tunnel uses
        assertEquals(
            listOf<FilesTunnelPlan?>(plan(cand, dav = 41000, session = 78)),
            m.step(Event.SetFiles(ready.copy(port = 41000), wifi(cand))).plans(),
        )
    }

    @Test fun whenTheOldSessionIsSupersededDuringAMigrationProofTheFileResourcesEndAtOnce() {
        for (how in listOf("bye", "closed")) {
            val m = machine()
            val gen = m.accepted()
            m.live(gen)
            val cand = m.step(Event.Migrate(usb)).filterIsInstance<Action.OpenCandidate>().single().gen
            m.step(Event.ControlOpened(cand))
            m.step(Event.Received(cand, HelloAck(1, HelloAck.ACCEPTED, 78, 47002, "Mac"))) // proof PING sent, waiting
            val a = if (how == "bye") m.step(Event.Received(gen, Bye(Bye.SUPERSEDED))) else m.step(Event.ControlClosed(gen))
            assertEquals("$how: tunnel closed now", listOf<FilesTunnelPlan?>(null), a.plans())
            assertEquals("$how: the UI hears CLOSE (server stops)", listOf(Action.FilesNetReceived(close, gen, 0)), a.nets())
            // the dead session cannot be re-armed by a late OPEN
            val b = m.step(Event.Received(gen, open))
            assertTrue(b.plans().isEmpty() && b.nets().isEmpty())
        }
    }
}
