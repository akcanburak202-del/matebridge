package dev.matebridge.client.session

import dev.matebridge.client.input.InputCapture
import dev.matebridge.client.input.InputSink
import dev.matebridge.client.input.KeyFrame
import dev.matebridge.client.input.VP
import dev.matebridge.client.protocol.Bye
import dev.matebridge.client.protocol.Bytes
import dev.matebridge.client.protocol.ReleaseAll
import dev.matebridge.client.video.HealthEvent
import dev.matebridge.client.video.VideoHealth
import dev.matebridge.client.protocol.Hello
import dev.matebridge.client.protocol.HelloAck
import dev.matebridge.client.protocol.Key
import dev.matebridge.client.protocol.KeyframeRequest
import dev.matebridge.client.protocol.Limits
import dev.matebridge.client.protocol.Message
import dev.matebridge.client.protocol.Pen
import dev.matebridge.client.protocol.PenSample
import dev.matebridge.client.protocol.Ping
import dev.matebridge.client.protocol.Pong
import dev.matebridge.client.protocol.ProtocolException
import dev.matebridge.client.protocol.StreamConfig
import dev.matebridge.client.protocol.StreamPrefs
import dev.matebridge.client.security.ClientHandshake
import dev.matebridge.client.security.PairTrust
import dev.matebridge.client.security.ReadOnlyPairKeyStore
import dev.matebridge.client.security.RecordDecoder
import dev.matebridge.client.security.TrustFixture
import dev.matebridge.client.security.hexOf
import dev.matebridge.client.session.PairTrustFlowTest.FakeHost
import dev.matebridge.client.session.SessionMachine.Action
import dev.matebridge.client.session.SessionMachine.Event
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * T-205 (decision 0018): an AUTO USB migration candidate is promoted only after its first host record decrypts and
 * authenticates; until then the Wi-Fi session stays current and keeps carrying input. Real crypto ([FakeHost],
 * [ClientHandshake], [FirstAck], [RecordDecoder]) over a real trust store, and a mirror of the controller's routing
 * (`SessionController.dispatch` / `exec` / `trySendInput`), so "the up is sent on the Wi-Fi connection" is checked
 * where it happens.
 */
class MigrationAuthGateTest {
    private val template = Hello(0, Bytes(ByteArray(16) { it.toByte() }), 2800, 1840, 360, 144, 0xFF, "MatePad")
    private val wifi = Endpoint("10.0.0.5", 47001)
    private val usb = ConnectMode.usbEndpoint
    private val f = TrustFixture()
    private val logs = ArrayList<String>()
    private val m = SessionMachine(template, initialAudio = true, trust = f.trust) { l, ev, fields -> logs += "$l $ev $fields" }
    /** The controller's candidate store: read-only, never user-initiated. */
    private val candTrust = PairTrust(ReadOnlyPairKeyStore(f.store), { f.wallMs })
    private var now = 1_000_000L

    private val hostId = ByteArray(16) { (0x40 + it).toByte() }
    private val keyK = ByteArray(32) { 0x11 }
    private val wrongKey = ByteArray(32) { 0x22 }

    // ---- mirror of SessionController's routing ----
    private var current = -1
    private var candidate = -1
    private var video = -1
    private var gate = false
    /** Everything sent, per control connection generation. */
    private val wire = HashMap<Int, MutableList<Message>>()
    private val actions = ArrayList<Action>()

    private fun step(e: Event, advanceUs: Long = 0): List<Action> {
        now += advanceUs
        val a = m.handle(e, now)
        val allowed = m.inputAllowed
        if (!allowed || a.any { it is Action.PromoteCandidate }) gate = false
        for (x in a) exec(x)
        gate = allowed
        actions += a
        return a
    }

