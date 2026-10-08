package dev.matebridge.client.input

/**
 * Policy for asking Android to deliver pen samples as they arrive instead of batching them per display frame (T-026).
 * Pure Kotlin, JVM-tested; the Android calls sit behind [Backend] and live in MainActivity.
 *
 * Why: batching per frame turns ~330 pen samples/s into ~100 events/s with about three samples each, and the host
 * then injects each message back to back, so a drawing app sees bursts instead of evenly spaced points. With the
 * request in place each sample arrives in its own MotionEvent and leaves in its own PEN message.
 *
 * The request (minSdk 31, decision 0037) is logged once (`unbuffered path=... sources=...` on `MB/input`):
 *  - [Path.SOURCE]: `View.requestUnbufferedDispatch(int source)` for the stylus source, made on a LEAF view
 *    (a ViewGroup recomputes its own source from its children and would overwrite a request stored on the group
 *    itself). It stays in force until it is cleared, and it covers hover, which arrives as generic motion events. It is
 *    requested while input capture is active (video visible) and cleared otherwise. Two things are tracked apart:
 *    whether a request may be in force (`inForce`: [sync] with `false` always clears it, whatever else happened) and
 *    whether it has to be pushed to the window again (`stale`, set by [reapplyOnNextSync]: the window may be a new one,
 *    so [sync] with `true` asserts it again even though it was requested before). A view that is not attached yet
 *    makes the backend answer false and [sync] retries.
 *
 * If the platform call throws, batched delivery simply continues: the failure is logged once and never retried.
 * Everything else about input is unchanged: whatever batching the system still does travels in one message, in order,
 * with no sample dropped.
 * UI thread only.
 */
class UnbufferedPenDispatch(
    private val backend: Backend,
    /** Rare-event log hook of `MB/input` (name, key=value fields). */
    private val onEvent: (String, String) -> Unit = { _, _ -> },
    /** T-322: label of the sources the backend requests (`stylus` alone, or more with `unbuffered_src`); logged with the path. */
    private val sourcesLabel: String = "stylus",
) {
    enum class Path { SOURCE, FAILED }

    fun interface Backend {
        /**
         * Sets or clears the source-wide request for the stylus source. Setting must reach the window even if the
         * same request was made before (`View` ignores a request equal to its current value, so clear first).
         * Returns false when it could not be applied because the view is not attached to a window (yet); the caller
         * retries. Clearing must always work.
         */
        fun setStylusUnbuffered(on: Boolean): Boolean
    }

    var path = Path.SOURCE
        private set

    /** A request may be in force on the platform (the last successful backend call was a set). */
    private var inForce = false

    /** The request has to be pushed to the window again although `inForce`: the window may be a new one. */
    private var stale = false
    private var logged = false

    /**
     * Input capture is active ([on] = true) or not; call as often as convenient, it acts only when something has to
     * change: `true` sets the request when none is in force or after [reapplyOnNextSync]; `false` clears it whenever
     * one may be in force.
     */
    fun sync(on: Boolean) {
        when (path) {
            Path.FAILED -> return
            Path.SOURCE -> {
                if (on) {
                    if (inForce && !stale) return
                } else if (!inForce) {
                    return
                }
                val ok = try {
                    backend.setStylusUnbuffered(on)
                } catch (e: RuntimeException) {
                    path = Path.FAILED
                    logged = true
                    onEvent("unbuffered", "path=failed err=${e.javaClass.simpleName}")
                    return
                }
                if (ok) {
                    inForce = on
                    stale = false
                    if (on) logPathOnce()
                }
            }
        }
    }

    /**
     * The window (its ViewRootImpl) may be a new one, or focus is back: whatever was requested may be gone, so the
     * next [sync] with `true` requests it again. A request that may still be in force is not forgotten: [sync] with
     * `false` still clears it.
     */
    fun reapplyOnNextSync() {
        stale = true
    }

    private fun logPathOnce() {
        if (logged) return
        logged = true
        onEvent("unbuffered", "path=source sources=$sourcesLabel")
    }
}
