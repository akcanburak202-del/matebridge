package dev.matebridge.yuv444probe

import android.os.Handler
import android.os.Looper
import android.view.Choreographer

/**
 * Samples Choreographer vsync times on the main looper and turns the last [KEEP] into a [VsyncGrid]. Choreographer's
 * phase can differ from the HWC vsync by the app vsync offset; `vsync_off_ms` shifts it (see [Args]).
 */
class VsyncTracker(private val offsetNs: Long) {
    private companion object { const val KEEP = 32 }

    private val ring = LongArray(KEEP)
    private var count = 0
    private val lock = Any()
    @Volatile private var running = false
    @Volatile private var cached: VsyncGrid? = null
    private val handler = Handler(Looper.getMainLooper())

    private val callback = object : Choreographer.FrameCallback {
        override fun doFrame(frameTimeNanos: Long) {
            synchronized(lock) {
                ring[count % KEEP] = frameTimeNanos
                count++
                val n = minOf(count, KEEP)
                cached = VsyncEstimator.estimate(ring.copyOf(n), offsetNs)
            }
            if (running) Choreographer.getInstance().postFrameCallback(this)
        }
    }

    fun start() {
        running = true
        handler.post { Choreographer.getInstance().postFrameCallback(callback) }
    }

    fun stop() {
        running = false
        handler.post { Choreographer.getInstance().removeFrameCallback(callback) }
    }

    /** The newest grid, anchored at the latest sampled vsync; null until enough samples arrived. */
    fun grid(): VsyncGrid? = cached
}
