package dev.matebridge.client.video

import dev.matebridge.client.protocol.Bytes
import dev.matebridge.client.protocol.KeyframeRequest
import dev.matebridge.client.protocol.VideoFrame
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * T-252: a backlog inside the bounds is decoded and caught up (SKIP ... TAIL marks, no flush, no keyframe request); beyond
 * the bounds, with catch-up off, or after a flush / error the old behaviour and a clean state apply.
 */
class FrameQueueCatchUpTest {
    private val ms = 1_000_000L
    private var now = 1_000 * ms
    private var seq = 0L
    private val stats = VideoStats()
    private val q = FrameQueue(stats, 4) { now }.also { it.catchUpDepth = 12 }
    private val requests = ArrayList<Pair<Int, FrameQueue.Source>>()
    private val done = ArrayList<Pair<Int, Long>>()
    private val mark = TakeMark()

    init {
        q.onRequest = { r, s -> requests += r to s }
        q.onCatchUp = { f, m -> done += f to m }
    }

    private fun data(size: Int = 3) = Bytes(ByteArray(size))
    private fun p(size: Int = 3): Int? = q.offer(VideoFrame(seq, seq * 1000, 0, 0, 1, 3, data(size))).also { seq++ }
    private fun key(): Int? = q.offer(VideoFrame(seq, seq * 1000, VideoFrame.KEYFRAME, 0, 1, 3, data())).also { seq++ }
    private fun config() = q.offer(VideoFrame(seq, 0, VideoFrame.CODEC_CONFIG, 0, 1, 3, data())).also { seq++ }

    private fun take(): VideoFrame? = q.awaitNext(0, FrameQueue.ANY_CONSUMER, mark)

    /** Takes everything pending; returns the marks in order. */
    private fun drain(): List<Int> {
        val m = ArrayList<Int>()
        while (take() != null) m += mark.value
        return m
    }

    @Test fun overflowInsideTheBoundsKeepsEveryFrameAndRequestsNothing() {
        assertNull(key()); take()
        repeat(10) { assertNull(p()) } // 10 > limit 4, <= depth 12
        assertEquals(10, q.pending())
        assertFalse(q.isWaitingKeyframe())
        assertTrue(requests.isEmpty())
        assertEquals(0L, stats.snapshot().dropped)
        val c = q.counters()
        assertEquals(0L, c.overflows); assertEquals(0L, c.kfRequests); assertEquals(1L, c.catchUps)
    }

    @Test fun takenFramesAreSkipUntilTheNewestWhichIsTheTail() {
        key(); take()
        repeat(10) { p() }
        val marks = drain()
        assertEquals(List(9) { CatchUp.SKIP } + CatchUp.TAIL, marks)
        assertFalse(q.isCatchingUp())
        assertEquals(9L, q.counters().catchUpSkipped)
    }

    @Test fun catchUpEndsWithAnEventWithFramesAndMilliseconds() {
        key(); take()
        repeat(6) { p() } // starts at now
        now += 25 * ms
        drain()
        assertEquals(listOf(6 to 25L), done)
    }

    @Test fun framesAfterTheTailAreNormalAgain() {
        key(); take()
        repeat(6) { p() }
        drain()
        p(); take()
        assertEquals(CatchUp.NONE, mark.value)
        repeat(6) { p() } // a second episode counts separately
        assertEquals(List(5) { CatchUp.SKIP } + CatchUp.TAIL, drain())
        assertEquals(2L, q.counters().catchUps)
    }

    @Test fun framesNormallyInsideTheLimitAreNotMarked() {
        key(); take()
        repeat(4) { p() }
        assertEquals(List(4) { CatchUp.NONE }, drain())
        assertEquals(0L, q.counters().catchUps)
    }

    @Test fun aBacklogBeyondTheDepthTakesTheOldPathDropAndRequest() {
        key(); take()
        var r: Int? = null
        repeat(13) { r = p() } // the 13th is beyond depth 12
        assertEquals(KeyframeRequest.FRAMES_DROPPED, r)
        assertTrue(q.isWaitingKeyframe())
        assertEquals(0, q.pending())
        assertEquals(1L, q.counters().overflows)
        assertFalse(q.isCatchingUp())
        assertEquals(13L, stats.snapshot().dropped) // 12 pending + the incoming one
    }

