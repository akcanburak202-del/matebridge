package dev.matebridge.client.video

/**
 * T-252: what the presentation side does with a frame taken from [FrameQueue] while it is catching up a backlog.
 *
 * A backlog (more frames pending than the normal depth, [FrameQueue.maxPending]) used to be flushed and a keyframe was
 * requested. Now every frame is still decoded in order (the reference chain stays intact) and only the presentation
 * skips: [SKIP] frames are decoded and then released without rendering, the [TAIL] (the newest one of the backlog, the
 * last one taken before the queue is empty) is shown at once and the pacer starts over from the next frame (the same
 * re-anchor as after an idle gap).
 */
object CatchUp {
    /** Normal frame: presentation as usual. */
    const val NONE = 0
    /** Decode, do not show: a newer frame of the backlog follows. */
    const val SKIP = 1
    /** Newest frame of the backlog (or the first frame after a flush that ended a catch-up): show now, re-anchor. */
    const val TAIL = 2

    /**
     * Output side only (T-252 review): a [SKIP] output that comes out at least [SHOW_INTERVAL_MS] after the last
     * presented one is shown after all (like [TAIL], the catch-up goes on), so the display never stands still for
     * longer than that while a backlog is worked off, however late the codec emits its outputs.
     */
    const val SHOW = 3
    /** Longest gap between two presented frames during a catch-up. */
    const val SHOW_INTERVAL_MS = 50L
    /**
     * Longest catch-up (from its start): a backlog that is still above the normal depth after this long is not
     * shrinking (arrival rate >= decode rate); the old flush + keyframe request path takes over.
     */
    const val MAX_CATCH_UP_MS = 300L

    /** Milliseconds of video the backlog may reach before the old drop + keyframe request path takes over. */
    const val MAX_BACKLOG_MS = 500
    /** Memory bound of the backlog (frame payload bytes). */
    const val MAX_BACKLOG_BYTES = 32L * 1024 * 1024
    /** Count bound of the backlog whatever the rate. */
    const val MAX_BACKLOG_FRAMES = 64

    /** Backlog depth (non-config frames) for a stream of [fps]: [MAX_BACKLOG_MS] worth, 1..[MAX_BACKLOG_FRAMES]. */
    fun depthForFps(fps: Int): Int {
        val n = if (fps <= 0) MAX_BACKLOG_FRAMES else ((fps.toLong() * MAX_BACKLOG_MS) / 1000).toInt()
        return n.coerceIn(1, MAX_BACKLOG_FRAMES)
    }
}

/** Out-parameter of [FrameQueue.awaitNext]: the [CatchUp] mark of the frame just taken (set under the queue lock). */
class TakeMark {
    @Volatile @JvmField var value = CatchUp.NONE
}

/**
 * frame_seq (codec pts) -> [CatchUp] mark, written by the input thread before the frame is queued to the codec and
 * consumed by the output thread when that frame comes out. Bounded (oldest evicted: an evicted mark just means the
 * frame is presented normally). Thread-safe.
 */
internal class CatchUpMarks(private val max: Int) {
    private val m = object : LinkedHashMap<Long, Int>() {
        override fun removeEldestEntry(e: MutableMap.MutableEntry<Long, Int>) = size > max
    }
    @Synchronized fun put(pts: Long, mark: Int) { if (mark != CatchUp.NONE) m[pts] = mark }
    @Synchronized fun take(pts: Long): Int = m.remove(pts) ?: CatchUp.NONE
}
