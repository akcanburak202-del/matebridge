package dev.matebridge.client.session

import android.os.ParcelFileDescriptor
import android.system.Os
import android.system.OsConstants
import java.io.Closeable
import java.net.Socket

/**
 * T-074: Linux `TCP_QUICKACK` is not sticky, so it is re-armed after every read. It stops the receiving socket's
 * delayed ACK (>= 40 ms) from stalling the sender's Nagle in the adb loopback tunnel.
 * [rearm] is the actual setsockopt (fake in tests); a failure is logged once and disables the feature, never the session.
 */
class QuickAck(enabled: Boolean, private val rearm: () -> Unit, private val onFail: (String) -> Unit = {}) {
    private var active = enabled

    /** Call after every successful read. At most one syscall; a no-op when off or after a failure. */
    fun afterRead() {
        if (!active) return
        try {
            rearm()
        } catch (e: Exception) {
            active = false
            onFail(e.javaClass.simpleName)
        }
    }

    companion object {
        const val TCP_QUICKACK = 12 // Linux, linux/tcp.h

        /** `--ez quickack false` turns it off; absent means on. */
        fun parseExtra(present: Boolean, value: Boolean): Boolean = if (present) value else true

        /** A connected [socket] with a dup'd fd for setsockopt. Closing the handle never closes the socket. */
        fun forSocket(socket: Socket, enabled: Boolean, component: String): Handle {
            if (!enabled) return Handle(QuickAck(false, {}), null)
            val pfd = try { ParcelFileDescriptor.fromSocket(socket) } catch (e: Exception) { null }
            if (pfd == null) {
                MbLog.w("quickack_off", "err=nofd", component)
                return Handle(QuickAck(false, {}), null)
            }
            val fd = pfd.fileDescriptor
            return Handle(
                QuickAck(true, { Os.setsockoptInt(fd, OsConstants.IPPROTO_TCP, TCP_QUICKACK, 1) }) { err ->
                    MbLog.w("quickack_off", "err=$err", component)
                },
                pfd,
            )
        }
    }

    class Handle(val ack: QuickAck, private val pfd: ParcelFileDescriptor?) : Closeable {
        override fun close() { try { pfd?.close() } catch (_: Exception) {} }
    }
}
