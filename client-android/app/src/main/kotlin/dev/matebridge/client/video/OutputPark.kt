package dev.matebridge.client.video

import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.locks.LockSupport

/**
 * T-312 (CB2): the output thread parks while the codec holds nothing. [DecoderWaits.outputWaitUs] keeps the 5 ms
 * `dequeueOutputBuffer` poll for 300 ms after every output, and each timed-out synchronous dequeue costs two more
 * `MediaCodec_loop` / `CodecLooper` wake-ups, so a 10 fps stream burns hundreds of wake-ups per second between frames.
 *
 * The count is inputs given to the codec (CODEC_CONFIG excluded) minus outputs taken. At 0, with no output buffer held
 * for a later release, nothing can come out: the output thread parks ([parkIfEmpty]) until the input thread queues
 * another frame ([signal] after `queueInputBuffer`) or the codec generation is retired ([signal]). While a frame is in
 * flight the caller keeps the short dequeue poll (no long dequeue: a stop or an error is still noticed in 5 ms).
 *
 * Safety: the park is bounded by [FUSE_NS] (a lost or never-sent unpark costs at most that), the count is re-synchronised
 * to 0 after [RESYNC_NS] without an output (a frame the codec swallowed would otherwise keep the thread polling for the
 * rest of the generation), and an output beyond the count never makes it negative. Disabled ([enabled] false, the
 * default `dec_out_park off`): [parkIfEmpty] never parks and nothing is counted, i.e. exactly the previous behaviour.
 *
 * Threads: [onQueued] / [onQueueFailed] / [signal] from the input thread (or the retiring thread); the rest from the
 * output thread. Thread-safe.
 */
class OutputPark(
    val enabled: Boolean,
    private val fuseNs: Long = FUSE_NS,
    private val clockNs: () -> Long = System::nanoTime,
) {
    companion object {
        /** Longest single park. Same as the idle poll it replaces, so a stop is noticed as fast as before. */
        const val FUSE_NS = 20_000_000L

        /** An input outstanding for this long is presumed swallowed by the codec; the count is then reset. */
        const val RESYNC_NS = 1_000_000_000L
    }

    // Count and the queue time of the OLDEST outstanding input, one lock (both are read and written together).
    private val state = Any()
    private var inFlight = 0
    private var oldestNs = 0L
    @Volatile private var thread: Thread? = null

    /** Frames given to the codec and not yet taken as outputs (tests and logs). */
    val pending: Int get() = synchronized(state) { inFlight }

    /** Output thread, once at its start: the thread [signal] unparks. */
    fun bindOutputThread(t: Thread = Thread.currentThread()) { thread = t }

    /** Input thread, BEFORE `queueInputBuffer` of a non-config frame (the output can come back before the call returns). */
    fun onQueued() {
        if (!enabled) return
        synchronized(state) {
            if (inFlight == 0) oldestNs = clockNs()
            inFlight++
        }
    }

    /** The `queueInputBuffer` that [onQueued] announced failed: no output will come for it. */
    fun onQueueFailed() { if (enabled) synchronized(state) { if (inFlight > 0) inFlight-- } }

    /** Output thread, per non-config output taken. The next outstanding input is younger than the one that came out. */
    fun onOutput() {
        if (!enabled) return
        synchronized(state) {
            if (inFlight > 0) inFlight--
            if (inFlight > 0) oldestNs = clockNs()
        }
    }

    /** Any thread, AFTER `queueInputBuffer` and on retirement: ends a park. A permit left behind makes the next park return at once. */
    fun signal() { if (enabled) thread?.let(LockSupport::unpark) }

    /**
     * Output thread: parks (at most [FUSE_NS]) when the codec is empty and nothing is [holding]; true = it parked (the
     * caller re-checks its loop condition), false = go on with the normal dequeue. A frame in flight never parks; one
     * outstanding longer than [RESYNC_NS] is presumed swallowed: the count is reset, but this call still returns false so
     * one real dequeue probe happens before the next park (a frame queued just after the reset is never skipped).
     */
    fun parkIfEmpty(holding: Boolean): Boolean {
        if (!enabled || holding) return false
        synchronized(state) {
            if (inFlight > 0) {
                if (clockNs() - oldestNs >= RESYNC_NS) inFlight = 0
                return false
            }
        }
        LockSupport.parkNanos(this, fuseNs)
        return true
    }
}

/**
 * T-312 (C10/CB9): how long the packed presenter's GL thread waits for a notification ([PackedPresenter.offerMain],
 * `offerAux`, shutdown all notify). While something is pending (a held image, an unsignalled draw, a retired image
 * waiting for its fence, timestamps of a recent draw still to come) its own timers need the short [TICK_MS]; with nothing
 * pending only a notification matters and [FUSE_MS] is a safety net.
 */
object GlWait {
    const val TICK_MS = 25L
    const val FUSE_MS = 250L

    /** Draw timestamps arrive up to a few vsyncs after a draw; this long after one the thread still drains them. */
    const val TIMESTAMP_TAIL_NS = 500_000_000L

    fun waitMs(pending: Boolean): Long = if (pending) TICK_MS else FUSE_MS

    /** [sinceLastDrawNs] null = no draw yet. */
    fun pending(held: Boolean, retiredWaiting: Boolean, drawsOutstanding: Boolean, sinceLastDrawNs: Long?): Boolean =
        held || retiredWaiting || drawsOutstanding || (sinceLastDrawNs != null && sinceLastDrawNs < TIMESTAMP_TAIL_NS)
}
