package dev.matebridge.client.security

import dev.matebridge.client.protocol.Bytes
import dev.matebridge.client.protocol.Codec
import dev.matebridge.client.protocol.Hello
import dev.matebridge.client.protocol.HelloAck
import dev.matebridge.client.protocol.Limits
import dev.matebridge.client.protocol.Ping
import dev.matebridge.client.protocol.ProtocolException
import dev.matebridge.client.protocol.VideoFrame
import java.io.ByteArrayInputStream
import java.io.EOFException
import java.util.Random
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class HandshakeMatrixTest {
    private val template = Hello(1, Bytes(ByteArray(16) { it.toByte() }), 2800, 1840, 360, 144, 255, "MatePad")
    private val hostId = ByteArray(16) { (0x30 + it).toByte() }

    private fun ack(status: Int, mode: Int, hostPub: ByteArray = P256.generate().publicBytes) =
        HelloAck(1, status, 5, 47002, "Mac", mode, Bytes(hostId), Bytes(ByteArray(16) { 9 }), Bytes(hostPub))

    private fun run(a: HelloAck, store: PairKeyStore = MemStore(), userInitiated: Boolean = true): HandshakeOutcome {
        val hs = ClientHandshake()
        hs.hello(template)
        return hs.complete(a, Codec.encodePayload(a), PairTrust(store), userInitiated)
    }

    private fun assertProtocolError(a: HelloAck, store: PairKeyStore = MemStore()) {
        try {
            run(a, store); fail("expected a protocol error")
        } catch (e: ProtocolException) {
        }
    }

    @Test
    fun terminalPlaintextAnswersPassThrough() {
        for (status in listOf(HelloAck.REJECTED, HelloAck.VERSION_MISMATCH, HelloAck.BUSY)) {
            val out = run(HelloAck(1, status, 0, 0, ""))
            assertEquals(status, (out as HandshakeOutcome.Plain).ack.status)
        }
    }

    @Test
    fun unencryptedPendingOrAcceptedIsADowngradeAndRejected() {
        assertProtocolError(HelloAck(1, HelloAck.PENDING_APPROVAL, 0, 0, "Mac"))
        assertProtocolError(HelloAck(1, HelloAck.ACCEPTED, 5, 47002, "Mac"))
    }

    @Test
    fun statusMustMatchKeyMode() {
        assertProtocolError(ack(HelloAck.PENDING_APPROVAL, HelloAck.KEY_PAIRED), MemStore().also { it.put(hostId, ByteArray(32)) })
        assertProtocolError(ack(HelloAck.ACCEPTED, HelloAck.KEY_PAIRING))
        assertProtocolError(ack(HelloAck.REJECTED, HelloAck.KEY_PAIRING))
        assertProtocolError(ack(HelloAck.BUSY, HelloAck.KEY_PAIRED))
    }

    @Test
    fun pairedWithoutAStoredKeyNeedsRePairing() {
        assertEquals(HandshakeOutcome.KeyMissing, run(ack(HelloAck.ACCEPTED, HelloAck.KEY_PAIRED)))
    }

    @Test
    fun pairedWithAKeyDerivesASession() {
        val store = MemStore().also { it.put(hostId, ByteArray(32) { 1 }) }
        val out = run(ack(HelloAck.ACCEPTED, HelloAck.KEY_PAIRED), store) as HandshakeOutcome.Secure
        assertNull(out.session.sas)
    }

    /** PAIRING handshake; returns the session and the pair key the host derives for the same handshake. */
    private fun pairingHandshake(store: PairKeyStore): Pair<SecureSession, ByteArray> {
        val hostKey = P256.generate()
        val hs = ClientHandshake()
        val hello = hs.hello(template)
        val a = ack(HelloAck.PENDING_APPROVAL, HelloAck.KEY_PAIRING, hostKey.publicBytes)
        val payload = Codec.encodePayload(a)
        val sess = (hs.complete(a, payload, PairTrust(store), userInitiated = true) as HandshakeOutcome.Secure).session
        val ecdh = P256.ecdh(hostKey.privateKey, P256.decodePublic(hello.clientEphPub.value))
        val prk = KeySchedule.prk(KeySchedule.ikm(null, ecdh), KeySchedule.transcriptHash(Codec.encodePayload(hello), payload))
        return sess to KeySchedule.newPairKey(prk)
    }

    @Test
    fun pairKeyIsKeptPendingAtTheFirstAckAndAPairedHandshakeNeverUsesItBeforeConfirmation() {
        val f = TrustFixture()
        val (sess, hostKey) = pairingHandshake(f.store)
        assertEquals(0, f.kv.commits) // nothing before the caller commits
        assertTrue(sess.storePending(f.trust))
        assertEquals(1, f.kv.commits)
        assertNull(f.store.get(hostId)) // T-150: not trusted before the local confirmation
        assertArrayEquals(hostKey, f.store.getPending(hostId)!!.key) // the key the Mac keeps on approval
        assertFalse(sess.storePending(f.trust)) // idempotent
        // Connection dropped before ACCEPTED: the pending key survives; a PAIRED answer is NOT derived from it.
        val hs = ClientHandshake()
        hs.hello(template)
        val a = ack(HelloAck.ACCEPTED, HelloAck.KEY_PAIRED)
        val out = hs.complete(a, Codec.encodePayload(a), f.trust, userInitiated = true)
        assertTrue(out is HandshakeOutcome.PendingUnconfirmed)
        assertArrayEquals(hostId, (out as HandshakeOutcome.PendingUnconfirmed).hostId)
        // after the confirmation the PAIRED handshake completes with the promoted key
        assertTrue(f.trust.promote(hostId, awaitHost = true))
        val hs2 = ClientHandshake()
        hs2.hello(template)
        val out2 = hs2.complete(a, Codec.encodePayload(a), f.trust, userInitiated = false)
        assertTrue(out2 is HandshakeOutcome.Secure)
        assertNull((out2 as HandshakeOutcome.Secure).session.sas)
    }

    @Test
    fun aNewPairingDoesNotReplaceTheOldKeyBeforeConfirmation() {
        val f = TrustFixture().also { it.store.put(hostId, ByteArray(32) { 9 }) }
        val (sess, hostKey) = pairingHandshake(f.store)
        assertTrue(sess.rePairing)
        sess.storePending(f.trust)
        assertArrayEquals(ByteArray(32) { 9 }, f.store.get(hostId))
        assertTrue(f.trust.promote(hostId, awaitHost = false))
        assertArrayEquals(hostKey, f.store.get(hostId))
    }

    @Test
    fun pairedSessionsNeverWriteTheStore() {
        val f = TrustFixture().also { it.store.put(hostId, ByteArray(32) { 1 }) }
        val a = ack(HelloAck.ACCEPTED, HelloAck.KEY_PAIRED)
        val hs = ClientHandshake(); hs.hello(template)
        val sess = (hs.complete(a, Codec.encodePayload(a), f.trust, userInitiated = true) as HandshakeOutcome.Secure).session
        assertFalse(sess.storePending(f.trust))
        assertEquals(1, f.kv.commits)
    }

    @Test
    fun aPairingAnswerOnAConnectionTheUserDidNotStartDerivesAndStoresNothing() {
        val f = TrustFixture()
        val out = run(ack(HelloAck.PENDING_APPROVAL, HelloAck.KEY_PAIRING), f.store, userInitiated = false)
        assertEquals(HandshakeOutcome.PairingNeedsUser("Mac", rePair = false), out)
        f.store.put(hostId, ByteArray(32) { 3 })
        val again = run(ack(HelloAck.PENDING_APPROVAL, HelloAck.KEY_PAIRING), f.store, userInitiated = false)
        assertEquals(HandshakeOutcome.PairingNeedsUser("Mac", rePair = true), again)
        assertArrayEquals(ByteArray(32) { 3 }, f.store.get(hostId))
        assertTrue(f.store.pendingHosts().isEmpty())
    }

    @Test
    fun invalidHostKeyIsAProtocolError() {
        val bad = ByteArray(65).also { it[0] = 4; it[64] = 1 }
        assertProtocolError(ack(HelloAck.PENDING_APPROVAL, HelloAck.KEY_PAIRING, bad))
        assertProtocolError(ack(HelloAck.PENDING_APPROVAL, HelloAck.KEY_PAIRING, ByteArray(65)))
    }

    @Test
    fun aDifferentPairKeyGivesDifferentKeysSoTheRecordsFail() {
        val hostKey = P256.generate()
        val hs = ClientHandshake()
        val hello = hs.hello(template)
        val a = ack(HelloAck.ACCEPTED, HelloAck.KEY_PAIRED, hostKey.publicBytes)
        val payload = Codec.encodePayload(a)
        val storeA = MemStore().also { it.put(hostId, ByteArray(32) { 1 }) }
        val sess = (hs.complete(a, payload, PairTrust(storeA), userInitiated = false) as HandshakeOutcome.Secure).session
        // Host side with another key for the same host_id: derives a different h2c key.
        val ecdh = P256.ecdh(hostKey.privateKey, P256.decodePublic(hello.clientEphPub.value))
        val prkWrong = KeySchedule.prk(
            KeySchedule.ikm(ByteArray(32) { 2 }, ecdh),
            KeySchedule.transcriptHash(Codec.encodePayload(hello), payload),
        )
        val rec = RecordSealer(KeySchedule.controlH2c(prkWrong)).seal(0x20, ByteArray(12))
        try {
            sess.opener.open(rec.copyOf(4), rec.copyOfRange(4, rec.size)); fail()
        } catch (e: ProtocolException) {
            assertEquals(ProtocolException.Kind.AUTH_FAILED, e.kind)
        }
        // ... and the right key works, which also shows client and host agree on the derivation.
        val prkRight = KeySchedule.prk(
            KeySchedule.ikm(ByteArray(32) { 1 }, ecdh),
            KeySchedule.transcriptHash(Codec.encodePayload(hello), payload),
        )
        val ok = RecordSealer(KeySchedule.controlH2c(prkRight)).seal(0x20, ByteArray(12))
        sess.opener.open(ok.copyOf(4), ok.copyOfRange(4, ok.size))
    }

    @Test
    fun plainFrameReaderConsumesExactlyOneFrame() {
        val a = Codec.encode(HelloAck(1, HelloAck.BUSY, 0, 0, ""))
        val trailing = byteArrayOf(1, 2, 3)
        val input = ByteArrayInputStream(a + trailing)
        val (ack, payload) = PlainFrames.readHelloAck(input)
        assertEquals(HelloAck.BUSY, ack.status)
        assertEquals(a.size - 5, payload.size)
        assertEquals(3, input.available()) // encrypted records behind it stay unread
    }

    @Test
    fun plainFrameReaderRejectsOversizeNonAckAndEof() {
        try {
            PlainFrames.read(ByteArrayInputStream(byteArrayOf(2, 1, 0, 1, 0)), 65_536); fail() // length 65537
        } catch (e: ProtocolException) {
            assertEquals(ProtocolException.Kind.OVERSIZE, e.kind)
        }
        try {
            PlainFrames.readHelloAck(ByteArrayInputStream(Codec.encode(Ping(1, 2)))); fail()
        } catch (e: ProtocolException) {
        }
        try {
            PlainFrames.read(ByteArrayInputStream(byteArrayOf(2, 10, 0, 0, 0, 1))); fail()
        } catch (e: EOFException) {
        }
    }
}

