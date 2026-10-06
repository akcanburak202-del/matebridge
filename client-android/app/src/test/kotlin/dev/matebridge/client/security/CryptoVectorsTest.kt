package dev.matebridge.client.security

import dev.matebridge.client.protocol.Codec
import dev.matebridge.client.protocol.FrameDecoder
import dev.matebridge.client.protocol.Hello
import dev.matebridge.client.protocol.HelloAck
import dev.matebridge.client.protocol.ProtocolException
import java.io.File
import java.security.InvalidKeyException
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/** Every value of protocol/fixtures/crypto_vectors.json (PROTOCOL.md section 9), reproduced from the fixed private keys. */
class CryptoVectorsTest {
    @Suppress("UNCHECKED_CAST")
    private val v: Map<String, Any> = MiniJson.parse(File(dir, "crypto_vectors.json").readText()) as Map<String, Any>

    @Suppress("UNCHECKED_CAST")
    private fun obj(name: String) = v[name] as Map<String, String>
    private val inputs get() = obj("inputs")

    private fun inp(name: String) = hex(inputs.getValue(name))

    private fun ecdhVector() = hex(v["ecdh"] as String)

    private fun mode(name: String) = obj(name)

    private fun helloPayload() = inp("hello_payload")

    @Test
    fun ecdhMatchesFromBothSides() {
        val client = P256.privateFromScalar(inp("client_eph_priv"))
        val host = P256.privateFromScalar(inp("host_eph_priv"))
        assertArrayEquals(ecdhVector(), P256.ecdh(client, P256.decodePublic(inp("host_eph_pub"))))
        assertArrayEquals(ecdhVector(), P256.ecdh(host, P256.decodePublic(inp("client_eph_pub"))))
    }

    @Test
    fun publicKeysRoundTripThroughDecodeAndEncode() {
        for (name in listOf("client_eph_pub", "host_eph_pub")) {
            val bytes = inp(name)
            val key = P256.decodePublic(bytes) as java.security.interfaces.ECPublicKey
            assertArrayEquals(bytes, P256.encodePublic(key))
        }
    }

    @Test
    fun invalidPublicKeysAreRejected() {
        val good = inp("host_eph_pub")
        fun bad(b: ByteArray) {
            try {
                P256.decodePublic(b); fail("accepted an invalid point")
            } catch (e: InvalidKeyException) {
            }
        }
        bad(good.copyOf(64)) // short
        bad(good + byteArrayOf(0)) // long
        bad(good.copyOf().also { it[0] = 2 }) // compressed prefix
        bad(good.copyOf().also { it[0] = 0 })
        bad(good.copyOf().also { it[64] = (it[64] + 1).toByte() }) // off the curve
        bad(ByteArray(65).also { it[0] = 4 }) // (0, 0) is not on P-256
        bad(ByteArray(65) { 0xFF.toByte() }.also { it[0] = 4 }) // coordinates >= p
    }

    @Test
    fun generatedEphemeralKeysAgree() {
        val a = P256.generate()
        val b = P256.generate()
        assertEquals(65, a.publicBytes.size)
        assertEquals(4, a.publicBytes[0].toInt())
        assertArrayEquals(
            P256.ecdh(a.privateKey, P256.decodePublic(b.publicBytes)),
            P256.ecdh(b.privateKey, P256.decodePublic(a.publicBytes)),
        )
    }