    private fun exec(a: Action) {
        when (a) {
            is Action.OpenControl -> current = a.gen
            is Action.OpenVideo -> video = a.gen
            is Action.Send -> if (current >= 0) out(current, a.msg)
            is Action.CloseControl -> current = -1
            is Action.OpenCandidate -> candidate = a.gen
            is Action.SendCandidate -> if (candidate >= 0) out(candidate, a.msg)
            Action.CloseCandidate -> candidate = -1
            Action.RetireControl -> current = -1
            is Action.PromoteCandidate -> {
                assertEquals(candidate, a.gen)
                current = a.gen
                candidate = -1
            }
            else -> Unit
        }
    }

    private fun out(gen: Int, msg: Message) {
        wire.getOrPut(gen) { ArrayList() } += msg
    }

    private fun sent(gen: Int): List<Message> = wire[gen] ?: emptyList()

    /** `SessionController.trySendInput`: the gate and the input layer's generation must both match. */
    private fun sendInput(msg: Message, gen: Int): Boolean {
        if (!gate || current != gen) return false
        out(gen, msg)
        return true
    }

    // ---- one control connection with real crypto, read like the controller's reader ----
    private inner class Conn(val gen: Int, private val keys: PairTrust) {
        private val hs = ClientHandshake()
        private val wireHello = hs.hello(template)
        private var decoder: RecordDecoder? = null
        lateinit var host: FakeHost

        fun first(host: FakeHost, pairing: Boolean = false): List<Action> {
            this.host = host
            val (ack, payload) = host.answer(wireHello, pairing)
            val r = FirstAck.handle(gen, ack, hs.complete(ack, payload, keys, userInitiated = false))
            r.session?.let { decoder = RecordDecoder(Limits.CONTROL_MAX_PAYLOAD, it.opener) }
            return r.events.flatMap { step(it) }
        }

        fun records(vararg msgs: Message): List<Action> {
            val d = decoder!!
            d.feed(host.seal(*msgs))
            val out = ArrayList<Action>()
            while (true) {
                val msg = try {
                    d.next()
                } catch (e: ProtocolException) {
                    out += step(Event.ProtocolError(gen)) // the reader's reaction to a record that does not authenticate
                    return out
                } ?: break
                out += step(Event.Received(gen, msg))
            }
            return out
        }
    }

    private fun mac(id: ByteArray = hostId, key: ByteArray? = keyK) = FakeHost(id, "Mac mini").also { it.key = key?.copyOf() }
    private fun cfg(id: Int) = StreamConfig(id, 1, 2800, 1840, 1400, 920, 60, 20000, 1, 1, 1, 1)
    private fun key(action: Int) = Key(now, 30, 29, action, 0)
    private fun pen(contact: Boolean) =
        Pen(Pen.TOOL_PEN, now, listOf(PenSample(0, 100, 100, if (contact) 500 else 0, 0, 0, PenSample.IN_RANGE or (if (contact) PenSample.CONTACT else 0))))

    private lateinit var wifiConn: Conn

    /** Accepted (PAIRED, trusted key) and streaming on Wi-Fi; returns its generation. */
    private fun streamingOnWifi(): Int {
        f.store.put(hostId, keyK)
        val gen = step(Event.Start(wifi)).filterIsInstance<Action.OpenControl>().single().gen
        step(Event.ControlOpened(gen))
        wifiConn = Conn(gen, f.trust)
        wifiConn.first(mac())
        assertTrue(wifiConn.records(cfg(1)).any { it is Action.OpenVideo })
        assertTrue(m.inputAllowed)
        return gen
    }

    private fun openCandidate(): Conn {
        val open = step(Event.Migrate(usb)).filterIsInstance<Action.OpenCandidate>().single()
        assertEquals(usb, open.endpoint)
        step(Event.ControlOpened(open.gen))
        return Conn(open.gen, candTrust)
    }

    /** The candidate's plaintext ACCEPTED: only the proof PING goes out, on the candidate; nothing else happens. */
    private fun ackOnly(c: Conn, host: FakeHost): List<Action> {
        val a = c.first(host)
        assertTrue(a.none { it is Action.PromoteCandidate || it is Action.RetireControl || it is Action.CloseVideo })
        assertTrue(a.none { it is Action.CloseControl || it is Action.Ui || it is Action.MigrationResult || it is Action.Send })
        assertEquals(listOf(Action.SendCandidate::class.java), a.map { it.javaClass })
        assertEquals(listOf(Hello::class.java, Ping::class.java), sent(c.gen).map { it.javaClass })
        assertTrue(logs.any { it.startsWith("I migration_proof_wait ") })
        return a
    }