class RecordDecoderTest {
    private val key = ByteArray(32) { (it * 3).toByte() }

    private fun records(n: Int, from: Long = 0): List<ByteArray> {
        val s = RecordSealer(key, from)
        return (0 until n).map { s.sealFrame(Codec.encode(Ping(it.toLong(), it * 10L))) }
    }

    @Test
    fun decodesRecordsFedInArbitraryChunks() {
        val stream = records(40).reduce { a, b -> a + b }
        val rnd = Random(7)
        repeat(20) {
            val dec = RecordDecoder(Limits.CONTROL_MAX_PAYLOAD, RecordOpener(key))
            val got = ArrayList<dev.matebridge.client.protocol.Message>()
            var pos = 0
            while (pos < stream.size) {
                val n = minOf(1 + rnd.nextInt(60), stream.size - pos)
                dec.feed(stream, pos, n)
                got += dec.drain()
                pos += n
            }
            assertEquals(40, got.size)
            assertEquals(Ping(39, 390), got.last())
        }
    }

    @Test
    fun aFlippedByteFailsAndStaysFailed() {
        val recs = records(3)
        val bad = recs[1].copyOf().also { it[6] = (it[6].toInt() xor 1).toByte() }
        val dec = RecordDecoder(Limits.CONTROL_MAX_PAYLOAD, RecordOpener(key))
        dec.feed(recs[0] + bad + recs[2])
        assertEquals(Ping(0, 0), dec.next())
        repeat(2) {
            try {
                dec.next(); fail()
            } catch (e: ProtocolException) {
                assertEquals(ProtocolException.Kind.AUTH_FAILED, e.kind)
            }
        }
    }

