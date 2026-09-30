package dev.matebridge.client.input

/**
 * Policy for asking Android to deliver pen samples as they arrive instead of batching them per display frame (T-026).
 * Pure Kotlin, JVM-tested; the Android calls sit behind [Backend] and live in MainActivity.
 *
 * Why: batching per frame turns ~330 pen samples/s into ~100 events/s with about three samples each, and the host
 * then injects each message back to back, so a drawing app sees bursts instead of evenly spaced points. With the
 * request in place each sample arrives in its own MotionEvent and leaves in its own PEN message.
 *
 * Two paths, chosen once from the API level and logged once (`unbuffered path=...` on `MB/input`):
 *  - [Path.SOURCE], API 30+: `View.requestUnbufferedDispatch(int source)` for the stylus source. It stays in force
 *    until it is cleared, and it covers hover, which arrives as generic motion events. It is requested while input
 *    capture is active (video visible) and cleared otherwise, and requested again whenever the window may have been
 *    recreated ([reapplyOnNextSync]) or the view was not attached yet (the backend answers false and [sync] retries).
 *  - [Path.PER_GESTURE], older API: `View.requestUnbufferedDispatch(MotionEvent)` on each pen `ACTION_DOWN` (it only
 *    lasts for that gesture, and hover is not covered). The caller asks [wantsPerGestureRequest].
 *
 * If the platform call throws, batched delivery simply continues: the failure is logged once and never retried.
 * Everything else about input is unchanged: whatever batching the system still does travels in one message, in order,
 * with no sample dropped.
 * UI thread only.
 */
class UnbufferedPenDispatch(
    sdkInt: Int,
    private val backend: Backend,
    /** Rare-event log hook of `MB/input` (name, key=value fields). */
    private val onEvent: (String, String) -> Unit = { _, _ -> },
) {
    enum class Path { SOURCE, PER_GESTURE, FAILED }

    fun interface Backend {
        /**
         * Sets or clears the source-wide request for the stylus source. Returns false when it could not be applied
         * because the view is not attached to a window (yet); the caller retries.
         */
        fun setStylusUnbuffered(on: Boolean): Boolean
    }

    var path = if (sdkInt >= SOURCE_API) Path.SOURCE else Path.PER_GESTURE
        private set

    private var wanted = false
    private var applied = false
    private var logged = false

    /** True when this run of the app should ask per pen DOWN (old API) and input capture is active. */
    fun wantsPerGestureRequest() = path == Path.PER_GESTURE && wanted

    /** Input capture is active ([on] = true) or not; call as often as convenient, it acts only on a change. */
    fun sync(on: Boolean) {
        wanted = on
        when (path) {
            Path.FAILED -> return
            Path.PER_GESTURE -> if (on) logPathOnce()
            Path.SOURCE -> {
                if (on == applied) return
                val ok = try {
                    backend.setStylusUnbuffered(on)
                } catch (e: RuntimeException) {
                    path = Path.FAILED
                    logged = true
                    onEvent("unbuffered", "path=failed err=${e.javaClass.simpleName}")
                    return
                }
                if (ok) {
                    applied = on
                    if (on) logPathOnce()
                }
            }
        }
    }

    /**
     * The window (its ViewRootImpl) may be a new one, or focus is back: whatever was requested may be gone, so the
     * next [sync] requests it again.
     */
    fun reapplyOnNextSync() {
        applied = false
    }

    private fun logPathOnce() {
        if (logged) return
        logged = true
        onEvent("unbuffered", "path=${if (path == Path.SOURCE) "source" else "per_gesture"}")
    }

    companion object {
        /** `View.requestUnbufferedDispatch(int source)` exists from API 30. */
        const val SOURCE_API = 30
    }
}
