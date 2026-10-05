package dev.matebridge.client.video

import android.media.Image
import android.os.Process
import android.view.Surface
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ConcurrentLinkedQueue

/**
 * An image whose draw's fence has not signalled for this long means the GPU (or the fence) is stuck: the presenter fails
 * over to the direct path, but the image is NEVER closed before its fence signals (or glFinish returned at teardown).
 */
internal const val IMAGE_STALL_NS = 500_000_000L

/**
 * Images the GPU may still read: each is retired with the number of the last submitted draw that can use it and is closed
 * only once that draw's fence signalled ([closeDue] with the completed-draw count). A fence that stays unsignalled is
 * detected by [stalledForNs] (recovery is the owner's job), never by closing the image early.
 */
internal class RetiredImages {
    private class Entry(val image: Image, val atNs: Long, val draw: Long)
    private val q = ConcurrentLinkedQueue<Entry>()

    fun retire(image: Image, nowNs: Long, lastDraw: Long) { q.add(Entry(image, nowNs, lastDraw)) }

    /** Closes images whose draw completed ([completedDraws]); [force] closes everything (only after a glFinish). */
    fun closeDue(nowNs: Long, completedDraws: Long, force: Boolean = false) {
        while (true) {
            val e = q.peek() ?: return
            if (!force && e.draw > completedDraws) return
            q.poll()
            runCatching { e.image.close() }
        }
    }

    /** How long the oldest still-waiting image has been waiting for its draw's fence (0 when none waits). */
    fun stalledForNs(nowNs: Long, completedDraws: Long): Long {
        val e = q.peek() ?: return 0L
        return if (e.draw > completedDraws) nowNs - e.atNs else 0L
    }
}

/** What the presenter expects of a main frame released to the main ImageReader (put before the release call). */
class FrameExpectation(val captureUs: Long, val renderNs: Long)

/**
 * The GL thread of the packed full colour path (decision 0034). Takes the main decoder's images (newest wins), pairs each
 * with the auxiliary image of the same `capture_time_us` ([AuxPairing]; none in time: main-only pass), draws into the
 * SurfaceView's EGL window surface with swap interval 0 and `eglPresentationTimeANDROID` = the slot target the pacer
 * chose (no standing queue, T-256), and reports each frame's display time (EGL present timestamp) through [onShown].
 * All native GL calls of this context happen on this thread. Images are closed once the fence of the last draw that may read them signalled ([RetiredImages]).
 *
 * Failure ([onFailed]): init failed, or [MAX_CONSECUTIVE_ERRORS] draws in a row failed; the owner falls back to the direct
 * path. [stop] must complete before the Surface is destroyed.
 */
