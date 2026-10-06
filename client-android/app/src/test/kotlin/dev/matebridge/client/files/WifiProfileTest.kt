package dev.matebridge.client.files

import java.io.File
import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/** T-266 (decision 0035): the Wi-Fi profile of the file server's pure parts. */
class WifiProfileTest {
    @get:Rule val tmp = TemporaryFolder()

    // ---- TokenBucket.setRate ----

    @Test fun setRateRaiseAndLowerApplyFromNow() {
        var t = 0L
        val b = TokenBucket(1_000_000, 100_000, nanoTime = { t }, sleepNs = { t += it })
        assertEquals(0L, b.reserve(100_000)) // empty
        b.setRate(2_000_000)
        assertEquals(2_000_000L, b.rateBytesPerSec)
        assertEquals(50_000_000L, b.reserve(100_000)) // 100 KB of debt at 2 MB/s = 50 ms
        b.setRate(500_000)
        // The debt of 100 KB stays in bytes; the new 100 KB now stands behind it: 200 KB at 0.5 MB/s = 400 ms.
        assertEquals(400_000_000L, b.reserve(100_000))
    }

    @Test fun setRateCreditsTheTimeBeforeTheChangeAtTheOldRate() {
        var t = 0L
        val b = TokenBucket(1_000_000, 1_000_000, nanoTime = { t }, sleepNs = { t += it })
        b.reserve(1_000_000)
        t += 500_000_000 // 0.5 s at 1 MB/s = 500 KB
        b.setRate(10_000_000)
        assertEquals(0L, b.reserve(500_000)) // exactly the credit; not 5 MB from the new rate
        assertTrue(b.reserve(1) > 0)
    }

    @Test fun aRaiseDuringASleepEndsItEarly() {
        var t = 0L
        lateinit var b: TokenBucket
        var calls = 0
        val sleeps = ArrayList<Long>()
        b = TokenBucket(100_000, 10_000, nanoTime = { t }, sleepNs = {
            sleeps += it
            t += it
            if (++calls == 1) b.setRate(10_000_000) // raised while asleep
        })
        assertEquals(0L, b.reserve(10_000))
        val slept = b.acquire(100_000) // 1 s at the old rate
        // First slice 100 ms (10 KB paid at the old rate), then the other 90 KB at 10 MB/s = 9 ms.
        assertEquals(listOf(100_000_000L, 9_000_000L), sleeps)
        assertEquals(109_000_000L, slept)
    }

    @Test fun aCutDuringASleepExtendsIt() {
        var t = 0L
        lateinit var b: TokenBucket
        var calls = 0
        b = TokenBucket(1_000_000, 10_000, nanoTime = { t }, sleepNs = {
            t += it
            if (++calls == 1) b.setRate(100_000)
        })
        b.reserve(10_000)
        val slept = b.acquire(200_000) // 200 ms at 1 MB/s
        // 100 ms paid 100 KB; 100 KB left at 0.1 MB/s = 1 s.
        assertEquals(1_100_000_000L, slept)
    }

    @Test fun usbBehaviourIsUnchangedWithoutSetRate() {
        var t = 0L
        val b = TokenBucket(20_000_000, 256 * 1024, nanoTime = { t }, sleepNs = { t += it })
        var sent = 0L
        repeat(500) { b.acquire(65_536); sent += 65_536 }
        assertEquals(20_000_000.0, (sent - 256 * 1024) * 1e9 / t, 20_000.0)
    }

    // ---- small lane ----

    private class Fake : ByteBudget {
        val taken = ArrayList<Long>()
        override fun acquire(n: Long): Long { taken += n; return 0 }
    }