    /** Keeps the Wi-Fi session alive like a real host answering our pings. */
    private fun ticksWithPongs(totalUs: Long, everyUs: Long = 100_000): List<Action> {
        val out = ArrayList<Action>()
        var t = 0L
        while (t < totalUs) {
            val stepUs = minOf(everyUs, totalUs - t)
            out += step(Event.Tick(0), stepUs)
            t += stepUs
            if (current == wifiConn.gen) wifiConn.records(Pong(0, 0, 0))
        }
        return out
    }

    private fun assertWifiUntouched(wifiGen: Int, since: Int) {
        val after = actions.drop(since)
        assertTrue(after.none { it is Action.Ui }) // no lose, no reconnect, no UI change
        assertTrue(after.none { it is Action.CloseControl || it is Action.CloseVideo || it is Action.OpenControl })
        assertTrue(after.none { it is Action.RetireControl || it is Action.PromoteCandidate || it is Action.OpenVideo })
        assertTrue(m.inputAllowed)
        assertEquals(wifiGen, m.acceptedGen)
        assertEquals(wifiGen, current)
        assertFalse(m.migrating)
        // its pings go on, on the Wi-Fi connection
        val before = sent(wifiGen).count { it is Ping }
        step(Event.Tick(0), SessionMachine.PING_INTERVAL_US)
        assertTrue(sent(wifiGen).count { it is Ping } > before)
    }

    @After fun noSecretInLogs() {
        val id = hexOf(hostId)
        for (l in logs) assertFalse(l, l.contains(id) || l.contains(hexOf(keyK)))
    }

    // ---- acceptance ----

    @Test fun plaintextAcceptedDoesNotPromoteUntilTheFirstAuthenticatedRecord() {
        val w = streamingOnWifi()
        val c = openCandidate()
        ackOnly(c, mac())
        assertTrue(m.migrating)
        assertTrue(m.inputAllowed)
        assertEquals(w, m.acceptedGen)
        // Wi-Fi pings keep going on Wi-Fi meanwhile (none on the candidate)
        ticksWithPongs(SessionMachine.PING_INTERVAL_US)
        assertEquals(1, sent(c.gen).count { it is Ping })
        // the real host answers the proof: STREAM_CONFIG first (after superseding the old session), then the PONG
        val r = c.records(cfg(2), Pong(0, 0, 0))
        assertEquals(Action.PromoteCandidate(c.gen, usb), r.filterIsInstance<Action.PromoteCandidate>().single())
        assertEquals(Action.MigrationResult(usb, true, SessionMachine.REASON_OK), r.filterIsInstance<Action.MigrationResult>().single())
        assertEquals(c.gen, m.acceptedGen)
        assertEquals(c.gen, current)
        assertTrue(logs.any { it.startsWith("I migration_proved ") })
    }

    @Test fun squatterWithABadRecordIsAbortedAndTheWifiSessionIsUntouched() =
        squatter(SessionMachine.REASON_PROOF_FAILED) { c -> c.records(cfg(2)) } // sealed without the pair key

    @Test fun squatterThatClosesIsAbortedAndTheWifiSessionIsUntouched() =
        squatter(SessionMachine.REASON_PROOF_CLOSED) { c -> step(Event.ControlClosed(c.gen)) }

    @Test fun squatterThatSendsNothingTimesOutAndTheWifiSessionIsUntouched() =
        squatter(SessionMachine.REASON_PROOF_TIMEOUT) {
            // the deadline counts from the migration request; the Wi-Fi session answers its pings meanwhile
            assertTrue(ticksWithPongs(SessionMachine.MIGRATE_TIMEOUT_US - 200_000).none { it is Action.MigrationResult })
            ticksWithPongs(200_000)
        }