    @Test
    fun transcriptHashPrkKeysSasAndPairKeyForBothModes() {
        val ecdh = ecdhVector()
        val hello = helloPayload()
        for ((name, ackName, pairKey) in listOf(
            Triple("paired", "hello_ack_paired_payload", inp("pair_key")),
            Triple("pairing", "hello_ack_pairing_payload", null),
        )) {
            val m = mode(name)
            val hash = KeySchedule.transcriptHash(hello, inp(ackName))
            assertArrayEquals("$name transcript_hash", hex(m.getValue("transcript_hash")), hash)
            val ikm = KeySchedule.ikm(pairKey, ecdh)
            assertArrayEquals("$name ikm", hex(m.getValue("ikm")), ikm)
            val prk = KeySchedule.prk(ikm, hash)
            assertArrayEquals("$name prk", hex(m.getValue("prk")), prk)
            assertArrayEquals("$name key_control_c2h", hex(m.getValue("key_control_c2h")), KeySchedule.controlC2h(prk))
            assertArrayEquals("$name key_control_h2c", hex(m.getValue("key_control_h2c")), KeySchedule.controlH2c(prk))
            val nonce = inp("video_nonce")
            assertArrayEquals("$name key_video_c2h", hex(m.getValue("key_video_c2h")), KeySchedule.videoC2h(prk, nonce))
            assertArrayEquals("$name key_video_h2c", hex(m.getValue("key_video_h2c")), KeySchedule.videoH2c(prk, nonce))
            // decision 0035: both nonces of a file connection are in the info string
            val cn = inp("client_files_nonce")
            val hn = inp("host_files_nonce")
            assertArrayEquals("$name key_files_c2h", hex(m.getValue("key_files_c2h")), KeySchedule.filesC2h(prk, cn, hn))
            assertArrayEquals("$name key_files_h2c", hex(m.getValue("key_files_h2c")), KeySchedule.filesH2c(prk, cn, hn))
            val viaSecrets = SessionSecrets(prk, pairing = false, hostId = ByteArray(16)).filesKeys(cn, hn)
            assertArrayEquals("$name SessionSecrets.filesKeys c2h", hex(m.getValue("key_files_c2h")), viaSecrets.c2h)
            assertArrayEquals("$name SessionSecrets.filesKeys h2c", hex(m.getValue("key_files_h2c")), viaSecrets.h2c)
            if (name == "pairing") {
                assertArrayEquals("sas_bytes", hex(m.getValue("sas_bytes")), KeySchedule.sasBytes(prk))
                assertEquals("sas", m.getValue("sas"), KeySchedule.sas(prk))
                assertArrayEquals("new_pair_key", hex(m.getValue("new_pair_key")), KeySchedule.newPairKey(prk))
            }
        }
    }

    @Test
    fun sasKeepsLeadingZeros() {
        // the vector's own code starts with a zero ("044261"): the padded 6-digit form is what is compared
        assertEquals(6, mode("pairing").getValue("sas").length)
        assertTrue(mode("pairing").getValue("sas").startsWith("0"))
    }

    @Test
    fun framesAreReproducedDecryptedAndRejectedWhenTampered() {
        @Suppress("UNCHECKED_CAST")
        val frames = v["frames"] as List<Map<String, String>>
        assertTrue(frames.isNotEmpty())
        for (f in frames) {
            val key = hex(f.getValue("key"))
            val counter = f.getValue("counter").toLong()
            val type = f.getValue("type").removePrefix("0x").toInt(16)
            val payload = hex(f.getValue("payload"))
            val frame = hex(f.getValue("frame"))
            assertArrayEquals("nonce", hex(f.getValue("nonce")), Records.nonce(counter))
            assertArrayEquals("seal counter $counter", frame, RecordSealer(key, counter).seal(type, payload))
            assertArrayEquals(
                "sealFrame counter $counter", frame,
                RecordSealer(key, counter).sealFrame(plainFrame(type, payload)),
            )
            val plain = RecordOpener(key, counter).open(frame.copyOf(4), frame.copyOfRange(4, frame.size))
            assertEquals(type, plain[0].toInt() and 0xFF)
            assertArrayEquals(payload, plain.copyOfRange(1, plain.size))
            // wrong counter
            assertRejected { RecordOpener(key, counter + 1).open(frame.copyOf(4), frame.copyOfRange(4, frame.size)) }
            // every single flipped byte (header = AAD, ciphertext, tag)
            for (i in frame.indices) {
                val bad = frame.copyOf().also { it[i] = (it[i].toInt() xor 0x01).toByte() }
                assertRejected { RecordOpener(key, counter).open(bad.copyOf(4), bad.copyOfRange(4, bad.size)) }
            }
            // wrong key
            assertRejected {
                RecordOpener(key.copyOf().also { it[0] = (it[0].toInt() xor 1).toByte() }, counter)
                    .open(frame.copyOf(4), frame.copyOfRange(4, frame.size))
            }
        }
    }

