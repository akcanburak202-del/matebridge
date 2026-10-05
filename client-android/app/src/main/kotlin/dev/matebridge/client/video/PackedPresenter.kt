package dev.matebridge.client.video

import android.media.Image
import android.os.Process
import android.view.Surface
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ConcurrentLinkedQueue

/** Time a decoder image waits after its last possible use by the GPU before it goes back to its ImageReader. */
internal const val IMAGE_RETIRE_NS = 50_000_000L

/**
 * An image with the moment it was closed late: the GPU may still read it for a while after the draw call returned, so a
 * displaced or used image is closed [IMAGE_RETIRE_NS] after it was retired (T-254/T-256 closed one draw late).
 */
internal class RetiredImages {
    private class Entry(val image: Image, val atNs: Long)
    private val q = ConcurrentLinkedQueue<Entry>()

    fun retire(image: Image, nowNs: Long) { q.add(Entry(image, nowNs)) }

    /** Closes what has been retired for at least [IMAGE_RETIRE_NS]; [force] closes everything. */
    fun closeDue(nowNs: Long, force: Boolean = false) {
        while (true) {
            val e = q.peek() ?: return
            if (!force && nowNs - e.atNs < IMAGE_RETIRE_NS) return
            q.poll()
            runCatching { e.image.close() }
        }
    }
}

/** What the presenter expects of a main frame released to the main ImageReader (put before the release call). */
class FrameExpectation(val captureUs: Long, val renderNs: Long)

/**
 * The GL thread of the packed full colour path (decision 0034). Takes the main decoder's images (newest wins), pairs each
 * with the auxiliary image of the same `capture_time_us` ([AuxPairing]; none in time: main-only pass), draws into the
 * SurfaceView's EGL window surface with swap interval 0 and `eglPresentationTimeANDROID` = the slot target the pacer
 * chose (no standing queue, T-256), and reports each frame's display time (EGL present timestamp) through [onShown].
 * All native GL calls of this context happen on this thread. Images are closed [IMAGE_RETIRE_NS] after their last use.
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
    }

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
    private val pairing = AuxPairing<Image>(AUX_RING) { retired.retire(it, clockNs()) }
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
            mainSlot?.let { retired.retire(it.image, clockNs()); synchronized(counters) { displaced++ } }
            mainSlot = Arrived(image, seq)
            lock.notifyAll()
        }
    }

    /** A decoded auxiliary image (from the aux ImageReader listener). The presenter owns [image] from now on. */
    fun offerAux(image: Image, captureUs: Long) {
        auxArrivals.add(AuxArrived(image, captureUs))
        // Bounded even if the GL thread is stuck: a backlog beyond a few images is stale.
        while (auxArrivals.size > AUX_RING + 2) auxArrivals.poll()?.let { retired.retire(it.image, clockNs()) }
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
    fun shutdown(joinMs: Long = 500) {
        stopFlag = true
        synchronized(lock) { lock.notifyAll() }
        if (isAlive && Thread.currentThread() !== this) {
            try { join(joinMs) } catch (_: InterruptedException) {}
            if (isAlive) log('W', "gl_stop_slow", "join_ms=$joinMs")
        }
    }

    override fun run() {
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
                retired.closeDue(now)
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
                retired.retire(item.image, clockNs())
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
            retired.closeDue(clockNs(), force = true)
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
