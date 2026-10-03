package dev.matebridge.client.security

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/** T-150 (decision 0018): pending / trusted / awaiting-host records and their wall-clock rules. */
class PairTrustTest {
    private val hostA = ByteArray(16) { 1 }
    private val hostB = ByteArray(16) { 2 }
    private val keyK = ByteArray(32) { 0x11 }
    private val keyP = ByteArray(32) { 0x22 }
    private val keyQ = ByteArray(32) { 0x33 }

    @Test fun pendingRecordRoundTripsWrappedAndBoundToItsHostAndKind() {
        val f = TrustFixture()
        f.trust.storePending(hostA, keyP, "123456")
        val p = f.store.getPending(hostA)!!
        assertArrayEquals(keyP, p.key)
        assertEquals("123456", p.sas)
        assertEquals(f.wallMs, p.createdAtWallMs)
        // neither the key nor the code is readable in the stored values
        assertTrue(f.kv.m.values.none { it.contains("22".repeat(32)) || it.contains(hexOf("123456".toByteArray())) })
        // a pending blob moved into the trusted slot (or to another host) does not unwrap: AAD = host_id ‖ "pending"
        val blob = f.kv.m.getValue("pairpend." + hexOf(hostA))
        f.kv.m["pairkey." + hexOf(hostA)] = blob
        assertNull(f.store.get(hostA))
        f.kv.m["pairpend." + hexOf(hostB)] = blob
        assertNull(f.store.getPending(hostB))
        assertNull(f.trust.freshPending(hostB)) // unreadable: dropped
        assertFalse(f.kv.m.containsKey("pairpend." + hexOf(hostB)))
    }

    @Test fun oneUnresolvedPairingAtATimeAndANewOneClearsThatHostsMarker() {
        val f = TrustFixture()
        f.trust.storePending(hostA, keyP, "111111")
        assertTrue(f.trust.promoteCurrent(hostA, awaitHost = true))
        assertTrue(f.trust.hasFreshMarker(hostA))
        f.trust.storePending(hostB, keyQ, "222222")
        f.trust.storePending(hostA, keyQ, "333333")
        assertNull(f.store.getPending(hostB)) // replaced by the newer pairing
        assertEquals("333333", f.store.getPending(hostA)!!.sas)
        assertFalse(f.trust.hasFreshMarker(hostA)) // the Mac answered PAIRING again: the old marker is moot
        assertArrayEquals(keyP, f.store.get(hostA)) // the trusted key is untouched
    }

    @Test fun promotionIsOneCommitAndAFailedCommitLeavesTheOldStateWhole() {
        val f = TrustFixture()
        f.store.put(hostA, keyK)
        f.trust.storePending(hostA, keyP, "123456")
        val before = HashMap(f.kv.m)
        f.kv.failCommits = true
        try {
            f.trust.promoteCurrent(hostA, awaitHost = true); fail()
        } catch (e: java.io.IOException) {
        }
        assertEquals(before, f.kv.m) // old state: trusted K, pending P, no marker
        assertArrayEquals(keyK, f.store.get(hostA))
        assertArrayEquals(keyP, f.store.getPending(hostA)!!.key)
        f.kv.failCommits = false
        val commits = f.kv.commits
        assertTrue(f.trust.promoteCurrent(hostA, awaitHost = true))
        assertEquals(commits + 1, f.kv.commits) // one commit: trusted + pending + marker
        assertArrayEquals(keyP, f.store.get(hostA))
        assertNull(f.store.getPending(hostA))
        assertEquals(f.wallMs, f.store.getMarker(hostA))
        assertFalse(f.trust.promoteCurrent(hostA, awaitHost = true)) // nothing pending any more
    }

    @Test fun promotionOnlyAcceptsTheRecordThatWasShown() {
        val f = TrustFixture()
        f.store.put(hostA, keyK)
        f.trust.storePending(hostA, keyP, "123456")
        val shown = f.store.getPending(hostA)!!.fingerprint()
        f.trust.storePending(hostA, keyQ, "123456") // replaced behind the prompt: same code, other key
        val before = HashMap(f.kv.m)
        assertFalse(f.trust.promote(hostA, awaitHost = true, fingerprint = shown))
        assertEquals(before, f.kv.m) // nothing written
        assertArrayEquals(keyK, f.store.get(hostA))
        assertFalse(f.trust.promote(hostA, awaitHost = true, fingerprint = PendingRecord.fingerprint(keyQ, "654321")))
        assertTrue(f.trust.promote(hostA, awaitHost = true, fingerprint = PendingRecord.fingerprint(keyQ, "123456")))
        assertArrayEquals(keyQ, f.store.get(hostA))
    }