    @Test
    fun sealedCounterOrderFollowsCallOrder() {
        val key = ByteArray(32) { it.toByte() }
        val s = RecordSealer(key)
        val o = RecordOpener(key)
        for (i in 0 until 5) {
            val rec = s.seal(0x20, byteArrayOf(i.toByte()))
            val plain = o.open(rec.copyOf(4), rec.copyOfRange(4, rec.size))
            assertEquals(i, plain[1].toInt())
        }
        val replay = s.seal(0x20, byteArrayOf(9))
        o.open(replay.copyOf(4), replay.copyOfRange(4, replay.size))
        assertRejected { o.open(replay.copyOf(4), replay.copyOfRange(4, replay.size)) } // replayed record
    }

    @Test
    fun handshakeReproducesTheVectorsEndToEnd() {
        val eph = EphemeralKeyPair(P256.privateFromScalar(inp("client_eph_priv")), inp("client_eph_pub"))
        val nonce = hex("c0c1c2c3c4c5c6c7c8c9cacbcccdcecf")
        // Paired: known pair_key for host_id.
        val ackPayload = inp("hello_ack_paired_payload")
        val hs = ClientHandshake(eph, nonce)
        val template = Codec.decodePayload(1, helloPayload()) as Hello
        val hello = hs.hello(template)
        assertArrayEquals("HELLO payload", helloPayload(), Codec.encodePayload(hello))
        val ack = Codec.decodePayload(2, ackPayload) as HelloAck
        val store = MemStore()
        store.put(ack.hostId.value, inp("pair_key"))
        val out = hs.complete(ack, ackPayload, PairTrust(store), userInitiated = false) as HandshakeOutcome.Secure
        assertNull(out.session.sas)
        assertEquals(false, out.session.rePairing)
        @Suppress("UNCHECKED_CAST")
        val frames = v["frames"] as List<Map<String, String>>
        val c2h = frames.first { it.getValue("counter") == "0" && it.getValue("type") == "0x20" }
        assertArrayEquals(hex(c2h.getValue("frame")), out.session.sealer.seal(0x20, hex(c2h.getValue("payload"))))
        val h2c = frames.first { it.getValue("counter") == "5" }
        val opener = out.session.opener
        // advance the opener to counter 5 with five real records, then the vector record must open
        val hostSealer = RecordSealer(hex(mode("paired").getValue("key_control_h2c")))
        repeat(5) {
            val rec = hostSealer.seal(0x20, ByteArray(12))
            opener.open(rec.copyOf(4), rec.copyOfRange(4, rec.size))
        }
        val f = hex(h2c.getValue("frame"))
        val plain = opener.open(f.copyOf(4), f.copyOfRange(4, f.size))
        assertEquals(0x16, plain[0].toInt())
        val video = out.session.secrets.videoKeys(inp("video_nonce"))
        assertArrayEquals(hex(mode("paired").getValue("key_video_h2c")), video.h2c)
        assertArrayEquals(hex(mode("paired").getValue("key_video_c2h")), video.c2h)
        val vframe = frames.first { it.getValue("type") == "0x41" }
        assertArrayEquals(
            hex(vframe.getValue("frame")),
            RecordSealer(video.h2c).seal(0x41, hex(vframe.getValue("payload"))),
        )
    }

    @Test
    fun fileConnectionRecordsOfTheVectorsOpenAndSealWithTheDerivedKeys() {
        @Suppress("UNCHECKED_CAST")
        val frames = v["frames"] as List<Map<String, String>>
        val m = mode("paired")
        val cn = inp("client_files_nonce")
        val hn = inp("host_files_nonce")
        val ch = FilesChannel(SessionSecrets(hex(m.getValue("prk")), pairing = false, hostId = ByteArray(16)).filesKeys(cn, hn))
        // c2h counter 0: the proof PING; c2h counter 1: an HTTP answer as FILES_DATA (what the tablet's pump seals)
        val c2h = frames.filter { it.getValue("key") == m.getValue("key_files_c2h") }.sortedBy { it.getValue("counter").toLong() }
        assertEquals(2, c2h.size)
        for (f in c2h) {
            assertArrayEquals(
                "files c2h counter ${f.getValue("counter")}", hex(f.getValue("frame")),
                ch.sealer.seal(f.getValue("type").removePrefix("0x").toInt(16), hex(f.getValue("payload"))),
            )
        }
        // h2c counter 0: the Mac's first FILES_DATA decodes to the message on the tablet's file decoder
        val h2c = frames.single { it.getValue("key") == m.getValue("key_files_h2c") }
        val dec = ch.decoder
        dec.feed(hex(h2c.getValue("frame")))
        val msg = dec.next() as dev.matebridge.client.protocol.FilesData
        assertEquals("OPTIONS / HTTP/1.1", String(msg.data.value, Charsets.US_ASCII))
        // the keys differ per direction, per nonce and from the control and video keys of the same session
        val other = KeySchedule.filesC2h(hex(m.getValue("prk")), cn, ByteArray(16))
        assertTrue(!other.contentEquals(hex(m.getValue("key_files_c2h"))))
        assertTrue(!hex(m.getValue("key_files_c2h")).contentEquals(hex(m.getValue("key_files_h2c"))))
        assertTrue(!hex(m.getValue("key_files_c2h")).contentEquals(hex(m.getValue("key_control_c2h"))))
        assertTrue(!hex(m.getValue("key_files_h2c")).contentEquals(hex(m.getValue("key_video_h2c"))))
    }