    /**
     * A local app squatting the loopback port, knowing the real host_id (clear in every ack) but not the pair key. A key
     * and a pen contact pressed on Wi-Fi before the candidate opened are released during the proof wait: both ups go
     * out on Wi-Fi, and no input is refused at any point.
     */
    private fun squatter(reason: String, fail: (Conn) -> List<Action>) {
        val w = streamingOnWifi()
        assertTrue(sendInput(key(Key.DOWN), w))
        assertTrue(sendInput(pen(contact = true), w))
        val since = actions.size
        val c = openCandidate()
        assertTrue(sendInput(pen(contact = true), w))
        ackOnly(c, mac(key = wrongKey))
        assertTrue(sendInput(key(Key.UP), w))
        assertTrue(sendInput(pen(contact = false), w))
        val r = fail(c)
        assertEquals(listOf(Action.CloseCandidate, Action.MigrationResult(usb, false, reason)), r.filter {
            it is Action.CloseCandidate || it is Action.MigrationResult
        })
        assertEquals(AutoUsbPolicy.Outcome.HARD_FAIL, AutoUsbPolicy.outcomeOf(false, reason)) // AUTO backs off
        assertWifiUntouched(w, since)
        assertTrue(sendInput(key(Key.DOWN), w) && sendInput(key(Key.UP), w))
        // every input went out on Wi-Fi, ups included; nothing on the candidate but HELLO and the proof PING
        val inputs = sent(w).filter { it is Key || it is Pen }
        assertEquals(listOf(Key.DOWN, Key.UP, Key.DOWN, Key.UP), inputs.filterIsInstance<Key>().map { it.action })
        assertEquals(listOf(true, true, false), inputs.filterIsInstance<Pen>().map { it.samples.single().flags and PenSample.CONTACT != 0 })
        assertEquals(listOf(Hello::class.java, Ping::class.java), sent(c.gen).map { it.javaClass })
        // a late record of the dead candidate does nothing
        assertTrue(step(Event.Received(c.gen, cfg(3))).isEmpty())
    }

    @Test fun realMigrationKeepsUpsOnWifiAndStillPromotes() {
        val w = streamingOnWifi()
        assertTrue(sendInput(key(Key.DOWN), w))
        assertTrue(sendInput(pen(contact = true), w))
        step(Event.Tick(0), 1_500_000) // no PONG since the accept: a PONG timeout would be due 1.5 s into the proof wait
        val c = openCandidate()
        ackOnly(c, mac())
        // released during the proof wait: the ups go out on Wi-Fi
        assertTrue(sendInput(key(Key.UP), w))
        assertTrue(sendInput(pen(contact = false), w))
        // the host supersedes the Wi-Fi session on our proof; its BYE and close come before the candidate's record
        val since = actions.size
        wifiConn.records(Bye(Bye.SUPERSEDED))
        step(Event.ControlClosed(w))
        assertTrue(actions.drop(since).isEmpty()) // the session does not end
        assertTrue(m.inputAllowed)
        // input made now still goes to the Wi-Fi generation (the host released everything there already): never refused
        assertTrue(sendInput(key(Key.DOWN), w) && sendInput(key(Key.UP), w))
        // the old connection is not pinged, PONG-timed-out or video-retried any more while the proof is pending
        // the host closed the old video too. T-218: input is gated at once anyway (the overlay may wait for the promotion).
        assertEquals(listOf<Action>(Action.VideoLost(video, duringMigration = true)), step(Event.VideoClosed(video)))
        val idle = ArrayList<Action>()
        repeat(25) { idle += step(Event.Tick(0), 100_000) } // 4 s since the last PONG, 2.5 s into the proof wait
        assertTrue(idle.isEmpty())

        val r = c.records(cfg(2), Pong(0, 0, 0))
        assertEquals(1, r.count { it == Action.CloseVideo }) // the old video closes once
        assertEquals(1, r.count { it is Action.ApplyConfig })
        assertEquals(Endpoint(usb.host, 47002), r.filterIsInstance<Action.OpenVideo>().single().endpoint)
        assertTrue(r.indexOfFirst { it is Action.OpenVideo } > r.indexOfFirst { it is Action.ApplyConfig })
        assertTrue(r.indexOf(Action.RetireControl) in 0 until r.indexOfFirst { it is Action.PromoteCandidate })
        assertEquals(c.gen, current)
        // the new session: HELLO, the proof PING, then the settings; no KEYFRAME_REQUEST from the switch
        val onUsb = sent(c.gen)
        assertEquals(listOf(Hello::class.java, Ping::class.java, StreamPrefs::class.java), onUsb.take(3).map { it.javaClass })
        assertTrue((wire.values.flatten()).none { it is KeyframeRequest })
        // no input from the old generation reaches the new session
        assertFalse(sendInput(key(Key.UP), w))
        assertFalse(sendInput(pen(contact = false), w))
        assertTrue(onUsb.none { it is Key || it is Pen })
        val wifiKeys = sent(w).filterIsInstance<Key>().map { it.action }
        assertEquals(listOf(Key.DOWN, Key.UP, Key.DOWN, Key.UP), wifiKeys)
        assertEquals(listOf(true, false), sent(w).filterIsInstance<Pen>().map { it.samples.single().flags and PenSample.CONTACT != 0 })
        // the new generation carries input
        assertTrue(sendInput(key(Key.DOWN), c.gen))
        // T-218: the one video loss (the takeover's close) was reported, marked as during the migration
        assertEquals(listOf(true), actions.filterIsInstance<Action.VideoLost>().map { it.duringMigration })
    }