class PackedPresenter(
    private val surface: Surface,
    private val width: Int,
    private val height: Int,
    private val conversion: YuvConversion,
    /** (level, ev, key=value fields): `MB/render`. */
    private val log: (Char, String, String) -> Unit,
    /** (main frame_seq, display time ns on the System.nanoTime clock): GL thread. */
    private val onShown: (Long, Long) -> Unit,
    private val onFailed: (String) -> Unit,
    private val clockNs: () -> Long = System::nanoTime,
) : Thread("mb-gl") {
    companion object {
        const val AUX_RING = 2
        const val MAX_CONSECUTIVE_ERRORS = 30
        const val EXPECT_MAX = 64
        private const val EXPECT_TRIM = 32
        private const val TICK_MS = 25L

        /** The native present context is a single global: never two presenters at once ([awaitPrevious]). */
        @Volatile private var previous: PackedPresenter? = null

        /**
         * Waits up to [ms] for the previously created presenter's GL thread to exit. False = it is still alive (a stuck
         * GL call): the caller must NOT start another presenter (the native context would be replaced under it).
         */
        /** Clears [previous] once [p] has terminated (identity-guarded: a newer presenter is never cleared). */
        internal fun clearIfPrevious(p: PackedPresenter) {
            synchronized(PackedPresenter::class.java) { if (previous === p) previous = null }
        }

        fun awaitPrevious(ms: Long): Boolean {
            val p = previous ?: return true
            if (p.isAlive && ms > 0) { try { p.join(ms) } catch (_: InterruptedException) {} }
            return !p.isAlive
        }
    }

    init { synchronized(PackedPresenter::class.java) { previous = this } }

    /** One window of presenter counters (the `render ev=stats` fields). */
    class Snapshot(
        val drawn: Long, val mainOnly: Long, val paired: Long, val displaced: Long, val drawErrors: Long,
        val glMsP50: Double?, val glMsP95: Double?, val outstandingMax: Int,
    ) {
        /** `aux_paired_pct` of the window, null when nothing was drawn. */
        val pairedPct: Double? get() = if (paired + mainOnly == 0L) null else paired * 100.0 / (paired + mainOnly)
    }

    private class Arrived(val image: Image, val seq: Long)
    private class AuxArrived(val image: Image, val captureUs: Long)

    private val retired = RetiredImages()
    private val expectations = ConcurrentHashMap<Long, FrameExpectation>()
    private val lock = Object()
    private var mainSlot: Arrived? = null
    private val auxArrivals = ConcurrentLinkedQueue<AuxArrived>()
    /** Draws submitted with a fence (GL thread writes; other threads read it to tag retired images). */
    @Volatile private var submitted = 0L
    private val pairing = AuxPairing<Image>(AUX_RING) { retired.retire(it, clockNs(), submitted) }
    private val timings = GlTimings()
    @Volatile private var stopFlag = false
    @Volatile var started = false
        private set

    // Window counters (GL thread writes, any thread reads through [snapshot]).
    private val counters = Any()
    private var drawn = 0L
    private var displaced = 0L
    private var drawErrors = 0L
    private var outstandingMax = 0
    private var consecutiveErrors = 0
    private var cpuFallbackMs = false

    /** Registers the expectation of main frame [pts] before it is released to the reader. Any thread. */
    fun expect(pts: Long, captureUs: Long, renderNs: Long) {
        expectations[pts] = FrameExpectation(captureUs, renderNs)
        if (expectations.size > EXPECT_MAX) {
            val keys = expectations.keys.sorted()
            for (k in keys.take(keys.size - EXPECT_TRIM)) expectations.remove(k)
        }
    }

    /** A decoded main image (from the main ImageReader listener): newest wins. The presenter owns [image] from now on. */
    fun offerMain(image: Image, seq: Long) {
        synchronized(lock) {
            mainSlot?.let { retired.retire(it.image, clockNs(), submitted); synchronized(counters) { displaced++ } }
            mainSlot = Arrived(image, seq)
            lock.notifyAll()
        }
    }

    /** A decoded auxiliary image (from the aux ImageReader listener). The presenter owns [image] from now on. */
    fun offerAux(image: Image, captureUs: Long) {
        auxArrivals.add(AuxArrived(image, captureUs))
        // Bounded even if the GL thread is stuck: a backlog beyond a few images is stale.
        while (auxArrivals.size > AUX_RING + 2) auxArrivals.poll()?.let { retired.retire(it.image, clockNs(), submitted) }
    }

    /** Counters since the last call with [reset]. */
    fun snapshot(reset: Boolean = true): Snapshot {
        val gl = timings.percentiles(reset)
        synchronized(counters) {
            val s = Snapshot(drawn, pairing.late, pairing.paired, displaced, drawErrors, gl?.first, gl?.second, outstandingMax)
            if (reset) { drawn = 0; displaced = 0; drawErrors = 0; outstandingMax = 0; pairing.resetCounts() }
            return s
        }
    }

    /** Stops the GL thread and waits (bounded) for it; the EGL surface is gone afterwards. */
    fun shutdown(joinMs: Long = 500): Boolean {
        stopFlag = true
        synchronized(lock) { lock.notifyAll() }
        if (isAlive && Thread.currentThread() !== this) {
            try { join(joinMs) } catch (_: InterruptedException) {}
            if (isAlive) log('W', "gl_stop_slow", "join_ms=$joinMs")
        }
        return !isAlive
    }

    override fun run() {
        try { runLoop() } finally { clearIfPrevious(this) } // do not retain the pipeline/activity after the thread ends
    }

    private fun runLoop() {
        try { Process.setThreadPriority(Process.THREAD_PRIORITY_DISPLAY) } catch (_: Exception) {}
        val initError = FullChromaNative.presentInit(surface, width, height, 0)
        if (initError.isNotEmpty()) {
            started = true
            onFailed("init:$initError")
            return
        }
        FullChromaNative.presentSetConversion(conversion.toArray())
        val features = FullChromaNative.presentFeatures()
        cpuFallbackMs = !features.contains("gpu_timer=1") // no GPU timer: the draw call's CPU time stands in for gl_ms
        log('I', "gl_present_init", "$features size=${width}x$height swap_interval=0")
        started = true
        var failed: String? = null
        try {
            while (!stopFlag) {
                val item = takeMain()
                val now = clockNs()
                absorbAux()
                val completed = FullChromaNative.presentCompletedDraws()
                retired.closeDue(now, completed)
                if (retired.stalledForNs(now, completed) > IMAGE_STALL_NS) {
                    failed = "fence_stall"
                    break
                }
                if (item == null) { drainTimestamps(); continue }
                val exp = expectations.remove(item.seq)
                val aux = if (exp != null) pairing.pair(exp.captureUs) else null
                val presentNs = exp?.renderNs ?: 0L
                val hwMain = item.image.hardwareBuffer
                val hwAux = aux?.hardwareBuffer
                val t0 = clockNs()
                val rc = if (hwMain != null) {
                    try {
                        FullChromaNative.presentDraw(hwMain, hwAux, item.seq, presentNs)
                    } catch (e: Exception) { -20 }
                } else -10
                val cpuMs = (clockNs() - t0) / 1e6
                hwMain?.close()
                hwAux?.close()
                if (rc == 0 || rc == -5) submitted++ // a fence was created for this draw
                retired.retire(item.image, clockNs(), submitted)
                if (rc != 0) {
                    synchronized(counters) { drawErrors++ }
                    if (++consecutiveErrors >= MAX_CONSECUTIVE_ERRORS) {
                        failed = "draw:$rc:${FullChromaNative.presentLastError()}"
                        break
                    }
                } else {
                    consecutiveErrors = 0
                    synchronized(counters) { drawn++ }
                    if (cpuFallbackMs) timings.add(cpuMs)
                }
                drainTimestamps()
            }
        } finally {
            try { drainTimestamps() } catch (_: Throwable) {}
            val d = FullChromaNative.presentOutstanding() // diagnostic only
            if (d > 0) log('I', "gl_stop", "outstanding=$d")
            FullChromaNative.presentShutdown()
            for (a in auxArrivals) runCatching { a.image.close() }
            auxArrivals.clear()
            pairing.clear()
            synchronized(lock) { mainSlot?.let { runCatching { it.image.close() } }; mainSlot = null }
            retired.closeDue(clockNs(), Long.MAX_VALUE, force = true) // after glFinish + EGL teardown
        }
        failed?.let { onFailed(it) }
    }

    private fun takeMain(): Arrived? = synchronized(lock) {
        if (mainSlot == null && !stopFlag) lock.wait(TICK_MS)
        val m = mainSlot
        mainSlot = null
        m
    }

    private fun absorbAux() {
        while (true) {
            val a = auxArrivals.poll() ?: break
            pairing.add(a.captureUs, a.image)
        }
    }

    private fun drainTimestamps() {
        for (ns in FullChromaNative.presentDrainGpuNs()) timings.add(ns / 1e6)
        val q = FullChromaNative.presentDrainTimestamps()
        var i = 0
        while (i + 3 < q.size) {
            val tag = q[i]; val latch = q[i + 1]; val present = q[i + 2]
            val shown = if (present > 0) present else latch
            if (shown > 0) onShown(tag, shown)
            i += 4
        }
        val out = FullChromaNative.presentOutstanding()
        if (out > 0) synchronized(counters) { if (out > outstandingMax) outstandingMax = out }
    }
}