    @Test
    fun filesChannelWipesTheKeyArraysItWasGiven() {
        val keys = FilesKeys(ByteArray(32) { 1 }, ByteArray(32) { 2 })
        FilesChannel(keys)
        assertTrue(keys.c2h.all { it == 0.toByte() } && keys.h2c.all { it == 0.toByte() })
    }

    @Test
    fun pairingHandshakeShowsTheVectorCodeAndKeepsTheNewKeyPendingUntilConfirmed() {
        val eph = EphemeralKeyPair(P256.privateFromScalar(inp("client_eph_priv")), inp("client_eph_pub"))
        val hs = ClientHandshake(eph, hex("c0c1c2c3c4c5c6c7c8c9cacbcccdcecf"))
        hs.hello(Codec.decodePayload(1, helloPayload()) as Hello)
        val ackPayload = inp("hello_ack_pairing_payload")
        val ack = Codec.decodePayload(2, ackPayload) as HelloAck
        assertEquals(HelloAck.PENDING_APPROVAL, ack.status)
        val f = TrustFixture()
        val sec = (hs.complete(ack, ackPayload, f.trust, userInitiated = true) as HandshakeOutcome.Secure).session
        assertEquals(mode("pairing").getValue("sas"), sec.sas)
        assertEquals(false, sec.rePairing)
        // T-150: the new key is kept pending at the first ack (before the Mac's approval), once; it is not trusted.
        assertNull(f.store.get(ack.hostId.value))
        assertEquals(true, sec.storePendingForTest(f.trust))
        assertNull(f.store.get(ack.hostId.value)) // not replaced (nor created) before the local confirmation
        val pending = f.store.getPending(ack.hostId.value)!!
        assertArrayEquals(hex(mode("pairing").getValue("new_pair_key")), pending.key)
        assertEquals(mode("pairing").getValue("sas"), pending.sas)
        assertEquals(false, sec.storePendingForTest(f.trust))
        assertEquals(1, f.kv.commits)
        // only the confirmation makes it the trusted key
        assertTrue(f.trust.promoteCurrent(ack.hostId.value, awaitHost = false))
        assertArrayEquals(hex(mode("pairing").getValue("new_pair_key")), f.store.get(ack.hostId.value))
        // control keys of the PAIRING session
        assertArrayEquals(
            RecordSealer(hex(mode("pairing").getValue("key_control_c2h"))).seal(0x20, byteArrayOf(1)),
            sec.sealer.seal(0x20, byteArrayOf(1)),
        )
    }

    @Test
    fun rePairingIsFlaggedAndTheOldKeyStaysUntilConfirmed() {
        val eph = EphemeralKeyPair(P256.privateFromScalar(inp("client_eph_priv")), inp("client_eph_pub"))
        val hs = ClientHandshake(eph, hex("c0c1c2c3c4c5c6c7c8c9cacbcccdcecf"))
        hs.hello(Codec.decodePayload(1, helloPayload()) as Hello)
        val ackPayload = inp("hello_ack_pairing_payload")
        val ack = Codec.decodePayload(2, ackPayload) as HelloAck
        val f = TrustFixture().also { it.store.put(ack.hostId.value, ByteArray(32) { 7 }) }
        val sec = (hs.complete(ack, ackPayload, f.trust, userInitiated = true) as HandshakeOutcome.Secure).session
        assertEquals(true, sec.rePairing)
        sec.storePendingForTest(f.trust)
        assertArrayEquals(ByteArray(32) { 7 }, f.store.get(ack.hostId.value)) // not replaced before confirmation
        assertArrayEquals(hex(mode("pairing").getValue("new_pair_key")), f.store.getPending(ack.hostId.value)!!.key)
    }