    @Test
    fun reorderedOrDroppedRecordsFail() {
        val recs = records(3)
        for (stream in listOf(recs[1] + recs[0], recs[0] + recs[2])) {
            val dec = RecordDecoder(Limits.CONTROL_MAX_PAYLOAD, RecordOpener(key))
            dec.feed(stream)
            try {
                dec.drain(); fail()
            } catch (e: ProtocolException) {
            }
        }
    }

    @Test
    fun lengthBelowSeventeenAndAboveTheLimitFailAtTheHeader() {
        fun header(len: Long) = byteArrayOf(len.toByte(), (len shr 8).toByte(), (len shr 16).toByte(), (len shr 24).toByte())
        for (len in listOf(0L, 16L)) {
            val dec = RecordDecoder(Limits.CONTROL_MAX_PAYLOAD, RecordOpener(key))
            dec.feed(header(len))
            try {
                dec.next(); fail()
            } catch (e: ProtocolException) {
                assertEquals(ProtocolException.Kind.AUTH_FAILED, e.kind)
            }
        }
        val dec = RecordDecoder(Limits.CONTROL_MAX_PAYLOAD, RecordOpener(key))
        dec.feed(header(Limits.CONTROL_MAX_PAYLOAD + 18L)) // max is payload limit + 17
        try {
            dec.next(); fail()
        } catch (e: ProtocolException) {
            assertEquals(ProtocolException.Kind.OVERSIZE, e.kind)
        }
        // exactly at the limit is fine (no error until the body is complete)
        val ok = RecordDecoder(Limits.CONTROL_MAX_PAYLOAD, RecordOpener(key))
        ok.feed(header(Limits.CONTROL_MAX_PAYLOAD + 17L))
        assertNull(ok.next())
    }