    @Test fun oldSupersededThenCandidateFailsLosesTheSessionInsteadOfHanging() {
        val w = streamingOnWifi()
        val c = openCandidate()
        ackOnly(c, mac())
        wifiConn.records(Bye(Bye.SUPERSEDED))
        val r = step(Event.ControlClosed(c.gen))
        assertEquals(Action.MigrationResult(usb, false, SessionMachine.REASON_PROOF_CLOSED), r.filterIsInstance<Action.MigrationResult>().single())
        assertTrue(r.any { it is Action.CloseControl })
        assertTrue(r.filterIsInstance<Action.Ui>().single().state is SessionUi.Disconnected) // reconnects
        assertFalse(m.inputAllowed)
        assertFalse(sendInput(key(Key.UP), w))
        // the deadline variant: nothing from the candidate after the old one was closed
        streamingOnWifi()
        val c2 = openCandidate()
        ackOnly(c2, mac())
        step(Event.ControlClosed(wifiConn.gen))
        var t = 0L
        var res: List<Action> = emptyList()
        while (res.none { it is Action.MigrationResult }) {
            res = step(Event.Tick(0), 100_000)
            t += 100_000
            assertTrue(t <= SessionMachine.MIGRATE_TIMEOUT_US)
        }
        assertEquals(SessionMachine.REASON_PROOF_TIMEOUT, res.filterIsInstance<Action.MigrationResult>().single().reason)
        assertTrue(res.filterIsInstance<Action.Ui>().single().state is SessionUi.Disconnected)
    }

