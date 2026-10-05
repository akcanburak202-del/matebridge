package dev.matebridge.yuv444probe

import android.media.Image
import android.view.Surface
import java.util.concurrent.ConcurrentLinkedQueue

/** A decoder image with the time its ImageReader callback saw it. */
class Arrived(val image: Image, val arrivalNs: Long)

/**
 * Newest-wins mailbox for the main stream and a "latest value" holder for the auxiliary one. A displaced image is not
 * closed here: it goes to [retired] and the GL thread closes it one draw later (the GPU may still be reading it).
 */
class Mailbox(private val retired: ConcurrentLinkedQueue<Image>) {
    private var main: Arrived? = null
    private var aux: Arrived? = null
    private val lock = Object()

    fun offerMain(a: Arrived) = synchronized(lock) {
        main?.let { retired.add(it.image) }
        main = a
        lock.notifyAll()
    }

    fun offerAux(a: Arrived) = synchronized(lock) {
        aux?.let { retired.add(it.image) }
        aux = a
    }

    fun takeMain(timeoutMs: Long): Arrived? = synchronized(lock) {
        if (main == null) lock.wait(timeoutMs)
        val m = main
        main = null
        m
    }

    fun latestAux(): Arrived? = synchronized(lock) { aux }

    /** Closes whatever is still held (after the GL thread has stopped). */
    fun closeAll() = synchronized(lock) {
        main?.let { runCatching { it.image.close() } }
        aux?.let { runCatching { it.image.close() } }
        main = null
        aux = null
    }
}

/** What the presentation loop measured. */
class PresentTotals(
    val drawn: Int,
    /** Image arrival to eglSwapBuffers return (ns), frames after warm-up. */
    val arrivalToSwapNs: LongArray,
    /** CPU time inside presentDraw (ns). */
    val drawCallNs: LongArray,
    val gpuNs: LongArray,
    val present: PresentResult,
    val features: String,
    val error: String?,
    val drawErrors: Int,
)

/**
 * The GL thread of the presentation test: takes the newest main image, draws it (merged with the latest aux image in
 * GL mode MERGE) into the window surface, closes images one draw late. All native GL calls happen on this thread.
 */
class PresentLoop(
    private val surface: Surface,
    private val width: Int,
    private val height: Int,
    private val mode: GlMode,
    private val swapInterval: Int,
    private val feedPeriodNs: Long,
    private val retired: ConcurrentLinkedQueue<Image>,
    private val mailbox: Mailbox,
) : Thread("y444-gl") {
    @Volatile private var stopFlag = false
    /** Draws before this `System.nanoTime()` are warm-up and not measured. */
    @Volatile var windowStartNs = 0L
    @Volatile var started = false
        private set
    @Volatile private var totals: PresentTotals? = null
    @Volatile var drawnSoFar = 0
        private set

    fun halt() {
        stopFlag = true
    }

    fun result(): PresentTotals? = totals

    override fun run() {
        val initError = Native.presentInit(surface, width, height, mode.native, swapInterval)
        if (initError.isNotEmpty()) {
            totals = PresentTotals(0, LongArray(0), LongArray(0), LongArray(0),
                PresentStats.analyze(LongArray(0), feedPeriodNs), "none", "init:$initError", 0)
            started = true
            return
        }
        val features = Native.presentFeatures()
        started = true
        val swap = LongList()
        val call = LongList()
        val quads = LongList()
        val gpu = LongList()
        var drawn = 0
        var drawErrors = 0
        var delayed = ArrayList<Image>()
        var lastError: String? = null
        try {
            while (!stopFlag) {
                val item = mailbox.takeMain(50) ?: continue
                val aux = mailbox.latestAux()
                val t0 = System.nanoTime()
                val hwMain = item.image.hardwareBuffer
                val hwAux = aux?.image?.hardwareBuffer
                val rc = if (hwMain != null) Native.presentDraw(hwMain, hwAux, item.arrivalNs) else -10
                val t1 = System.nanoTime()
                hwMain?.close()
                hwAux?.close()
                if (rc != 0) {
                    drawErrors++
                    lastError = "draw:$rc:${Native.presentLastError()}"
                } else if (item.arrivalNs >= windowStartNs) {
                    swap.add(t1 - item.arrivalNs)
                    call.add(t1 - t0)
                }
                drawn++
                drawnSoFar = drawn
                // Close what was retired before the previous draw, then queue this round's for the next one.
                for (img in delayed) runCatching { img.close() }
                delayed = ArrayList()
                while (true) delayed.add(retired.poll() ?: break)
                delayed.add(item.image)
                if (drawn % 20 == 0) drain(quads, gpu)
            }
        } finally {
            drain(quads, gpu)
            for (img in delayed) runCatching { img.close() }
            Native.presentShutdown()
            val inWindow = quadsInWindow(quads.toArray(), windowStartNs)
            totals = PresentTotals(
                drawn, swap.toArray(), call.toArray(), gpu.toArray().let { if (it.size > 30) it.copyOfRange(30, it.size) else it },
                PresentStats.analyze(inWindow, feedPeriodNs), features, lastError, drawErrors,
            )
        }
    }

    private fun drain(quads: LongList, gpu: LongList) {
        quads.addAll(Native.presentDrainTimestamps())
        gpu.addAll(Native.presentDrainGpuNs())
    }

    private fun quadsInWindow(q: LongArray, startNs: Long): LongArray {
        val out = LongList()
        var i = 0
        while (i + 3 < q.size) {
            if (q[i] >= startNs) for (k in 0..3) out.add(q[i + k])
            i += 4
        }
        return out.toArray()
    }
}
