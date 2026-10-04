package dev.matebridge.client.video

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PaceTraceTest {
    private fun csv(t: PaceTrace) = StringBuilder().also { t.writeCsv(it) }.toString().trim().split("\n")

    @Test fun headerHasAllColumns() {
        val lines = csv(PaceTrace(4))
        assertEquals(1, lines.size)
        assertEquals(PaceTrace.CSV_COLS, lines[0].split(",").size)
        assertTrue(lines[0].contains(",own_slot_ns,recv_ns,decrypted_ns,queued_ns,input_ns,bytes,rx_action,"))
        assertTrue(lines[0].endsWith(",rx_action,open_start_ns,open_init_ns,open_final_ns,taken_ns,inbuf_ns,copied_ns,inbuf_pre,latch_slot_ns,latch_period_ns")) // T-220: latch columns last
        assertTrue(lines[0].startsWith("seq,capture_us,ready_ns,"))
        assertTrue(lines[0].contains(",path,late_drop,collided,released_slot_ns,release_ns,render_ns,action"))
    }

    @Test fun ringOverflowKeepsNewestRowsInOrder() {
        val t = PaceTrace(3)
        for (i in 1..5) t.record(i.toLong(), 0, 0, null, 0, false, false, 0)
        assertEquals(3, t.size)
        val lines = csv(t)
        assertEquals(4, lines.size)
        assertEquals(listOf("3", "4", "5"), lines.drop(1).map { it.substringBefore(',') })
    }

    @Test fun updatesOfEvictedFramesAreIgnored() {
        val t = PaceTrace(2)
        val old = t.record(1, 0, 0, null, 0, false, false, 0)
        t.record(2, 0, 0, null, 0, false, false, 0)
        t.record(3, 0, 0, null, 0, false, false, 0)
        t.onRelease(old, 5, 6, 7) // must not corrupt the row that reuses the slot
        val rows = csv(t).drop(1).map { it.split(",") }
        assertEquals(listOf("2", "3"), rows.map { it[0] })
        assertTrue(rows.all { it[22] == "pending" })
    }

    @Test fun releaserReportsActionsAndProbeValuesLandInTheRow() {
        val t = PaceTrace(8)
        val counters = PresentCounters()
        val rel = SlotReleaser(object : SlotReleaser.Sink {
            override fun release(idx: Int, renderNs: Long) {}
            override fun discard(idx: Int) {}
        }, counters)
        rel.trace = t
        val probe = PaceProbe().also { it.path = PaceProbe.PATH_LOCKED; it.k = 1; it.badRun = 3; it.periodNs = 8_333_333 }
        val a = t.record(1, 10, 100, probe, 1000, false, false, 0)
        rel.submit(1, 1000, 900, 10_000, 0, 100, a)
        val b = t.record(2, 20, 110, probe, 1000, false, true, 0)
        rel.submit(2, 1000, 900, 10_000, 0, 100, b) // same slot: replaces a
        rel.flushAll()
        val rows = csv(t).drop(1).map { it.split(",") }
        assertEquals("replace", rows[0][22])
        assertEquals("release", rows[1][22])
        assertEquals("locked", rows[1][16])
        assertEquals("3", rows[1][15])
        assertEquals("1000", rows[1][19])
        assertEquals("900", rows[1][21])
        val c = t.record(3, 30, 120, probe, 1000, false, false, 0)
        rel.submit(3, 1000, 900, 10_000, 0, 100, c) // slot already released: moves one slot later
        rel.flushAll()
        val last = csv(t).last().split(",")
        assertEquals("move", last[22])
        assertEquals("1100", last[19])
    }

    @Test fun pacerFillsTheProbe() {
        val v = VsyncClock(60f)
        for (i in 0..5) v.onVsync(i * 16_666_667L)
        val p = AdaptivePacer(v, 16_666_667L)
        val probe = PaceProbe()
        p.probe = probe
        for (i in 0 until 5) {
            probe.clear()
            p.schedule(i * 16_667L, 100_000_000L + i * 16_666_667L)
        }
        assertTrue(probe.path != PaceProbe.PATH_NONE)
        assertTrue(probe.periodNs > 0)
        assertTrue(probe.earliestNs > 0)
    }

    @Test fun receiveColumnsJoinThePresentationRowBySeq() {
        val t = PaceTrace(8)
        t.onRecv(7, 700, 1234, 1000, 1100)
        t.onRxAction(7, 1200, PaceTrace.RX_QUEUED)
        t.onInput(7, 1300)
        t.record(7, 700, 5000, null, 0, false, false, 0)
        val lines = csv(t)
        assertEquals(2, lines.size)
        val row = lines[1].split(",")
        assertEquals(PaceTrace.CSV_COLS, row.size)
        assertEquals(listOf("1000", "1100", "1200", "1300", "1234", "queued"), row.drop(24).take(6))
        assertEquals("pending", row[22])
    }

    @Test fun droppedFramesGetTheirOwnRowWithTheFateInActionColumn() {
        val t = PaceTrace(8)
        t.onRecv(3, 300, 50, 10, 20)
        t.onRxAction(3, 30, PaceTrace.RX_QUEUE_DROP)
        val lines = csv(t)
        assertEquals(2, lines.size)
        val row = lines[1].split(",")
        assertEquals(PaceTrace.CSV_COLS, row.size)
        assertEquals("3", row[0]); assertEquals("300", row[1])
        assertEquals("queue_drop", row[22])
        assertEquals(listOf("10", "20", "30", "0", "50", "queue_drop"), row.drop(24).take(6))
    }

    @Test fun frameQueueStampsItsFates() {
        val t = PaceTrace(16)
        val q = FrameQueue(VideoStats(), maxPending = 2).also { it.trace = t } // overflow fates at the pre-T-121 depth
        fun f(seq: Long, flags: Int) = dev.matebridge.client.protocol.VideoFrame(
            seq, seq * 10, flags, 0, 1, 1, dev.matebridge.client.protocol.Bytes(ByteArray(1)))
        for (s in 1L..5L) t.onRecv(s, s * 10, 1, 0, 0)
        q.offer(f(1, 0)) // gate closed
        q.offer(f(2, dev.matebridge.client.protocol.VideoFrame.KEYFRAME))
        q.offer(f(3, 0))
        q.offer(f(4, 0)) // third pending: overflow drops 2.. and incoming
        val acts = csv(t).drop(1).map { it.split(",") }.associate { it[0] to it[29] }
        assertEquals("gate_drop", acts["1"])
        assertEquals("pending_drop", acts["2"])
        assertEquals("pending_drop", acts["3"])
        assertEquals("queue_drop", acts["4"])
    }

    @Test fun inputStepsAndOpenStampsLandInTheT077Columns() {
        val t = PaceTrace(8)
        t.onRecv(9, 900, 3000, 1000, 1500, 1100, 1200, 1400)
        t.onRxAction(9, 1600, PaceTrace.RX_QUEUED)
        t.onInput(9, 2000, takenNs = 1700, inbufNs = 1750, copiedNs = 1800, prefetched = true)
        t.record(9, 900, 9000, null, 0, false, false, 0)
        val row = csv(t)[1].split(",")
        assertEquals(PaceTrace.CSV_COLS, row.size)
        assertEquals(listOf("1000", "1500", "1600", "2000", "3000", "queued"), row.drop(24).take(6))
        assertEquals(listOf("1100", "1200", "1400", "1700", "1750", "1800", "1"), row.drop(30).take(7))
    }

    @Test fun reusedReceiveSlotStartsWithClearedInputSteps() {
        val t = PaceTrace(2)
        t.onRecv(1, 10, 1, 1, 2)
        t.onInput(1, 5, 3, 4, 4, true)
        t.onRecv(3, 30, 1, 7, 8) // same slot (3 % 2 == 1)
        t.onRxAction(3, 9, PaceTrace.RX_GATE_DROP)
        val row = csv(t).drop(1).single { it.startsWith("3,") }.split(",")
        assertEquals(PaceTrace.CSV_COLS, row.size)
        assertEquals(listOf("0", "0", "0", "0", "0", "0", "0"), row.drop(30).take(7))
    }

    @Test fun openStampsComeFromTheRecordOpenerWhenEnabled() {
        val key = ByteArray(32) { 3 }
        val rec = dev.matebridge.client.security.RecordSealer(key).seal(0x41, ByteArray(50))
        val t = PaceTrace(4)
        try {
            dev.matebridge.client.security.Records.stampOpens = true
            dev.matebridge.client.security.RecordOpener(key).open(rec.copyOf(4), rec.copyOfRange(4, rec.size))
            t.onRecv(2, 20, 50, 1, System.nanoTime())
        } finally {
            dev.matebridge.client.security.Records.stampOpens = false
        }
        val row = csv(t)[1].split(",")
        val (start, init, fin) = row.drop(30).take(3).map { it.toLong() }
        assertTrue(start > 0 && init >= start && fin >= init)
    }

    @Test fun t115PathsHaveTheirOwnNames() {
        val t = PaceTrace(8)
        val probe = PaceProbe()
        val paths = listOf(PaceProbe.PATH_EARLY_SPARSE to "early_sparse", PaceProbe.PATH_EARLY_FIRST to "early_first", PaceProbe.PATH_WARMUP to "warmup")
        for ((i, p) in paths.withIndex()) { probe.path = p.first; t.record(i.toLong(), 10, 20, probe, 30, false, false, 0) }
        val rows = csv(t).drop(1).map { it.split(",")[16] }
        assertEquals(paths.map { it.second }, rows)
    }
}