    /**
     * Codex review (T-205): the Wi-Fi PONG baseline is 2.9 s old when the candidate's proof goes out and the host's takeover
     * answer takes another 150 ms. The old heartbeat expiring meanwhile must not lose the session (and with it the
     * candidate's authenticated STREAM_CONFIG): it counts as the old connection gone, and the candidate decides.
     */
    @Test fun oldHeartbeatExpiringDuringTheProofDoesNotAbortAValidMigration() {
        val w = streamingOnWifi() // last PONG baseline: the accept, now
        assertTrue(sendInput(key(Key.DOWN), w))
        assertTrue(step(Event.Tick(0), 2_900_000).none { it is Action.Ui }) // no PONG for 2.9 s: not yet a timeout
        val c = openCandidate()
        ackOnly(c, mac())
        val since = actions.size
        val t = step(Event.Tick(0), 150_000) // 3.05 s since the last PONG
        assertTrue(t.isEmpty()) // before T-205's fix: lose() here (CloseControl, CloseCandidate, Ui Disconnected)
        assertTrue(logs.any { it == "I migration_old_stale " })
        assertTrue(m.migrating)
        assertTrue(m.inputAllowed)
        assertTrue(sendInput(key(Key.UP), w)) // the release is never refused; it goes to the Wi-Fi generation
        assertEquals(listOf(Key.DOWN, Key.UP), sent(w).filterIsInstance<Key>().map { it.action })
        // no more pings or PONG-timeout on the old connection while the candidate's deadline runs
        val pings = sent(w).count { it is Ping }
        assertTrue(step(Event.Tick(0), 100_000).isEmpty())
        assertEquals(pings, sent(w).count { it is Ping })
        // the takeover's answer arrives: promoted, and the promoted generation is announced before its STREAM_CONFIG
        // (T-153's FilesSessionGate relies on onConnectionGen preceding ApplyConfig)
        val r = c.records(cfg(2), Pong(0, 0, 0))
        val iPromote = r.indexOfFirst { it is Action.PromoteCandidate }
        assertTrue(iPromote >= 0 && iPromote < r.indexOfFirst { it is Action.ApplyConfig })
        assertEquals(Action.MigrationResult(usb, true, SessionMachine.REASON_OK), r.filterIsInstance<Action.MigrationResult>().single())
        assertEquals(1, r.count { it is Action.OpenVideo })
        assertTrue(actions.drop(since).none { it is Action.CloseControl || it is Action.CloseCandidate })
        assertTrue(actions.drop(since).filterIsInstance<Action.Ui>().all { it.state is SessionUi.Connected })
        assertEquals(c.gen, m.acceptedGen)
        // the new session's heartbeat starts at the promotion: no timeout right after it
        assertTrue(step(Event.Tick(0), 100_000).none { it is Action.Ui && it.state is SessionUi.Disconnected })
    }

    @Test fun oldHeartbeatExpiredAndASquatterCandidateReconnects() {
        streamingOnWifi()
        step(Event.Tick(0), 2_900_000)
        val c = openCandidate()
        ackOnly(c, mac(key = wrongKey))
        assertTrue(step(Event.Tick(0), 150_000).isEmpty()) // old heartbeat expired: marked gone, no lose yet
        val r = c.records(cfg(2)) // does not authenticate
        assertEquals(Action.MigrationResult(usb, false, SessionMachine.REASON_PROOF_FAILED), r.filterIsInstance<Action.MigrationResult>().single())
        assertEquals(SessionUi.Disconnected(SessionUi.Cause.LOST, SessionMachine.BACKOFF_START_US / 1000), r.filterIsInstance<Action.Ui>().single().state)
        assertTrue(r.any { it is Action.CloseControl })
        assertFalse(m.inputAllowed)
    }