    @Test fun theFirstBytesOfAnExchangeUseTheSmallLane() {
        val main = Fake()
        val small = Fake()
        val lane = LaneBudget(main, small, 32 * 1024).newLane()
        lane.acquire(1000)
        lane.acquire(16 * 1024)
        assertEquals(listOf(1000L, 16 * 1024L), small.taken)
        assertTrue(main.taken.isEmpty())
        lane.acquire(16 * 1024) // crosses the 32 KiB: the rest of the 32 KiB small, then main
        assertEquals(32 * 1024L - 1000 - 16 * 1024, small.taken.last())
        assertEquals(listOf(1000L + 16 * 1024 + 16 * 1024 - 32 * 1024), main.taken)
        lane.acquire(64 * 1024) // all main now
        assertEquals(64 * 1024L, main.taken.last())
        assertEquals(3, small.taken.size)
        lane.reset() // the next exchange
        lane.acquire(2000)
        assertEquals(2000L, small.taken.last())
    }

    @Test fun withoutASmallLaneEverythingIsMain() {
        val main = Fake()
        val lane = LaneBudget(main, null, 32 * 1024).newLane()
        lane.acquire(100)
        lane.acquire(100_000)
        assertEquals(listOf(100L, 100_000L), main.taken)
    }

    @Test fun aSmallRequestDoesNotQueueBehindABigTransfersDebt() {
        var t = 0L
        val mainBucket = TokenBucket(2_000_000, 64 * 1024, nanoTime = { t }, sleepNs = { t += it })
        val smallBucket = TokenBucket(256_000, 32 * 1024, nanoTime = { t }, sleepNs = { t += it })
        val lanes = LaneBudget(mainBucket, smallBucket, 32 * 1024)
        // Eight big transfers have booked a burst each: ~250 ms of debt on the main bucket.
        repeat(8) { mainBucket.reserve(64 * 1024) }
        assertTrue(mainBucket.reserve(1) > 200_000_000L)
        // A PROPFIND answer of 20 KB takes no main debt at all.
        val lane = lanes.newLane()
        assertEquals(0L, lane.acquire(20 * 1024))
        // The same bytes through the main bucket would have waited.
        assertTrue(mainBucket.reserve(20 * 1024) > 200_000_000L)
    }

    @Test fun theSmallLaneIsOffByDefaultAndOnInTheWifiProfile() {
        assertEquals(0L, FilesConfig().smallRateBytesPerSec)
        assertEquals(20_000_000L, FilesConfig().rateBytesPerSec)
        assertEquals(256L * 1024, FilesConfig().burstBytes)
        assertEquals(64 * 1024, FilesConfig().bufferBytes)
        val w = FilesConfig.wifi(2_250_000)
        assertEquals(2_250_000L, w.rateBytesPerSec)
        assertEquals(64L * 1024, w.burstBytes)
        assertEquals(16 * 1024, w.bufferBytes)
        assertEquals(8, w.maxConnections)
        assertEquals(4, w.overflowConnections)
        assertEquals(256_000L, w.smallRateBytesPerSec)
        assertEquals(32L * 1024, w.smallBurstBytes)
        assertEquals(32L * 1024, w.smallThresholdBytes)
        assertFalse(w.readOnly)
        assertTrue(FilesConfig.wifi(1, readOnly = true).readOnly)
    }

    // ---- rate formula ----

    @Test fun capFormulaTable() {
        assertEquals(2_250_000L, filesCapBytesPerSec(30_000))
        assertEquals(3_000_000L, filesCapBytesPerSec(15_000))
        assertEquals(500_000L, filesCapBytesPerSec(60_000))
        assertEquals(3_000_000L, filesCapBytesPerSec(1)) // clamped at the top
        assertEquals(3_000_000L, filesCapBytesPerSec(24_000)) // exactly 3.0
        assertEquals(500_000L, filesCapBytesPerSec(100_000)) // clamped at the bottom
        assertEquals(500_000L, filesCapBytesPerSec(44_000)) // exactly 0.5
        assertEquals(1_000_000L, filesCapBytesPerSec(40_000))
        assertEquals(2_000_000L, filesCapBytesPerSec(0)) // unknown: 2 MB/s, not the lowest
        assertEquals(2_000_000L, filesCapBytesPerSec(-5))
    }

    // ---- Wi-Fi root ----

    private fun storage(): File = tmp.newFolder("storage").canonicalFile

