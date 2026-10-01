package dev.matebridge.client.settings

import java.util.concurrent.atomic.AtomicBoolean

/**
 * At most one queued run of [action] (T-105): a burst of SETTINGS_OPEN messages from the session thread must not grow
 * the UI thread's queue. [request] posts a runnable only when none is pending; the flag is cleared just before
 * [action] runs, so a request arriving during or after it posts again. Any thread may call [request].
 */
class CoalescedPost(private val post: (Runnable) -> Unit, private val action: () -> Unit) {
    private val pending = AtomicBoolean(false)

    /** True when a runnable was posted, false when one was already pending (this request is folded into it). */
    fun request(): Boolean {
        if (!pending.compareAndSet(false, true)) return false
        try {
            post(Runnable {
                pending.set(false)
                action()
            })
        } catch (e: RuntimeException) {
            pending.set(false) // nothing was queued: a later request must be able to post
            throw e
        }
        return true
    }
}
