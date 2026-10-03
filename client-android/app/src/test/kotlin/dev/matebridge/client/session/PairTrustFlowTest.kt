package dev.matebridge.client.session

import dev.matebridge.client.protocol.AudioConfig
import dev.matebridge.client.protocol.AudioFrame
import dev.matebridge.client.protocol.AudioPrefs
import dev.matebridge.client.protocol.Bye
import dev.matebridge.client.protocol.Bytes
import dev.matebridge.client.protocol.Clipboard
import dev.matebridge.client.protocol.Codec
import dev.matebridge.client.protocol.DisplayRate
import dev.matebridge.client.protocol.FilesInfo
import dev.matebridge.client.protocol.Hello
import dev.matebridge.client.protocol.HelloAck
import dev.matebridge.client.protocol.Limits
import dev.matebridge.client.protocol.Message
import dev.matebridge.client.protocol.Ping
import dev.matebridge.client.protocol.Pong
import dev.matebridge.client.protocol.ProtocolException
import dev.matebridge.client.protocol.SettingsOpen
import dev.matebridge.client.protocol.StreamConfig
import dev.matebridge.client.protocol.StreamPrefs
import dev.matebridge.client.security.ClientHandshake
import dev.matebridge.client.security.HandshakeOutcome
import dev.matebridge.client.security.KeySchedule
import dev.matebridge.client.security.P256
import dev.matebridge.client.security.PairTrust
import dev.matebridge.client.security.ReadOnlyPairKeyStore
import dev.matebridge.client.security.RecordDecoder
import dev.matebridge.client.security.RecordSealer
import dev.matebridge.client.security.TrustFixture
import dev.matebridge.client.security.hexOf
import dev.matebridge.client.session.SessionMachine.Action
import dev.matebridge.client.session.SessionMachine.Event
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * T-150 (decision 0018) acceptance: a scripted fake host with real crypto drives [ClientHandshake], [FirstAck] (the
 * control reader's decision), [PairTrust] over a real [dev.matebridge.client.security.EncryptedPairKeyStore] and
 * [SessionMachine], exactly as the controller wires them.
 */
class PairTrustFlowTest {
    private val template = Hello(0, Bytes(ByteArray(16) { it.toByte() }), 2800, 1840, 360, 144, 0xFF, "MatePad")
    private val discovered = Endpoint("10.0.0.5", 47001)
    private val remembered = Endpoint("10.0.0.9", 47001)
    private val usb = ConnectMode.usbEndpoint
    private val token = "dav-token-7f3a91c2"
    private val f = TrustFixture()
    private val machineLogs = ArrayList<String>()
    private val m = SessionMachine(
        template, initialAudio = true, initialFiles = FilesInfo(FilesInfo.STATE_READY, 8443, token), trust = f.trust,
    ) { level, ev, fields -> machineLogs += "$level $ev $fields" }
    private var now = 1_000_000L

    private val mac = FakeHost(ByteArray(16) { (0x40 + it).toByte() }, "Mac mini")
    private val keyK = ByteArray(32) { 0x11 }

    // everything observed, for the "never" assertions
    private val events = ArrayList<Event>()
    private val actions = ArrayList<Action>()
    private val sent = ArrayList<Message>()
    private val uis = ArrayList<SessionUi>() // without promptGen (see [plain])
    private val rawUis = ArrayList<SessionUi>()
    private val audio = ArrayList<Message>()

    private fun step(e: Event, advanceUs: Long = 0): List<Action> {
        now += advanceUs
        events += e
        val a = m.handle(e, now)
        actions += a
        for (x in a) {
            if (x is Action.Send) sent += x.msg
            if (x is Action.Ui) {
                uis += x.state.plain()
                rawUis += x.state
            }
            if (x is Action.CloseControl) conn?.closed = true
        }
        return a
    }

    private fun ticks(totalUs: Long, everyUs: Long = 100_000): List<Action> {
        val out = ArrayList<Action>()
        var t = 0L
        while (t < totalUs) {
            out += step(Event.Tick(0), everyUs)
            t += everyUs
            // keep the connection alive like a real host answering our pings
            conn?.let { if (!it.closed && it.decoder != null) it.pong() }
        }
        return out
    }

    private inline fun <reified T : Action> List<Action>.only(): T = filterIsInstance<T>().single()
    private fun List<Action>.ui() = filterIsInstance<Action.Ui>().map { it.state.plain() }

    /** UI states compared without their prompt generation (asserted separately where it matters). */
    private fun SessionUi.plain(): SessionUi = when (this) {
        is SessionUi.AwaitingApproval -> copy(promptGen = -1)
        is SessionUi.StoredTrust -> copy(promptGen = -1)
        else -> this
    }

    /** The prompt generation the UI rendered last: what T-151 passes to `confirmTrust` / `cancelTrust`. */
    private fun shownGen(): Int = when (val u = rawUis.last()) {
        is SessionUi.AwaitingApproval -> u.promptGen
        is SessionUi.StoredTrust -> u.promptGen
        else -> -1
    }
    private fun List<Action>.sends() = filterIsInstance<Action.Send>().map { it.msg }

    private fun trustedOf(host: FakeHost) = f.store.get(host.hostId)
    private fun pendingOf(host: FakeHost) = f.store.getPending(host.hostId)

    /** The host side, with real crypto: answers one HELLO and seals its records. */
    class FakeHost(val hostId: ByteArray, val name: String) {
        /** T-207: the identity the UI sees for this host. */
        val tag: HostTag get() = HostTag.of(hostId)!!
        /** The pair key this Mac keeps for the tablet ("İzin ver"); PAIRED answers derive with it. */
        var key: ByteArray? = null
        var lastNewKey: ByteArray? = null
        var lastSas: String? = null
        private var sealer: RecordSealer? = null

        fun answer(clientHello: Hello, pairing: Boolean): Pair<HelloAck, ByteArray> {
            val eph = P256.generate()
            val ack = HelloAck(
                1, if (pairing) HelloAck.PENDING_APPROVAL else HelloAck.ACCEPTED, 42, 47002, name,
                if (pairing) HelloAck.KEY_PAIRING else HelloAck.KEY_PAIRED, Bytes(hostId), Bytes(ByteArray(16) { 9 }),
                Bytes(eph.publicBytes),
            )
            val payload = Codec.encodePayload(ack)
            val ecdh = P256.ecdh(eph.privateKey, P256.decodePublic(clientHello.clientEphPub.value))
            val prk = KeySchedule.prk(
                KeySchedule.ikm(if (pairing) null else key, ecdh),
                KeySchedule.transcriptHash(Codec.encodePayload(clientHello), payload),
            )
            sealer = RecordSealer(KeySchedule.controlH2c(prk))
            if (pairing) {
                lastNewKey = KeySchedule.newPairKey(prk)
                lastSas = KeySchedule.sas(prk)
            }
            return ack to payload
        }

        /** "İzin ver" on the Mac (also after the connection dropped: the orphan window keeps that handshake's key). */
        fun approve() {
            key = lastNewKey?.copyOf()
        }

        fun seal(vararg msgs: Message): ByteArray = msgs.fold(ByteArray(0)) { acc, msg -> acc + sealer!!.sealFrame(Codec.encode(msg)) }

        fun acceptedRecord() = HelloAck(1, HelloAck.ACCEPTED, 42, 47002, name)
    }

    /** One control connection as the controller runs it (reader decision = [FirstAck]). */
    inner class Conn(val gen: Int, val userInitiated: Boolean, private val trust: PairTrust = f.trust) {
        private val hs = ClientHandshake()
        val wireHello: Hello = hs.hello(template)
        lateinit var host: FakeHost
        var outcome: HandshakeOutcome? = null
        var decoder: RecordDecoder? = null
        var closed = false
        private var pongSeq = 0L

        /** The host's first write: the plaintext first ack, then [sameWrite] sealed records in the same write. */
        fun first(host: FakeHost, pairing: Boolean, vararg sameWrite: Message): List<Action> {
            val r = handshake(host, pairing)
            val out = ArrayList<Action>()
            for (e in r.events) out += step(e)
            return afterFirst(r, out, sameWrite)
        }

        /** The reader's part of [first] only: the handshake and its decision, events not yet delivered to the engine. */
        fun handshake(host: FakeHost, pairing: Boolean): FirstAck.Result {
            this.host = host
            val (ack, payload) = host.answer(wireHello, pairing)
            val o = hs.complete(ack, payload, trust, userInitiated)
            outcome = o
            return FirstAck.handle(gen, ack, o)
        }

        fun afterFirst(r: FirstAck.Result, out: MutableList<Action>, sameWrite: Array<out Message>): List<Action> {
            val sec = r.session
            if (r.terminal || sec == null) {
                closed = true // the reader stops here: [sameWrite] is never decrypted
                return out
            }
            decoder = RecordDecoder(Limits.CONTROL_MAX_PAYLOAD, sec.opener)
            if (sameWrite.isNotEmpty()) out += records(*sameWrite)
            return out
        }

        fun records(vararg msgs: Message): List<Action> {
            check(!closed) { "reading a closed connection" }
            val d = decoder!!
            d.feed(host.seal(*msgs))
            val out = ArrayList<Action>()
            while (true) {
                val msg = try {
                    d.next()
                } catch (e: ProtocolException) {
                    out += step(Event.ProtocolError(gen))
                    closed = true
                    return out
                } ?: break
                if (msg is AudioFrame || msg is AudioConfig) {
                    if (SessionMachine.deliversAudio(m.acceptedGen, gen)) audio += msg // the reader's audio gate
                } else {
                    out += step(Event.Received(gen, msg))
                }
            }
            return out
        }

        fun pong() = records(Pong(pongSeq++, 0, 0))
    }

    private var conn: Conn? = null

    /** A start; returns the connection it opened (HELLO sent), or null when it opened none. */
    private fun start(ep: Endpoint, user: Boolean): Conn? {
        conn?.closed = true
        val a = step(Event.Start(ep, userInitiated = user))
        val open = a.filterIsInstance<Action.OpenControl>().singleOrNull()
        if (open == null) {
            conn = null
            return null
        }
        assertEquals(user, open.userInitiated)
        return opened(open)
    }

    private fun opened(open: Action.OpenControl): Conn {
        conn?.closed = true
        assertEquals(listOf<Message>(template), step(Event.ControlOpened(open.gen)).sends())
        return Conn(open.gen, open.userInitiated).also { conn = it }
    }

    private fun sasShown(): String = (uis.last() as SessionUi.AwaitingApproval).code!!

    private fun clipboard() = Clipboard(1, 1, Bytes("secret".toByteArray()))
    private fun audioConfig() = AudioConfig(1, AudioConfig.STATE_STARTED, AudioConfig.FORMAT_PCM_S16LE, 48_000, 2, 480)
    private fun audioFrame() = AudioFrame(1, 0, 0, 0, 1, Bytes(ByteArray(4)))
    private fun cfg(id: Int) = StreamConfig(id, 1, 2800, 1840, 1400, 920, 60, 20000, 1, 1, 1, 1)

    private fun assertNothingGatedSent() {
        for (msg in sent) {
            assertTrue("sent $msg", msg is Hello || msg is Ping || msg is Pong || msg is Bye)
        }
    }

    /** User-initiated pairing up to the code prompt; returns the connection. */
    private fun pairUntilPrompt(ep: Endpoint = discovered): Conn {
        val rePairing = trustedOf(mac) != null
        val c = start(ep, user = true)!!
        val r = c.first(mac, pairing = true)
        assertEquals(SessionUi.AwaitingApproval("Mac mini", mac.lastSas, rePairing, needsLocalConfirm = true), r.ui().single())
        return c
    }

    // ---- acceptance criteria ----

    @Test fun knownHostWithoutLocalConfirmStaysClosed() {
        f.store.put(mac.hostId, keyK)
        val c = start(discovered, user = true)!!
        c.first(mac, pairing = true, mac.acceptedRecord()) // PAIRING ack and a sealed ACCEPTED in one write
        assertArrayEquals(keyK, trustedOf(mac)) // K unchanged
        val p = pendingOf(mac)!!
        assertArrayEquals(mac.lastNewKey, p.key)
        assertEquals(mac.lastSas, p.sas)
        assertFalse(m.inputAllowed)
        assertEquals(SessionUi.AwaitingApproval("Mac mini", mac.lastSas, true, needsLocalConfirm = true), uis.last())
        ticks(3_000_000)
        c.records(cfg(1), clipboard(), SettingsOpen, audioConfig(), audioFrame())
        ticks(1_000_000)
        assertFalse(m.inputAllowed)
        assertTrue(uis.none { it is SessionUi.Connected })
        assertNothingGatedSent()
        assertTrue(sent.any { it is Ping }) // only PING goes out (the host's silence limit is 5 s)
        assertTrue(actions.none { it is Action.DeliverClipboard || it is Action.OpenSettings || it is Action.OpenVideo || it is Action.ApplyConfig })
        assertTrue(audio.isEmpty())
    }

    @Test fun unknownHostWithoutLocalConfirmCreatesNoTrustedKey() {
        val c = start(discovered, user = true)!!
        c.first(mac, pairing = true, mac.acceptedRecord())
        ticks(2_000_000)
        assertNull(trustedOf(mac))
        assertNotNull(pendingOf(mac))
        assertFalse(m.inputAllowed)
        assertEquals(-1, m.acceptedGen)
        assertTrue(uis.none { it is SessionUi.Connected })
        assertNothingGatedSent()
    }

    @Test fun localhostSquatterNeverGetsTheFilesToken() {
        val squatter = FakeHost(ByteArray(16) { 0x66 }, "MatePad Files")
        // (a) reached through the AUTO probe / USB mode: not user-initiated
        val a = start(usb, user = false)!!
        val r = a.first(squatter, pairing = true, squatter.acceptedRecord())
        assertEquals(listOf<SessionUi>(SessionUi.PairingNeedsUser("MatePad Files", rePair = false, squatter.tag)), r.ui())
        assertTrue(r.any { it is Action.CloseControl })
        assertTrue(f.kv.m.isEmpty()) // nothing stored
        ticks(30_000_000)
        assertTrue(actions.none { it is Action.OpenControl && it.gen != a.gen }) // no automatic retry
        assertTrue(sent.none { it is FilesInfo })
        // (b) reached through a user-initiated connect: no FILES_INFO until the local confirmation
        val b = start(usb, user = true)!!
        b.first(squatter, pairing = true, squatter.acceptedRecord())
        ticks(2_000_000)
        assertTrue(sent.none { it is FilesInfo })
        val confirm = step(Event.TrustConfirmed(shownGen()))
        assertEquals(FilesInfo(FilesInfo.STATE_READY, 8443, token), confirm.sends().single { it is FilesInfo })
    }

    @Test fun autoDiscoveredFakeHostIsAbortedBeforeAnythingIsStored() {
        for (ep in listOf(discovered, remembered)) {
            val fake = FakeHost(ByteArray(16) { 0x77 }, "Totally a Mac")
            sent.clear()
            val c = start(ep, user = false)!!
            val r = c.first(fake, pairing = true, fake.acceptedRecord(), clipboard())
            assertEquals(listOf<SessionUi>(SessionUi.PairingNeedsUser("Totally a Mac", rePair = false, fake.tag)), r.ui())
            assertTrue(events.none { it is Event.Received && it.gen == c.gen }) // the sealed records are never processed
            assertTrue(events.none { it is Event.Secured && it.gen == c.gen })
            assertEquals(listOf<Message>(template), sent) // nothing but HELLO
            assertTrue(f.kv.m.isEmpty())
        }
        // with the stored Mac's host_id: rePair, and the trusted key stays byte-identical (no overwrite / DoS)
        f.store.put(mac.hostId, keyK)
        val stored = HashMap(f.kv.m)
        val impostor = FakeHost(mac.hostId, "Mac mini")
        val c = start(discovered, user = false)!!
        val r = c.first(impostor, pairing = true, impostor.acceptedRecord())
        assertEquals(listOf<SessionUi>(SessionUi.PairingNeedsUser("Mac mini", rePair = true, mac.tag)), r.ui())
        assertEquals(stored, f.kv.m)
        assertArrayEquals(keyK, trustedOf(mac))
        // the real Mac still connects silently with K (T-207: no host tag on the plaintext ack, only after a record)
        mac.key = keyK
        val ok = start(discovered, user = false)!!
        assertEquals(SessionUi.Connected("Mac mini", 0), ok.first(mac, pairing = false).ui().single())
    }

    @Test fun onlyAUserStartPairsAndItsRetriesStayUserInitiated() {
        // not user-initiated (discovery, saved endpoint, USB/AUTO probe, wake): abort, no retry
        for (wake in listOf(null, WakeTag(1, 1))) {
            val a = step(Event.Start(discovered, wake))
            val c = opened(a.only())
            assertFalse(c.userInitiated)
            assertTrue(c.first(mac, pairing = true).ui().single() is SessionUi.PairingNeedsUser)
            assertFalse(ticks(20_000_000).any { it is Action.OpenControl })
            assertNull(pendingOf(mac))
        }
        // user-initiated: pending
        val c = pairUntilPrompt()
        val firstCode = mac.lastSas
        val firstKey = mac.lastNewKey
        assertArrayEquals(firstKey, pendingOf(mac)!!.key)
        // the connection drops: the automatic retry is still user-initiated, and a new PAIRING replaces pending + code
        step(Event.ControlClosed(c.gen))
        c.closed = true
        val retry = ticks(1_200_000).only<Action.OpenControl>()
        assertTrue(retry.userInitiated)
        val c2 = opened(retry)
        val r = c2.first(mac, pairing = true)
        assertNotEquals(firstCode, mac.lastSas)
        assertEquals(mac.lastSas, (r.ui().single() as SessionUi.AwaitingApproval).code)
        assertArrayEquals(mac.lastNewKey, pendingOf(mac)!!.key)
        assertEquals(mac.lastSas, pendingOf(mac)!!.sas)
        // after acceptance the start is no longer user-initiated
        step(Event.TrustConfirmed(shownGen()))
        mac.approve()
        c2.records(mac.acceptedRecord())
        assertTrue(m.inputAllowed)
        step(Event.ControlClosed(c2.gen))
        c2.closed = true
        assertFalse(ticks(1_200_000).only<Action.OpenControl>().userInitiated)
    }

    @Test fun localConfirmThenHostAccepted() {
        step(Event.SetDisplayRate(120))
        val c = pairUntilPrompt()
        val confirm = step(Event.TrustConfirmed(shownGen()))
        assertArrayEquals(mac.lastNewKey, trustedOf(mac)) // promoted
        assertNull(pendingOf(mac))
        assertNotNull(f.store.getMarker(mac.hostId)) // the Mac's acceptance is not seen yet
        assertEquals(listOf<SessionUi>(SessionUi.AwaitingApproval("Mac mini", mac.lastSas, false, needsLocalConfirm = false)), confirm.ui())
        assertFalse(m.inputAllowed)
        mac.approve()
        val acc = c.records(mac.acceptedRecord(), cfg(4))
        assertEquals(
            listOf(Ping::class, StreamPrefs::class, DisplayRate::class, AudioPrefs::class, FilesInfo::class),
            acc.sends().map { it::class },
        )
        assertTrue(m.inputAllowed)
        assertNull(f.store.getMarker(mac.hostId)) // the sealed ACCEPTED cleared it
        val connectedAt = acc.indexOfFirst { it is Action.Ui && it.state is SessionUi.Connected }
        val lastSend = acc.indexOfLast { it is Action.Send }
        assertTrue(connectedAt > lastSend)
        assertEquals(4, acc.only<Action.ApplyConfig>().config.configId)
        assertTrue(acc.any { it is Action.OpenVideo })
    }

    @Test fun hostAcceptedThenLocalConfirmAppliesTheBufferedStreamConfig() {
        step(Event.SetDisplayRate(120))
        val c = pairUntilPrompt()
        mac.approve()
        val acc = c.records(mac.acceptedRecord(), cfg(1), cfg(2)) // STREAM_CONFIG before the confirmation: buffered
        assertEquals(SessionUi.AwaitingApproval("Mac mini", mac.lastSas, false, needsLocalConfirm = true), acc.ui().single())
        assertTrue(acc.none { it is Action.ApplyConfig || it is Action.OpenVideo || it is Action.Send })
        ticks(1_000_000)
        assertNothingGatedSent()
        val confirm = step(Event.TrustConfirmed(shownGen()))
        assertArrayEquals(mac.lastNewKey, trustedOf(mac))
        assertNull(pendingOf(mac))
        assertNull(f.store.getMarker(mac.hostId)) // the host had already accepted: no marker
        val kinds = confirm.map {
            when (it) {
                is Action.Send -> it.msg::class.simpleName
                is Action.Ui -> it.state::class.simpleName
                else -> it::class.simpleName
            }
        }
        assertEquals(
            listOf("Ping", "StreamPrefs", "DisplayRate", "AudioPrefs", "FilesInfo", "Connected", "ApplyConfig", "OpenVideo"),
            kinds,
        )
        assertEquals(2, confirm.only<Action.ApplyConfig>().config.configId) // latest only
        assertTrue(m.inputAllowed)
        // inbound is delivered now
        assertTrue(c.records(clipboard()).any { it is Action.DeliverClipboard })
        c.records(audioConfig())
        assertEquals(1, audio.size)
    }

    @Test fun orphanFlowConfirmOnTheStoredPromptThenPaired() {
        val c = pairUntilPrompt()
        val code = mac.lastSas
        step(Event.Stop) // the user leaves for Parsec; the connection closes
        c.closed = true
        mac.approve() // "İzin ver" in Parsec (orphan window)
        f.wallMs += 90_000 // background time does not drop it
        // back: the automatic reconnect opens no connection and shows the stored code
        assertNull(start(discovered, user = false))
        assertEquals(SessionUi.StoredTrust(code, confirmed = false), uis.last())
        val confirm = step(Event.TrustConfirmed(shownGen()))
        assertArrayEquals(mac.lastNewKey, trustedOf(mac))
        val open = confirm.only<Action.OpenControl>()
        assertEquals(discovered, open.endpoint) // the endpoint of the blocked start
        assertTrue(open.userInitiated)
        val c2 = opened(open)
        assertEquals(SessionUi.Connected("Mac mini", 0), c2.first(mac, pairing = false).ui().single())
        assertTrue(c2.outcome is HandshakeOutcome.Secure)
        c2.records(Pong(0, 0, 0))
        assertNull(f.store.getMarker(mac.hostId)) // the first authenticated record cleared the marker
        assertFalse(events.any { it is Event.ProtocolError })
    }

    @Test fun orphanFlowConnectWithoutConfirmShowsTheStoredCodeAndNeverDerives() {
        f.store.put(mac.hostId, keyK) // an older trusted key must not be used silently either
        val c = pairUntilPrompt()
        val code = mac.lastSas
        step(Event.Stop)
        c.closed = true
        mac.approve()
        assertNull(start(discovered, user = false))
        // "Bağlan" / "Yeniden eşleş" without confirming: the Mac answers PAIRED
        val c2 = start(discovered, user = true)!!
        val r = c2.first(mac, pairing = false, Pong(0, 0, 0))
        assertTrue(c2.outcome is HandshakeOutcome.PendingUnconfirmed)
        assertEquals(listOf<SessionUi>(SessionUi.StoredTrust(code, confirmed = false)), r.ui())
        assertTrue(r.any { it is Action.CloseControl })
        assertFalse(events.any { it is Event.ProtocolError })
        assertFalse(ticks(30_000_000).any { it is Action.OpenControl }) // no retry loop
        assertArrayEquals(keyK, trustedOf(mac))
        // confirm: the next connection completes PAIRED
        val c3 = opened(step(Event.TrustConfirmed(shownGen())).only())
        assertEquals(SessionUi.Connected("Mac mini", 0), c3.first(mac, pairing = false).ui().single())
        c3.records(Pong(0, 0, 0))
        assertFalse(events.any { it is Event.ProtocolError })
    }

    @Test fun returnBeforeTheMacApprovedOpensNoConnection() {
        // fresh pending record
        val c = pairUntilPrompt()
        val code = mac.lastSas
        step(Event.Stop)
        c.closed = true
        sent.clear()
        for (ep in listOf(discovered, remembered, usb)) {
            assertNull(start(ep, user = false)) // onStart reconnect, discovery, saved endpoint, USB/AUTO probe
            assertEquals(SessionUi.StoredTrust(code, confirmed = false), uis.last())
        }
        assertNull(step(Event.Start(discovered, WakeTag(3, 1))).filterIsInstance<Action.OpenControl>().singleOrNull()) // wake
        assertTrue(sent.isEmpty()) // no HELLO
        // "Yeniden eşleş": user-initiated; the Mac (not approved) answers PAIRING: new key and code
        val c2 = start(discovered, user = true)!!
        val r = c2.first(mac, pairing = true)
        assertNotEquals(code, mac.lastSas)
        assertEquals(mac.lastSas, (r.ui().single() as SessionUi.AwaitingApproval).code)
        assertEquals(mac.lastSas, pendingOf(mac)!!.sas)

        // only an awaiting-host marker: confirmed before leaving
        step(Event.TrustConfirmed(shownGen()))
        step(Event.Stop)
        c2.closed = true
        assertNull(start(discovered, user = false))
        assertEquals(SessionUi.StoredTrust(null, confirmed = true), uis.last())
        // the Mac approved meanwhile; "Bağlan" connects user-initiated and the PAIRED answer completes
        mac.approve()
        val c3 = start(discovered, user = true)!!
        assertEquals(SessionUi.Connected("Mac mini", 0), c3.first(mac, pairing = false).ui().single())
        c3.records(Pong(0, 0, 0))
        assertNull(f.store.getMarker(mac.hostId))
        step(Event.Stop)
        c3.closed = true
        assertNotNull(start(discovered, user = false)) // nothing unresolved any more
    }

    @Test fun confirmOnAMarkerOnlyPromptConnectsUserInitiated() {
        pairUntilPrompt()
        step(Event.TrustConfirmed(shownGen()))
        step(Event.Stop)
        assertNull(start(remembered, user = false))
        val open = step(Event.TrustConfirmed(shownGen())).only<Action.OpenControl>()
        assertTrue(open.userInitiated)
        assertEquals(remembered, open.endpoint)
    }

    @Test fun stalePendingOrMarkerNeitherBlocksNorIsUsed() {
        f.store.put(mac.hostId, keyK)
        mac.key = keyK
        val c = pairUntilPrompt()
        step(Event.Stop)
        c.closed = true
        f.wallMs += PairTrust.PENDING_MAX_AGE_MS
        // not blocked; a PAIRED answer derives silently with the trusted key
        val c2 = start(discovered, user = false)!!
        assertEquals(SessionUi.Connected("Mac mini", 0), c2.first(mac, pairing = false).ui().single())
        assertNull(pendingOf(mac)) // deleted on read
        assertArrayEquals(keyK, trustedOf(mac))
        c2.records(Pong(0, 0, 0))
        assertFalse(events.any { it is Event.ProtocolError })
        // same for a stale marker
        step(Event.Stop)
        val c3 = pairUntilPrompt()
        step(Event.TrustConfirmed(shownGen()))
        step(Event.Stop)
        c3.closed = true
        f.wallMs += PairTrust.PENDING_MAX_AGE_MS
        mac.approve()
        assertNotNull(start(discovered, user = false))
        assertNull(f.store.getMarker(mac.hostId))
        // and a future-dated pending record is stale too
        step(Event.Stop)
        pairUntilPrompt()
        step(Event.Stop)
        f.wallMs -= 1_000
        assertNotNull(start(discovered, user = false))
        assertNull(pendingOf(mac))
    }

    @Test fun cancelDropsPendingSendsByeAndIsTerminal() {
        for (hostAccepted in listOf(false, true)) {
            f.store.put(mac.hostId, keyK)
            val c = pairUntilPrompt()
            if (hostAccepted) {
                mac.approve()
                c.records(mac.acceptedRecord())
            }
            val r = step(Event.TrustCancelled(shownGen()))
            assertEquals(Bye(Bye.NORMAL), r.sends().single())
            assertEquals(true, r.only<Action.CloseControl>().graceful)
            assertTrue(r.indexOfFirst { it is Action.Send } < r.indexOfFirst { it is Action.CloseControl })
            assertEquals(listOf<SessionUi>(SessionUi.Failed(SessionUi.Cause.PAIR_CANCELLED)), r.ui())
            assertNull(pendingOf(mac))
            assertArrayEquals(keyK, trustedOf(mac))
            assertFalse(m.inputAllowed)
            assertFalse(ticks(30_000_000).any { it is Action.OpenControl })
            assertTrue(machineLogs.any { it.contains("pair_trust_cancelled reason=user") })
            // a user start connects again
            assertTrue(step(Event.Start(discovered, userInitiated = true)).any { it is Action.OpenControl })
            step(Event.Stop)
        }
    }

    @Test fun cancelOnAStoredPromptDropsItWithoutAConnection() {
        f.store.put(mac.hostId, keyK)
        pairUntilPrompt()
        step(Event.Stop)
        assertNull(start(discovered, user = false))
        val r = step(Event.TrustCancelled(shownGen()))
        assertTrue(r.none { it is Action.Send || it is Action.CloseControl || it is Action.OpenControl })
        assertEquals(listOf<SessionUi>(SessionUi.Failed(SessionUi.Cause.PAIR_CANCELLED)), r.ui())
        assertNull(pendingOf(mac))
        assertArrayEquals(keyK, trustedOf(mac))
    }

    @Test fun rejectedBeforeConfirmDropsPendingAndAfterConfirmKeepsTheKeyAndClearsTheMarker() {
        val c = pairUntilPrompt()
        val r = c.records(HelloAck(1, HelloAck.REJECTED, 0, 0, "Mac mini"))
        assertEquals(listOf<SessionUi>(SessionUi.Failed(SessionUi.Cause.REJECTED)), r.ui())
        assertNull(pendingOf(mac))
        assertNull(trustedOf(mac))

        val c2 = pairUntilPrompt()
        step(Event.TrustConfirmed(shownGen()))
        val promoted = mac.lastNewKey
        assertNotNull(f.store.getMarker(mac.hostId))
        c2.records(Bye(Bye.REJECTED))
        assertArrayEquals(promoted, trustedOf(mac))
        assertNull(f.store.getMarker(mac.hostId))
        assertEquals(SessionUi.Failed(SessionUi.Cause.REJECTED), uis.last())
    }

    @Test fun timeoutCountsOnlyVisiblePromptTime() {
        val c = pairUntilPrompt()
        step(Event.ConfirmPromptVisible(true))
        assertFalse(ticks(60_000_000, 1_000_000).any { it is Action.Ui && it.state is SessionUi.Failed })
        step(Event.ConfirmPromptVisible(false))
        // hidden time never counts (the host keeps us alive with PONGs)
        assertFalse(ticks(30_000_000, 1_000_000).any { it is Action.Ui && it.state is SessionUi.Failed })
        step(Event.ConfirmPromptVisible(true))
        assertFalse(ticks(59_000_000, 1_000_000).any { it is Action.Ui && it.state is SessionUi.Failed })
        val r = ticks(1_000_000, 1_000_000)
        assertTrue(r.ui().contains(SessionUi.Failed(SessionUi.Cause.PAIR_CANCELLED)))
        assertTrue(r.any { it is Action.Send && it.msg == Bye(Bye.NORMAL) })
        assertNull(pendingOf(mac))
        assertTrue(machineLogs.any { it.contains("pair_trust_cancelled reason=timeout") })
        c.closed = true

        // the stored prompt times out the same way, also across a hidden period
        pairUntilPrompt()
        step(Event.Stop)
        assertNull(start(discovered, user = false))
        step(Event.ConfirmPromptVisible(true))
        ticks(100_000_000, 1_000_000)
        step(Event.ConfirmPromptVisible(false))
        f.wallMs += 5 * 60_000
        ticks(300_000_000, 1_000_000)
        step(Event.ConfirmPromptVisible(true))
        assertFalse(ticks(19_000_000, 1_000_000).any { it is Action.Ui })
        assertEquals(SessionUi.Failed(SessionUi.Cause.PAIR_CANCELLED), ticks(1_000_000, 1_000_000).ui().single())
        assertNull(pendingOf(mac))
    }

    @Test fun forgetOnALiveSessionEndsItBeforeTheRecordsGo() {
        f.store.put(mac.hostId, keyK)
        mac.key = keyK
        val c = start(discovered, user = false)!!
        c.first(mac, pairing = false)
        assertTrue(m.inputAllowed) // a key is held (a down was sent)
        assertTrue(m.forgettableHost)
        val r = step(Event.ForgetHost)
        assertEquals(Bye(Bye.NORMAL), (r[0] as Action.Send).msg)
        assertEquals(Action.CloseControl(graceful = true), r[1])
        assertEquals(SessionUi.Idle, r.ui().single())
        assertFalse(m.inputAllowed) // only together with the close of the connection that carried the down
        assertNull(trustedOf(mac))
        assertTrue(machineLogs.any { it.contains("pair_forget live=1") })
        // the next PAIRED answer for that host has no key
        val c2 = start(discovered, user = false)!!
        assertEquals(listOf<SessionUi>(SessionUi.Failed(SessionUi.Cause.KEY_MISSING)), c2.first(mac, pairing = false).ui())
    }

    @Test fun review4AForgetThatDoesNotPersistIsNeverReportedAsDone() {
        f.store.put(mac.hostId, keyK)
        mac.key = keyK
        start(discovered, user = false)!!.first(mac, pairing = false)
        assertTrue(m.inputAllowed) // a key may be held
        val before = HashMap(f.kv.m)
        f.kv.failCommits = true // the removal's commit fails
        val r = step(Event.ForgetHost)
        // the session still ends with BYE + graceful close first (the host releases all input) ...
        assertEquals(Bye(Bye.NORMAL), (r[0] as Action.Send).msg)
        assertEquals(Action.CloseControl(graceful = true), r[1])
        assertFalse(m.inputAllowed)
        // ... but the forget is not reported as done: KEY_STORE_FAILED, records intact, the Mac stays forgettable
        assertEquals(listOf<SessionUi>(SessionUi.Failed(SessionUi.Cause.KEY_STORE_FAILED)), r.ui())
        assertEquals(before, f.kv.m)
        assertTrue(m.forgettableHost)
        assertTrue(machineLogs.any { it.contains("pair_forget_failed live=1") })
        assertFalse(machineLogs.any { it.contains("pair_forget live=") })
        assertFalse(ticks(10_000_000).any { it is Action.OpenControl }) // no silent reconnect meanwhile
        // the retry succeeds once the store works again
        f.kv.failCommits = false
        val retry = step(Event.ForgetHost)
        assertEquals(listOf<SessionUi>(SessionUi.Idle), retry.ui())
        assertNull(trustedOf(mac))
        assertFalse(m.forgettableHost)
        assertTrue(machineLogs.any { it.contains("pair_forget live=0") })
    }

    @Test fun forgetTouchesOnlyAnEligibleHost() {
        val other = FakeHost(ByteArray(16) { 0x50 }, "Other Mac")
        f.store.put(other.hostId, ByteArray(32) { 0x55 })
        f.store.put(mac.hostId, keyK)
        // a host_id seen only in an aborted PAIRING answer is never used
        val c = start(discovered, user = false)!!
        c.first(FakeHost(mac.hostId, "Mac mini"), pairing = true)
        assertFalse(m.forgettableHost)
        assertTrue(step(Event.ForgetHost).isEmpty())
        assertArrayEquals(keyK, trustedOf(mac))
        // after a PAIRED session with that Mac: its trusted, pending and marker records go, others stay
        mac.key = keyK
        start(discovered, user = false)!!.first(mac, pairing = false)
        f.trust.storePending(mac.hostId, ByteArray(32) { 1 }, "123456")
        step(Event.ForgetHost)
        assertNull(trustedOf(mac))
        assertNull(pendingOf(mac))
        assertArrayEquals(ByteArray(32) { 0x55 }, f.store.get(other.hostId))
        assertFalse(m.forgettableHost)
    }

    @Test fun aFailedPromotionCommitLeavesTheOldStateWhole() {
        f.store.put(mac.hostId, keyK)
        val c = pairUntilPrompt()
        val pending = mac.lastNewKey
        val before = HashMap(f.kv.m)
        f.kv.failCommits = true
        val r = step(Event.TrustConfirmed(shownGen()))
        assertEquals(listOf<SessionUi>(SessionUi.Failed(SessionUi.Cause.KEY_STORE_FAILED)), r.ui())
        assertEquals(before, f.kv.m) // old state: trusted K, pending P
        f.kv.failCommits = false
        assertArrayEquals(keyK, trustedOf(mac))
        assertArrayEquals(pending, pendingOf(mac)!!.key)
        assertFalse(m.inputAllowed)
        c.closed = true
    }

    @Test fun aPendingStoreFailureFailsTheSession() {
        f.kv.failCommits = true
        val c = start(discovered, user = true)!!
        val r = c.first(mac, pairing = true)
        assertEquals(listOf<SessionUi>(SessionUi.Failed(SessionUi.Cause.KEY_STORE_FAILED)), r.ui())
        assertTrue(f.kv.m.isEmpty())
    }

    @Test fun migrationCandidatesNeverStoreOrPend() {
        f.store.put(mac.hostId, keyK)
        mac.key = keyK
        val c = start(discovered, user = false)!!
        c.first(mac, pairing = false, cfg(1))
        val before = HashMap(f.kv.m)
        val cand = step(Event.Migrate(usb)).only<Action.OpenCandidate>()
        step(Event.ControlOpened(cand.gen))
        // the controller's candidate: read-only store, never user-initiated
        val candTrust = PairTrust(ReadOnlyPairKeyStore(f.store), { f.wallMs })
        val hs = ClientHandshake()
        val hello = hs.hello(template)
        val (ack, payload) = FakeHost(mac.hostId, "Mac mini").answer(hello, pairing = true)
        val res = FirstAck.handle(cand.gen, ack, hs.complete(ack, payload, candTrust, userInitiated = false))
        assertTrue(res.terminal)
        val r = res.events.flatMap { step(it) }
        assertEquals(Action.MigrationResult(usb, false, SessionMachine.REASON_KEY), r.only<Action.MigrationResult>())
        assertEquals(before, f.kv.m)
        assertTrue(m.inputAllowed) // the Wi-Fi session is intact
    }

    @Test fun secretsNeverReachTheLog() {
        f.store.put(mac.hostId, keyK)
        val codes = ArrayList<String>()
        val keys = ArrayList<ByteArray>()
        // pairing + confirm + accepted
        var c = pairUntilPrompt()
        codes += mac.lastSas!!; keys += mac.lastNewKey!!
        step(Event.TrustConfirmed(shownGen()))
        mac.approve()
        c.records(mac.acceptedRecord(), cfg(1), clipboard())
        // aborted pairing (not user-initiated)
        step(Event.Stop)
        start(remembered, user = false)!!.first(FakeHost(ByteArray(16) { 0x70 }, "Evil Mac"), pairing = true)
        // cancel
        c = pairUntilPrompt(); codes += mac.lastSas!!; keys += mac.lastNewKey!!
        step(Event.TrustCancelled(shownGen()))
        // timeout on a stored prompt
        c = pairUntilPrompt(); codes += mac.lastSas!!; keys += mac.lastNewKey!!
        step(Event.Stop)
        start(discovered, user = false)
        step(Event.ConfirmPromptVisible(true))
        ticks(SessionMachine.CONFIRM_TIMEOUT_US + 1_000_000, 1_000_000)
        // "Bağlan" (user start: the cancel latch holds automatic ones), then forget
        mac.key = keys[0]
        start(discovered, user = true)!!.first(mac, pairing = false)
        step(Event.ForgetHost)

        val lines = ArrayList<String>()
        lines += machineLogs
        lines += f.logs
        for (e in events) SessionController.eventLogLine(e, "")?.let { lines += "${it.level} ${it.ev} ${it.fields}" }
        assertTrue(lines.size > 20)
        val forbidden = ArrayList<String>()
        forbidden += codes
        forbidden += keys.map { hexOf(it) }
        forbidden += listOf(hexOf(keyK), token, hexOf(mac.hostId), "Mac mini", "Evil Mac", "secret")
        for (line in lines) for (bad in forbidden) assertFalse("'$line' leaks a secret", line.contains(bad, ignoreCase = true))
        assertTrue(lines.any { it.contains("pair_pending_stored") })
        assertTrue(lines.any { it.contains("pair_trust_confirmed") })
        assertTrue(lines.any { it.contains("pair_trust_cancelled reason=user") })
        assertTrue(lines.any { it.contains("pair_trust_cancelled reason=timeout") })
        assertTrue(lines.any { it.contains("pair_stored_prompt confirmed=0") })
        assertTrue(lines.any { it.contains("pairing_needs_user re_pair=0") })
        assertTrue(lines.any { it.contains("pair_forget live=1") })
    }

    // ---- Codex review (T-150) regressions ----

    @Test fun review1ConfirmAppliesOnlyToTheRenderedPrompt() {
        val c = pairUntilPrompt()
        val genA = shownGen()
        assertTrue(genA >= 0)
        // the connection drops and the user-initiated retry gets a new code B while the UI may still show A
        step(Event.ControlClosed(c.gen))
        val c2 = opened(ticks(1_200_000).only())
        c2.first(mac, pairing = true)
        val genB = shownGen()
        val keyB = mac.lastNewKey
        assertNotEquals(genA, genB)
        // a tap rendered for A is ignored (logged without the code): nothing is trusted, B stays pending
        assertTrue(step(Event.TrustConfirmed(genA)).isEmpty())
        assertTrue(step(Event.TrustCancelled(genA)).isEmpty())
        assertNull(trustedOf(mac))
        assertArrayEquals(keyB, pendingOf(mac)!!.key)
        assertTrue(machineLogs.contains("W pair_trust_event_stale kind=confirm"))
        // the tap rendered for B promotes B
        step(Event.TrustConfirmed(genB))
        assertArrayEquals(keyB, trustedOf(mac))
        // the stored prompt carries its own generation too
        step(Event.Stop)
        pairUntilPrompt()
        step(Event.Stop)
        assertNull(start(discovered, user = false))
        val stored = rawUis.last() as SessionUi.StoredTrust
        assertTrue(stored.promptGen >= 0)
        assertTrue(step(Event.TrustConfirmed(stored.promptGen + 1)).isEmpty())
        assertTrue(step(Event.TrustConfirmed(stored.promptGen)).any { it is Action.OpenControl })
    }

    @Test fun review2AStaleReaderNeverReplacesThePendingKeyBehindThePrompt() {
        // reader A derives, then pauses before the engine sees its events
        val a = start(discovered, user = true)!!
        val held = a.handshake(mac, pairing = true)
        val keyA = mac.lastNewKey!!.copyOf()
        // A is stopped; connection B pairs and shows its code
        step(Event.Stop)
        val b = pairUntilPrompt()
        val keyB = mac.lastNewKey!!.copyOf()
        val genB = shownGen()
        assertArrayEquals(keyB, pendingOf(mac)!!.key)
        // A resumes: its events reach the engine late and must not write anything
        val late = held.events.flatMap { step(it) }
        assertTrue(late.isEmpty())
        assertArrayEquals(keyB, pendingOf(mac)!!.key)
        assertNull(trustedOf(mac))
        // confirming B promotes B, never A
        step(Event.TrustConfirmed(genB))
        assertArrayEquals(keyB, trustedOf(mac))
        assertFalse(keyA.contentEquals(trustedOf(mac)))
        assertTrue(b.gen != a.gen)
    }

    @Test fun review2PromotionIsBoundToTheDisplayedRecord() {
        // live prompt: the pending record is replaced behind it (same code, other key) -> nothing is promoted
        pairUntilPrompt()
        val other = ByteArray(32) { 0x5A }
        f.trust.storePending(mac.hostId, other, mac.lastSas!!)
        val r = step(Event.TrustConfirmed(shownGen()))
        assertNull(trustedOf(mac))
        assertEquals(SessionUi.Failed(SessionUi.Cause.PAIR_CANCELLED), r.ui().last())
        assertTrue(machineLogs.any { it.contains("pair_trust_cancelled reason=stale") })
        // stored prompt: same
        pairUntilPrompt()
        step(Event.Stop)
        assertNull(start(discovered, user = false))
        f.trust.storePending(mac.hostId, other, mac.lastSas!!)
        val r2 = step(Event.TrustConfirmed(shownGen()))
        assertTrue(r2.none { it is Action.OpenControl })
        assertNull(trustedOf(mac))
        assertEquals(SessionUi.Failed(SessionUi.Cause.PAIR_CANCELLED), r2.ui().last())
    }

    @Test fun review3CancellationLatchHoldsAutomaticStartsUntilTheUser() {
        f.store.put(mac.hostId, keyK)
        mac.key = keyK
        pairUntilPrompt()
        mac.approve() // the Mac already holds the key the user is about to cancel
        step(Event.TrustCancelled(shownGen()))
        // automatic starts (already queued, onStart after a Stop, discovery, USB probe, wake) open nothing
        for (e in listOf(
            Event.Start(discovered), Event.Stop, Event.Start(remembered), Event.Start(usb), Event.Start(discovered, WakeTag(2, 1)),
        )) {
            val r = step(e)
            assertTrue(r.none { it is Action.OpenControl })
            if (e is Event.Start) assertEquals(listOf<SessionUi>(SessionUi.Failed(SessionUi.Cause.PAIR_CANCELLED)), r.ui())
        }
        assertTrue(machineLogs.any { it.contains("pair_cancel_latched") })
        assertFalse(ticks(30_000_000).any { it is Action.OpenControl })
        // a user start clears it
        assertTrue(step(Event.Start(discovered, userInitiated = true)).any { it is Action.OpenControl })
        step(Event.Stop)
        assertTrue(step(Event.Start(discovered)).any { it is Action.OpenControl })
        step(Event.Stop)
        // a timeout latches too; "Bu Mac'i unut" clears it
        pairUntilPrompt()
        step(Event.ConfirmPromptVisible(true))
        ticks(SessionMachine.CONFIRM_TIMEOUT_US + 1_000_000, 1_000_000)
        assertTrue(step(Event.Start(discovered)).none { it is Action.OpenControl })
        step(Event.ForgetHost)
        assertTrue(step(Event.Start(discovered)).any { it is Action.OpenControl })
    }

    // ---- T-207: the "asked" mark once the Mac is trusted again ----

    /** Feeds the UI states rendered since [from] to the activity's pick gate, in order; returns the new index. */
    private fun feed(pick: PairPick, from: Int): Int {
        for (s in rawUis.subList(from, rawUis.size)) pick.onUi(s)
        return rawUis.size
    }

    /**
     * Device session 2026-10-04: the Mac forgot the tablet ("Onaylı cihazları unut"), so in AUTO both the USB tunnel and
     * the Wi-Fi address answered PAIRING. The user pairs over Wi-Fi and trusts: the USB mark goes, AUTO migrates to USB
     * with no user action. An endpoint that claimed another host_id keeps its mark (decision 0018).
     */
    private fun trustOnWifiThenAutoMovesToUsb(knownBefore: Boolean) {
        if (knownBefore) f.store.put(mac.hostId, keyK)
        val pick = PairPick()
        val policy = AutoUsbPolicy()
        policy.onCable(CableState.CONNECTED, 0)
        var fed = 0
        // AUTO initial pick: the USB port is open, an automatic connect; the Mac answers PAIRING.
        start(usb, user = false)!!.first(mac, pairing = true)
        fed = feed(pick, fed)
        val usbPick = rawUis.last()
        assertEquals(SessionUi.PairingNeedsUser("Mac mini", knownBefore, mac.tag), usbPick)
        assertTrue(pick.isAsked(usb))
        assertTrue(AutoUsbPolicy.shouldFallBack(TransportMode.AUTO, true, usbPick))
        assertEquals("usb_asked", AutoUsbPolicy.fallbackReason(usbPick))
        policy.onTryResult(AutoUsbPolicy.Outcome.HARD_FAIL, 0) // fallBackToWifi
        // Wi-Fi: an impostor (same name, another host_id) is tried first, then the real Mac; both answer PAIRING.
        val impostor = FakeHost(ByteArray(16) { 0x77 }, "Mac mini")
        start(remembered, user = false)!!.first(impostor, pairing = true)
        start(discovered, user = false)!!.first(mac, pairing = true)
        fed = feed(pick, fed)
        assertTrue(pick.isAsked(remembered))
        assertEquals(AutoUsbPolicy.Step.NONE, policy.next(false, AutoUsbPolicy.stageOf(rawUis.last()), 10_000, pick.isAsked(usb)))
        // "Eşleş" on the real Mac's prompt: user start, the Mac says "İzin ver", the user "Kodlar aynı — Güven".
        val c = pairUntilPrompt(pick.pair()!!.endpoint)
        mac.approve()
        c.records(mac.acceptedRecord(), cfg(1))
        step(Event.TrustConfirmed(shownGen()))
        assertTrue(m.inputAllowed)
        fed = feed(pick, fed)
        assertEquals(mac.tag, (rawUis.last { it is SessionUi.Connected } as SessionUi.Connected).hostTag)
        val cleared = pick.takeCleared()
        assertEquals(listOf(usb), cleared)
        assertEquals("count=1 usb=1", TrustUiText.askedClearedFields(cleared))
        assertFalse(pick.isAsked(usb))
        assertTrue(pick.isAsked(remembered)) // another host_id: still out of automatic connects
        // MainActivity.onAskedCleared: AUTO tries USB at once (the accepted Wi-Fi session migrates).
        policy.onUsbUnblocked(10_000)
        assertEquals(AutoUsbPolicy.Step.MIGRATE, policy.next(false, AutoUsbPolicy.stageOf(rawUis.last()), 10_000, pick.isAsked(usb)))
        // The migration candidate to the USB tunnel (read-only store, not user-initiated) answers PAIRED with the new key.
        val cand = step(Event.Migrate(usb)).only<Action.OpenCandidate>()
        step(Event.ControlOpened(cand.gen))
        val candTrust = PairTrust(ReadOnlyPairKeyStore(f.store), { f.wallMs })
        val hs = ClientHandshake()
        val (ack, payload) = mac.answer(hs.hello(template), pairing = false)
        val res = FirstAck.handle(cand.gen, ack, hs.complete(ack, payload, candTrust, userInitiated = false))
        assertFalse(res.terminal)
        res.events.forEach { step(it) }
        val d = RecordDecoder(Limits.CONTROL_MAX_PAYLOAD, res.session!!.opener)
        d.feed(mac.seal(cfg(2), Pong(0, 0, 0)))
        val out = ArrayList<Action>()
        while (true) out += step(Event.Received(cand.gen, d.next() ?: break))
        assertEquals(Action.MigrationResult(usb, true, SessionMachine.REASON_OK), out.only<Action.MigrationResult>())
        assertTrue(m.inputAllowed)
    }

    @Test fun t207RePairOnWifiReturnsAutoToUsb() = trustOnWifiThenAutoMovesToUsb(knownBefore = true)

    @Test fun t207FreshPairOnWifiReturnsAutoToUsb() = trustOnWifiThenAutoMovesToUsb(knownBefore = false)

    @Test fun t207ATrustedPairedSessionClearsOnlyItsOwnHostsMarks() {
        f.store.put(mac.hostId, keyK)
        mac.key = keyK
        val pick = PairPick()
        var fed = 0
        // A localhost squatter with another host_id on the USB port, and one copying the Mac's host_id on another address.
        val squatter = FakeHost(ByteArray(16) { 0x66 }, "Mac mini")
        start(usb, user = false)!!.first(squatter, pairing = true)
        start(remembered, user = false)!!.first(FakeHost(mac.hostId, "Mac mini"), pairing = true)
        fed = feed(pick, fed)
        assertTrue(pick.isAsked(usb) && pick.isAsked(remembered))
        // The real Mac reconnects silently (PAIRED with the trusted key).
        val c = start(discovered, user = false)!!
        c.first(mac, pairing = false)
        fed = feed(pick, fed)
        assertNull((rawUis.last() as SessionUi.Connected).hostTag) // the plaintext ack proves nothing yet
        assertTrue(pick.takeCleared().isEmpty())
        c.records(cfg(1))
        step(Event.Tick(3), SessionMachine.UI_INTERVAL_US) // frames: the Connected update after an authenticated record
        fed = feed(pick, fed)
        assertEquals(mac.tag, (rawUis.last() as SessionUi.Connected).hostTag)
        assertEquals(listOf(remembered), pick.takeCleared()) // it claimed this Mac: one more automatic try
        assertTrue(pick.isAsked(usb)) // another host_id: the trust clears nothing for it
        assertEquals(AutoUsbPolicy.Step.NONE, AutoUsbPolicy().next(false, AutoUsbPolicy.Stage.ACCEPTED, 0, pick.isAsked(usb)))
        assertTrue(machineLogs.none { it.contains(hexOf(mac.hostId)) || it.contains(hexOf(squatter.hostId)) })
    }
}
