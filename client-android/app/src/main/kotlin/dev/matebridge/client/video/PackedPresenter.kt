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
 * T-261: the native draw keeps the last full colour in unchanged blocks of main-only frames ([ChromaReuse],
 * [reuseTolerance] < 0 = off), and the last drawn main image is held so that an auxiliary frame arriving after it was
 * shown redraws the same frame in full colour when nothing newer is waiting ([LateUpgrade]).
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
    private val reuseTolerance: Int = ChromaReuse.TOLERANCE,
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
        /** Sampled 2x2 blocks of main-only frames that kept the reference's full colour / were sampled (T-261). */
        val reuseSame: Long = 0, val reuseTotal: Long = 0,
        /** Frames redrawn in full colour because their auxiliary frame arrived late (T-261). */
        val lateUpgrades: Long = 0,
    ) {
        /** `reuse_pct` of the window, null when no block was sampled. */
        val reusePct: Double? get() = if (reuseTotal == 0L) null else reuseSame * 100.0 / reuseTotal

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
    /** The last drawn main image, kept (not retired) until the next main frame is drawn: GL thread only. */
    private var held: Arrived? = null
    private val upgrade = LateUpgrade()
    private val firstShown = FirstShown()
    private val drawWatch = DrawWatch()
    private var reuseActive = false
    private val timings = GlTimings()
    @Volatile private var stopFlag = false
    @Volatile var started = false
        private set

    // Window counters (GL thread writes, any thread reads through [snapshot]).
    private val counters = Any()
    private var drawn = 0L
    private var displaced = 0L
    private var drawErrors = 0L
    private var upgrades = 0L
    private var reuseSame = 0L
    private var reuseTotal = 0L
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
        synchronized(lock) { lock.notifyAll() } // wakes the GL thread: this may complete the frame it shows (late upgrade)
        // Bounded even if the GL thread is stuck: a backlog beyond a few images is stale.
        while (auxArrivals.size > AUX_RING + 2) auxArrivals.poll()?.let { retired.retire(it.image, clockNs(), submitted) }
    }

    /** Counters since the last call with [reset]. */
    fun snapshot(reset: Boolean = true): Snapshot {
        val gl = timings.percentiles(reset)
        synchronized(counters) {
            val s = Snapshot(
                drawn, pairing.late, pairing.paired, displaced, drawErrors, gl?.first, gl?.second, outstandingMax,
                reuseSame, reuseTotal, upgrades,
            )
            if (reset) {
                drawn = 0; displaced = 0; drawErrors = 0; outstandingMax = 0; pairing.resetCounts()
                upgrades = 0; reuseSame = 0; reuseTotal = 0
            }
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
            if (!stopFlag) onFailed("init:$initError")
            return
        }
        FullChromaNative.presentSetConversion(conversion.toArray())
        FullChromaNative.presentSetReuseTolerance(reuseTolerance)
        val features = FullChromaNative.presentFeatures()
        cpuFallbackMs = !features.contains("render_ts=1") // no EGL rendering-complete stamp: the draw call's CPU time stands in for gl_ms
        reuseActive = features.contains("reuse=1")
        log('I', "gl_present_init", "$features size=${width}x$height swap_interval=0 reuse_tol=$reuseTolerance")
        if (reuseTolerance >= 0 && !reuseActive) {
            log('W', "chroma_reuse_unavailable", "err=${FullChromaNative.presentLastError().replace(Regex("\\s+"), "_").take(120)}")
        }
        started = true
        var failed: String? = null
        try {
            while (!stopFlag) {
                val item = takeMain()
                val now = clockNs()
                absorbAux()
                val completed = FullChromaNative.presentCompletedDraws()
                retired.closeDue(now, completed)
                if (maxOf(retired.stalledForNs(now, completed), drawWatch.stalledForNs(now, completed)) > IMAGE_STALL_NS) {
                    failed = "fence_stall"
                    break
                }
                if (item == null) {
                    val rc = tryUpgrade(now)
                    if (rc != 0 && consecutiveErrors >= MAX_CONSECUTIVE_ERRORS) {
                        failed = "draw:$rc:${FullChromaNative.presentLastError()}"
                        break
                    }
                    drainTimestamps()
                    continue
                }
                val exp = expectations.remove(item.seq)
                val captureUs = exp?.captureUs ?: LateUpgrade.NONE
                val aux = if (exp != null) pairing.pair(exp.captureUs) else null
                val rc = drawFrame(item.image, aux, item.seq, exp?.renderNs ?: 0L, main = true)
                held?.let { retired.retire(it.image, clockNs(), submitted) } // the previous frame: no draw reads it any more
                held = item
                upgrade.onMainDrawn(captureUs, paired = aux != null || rc != 0, targetNs = maxOf(exp?.renderNs ?: 0L, clockNs()))
                if (rc != 0 && consecutiveErrors >= MAX_CONSECUTIVE_ERRORS) {
                    failed = "draw:$rc:${FullChromaNative.presentLastError()}"
                    break
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
            held?.let { retired.retire(it.image, clockNs(), submitted) }
            held = null
            upgrade.clear()
            firstShown.clear()
            synchronized(lock) { mainSlot?.let { runCatching { it.image.close() } }; mainSlot = null }
            retired.closeDue(clockNs(), Long.MAX_VALUE, force = true) // after glFinish + EGL teardown
        }
        failed?.let { if (!stopFlag) onFailed(it) }
    }

    /**
     * One native draw of [image] (+ [aux]): bookkeeping of the submitted-draw counter, error counters and the CPU time
     * fallback. [main] = a newly arrived main frame (counted in `gl_drawn`); false = a late-upgrade redraw. Returns the native code.
     */
    private fun drawFrame(image: Image, aux: Image?, tag: Long, presentNs: Long, main: Boolean): Int {
        val hwMain = image.hardwareBuffer
        val hwAux = aux?.hardwareBuffer
        val t0 = clockNs()
        val rc = if (hwMain != null) {
            try {
                FullChromaNative.presentDraw(hwMain, hwAux, tag, presentNs)
            } catch (e: Exception) { -20 }
        } else -10
        val cpuMs = (clockNs() - t0) / 1e6
        hwMain?.close()
        hwAux?.close()
        if (rc == 0 || rc == -5) { // a fence was created for this draw
            submitted++
            drawWatch.onSubmitted(submitted, clockNs())
        }
        if (rc != 0) {
            consecutiveErrors++
            synchronized(counters) { drawErrors++ }
        } else {
            consecutiveErrors = 0
            if (main) synchronized(counters) { drawn++ }
            if (cpuFallbackMs) timings.add(cpuMs)
        }
        return rc
    }

    /**
     * Nothing newer is waiting: when the held frame was shown main-only and its auxiliary frame has arrived since, draws
     * it again merged once the original was presented (or its target time passed), at the next vsync, under the original's
     * tag (its display statistics are reported once). 0 = nothing
     * drawn or a good draw, else the failed draw's code.
     */
    private fun tryUpgrade(nowNs: Long): Int {
        val cap = upgrade.candidate(nowNs) ?: return 0
        val h = held ?: return 0
        val aux = pairing.find(cap) ?: return 0
        upgrade.onUpgraded() // one attempt per frame, successful or not
        // Same tag as the original: whichever of the two reaches the display first reports the frame ([FirstShown]).
        val rc = drawFrame(h.image, aux, h.seq, 0L, main = false)
        if (rc == 0) synchronized(counters) { upgrades++ }
        return rc
    }

    private fun takeMain(): Arrived? = synchronized(lock) {
        if (mainSlot == null && auxArrivals.isEmpty() && !stopFlag) lock.wait(TICK_MS)
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
        val q = FullChromaNative.presentDrainTimestamps()
        var i = 0
        while (i + 4 < q.size) {
            val tag = q[i]; val latch = q[i + 1]; val present = q[i + 2]; val render = q[i + 3]; val submit = q[i + 4]
            val shown = if (present > 0) present else latch
            if (shown > 0 && tag >= 0 && firstShown.first(tag)) { // an upgrade redraw shares its original's tag: reported once
                onShown(tag, shown)
                if (tag == held?.seq) upgrade.onShown()
            }
            // gl_ms: from just before the swap to the GPU finishing this frame (EGL rendering-complete stamp, same clock)
            if (render > 0 && submit > 0 && render >= submit) timings.add((render - submit) / 1e6)
            i += 5
        }
        if (reuseActive) {
            val r = FullChromaNative.presentReuseStats()
            if (r[1] > 0) synchronized(counters) { reuseSame += r[0]; reuseTotal += r[1] }
        }
        val out = FullChromaNative.presentOutstanding()
        if (out > 0) synchronized(counters) { if (out > outstandingMax) outstandingMax = out }
    }
}
