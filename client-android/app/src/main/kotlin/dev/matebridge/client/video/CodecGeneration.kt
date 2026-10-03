package dev.matebridge.client.video

import java.util.concurrent.TimeUnit
import java.util.concurrent.locks.Condition
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/**
 * T-161: one decoder generation (one `attachSurface` / `reconfigure` / `restartCodec` call): its surface, its decoder
 * thread and the bookkeeping [GenerationHandoff] needs. A generation is finished only when every thread it started
 * (the decoder thread and each codec's output thread) has exited.
 */
class CodecGeneration(val gen: Int, val surface: Any) {
    /** False once retired (or given up / stuck); set through [GenerationHandoff.retire] so waits wake at once. */
    @Volatile var active = true
        internal set

    lateinit var thread: Thread

    /** An output thread outlived its join: the next generation's wait includes it (diagnostics). */
    @Volatile var outputStraggler = false

    /** Threads of this generation that have not exited yet; guarded by the [GenerationHandoff] lock. */
    internal var liveThreads = 0
}

/** T-161: clock and bounded wait of [GenerationHandoff]; tests pass a fake clock. */
interface HandoffTimer {
    fun nowMs(): Long

    /** Waits on [condition] (its lock is held) for at most [ms]; may return early (signal, spurious wake-up). */
    fun await(condition: Condition, ms: Long)

    companion object {
        val SYSTEM = object : HandoffTimer {
            override fun nowMs() = TimeUnit.NANOSECONDS.toMillis(System.nanoTime())
            override fun await(condition: Condition, ms: Long) { condition.await(ms, TimeUnit.MILLISECONDS) }
        }
    }
}

/**
 * T-161 (M03): the hand-off between decoder generations, one per renderer. Pure Kotlin, thread-safe.
 *
 * At most one generation holds a codec at a time: the [owner], the last generation whose decoder thread passed
 * [acquire]. A new generation's decoder thread waits in [acquire] until the owner is finished (its decoder thread and
 * every output thread exited), but at most `timeoutMs`; then it gets [Result.Stuck] and must not open a codec. The owner
 * stays the single "last stuck" reference, so the next generation waits for that one again and the chain cannot grow.
 * [retire] wakes a waiting thread at once ([Result.Retired]), so repeated attaches while stuck leave at most one
 * waiting thread. [pause] is the restart backoff, also woken by [retire].
 */
class GenerationHandoff(private val timer: HandoffTimer = HandoffTimer.SYSTEM) {
    sealed class Result {
        object Ready : Result()
        object Retired : Result()
        /** [previous] was not finished after [waitedMs]. */
        class Stuck(val previous: CodecGeneration, val waitedMs: Long) : Result()
    }

    private val lock = ReentrantLock()
    private val changed = lock.newCondition()
    private var owner: CodecGeneration? = null
    private var waiting = 0

    /** Decoder threads inside [acquire] right now. */
    val waitingThreads: Int get() = lock.withLock { waiting }

    /** A thread of [g] is about to start (count it before `Thread.start`). */
    fun threadStarted(g: CodecGeneration) = lock.withLock { g.liveThreads++ }

    /** A thread of [g] exited (last statement of the thread). */
    fun threadExited(g: CodecGeneration) = lock.withLock {
        g.liveThreads--
        changed.signalAll()
    }

    /** [g] must stop: its waits ([acquire], [pause]) return at once. Any thread. */
    fun retire(g: CodecGeneration) = lock.withLock {
        g.active = false
        changed.signalAll()
    }

    fun isFinished(g: CodecGeneration): Boolean = lock.withLock { g.liveThreads <= 0 }

    /**
     * On [g]'s decoder thread, before it opens a codec: waits until the owner generation is finished, at most
     * [timeoutMs]. [Result.Ready] makes [g] the owner. Throws [InterruptedException] like any wait.
     */
    fun acquire(g: CodecGeneration, timeoutMs: Long): Result = lock.withLock {
        val startMs = timer.nowMs()
        waiting++
        try {
            var result: Result? = null
            while (result == null) {
                val prev = owner
                val elapsed = timer.nowMs() - startMs
                result = when {
                    !g.active -> Result.Retired
                    prev == null || prev === g || prev.liveThreads <= 0 -> { owner = g; Result.Ready }
                    elapsed >= timeoutMs -> Result.Stuck(prev, elapsed)
                    else -> { timer.await(changed, timeoutMs - elapsed); null }
                }
            }
            result
        } finally {
            waiting--
        }
    }

    /** Restart backoff on [g]'s decoder thread: waits [ms] unless [g] is retired first. Returns [g]'s `active`. */
    fun pause(g: CodecGeneration, ms: Long): Boolean = lock.withLock {
        val startMs = timer.nowMs()
        while (g.active) {
            val left = ms - (timer.nowMs() - startMs)
            if (left <= 0) break
            timer.await(changed, left)
        }
        g.active
    }
}

/**
 * T-161: what one codec instance (one `runCodec`) owns, so a thread that outlives it can only touch its own copy:
 * decoder occupancy, PTS maps, arrival estimate, pacers, the output thread's last-output time. Shared renderer state
 * (stats, counters, the first-output bypass, decode progress) may be updated only while [current].
 */
internal class CodecState(val generation: CodecGeneration, ptsMapMax: Int) {
    /** False once the codec's decoder thread left its loop (the output thread must stop). */
    @Volatile var running = true

    /** The codec is the live one: its run has not ended and its generation is not retired. */
    val current: Boolean get() = running && generation.active

    val gauge = InFlightGauge()
    /** frameSeq (codec pts) -> host capture time (us). */
    val captureByPts = PtsMap(ptsMapMax)
    /** frameSeq (codec pts) -> time the decoded frame became ready (ns, System.nanoTime). */
    val readyByPts = PtsMap(ptsMapMax)
    val arrival = ArrivalTracker()
    @Volatile var adaptive: AdaptivePacer? = null
    @Volatile var cpd: ConstantPlayoutPacer? = null
    /** Output thread: time of the latest dequeued output (T-141 idle wait). */
    var lastOutputNs = 0L
}

/** Bounded pts -> time map (oldest entries evicted). Thread-safe. */
internal class PtsMap(private val max: Int) {
    private val m = object : LinkedHashMap<Long, Long>() {
        override fun removeEldestEntry(e: MutableMap.MutableEntry<Long, Long>) = size > max
    }
    @Synchronized fun put(k: Long, v: Long) { m[k] = v }
    @Synchronized fun get(k: Long): Long? = m[k]
}