    /**
     * Codex review 2 (T-205): the heartbeat expiry is provisional. The Wi-Fi heartbeat expires during the proof wait, then
     * a valid Wi-Fi PONG arrives before the (squatter) candidate fails: Wi-Fi pings and video retries resume, and the
     * candidate's failure keeps the healthy Wi-Fi session instead of losing it.
     */
    @Test fun wifiRecoveringBeforeTheCandidateFailsKeepsTheWifiSession() {
        val w = streamingOnWifi()
        step(Event.Tick(0), 2_900_000)
        val c = openCandidate()
        ackOnly(c, mac(key = wrongKey))
        assertTrue(step(Event.Tick(0), 150_000).isEmpty()) // expired: stale, nothing sent or retried on it
        assertTrue(logs.any { it == "I migration_old_stale " })
        // T-218: the current video's loss gates input at once, also while the proof is pending
        assertEquals(listOf<Action>(Action.VideoLost(video, duringMigration = true)), step(Event.VideoClosed(video)))
        val pings = sent(w).count { it is Ping }
        assertTrue(step(Event.Tick(0), 100_000).isEmpty())
        assertEquals(pings, sent(w).count { it is Ping })
        // a valid PONG on Wi-Fi: recovered
        assertTrue(wifiConn.records(Pong(0, 0, 0)).isEmpty())
        assertTrue(logs.any { it == "I migration_old_recovered " })
        val resumed = step(Event.Tick(0), SessionMachine.VIDEO_RETRY_US) // pings and the video retry resume on Wi-Fi
        assertTrue(resumed.any { it is Action.Send && it.msg is Ping })
        assertEquals(1, resumed.count { it is Action.OpenVideo })
        assertEquals(pings + 1, sent(w).count { it is Ping })
        assertTrue(sendInput(key(Key.DOWN), w) && sendInput(key(Key.UP), w))
        // the squatter's record does not authenticate: the candidate fails, the Wi-Fi session stays
        val since = actions.size
        val r = c.records(cfg(2))
        assertEquals(listOf(Action.CloseCandidate, Action.MigrationResult(usb, false, SessionMachine.REASON_PROOF_FAILED)), r)
        assertWifiUntouched(w, since)
        // its heartbeat is the ordinary one again: no PONG for 3 s now loses the session as before T-205
        val lost = step(Event.Tick(0), SessionMachine.PONG_TIMEOUT_US)
        assertTrue(lost.filterIsInstance<Action.Ui>().single().state is SessionUi.Disconnected)
    }

    /**
     * T-218 review (Codex P1): the candidate is ACCEPTED but its proof stalls, and the *current* video closes on its own
     * while the Wi-Fi control link keeps answering. A pending ack does not prove the takeover closed it: input must be
     * gated at once (releases on the current Wi-Fi connection), for the whole proof wait and after the candidate fails.
     * Only the overlay waits, until the ladder's first step.
     */
    @Test fun currentVideoLossDuringAStalledProofGatesInputAtOnce() {
        val healthLogs = ArrayList<String>()
        lateinit var health: VideoHealth
        lateinit var cap: InputCapture
        // MainActivity: health changes drive syncInputActive; capture sends through trySendInput (gate + generation).
        health = VideoHealth({ now / 1000 }, log = { l, ev, f -> healthLogs += "$l $ev $f" }) {
            cap.setActive(health.inputAllowed, now / 1000)
        }
        cap = InputCapture(object : InputSink {
            override fun send(msg: Message) = sendInput(msg, current)
            override fun congested() = false
            override fun closeConnection() {}
        }, { VP })
        cap.setStreamGeometry(1400, 920)
        val w = streamingOnWifi()
        health.onEvent(HealthEvent.Generation(1))
        health.onEvent(HealthEvent.Running(1))
        health.onEvent(HealthEvent.FirstOutput(1))
        assertTrue(health.inputAllowed)
        cap.onKey(KeyFrame(7, 30, 29, true, 0, false, false, false, now))
        assertEquals(listOf(Key.DOWN), sent(w).filterIsInstance<Key>().map { it.action })

        val c = openCandidate()
        ackOnly(c, mac()) // a real candidate whose proof answer is delayed
        val lost = step(Event.VideoClosed(video))
        assertEquals(listOf<Action>(Action.VideoLost(video, duringMigration = true)), lost)
        lost.filterIsInstance<Action.VideoLost>().forEach { health.videoLost(quietOverlay = it.duringMigration) }
        // Same step: input closed and released on the current (Wi-Fi) connection; nothing went to the candidate.
        assertFalse(health.inputAllowed)
        val wifi = sent(w)
        assertTrue("RELEASE_ALL(USER) follows the held key on Wi-Fi",
            wifi.indexOfLast { it is ReleaseAll && it.reason == ReleaseAll.USER } > wifi.indexOfFirst { it is Key })
        val keysAtLoss = wifi.count { it is Key }
        assertTrue(sent(c.gen).none { it is Key || it is ReleaseAll })
        assertFalse("the overlay waits for a promotion", health.showOverlay)

        // The proof stalls to its deadline with Wi-Fi PONGs going on; typing on the frozen picture reaches nothing.
        var t = 0L
        while (m.migrating) {
            ticksWithPongs(100_000)
            t += 100_000
            if (t % 500_000 == 0L) health.tick(null)
            cap.onKey(KeyFrame(7, 31, 30, true, 0, false, false, false, now))
            assertFalse(health.inputAllowed)
            if (t >= 1_000_000) assertTrue("the overlay shows from the ladder's first step at $t us", health.showOverlay)
        }
        assertTrue(actions.any { it is Action.MigrationResult && !it.ok })
        assertTrue("the Wi-Fi session stays", m.inputAllowed && current == w)
        assertFalse(health.inputAllowed)
        assertEquals("no key reached the Mac after the loss", keysAtLoss, sent(w).count { it is Key })
        assertTrue(sent(c.gen).none { it is Key })
        assertTrue(healthLogs.toString(), healthLogs.any { it.startsWith("W video_health state=fault cause=video_lost") })
    }