    @Test
    fun wipedSecretsRefuseToDeriveAnything() {
        val s = SessionSecrets(ByteArray(32) { 1 }, pairing = true, hostId = ByteArray(16))
        s.wipe()
        for (f in listOf<() -> Any>({ s.sas() }, { s.newPairKey() }, { s.videoKeys(ByteArray(16)) }, { s.filesKeys(ByteArray(16), ByteArray(16)) })) {
            try {
                f(); fail()
            } catch (e: IllegalStateException) {
            }
        }
    }

    @Test
    fun frameDecoderStillReadsTheFixtureHelloAckWithKeyFields() {
        val d = FrameDecoder.control()
        d.feed(dev.matebridge.client.protocol.FixtureTest.fixture("hello_ack_pending"))
        val ack = d.next() as HelloAck
        assertEquals(HelloAck.KEY_PAIRING, ack.keyMode)
        assertNotNull(ack.hostEphPub)
    }

    private fun assertRejected(block: () -> Unit) {
        try {
            block(); fail("record was accepted")
        } catch (e: ProtocolException) {
            assertEquals(ProtocolException.Kind.AUTH_FAILED, e.kind)
        }
    }

    companion object {
        val dir = File(System.getProperty("matebridge.fixtures") ?: "../../protocol/fixtures")
    }
}

/** type + payload framed like the plaintext format of PROTOCOL.md section 2 (5-byte header), without needing a Message instance. */
private fun plainFrame(type: Int, payload: ByteArray): ByteArray =
    byteArrayOf(type.toByte(), payload.size.toByte(), (payload.size ushr 8).toByte(), (payload.size ushr 16).toByte(), (payload.size ushr 24).toByte()) + payload

fun hex(s: String): ByteArray = ByteArray(s.length / 2) { s.substring(it * 2, it * 2 + 2).toInt(16).toByte() }

/** In-memory [PairKeyStore] for tests. */
class MemStore : PairKeyStore {
    private val map = HashMap<String, ByteArray>()
    var puts = 0
    override fun get(hostId: ByteArray) = map[hostId.joinToString("") { "%02x".format(it) }]?.copyOf()
    override fun put(hostId: ByteArray, key: ByteArray) {
        puts++
        map[hostId.joinToString("") { "%02x".format(it) }] = key.copyOf()
    }
}

/** Tiny JSON reader for the flat crypto_vectors.json (objects, arrays, strings only). */
object MiniJson {
    fun parse(text: String): Any = Parser(text).run { ws(); value().also { ws(); check(pos == text.length) } }

    private class Parser(val t: String) {
        var pos = 0
        fun ws() { while (pos < t.length && t[pos].isWhitespace()) pos++ }
        fun value(): Any {
            ws()
            return when (t[pos]) {
                '{' -> obj()
                '[' -> arr()
                '"' -> str()
                else -> error("unsupported JSON at $pos")
            }
        }

        fun str(): String {
            check(t[pos++] == '"')
            val sb = StringBuilder()
            while (t[pos] != '"') {
                if (t[pos] == '\\') pos++
                sb.append(t[pos++])
            }
            pos++
            return sb.toString()
        }

        fun obj(): Map<String, Any> {
            pos++
            val m = LinkedHashMap<String, Any>()
            ws()
            if (t[pos] == '}') { pos++; return m }
            while (true) {
                ws(); val k = str(); ws(); check(t[pos++] == ':')
                m[k] = value(); ws()
                if (t[pos] == ',') { pos++; continue }
                check(t[pos++] == '}'); return m
            }
        }

        fun arr(): List<Any> {
            pos++
            val l = ArrayList<Any>()
            ws()
            if (t[pos] == ']') { pos++; return l }
            while (true) {
                l += value(); ws()
                if (t[pos] == ',') { pos++; continue }
                check(t[pos++] == ']'); return l
            }
        }
    }
}