    @Test
    fun videoFramesRoundTripAndUnknownTypesAreSkipped() {
        val s = RecordSealer(key)
        val frame = VideoFrame(1, 5, VideoFrame.KEYFRAME, 0, 1, 4, Bytes(byteArrayOf(0, 0, 0, 1)))
        val unknown = s.seal(0x7F, ByteArray(3))
        val video = s.sealFrame(Codec.encode(frame))
        val dec = RecordDecoder(Limits.VIDEO_MAX_PAYLOAD, RecordOpener(key))
        dec.feed(unknown + video)
        assertEquals(frame, dec.next())
        assertEquals(1, dec.skippedFrames)
    }

    @Test
    fun undrainedFeedingHitsTheBufferCap() {
        val dec = RecordDecoder(1000, RecordOpener(key))
        val chunk = ByteArray(RecordDecoder.READ_CHUNK)
        try {
            repeat(10) { dec.feed(chunk) }
            dec.next(); fail()
        } catch (e: ProtocolException) {
        }
    }
}

class PairKeyStoreTest {
    private val hostA = ByteArray(16) { 1 }
    private val hostB = ByteArray(16) { 2 }

    @Test
    fun roundTripReplaceAndPerHostIsolation() {
        val kv = MapKv()
        val s = EncryptedPairKeyStore(kv, FakeWrapper())
        assertNull(s.get(hostA))
        s.put(hostA, ByteArray(32) { 10 })
        s.put(hostB, ByteArray(32) { 20 })
        assertArrayEquals(ByteArray(32) { 10 }, s.get(hostA))
        assertArrayEquals(ByteArray(32) { 20 }, s.get(hostB))
        s.put(hostA, ByteArray(32) { 11 }) // a re-pairing replaces the old key
        assertArrayEquals(ByteArray(32) { 11 }, s.get(hostA))
    }

    @Test
    fun theStoredBlobDoesNotContainTheKey() {
        val kv = MapKv()
        EncryptedPairKeyStore(kv, FakeWrapper()).put(hostA, ByteArray(32) { 0x33 })
        assertTrue(kv.m.values.none { it.contains("33".repeat(32)) })
    }

