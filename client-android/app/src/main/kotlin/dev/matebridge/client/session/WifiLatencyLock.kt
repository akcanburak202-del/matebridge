package dev.matebridge.client.session

import android.content.Context
import android.net.wifi.WifiManager

/**
 * T-388 (dev knob `--ez wifi_ll true`): a `WIFI_MODE_FULL_LOW_LATENCY` Wi-Fi lock held while the app is in the
 * foreground. Pure state here ([Handle] is the platform lock); [acquire] / [release] are idempotent and main-thread only.
 * [log] gets `held`, `released` or `unsupported` (MainActivity writes `ev=wifi_lock mode=low_latency state=<it>`).
 */
class WifiLatencyLock(private val handle: Handle?, private val log: (String) -> Unit) {
    /** The platform lock. [acquire] returns whether it is held afterwards; may throw. */
    interface Handle {
        fun acquire(): Boolean
        fun release()
    }

    private var held = false
    private var reportedUnsupported = false

    val isHeld: Boolean get() = held

    fun acquire() {
        if (held) return
        val ok = try { handle?.acquire() == true } catch (e: Exception) { false }
        if (ok) {
            held = true
            log("held")
        } else if (!reportedUnsupported) {
            reportedUnsupported = true
            log("unsupported")
        }
    }

    fun release() {
        if (!held) return
        held = false
        try { handle?.release() } catch (_: Exception) {}
        log("released")
    }

    companion object {
        private const val TAG = "matebridge-wifi-ll"

        /** Android lock; no public support query exists (`isLowLatencyModeSupported` is a system API): a null handle (no WifiManager,
         * `createWifiLock` throws) or an acquire that throws / is not held reports `unsupported`. */
        fun create(context: Context, log: (state: String) -> Unit): WifiLatencyLock {
            val handle = try {
                val wm = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
                if (wm == null) null
                else {
                    val lock = wm.createWifiLock(WifiManager.WIFI_MODE_FULL_LOW_LATENCY, TAG)
                    lock.setReferenceCounted(false)
                    object : Handle {
                        override fun acquire(): Boolean { lock.acquire(); return lock.isHeld }
                        override fun release() { if (lock.isHeld) lock.release() }
                    }
                }
            } catch (e: Exception) { null }
            return WifiLatencyLock(handle, log)
        }
    }
}