    @Test fun aBacklogBeyondTheByteBoundTakesTheOldPath() {
        q.catchUpMaxBytes = 100
        key(); take()
        repeat(5) { p(size = 30) } // 5th: 150 bytes pending > 100 and > limit 4
        assertTrue(q.isWaitingKeyframe())
        assertEquals(1L, q.counters().overflows)
        assertEquals(1L, q.counters().kfRequests)
    }

    @Test fun catchUpOffIsTheOldBehaviourExactly() {
        q.catchUpDepth = 0
        key(); take()
        var r: Int? = null
        repeat(5) { r = p() }
        assertEquals(KeyframeRequest.FRAMES_DROPPED, r)
        assertTrue(q.isWaitingKeyframe())
        assertEquals(0L, q.counters().catchUps)
    }

    @Test fun gatedFramesAreNeverQueuedWhateverTheCatchUpState() {
        // waiting for the first keyframe: P frames are dropped, not queued
        repeat(8) { assertNull(p()) }
        assertEquals(0, q.pending())
        assertEquals(8L, stats.snapshot().dropped)
        assertEquals(0L, q.counters().catchUps)
    }

    @Test fun aKeyframeDuringCatchUpFlushesTheOlderFramesAndIsShownAtOnce() {
        key(); take()
        repeat(8) { p() }
        assertEquals(CatchUp.SKIP, run { take(); mark.value }) // one frame already handed out as SKIP
        assertEquals(CatchUp.SKIP, run { take(); mark.value })
        key() // the host sent an IDR
        assertEquals(1, q.pending()) // older frames flushed (stale), only the keyframe left
        assertFalse(q.isCatchingUp())
        take()
        assertEquals(CatchUp.TAIL, mark.value) // skipped frames were shown nowhere: the keyframe is shown at once
        assertEquals(1, done.size)
        p(); take()
        assertEquals(CatchUp.NONE, mark.value)
    }

    @Test fun anOverflowBeyondTheBoundAfterSkipsMakesTheNextKeyframeTheTail() {
        key(); take()
        repeat(6) { p() }
        take() // SKIP
        repeat(10) { p() } // 5 + 10 = 15 > depth 12 -> old path
        assertTrue(q.isWaitingKeyframe())
        key()
        take()
        assertEquals(CatchUp.TAIL, mark.value)
    }

    @Test fun aDecoderErrorForgetsTheCatchUpAndStaysGated() {
        key(); take()
        repeat(6) { p() }
        take() // one SKIP out
        assertEquals(KeyframeRequest.DECODE_ERROR, q.onDecoderError())
        assertTrue(q.isWaitingKeyframe())
        assertEquals(0, q.pending())
        assertFalse(q.isCatchingUp())
        key(); take()
        assertEquals(CatchUp.NONE, mark.value) // fresh start, no stale TAIL
        assertTrue(done.isEmpty())
    }

    @Test fun resetForgetsTheCatchUp() {
        key(); take()
        repeat(6) { p() }
        take()
        q.reset(KeyframeRequest.STARTUP)
        assertFalse(q.isCatchingUp())
        assertEquals(0, q.pending())
        key(); take()
        assertEquals(CatchUp.NONE, mark.value)
    }

    @Test fun codecConfigFramesAreNeverMarkedAndDoNotCountAsBacklog() {
        config()
        key()
        assertEquals(CatchUp.NONE, run { take(); mark.value }) // config
        take(); assertEquals(CatchUp.NONE, mark.value) // keyframe
        repeat(6) { p() }
        config() // a config in the middle goes to the front, is not a pending frame
        take()
        assertEquals(CatchUp.NONE, mark.value)
        assertEquals(List(5) { CatchUp.SKIP } + CatchUp.TAIL, drain())
    }

    @Test fun aRevokedConsumerTakesNothingAndChangesNoCatchUpState() {
        q.assignConsumer(1)
        key()
        q.awaitNext(0, 1, mark)
        repeat(6) { p() }
        q.revokeConsumer(1)
        assertNull(q.awaitNext(0, 1, mark))
        assertEquals(6, q.pending())
        assertTrue(q.isCatchingUp())
        q.assignConsumer(2)
        val m = ArrayList<Int>()
        while (q.awaitNext(0, 2, mark) != null) m += mark.value
        assertEquals(List(5) { CatchUp.SKIP } + CatchUp.TAIL, m)
    }