    @Test fun aCloseAfterTheHeartbeatExpiredStaysFinal() {
        val w = streamingOnWifi()
        step(Event.Tick(0), 2_900_000)
        val c = openCandidate()
        ackOnly(c, mac(key = wrongKey))
        step(Event.Tick(0), 150_000) // stale
        assertTrue(step(Event.ControlClosed(w)).isEmpty()) // confirmed gone
        assertTrue(logs.any { it == "I migration_old_gone how=closed" })
        val r = step(Event.ControlClosed(c.gen))
        assertEquals(SessionMachine.REASON_PROOF_CLOSED, r.filterIsInstance<Action.MigrationResult>().single().reason)
        assertTrue(r.filterIsInstance<Action.Ui>().single().state is SessionUi.Disconnected) // reconnects
    }

    @Test fun cancelDuringTheProofLeavesTheWifiSession() {
        val w = streamingOnWifi()
        val c = openCandidate()
        ackOnly(c, mac())
        val since = actions.size
        val r = step(Event.CancelMigration)
        assertEquals(listOf(Action.CloseCandidate, Action.MigrationResult(usb, false, SessionMachine.REASON_CANCELLED)), r)
        assertWifiUntouched(w, since)
        assertTrue(c.records(cfg(2)).isEmpty()) // its late (authentic) record promotes nothing
    }

    @Test fun pairingAckOnACandidateAbortsAndTouchesNoRecord() {
        streamingOnWifi()
        val before = HashMap(f.kv.m)
        // with real crypto: PAIRING answer to a candidate (never user-initiated)
        val c = openCandidate()
        val r = c.first(mac(key = null), pairing = true)
        assertEquals(Action.MigrationResult(usb, false, SessionMachine.REASON_KEY), r.filterIsInstance<Action.MigrationResult>().single())
        assertTrue(m.inputAllowed)
        // as a plain PENDING_APPROVAL ack event
        val c2 = openCandidate()
        val r2 = step(Event.Received(c2.gen, HelloAck(0, HelloAck.PENDING_APPROVAL, 0, 0, "Mac mini")))
        assertEquals("ack_${HelloAck.PENDING_APPROVAL}", r2.filterIsInstance<Action.MigrationResult>().single().reason)
        assertEquals(before, f.kv.m) // neither the trusted nor the pending record changed
        assertTrue(m.inputAllowed)
    }

    @Test fun candidateOfAnotherTrustedHostIsNotATakeover() {
        val w = streamingOnWifi()
        val otherId = ByteArray(16) { (0x70 + it).toByte() }
        val otherKey = ByteArray(32) { 0x33 }
        f.store.put(otherId, otherKey)
        val since = actions.size
        val c = openCandidate()
        val r = c.first(mac(id = otherId, key = otherKey))
        assertEquals(Action.MigrationResult(usb, false, SessionMachine.REASON_KEY), r.filterIsInstance<Action.MigrationResult>().single())
        assertTrue(sent(c.gen).none { it is Ping }) // no proof PING to it
        assertWifiUntouched(w, since)
    }
}