    @Test fun wifiRootIsCreatedOnBothLevels() {
        val s = storage()
        val d = WifiFilesRoot.directory(s)!!
        assertEquals(File(File(s, "MateBridge"), "Wi-Fi"), d)
        assertTrue(d.isDirectory)
        File(d, "keep.txt").writeText("x")
        assertEquals(d, WifiFilesRoot.directory(s)) // existing: used as it is
        assertEquals("x", File(d, "keep.txt").readText())
        // The USB folder keeps its own choice and stays the parent.
        assertEquals(File(s, "MateBridge"), FilesScope(FilesRoot.MATEBRIDGE, false).directory(s))
        assertEquals("root=wifi", WifiFilesRoot.LOG_FIELDS)
    }

    @Test fun wifiRootWithOnlyMateBridgePresentMakesTheSubFolder() {
        val s = storage()
        File(s, "MateBridge").mkdir()
        File(s, "MateBridge/other.txt").writeText("usb only")
        val d = WifiFilesRoot.directory(s)!!
        assertEquals(File(s, "MateBridge/Wi-Fi"), d)
        assertEquals(listOf<String>(), d.list()!!.toList()) // the sibling file is not inside the Wi-Fi root
    }

    @Test fun wifiRootNeverFallsBackToTheParentOrTheStorage() {
        // MateBridge is a file.
        val s1 = tmp.newFolder("s1").canonicalFile
        File(s1, "MateBridge").writeText("not a folder")
        assertNull(WifiFilesRoot.directory(s1))
        // Wi-Fi is a file.
        val s2 = tmp.newFolder("s2").canonicalFile
        File(s2, "MateBridge").mkdir()
        File(s2, "MateBridge/Wi-Fi").writeText("not a folder")
        assertNull(WifiFilesRoot.directory(s2))
        // Wi-Fi is a link, even to a folder inside the storage; the target is left alone.
        val s3 = tmp.newFolder("s3").canonicalFile
        File(s3, "MateBridge").mkdir()
        File(s3, "DCIM").mkdir()
        Files.createSymbolicLink(File(s3, "MateBridge/Wi-Fi").toPath(), File(s3, "DCIM").toPath())
        assertNull(WifiFilesRoot.directory(s3))
        // MateBridge is a link: the sub-folder is not made through it.
        val s4 = tmp.newFolder("s4").canonicalFile
        File(s4, "Elsewhere").mkdir()
        Files.createSymbolicLink(File(s4, "MateBridge").toPath(), File(s4, "Elsewhere").toPath())
        assertNull(WifiFilesRoot.directory(s4))
        assertEquals(listOf<String>(), File(s4, "Elsewhere").list()!!.toList())
        // A dangling link in the place of Wi-Fi.
        val s5 = tmp.newFolder("s5").canonicalFile
        File(s5, "MateBridge").mkdir()
        Files.createSymbolicLink(File(s5, "MateBridge/Wi-Fi").toPath(), File(s5, "nowhere").toPath())
        assertNull(WifiFilesRoot.directory(s5))
        assertFalse(File(s5, "nowhere").exists())
        // No storage at all.
        assertNull(WifiFilesRoot.directory(File(tmp.root, "no-storage")))
    }

    // ---- fast 404 names ----

    @Test fun probeNamesAreExactlyTheKnownMacOsProbes() {
        for (n in listOf(".hidden", ".localized", ".Trashes", ".Spotlight-V100", ".fseventsd", ".VolumeIcon.icns", ".TemporaryItems")) {
            assertTrue(n, MetaStore.isProbeName(n))
            assertFalse(n, MetaStore.isMetaName(n))
        }
        for (n in listOf("._x", ".DS_Store", "hidden", ".Hidden", ".hidden2", "a.hidden", "", ".git")) assertFalse(n, MetaStore.isProbeName(n))
        assertTrue(MetaStore.isMetaName("._x")) // unchanged
        assertTrue(MetaStore.isMetaName(".DS_Store"))
    }
}