    @Test fun theQueueStaysBoundedWhateverTheArrival() {
        key(); take()
        var worst = 0
        repeat(500) { p(); worst = maxOf(worst, q.pending()) }
        assertTrue("pending $worst > depth 12", worst <= 12)
    }

    @Test fun depthForFpsIsHalfASecondCapped() {
        assertEquals(60, CatchUp.depthForFps(120))
        assertEquals(30, CatchUp.depthForFps(60))
        assertEquals(64, CatchUp.depthForFps(144))
        assertEquals(64, CatchUp.depthForFps(0))
        assertEquals(1, CatchUp.depthForFps(1))
    }

    @Test fun marksMapIsBoundedAndTakeRemoves() {
        val m = CatchUpMarks(2)
        m.put(1, CatchUp.SKIP); m.put(2, CatchUp.SKIP); m.put(3, CatchUp.TAIL)
        assertEquals(CatchUp.NONE, m.take(1)) // evicted: presented normally
        assertEquals(CatchUp.TAIL, m.take(3))
        assertEquals(CatchUp.NONE, m.take(3))
        m.put(9, CatchUp.NONE)
        assertEquals(CatchUp.NONE, m.take(9))
    }

    // --- T-252 review (P1): a catch-up must not suppress presentation or run unbounded ---

    private val step = 8 * ms // 120 fps

    /** Longest gap between two frames that were shown (not SKIP) over the run, in ms; run ends when the old path fires. */
    private class Run(var worstGapMs: Long = 0, var steps: Int = 0, var flushed: Boolean = false, var shown: Int = 0)

    private fun sustained(arrivalsPerTakes: Pair<Int, Int>, startBurst: Int = 6, maxSteps: Int = 400): Run {
        key(); take()
        repeat(startBurst) { p() } // a burst: backlog above the limit of 4
        val (arr, tak) = arrivalsPerTakes
        val r = Run()
        var lastShown = now
        var i = 0
        while (i < maxSteps && !r.flushed) {
            now += step; i++
            repeat(arr) { p() }
            repeat(tak) {
                if (take() != null && mark.value != CatchUp.SKIP) {
                    r.worstGapMs = maxOf(r.worstGapMs, (now - lastShown) / ms); lastShown = now; r.shown++
                }
            }
            r.flushed = q.isWaitingKeyframe()
        }
        r.steps = i
        r.worstGapMs = maxOf(r.worstGapMs, (now - lastShown) / ms)
        return r
    }

    @Test fun arrivalEqualToDecodeRateKeepsPresentingAndEndsInTheOldPath() {
        val r = sustained(1 to 1)
        assertTrue("old path never fired in ${r.steps} steps", r.flushed)
        assertTrue("catch-up ran ${r.steps} steps (> 300 ms + slack)", r.steps * 8 <= 300 + 2 * 8 + 8)
        assertTrue("display stood still ${r.worstGapMs} ms", r.worstGapMs <= CatchUp.SHOW_INTERVAL_MS + 8)
        assertTrue(r.shown >= 3)
        assertEquals(1L, q.counters().overflows)
    }

    @Test fun arrivalSlightlyAboveDecodeRateKeepsPresentingAndEnds() {
        val r = sustained(10 to 9) // but per step: 10 arrivals vs 9 takes scaled below
        assertTrue(r.flushed)
        assertTrue("display stood still ${r.worstGapMs} ms", r.worstGapMs <= CatchUp.SHOW_INTERVAL_MS + 8)
    }

    @Test fun decodeFasterThanArrivalEndsTheCatchUpWithATailAndNoRequest() {
        val r = sustained(1 to 2)
        assertFalse(r.flushed)
        assertFalse(q.isCatchingUp())
        assertTrue(requests.isEmpty())
        assertEquals(0L, q.counters().overflows)
        assertTrue(done.isNotEmpty())
        assertTrue(r.steps == 400)
    }

    @Test fun backBelowTheNormalDepthEndsTheCatchUpAndTheNextFrameIsTheTail() {
        key(); take()
        repeat(6) { p() }
        take() // SKIP; pending 5
        repeat(4) { take() } // pending 1 (all handed out as SKIP or SHOW)
        p() // pending 2 <= limit: caught up
        assertFalse(q.isCatchingUp())
        take()
        assertEquals(CatchUp.TAIL, mark.value)
    }
}