    @Test fun promotionAfterTheHostAcceptedWritesNoMarker() {
        val f = TrustFixture()
        f.trust.storePending(hostA, keyP, "123456")
        assertTrue(f.trust.promoteCurrent(hostA, awaitHost = false))
        assertNull(f.store.getMarker(hostA))
    }

    @Test fun staleOrFutureDatedPendingRecordsAreDroppedOnReadAndNeverShown() {
        val f = TrustFixture()
        f.trust.storePending(hostA, keyP, "123456")
        f.wallMs += PairTrust.PENDING_MAX_AGE_MS - 1
        assertEquals("123456", f.trust.storedPrompt()!!.code) // still fresh
        f.wallMs += 1
        assertNull(f.trust.storedPrompt())
        assertNull(f.store.getPending(hostA)) // dropped
        assertTrue(f.logs.contains("pair_pending_expired kind=pending"))

        f.trust.storePending(hostA, keyP, "123456")
        f.wallMs -= 1 // the clock went back: dated in the future
        assertNull(f.trust.freshPending(hostA))
        assertNull(f.store.getPending(hostA))
    }

    @Test fun staleOrFutureDatedMarkersAreClearedOnRead() {
        val f = TrustFixture()
        f.trust.storePending(hostA, keyP, "123456")
        f.trust.promoteCurrent(hostA, awaitHost = true)
        val p = f.trust.storedPrompt()!!
        assertNull(p.code)
        assertArrayEquals(hostA, p.hostId)
        f.wallMs += PairTrust.PENDING_MAX_AGE_MS
        assertNull(f.trust.storedPrompt())
        assertNull(f.store.getMarker(hostA))
        assertArrayEquals(keyP, f.store.get(hostA)) // the confirmed key stays

        f.trust.storePending(hostA, keyQ, "654321")
        f.trust.promoteCurrent(hostA, awaitHost = true)
        f.wallMs -= 5
        assertFalse(f.trust.hasFreshMarker(hostA))
        assertNull(f.store.getMarker(hostA))
    }

    @Test fun aPendingRecordIsShownBeforeAMarker() {
        val f = TrustFixture()
        f.trust.storePending(hostA, keyP, "111111")
        f.trust.promoteCurrent(hostA, awaitHost = true)
        f.wallMs += 10
        f.trust.storePending(hostB, keyQ, "222222")
        val p = f.trust.storedPrompt()!!
        assertEquals("222222", p.code)
        assertArrayEquals(hostB, p.hostId)
    }

    @Test fun forgetRemovesOnlyThatHostsRecords() {
        val f = TrustFixture()
        f.store.put(hostA, keyK)
        f.store.put(hostB, keyQ)
        f.trust.storePending(hostA, keyP, "123456")
        f.trust.promoteCurrent(hostA, awaitHost = true)
        f.trust.storePending(hostA, keyQ, "222222")
        f.trust.forget(hostA)
        assertNull(f.store.get(hostA))
        assertNull(f.store.getPending(hostA))
        assertNull(f.store.getMarker(hostA))
        assertArrayEquals(keyQ, f.store.get(hostB))
    }

    @Test fun readOnlyStoreReadsButNeverWrites() {
        val f = TrustFixture()
        f.store.put(hostA, keyK)
        f.trust.storePending(hostA, keyP, "123456")
        val ro = ReadOnlyPairKeyStore(f.store)
        assertArrayEquals(keyK, ro.get(hostA))
        assertArrayEquals(keyP, ro.getPending(hostA)!!.key)
        val writes = listOf<() -> Unit>(
            { ro.putPending(hostA, PendingRecord(keyQ, "000000", 0)) }, { ro.promote(hostA, null, ByteArray(32)) },
            { ro.dropPending(hostA) }, { ro.clearMarker(hostA) }, { ro.remove(hostA) },
        )
        for (w in writes) {
            try {
                w(); fail()
            } catch (e: UnsupportedOperationException) {
            }
        }
        try {
            ro.put(hostA, keyQ); fail()
        } catch (e: java.io.IOException) {
        }
        // a stale pending record seen through a read-only store is ignored, not written (best effort)
        f.wallMs += PairTrust.PENDING_MAX_AGE_MS
        assertNull(PairTrust(ro, { f.wallMs }).freshPending(hostA))
        assertArrayEquals(keyK, f.store.get(hostA))
    }
}