    @Test
    fun aBlobMovedToAnotherHostOrCorruptedOrUnreadableIsTreatedAsMissing() {
        val kv = MapKv()
        val s = EncryptedPairKeyStore(kv, FakeWrapper())
        s.put(hostA, ByteArray(32) { 10 })
        val name = kv.m.keys.single()
        // moved to host B's slot: AAD (host_id) differs
        kv.m["pairkey." + hostB.joinToString("") { "%02x".format(it) }] = kv.m.getValue(name)
        assertNull(s.get(hostB))
        // corrupted
        kv.m[name] = kv.m.getValue(name).dropLast(2) + "zz"
        assertNull(s.get(hostA))
        kv.m[name] = "abc"
        assertNull(s.get(hostA))
        // wrapper key gone/invalidated
        s.put(hostA, ByteArray(32) { 10 })
        assertNull(EncryptedPairKeyStore(kv, FakeWrapper(ByteArray(32) { 6 })).get(hostA))
    }

    @Test
    fun onlyThirtyTwoByteKeysAreAccepted() {
        try {
            EncryptedPairKeyStore(MapKv(), FakeWrapper()).put(hostA, ByteArray(16)); fail()
        } catch (e: IllegalArgumentException) {
        }
    }
}

class VideoChannelTest {
    private val keys = { VideoKeys(ByteArray(32) { 1 }, ByteArray(32) { 2 }) }
    private val hello = dev.matebridge.client.protocol.VideoHello(1, 3, 99)

    @Test
    fun openingIsPlainVideoHelloThenASealedPingWithTheC2hKey() {
        val nonce = ByteArray(16) { it.toByte() }
        val bytes = VideoChannel(keys()).opening(hello, nonce, 1234)
        val helloFrame = Codec.encode(hello.copy(videoNonce = Bytes(nonce)))
        assertArrayEquals(helloFrame, bytes.copyOf(helloFrame.size))
        val rec = bytes.copyOfRange(helloFrame.size, bytes.size)
        val plain = RecordOpener(ByteArray(32) { 1 }).open(rec.copyOf(4), rec.copyOfRange(4, rec.size))
        assertEquals(0x20, plain[0].toInt() and 0xFF) // PING
        val decoded = Codec.decodePayload(0x20, plain.copyOfRange(1, plain.size))
        assertEquals(Ping(0, 1234), decoded)
    }

    @Test
    fun everyVideoConnectionGetsADifferentKeyScheduleAndNonce() {
        val secrets = SessionSecrets(ByteArray(32) { 7 }, pairing = false, hostId = ByteArray(16))
        val rnd = java.security.SecureRandom()
        val seen = HashSet<String>()
        repeat(50) {
            val nonce = ByteArray(16).also { rnd.nextBytes(it) }
            assertTrue(seen.add(nonce.joinToString("") { "%02x".format(it) }))
            val k = secrets.videoKeys(nonce)
            val rec = VideoChannel(k).opening(hello, nonce, 0)
            assertTrue(rec.size > 5 + 24)
        }
        val a = secrets.videoKeys(ByteArray(16) { 1 })
        val b = secrets.videoKeys(ByteArray(16) { 2 })
        assertTrue(!a.h2c.contentEquals(b.h2c) && !a.c2h.contentEquals(b.c2h))
    }

    @Test
    fun aFailingKeyStoreSurfacesFromStorePendingSoTheSessionCanFail() {
        val prk = ByteArray(32) { 4 }
        val sec = SecureSession(
            HelloAck(1, 1, 0, 0, ""), SessionSecrets(prk, true, ByteArray(16)),
            RecordSealer(ByteArray(32)), RecordOpener(ByteArray(32)), "000000", false,
        )
        val f = TrustFixture().also { it.kv.failCommits = true }
        try {
            sec.storePending(f.trust); fail()
        } catch (e: java.io.IOException) {
        }
        assertTrue(f.kv.m.isEmpty())
        // a read-only (migration candidate) store refuses too
        val sec2 = SecureSession(
            HelloAck(1, 1, 0, 0, ""), SessionSecrets(ByteArray(32) { 5 }, true, ByteArray(16)),
            RecordSealer(ByteArray(32)), RecordOpener(ByteArray(32)), "000000", false,
        )
        try {
            sec2.storePending(PairTrust(ReadOnlyPairKeyStore(TrustFixture().store))); fail()
        } catch (e: UnsupportedOperationException) {
        }
    }
}
