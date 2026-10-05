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

    // --- T-252 review: a catch-up must be bounded in time, with or without new arrivals ---

    private val step = 8 * ms // 120 fps

    /** Offers [arr] and takes [tak] frames per 8 ms step; stops when the old path has fired. Returns the steps run. */
    private fun sustained(arr: Int, tak: Int, startBurst: Int = 6, maxSteps: Int = 400): Int {
        key(); take()
        repeat(startBurst) { p() } // a burst: backlog above the limit of 4
        var i = 0
        while (i < maxSteps && !q.isWaitingKeyframe()) {
            now += step; i++
            repeat(arr) { p() }
            repeat(tak) { take() }
        }
        return i
    }

    @Test fun arrivalEqualToDecodeRateEndsInTheOldPathWithinTheDeadline() {
        val steps = sustained(1, 1)
        assertTrue("old path never fired", q.isWaitingKeyframe())
        assertTrue("catch-up ran ${steps * 8} ms", steps * 8 <= 300 + 8 + 8)
        assertEquals(1L, q.counters().overflows)
        assertEquals(1L, q.counters().kfRequests)
    }

    @Test fun arrivalAboveDecodeRateEndsInTheOldPath() {
        sustained(2, 1)
        assertTrue(q.isWaitingKeyframe())
        assertEquals(1L, q.counters().overflows)
    }

    @Test fun decodeFasterThanArrivalEndsTheCatchUpWithATailAndNoRequest() {
        val steps = sustained(1, 2)
        assertEquals(400, steps)
        assertFalse(q.isWaitingKeyframe())
        assertFalse(q.isCatchingUp())
        assertTrue(requests.isEmpty())
        assertEquals(0L, q.counters().overflows)
        assertTrue(done.isNotEmpty())
    }

    @Test fun aBacklogDrainedToTheNormalDepthIsNeverFlushedAtTheDeadlineAndKeepsSkippingToTheNewest() {
        val exp = ArrayList<Int>()
        q.onExpired = { exp += it }
        key(); take()
        repeat(10) { p() } // limit 4; no further arrivals
        repeat(7) { take(); assertEquals(CatchUp.SKIP, mark.value) } // 3 left, below the normal depth
        assertEquals(3, q.pending())
        assertTrue(q.isCatchingUp())
        now += 400 * ms // well past the 300 ms deadline
        val rest = drain()
        assertEquals(listOf(CatchUp.SKIP, CatchUp.SKIP, CatchUp.TAIL), rest) // still straight to the newest
        assertTrue(exp.isEmpty())
        assertTrue(requests.isEmpty())
        assertFalse(q.isWaitingKeyframe())
        assertEquals(0L, q.counters().overflows)
        assertFalse(q.isCatchingUp())
    }

    @Test fun burstThenSilenceStillRecoversAtTheDeadlineInsideTake() {
        val exp = ArrayList<Int>()
        q.onExpired = { exp += it }
        key(); take()
        repeat(10) { p() } // catch-up starts, no more arrivals
        now += 100 * ms
        assertNotNull(take()) // within the deadline: normal catch-up
        now += 250 * ms // 350 ms after the start, the queue is not empty yet (slow decode)
        assertNull(take()) // the deadline fires in take(): backlog flushed, request produced
        assertEquals(listOf(KeyframeRequest.FRAMES_DROPPED), exp)
        assertTrue(q.isWaitingKeyframe())
        assertEquals(0, q.pending())
        assertFalse(q.isCatchingUp())
        assertEquals(1L, q.counters().overflows)
        key(); take()
        assertEquals(CatchUp.TAIL, mark.value) // skipped frames were never shown: the keyframe is
    }

    @Test fun anExpiredRequestInsideTakeIsHeldByTheHoldOffLikeAnyOther() {
        val exp = ArrayList<Int>()
        q.onExpired = { exp += it }
        q.reset(KeyframeRequest.STARTUP) // a request just went out
        key(); take()
        repeat(10) { p() }
        now += 350 * ms
        assertNull(take())
        assertTrue(exp.isEmpty())
        assertEquals(1L, q.counters().kfHeld)
        now += 600 * ms
        assertTrue(q.takeRetry()) // the periodic retry sends it later
    }
}
