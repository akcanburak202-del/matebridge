package dev.matebridge.client.session

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.SystemClock
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.Inet4Address
import java.net.InetAddress
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit

/**
 * T-129: sends Wake-on-LAN magic packets ([WolPacket]) on its own thread, always over the Wi-Fi network (the socket is
 * bound to it with [Network.bindSocket], so it goes out on Wi-Fi even while an `adb reverse` USB session exists).
 * Driven by [WakePlanner] steps from the main thread: [start], [send], [stop]. Without Wi-Fi nothing is sent (logged).
 * MAC and IP addresses are never logged. Thin Android wrapper, verified on the device only.
 */
class WolSender(context: Context) {
    private val cm = context.applicationContext.getSystemService(ConnectivityManager::class.java)
    private val exec = ThreadPoolExecutor(
        1, 1, 0L, TimeUnit.MILLISECONDS, ArrayBlockingQueue(QUEUE),
        { r -> Thread(r, "mb-wol").also { it.isDaemon = true } },
        ThreadPoolExecutor.DiscardPolicy(), // a full queue only loses a wake packet; the next tick sends again
    )

    // Episode state, touched on the executor thread only.
    private var packets: List<ByteArray> = emptyList()
    private var lastHost: String? = null
    private var socket: DatagramSocket? = null
    private var targets: List<InetAddress> = emptyList()
    private var sent = 0
    private var noWifiLogged = false
    private var lastFailLogMs = 0L
    private var failSuppressed = 0

    fun start(reason: String, macs: List<String>, host: String?) = post {
        closeSocket()
        packets = macs.mapNotNull { WolTxt.bytes(it) }.map { WolPacket.magic(it) }
        lastHost = host
        sent = 0
        noWifiLogged = false
        failSuppressed = 0
        lastFailLogMs = 0L
        openSocket()
        MbLog.i("wol_start", "reason=$reason macs=${packets.size} targets=${targets.size}")
    }

    fun send() = post {
        if (packets.isEmpty()) return@post
        if (socket == null) openSocket()
        val s = socket ?: return@post
        var ok = 0
        for (t in targets) {
            for (p in packets) {
                try {
                    s.send(DatagramPacket(p, p.size, t, WolPacket.PORT))
                    ok++
                } catch (e: Exception) {
                    sendFailed(e) // one target may refuse (e.g. limited broadcast); the others still go out
                }
            }
        }
        sent += ok
        if (ok == 0) closeSocket() // nothing went out: re-resolve the Wi-Fi network on the next send
    }

    fun stop(reason: String) = post {
        closeSocket()
        packets = emptyList()
        MbLog.i("wol_stop", "reason=$reason sent=$sent" + if (failSuppressed > 0) " fail_suppressed=$failSuppressed" else "")
        failSuppressed = 0
    }

    fun shutdown() {
        exec.shutdown() // a queued stop still runs and closes the socket
    }

    private fun post(task: () -> Unit) {
        try {
            exec.execute(task)
        } catch (_: RejectedExecutionException) {
            // shut down: nothing more is sent
        }
    }

    /** Binds a broadcast-capable UDP socket to the Wi-Fi network and computes the targets; quietly gives up without Wi-Fi. */
    private fun openSocket() {
        val wifi = findWifi()
        if (wifi == null) {
            targets = emptyList()
            if (!noWifiLogged) {
                noWifiLogged = true
                MbLog.w("wol_no_wifi")
            }
            return
        }
        val (network, broadcasts) = wifi
        targets = WolTargets.build(broadcasts, lastHost).mapNotNull {
            try { InetAddress.getByAddress(it) } catch (_: Exception) { null }
        }
        var s: DatagramSocket? = null
        try {
            s = DatagramSocket()
            network.bindSocket(s)
            s.broadcast = true
            socket = s
        } catch (e: Exception) {
            s?.close()
            sendFailed(e)
        }
    }

    @Suppress("DEPRECATION") // allNetworks: the callback API is overkill for a lookup once per episode
    private fun findWifi(): Pair<Network, List<ByteArray>>? = try {
        cm?.allNetworks?.firstNotNullOfOrNull { n ->
            val caps = cm.getNetworkCapabilities(n)
            if (caps == null || !caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) return@firstNotNullOfOrNull null
            val broadcasts = cm.getLinkProperties(n)?.linkAddresses.orEmpty()
                .filter { it.address is Inet4Address }
                .mapNotNull { WolTargets.subnetBroadcast(it.address.address, it.prefixLength) }
            n to broadcasts
        }
    } catch (e: RuntimeException) {
        null
    }

    private fun closeSocket() {
        socket?.close()
        socket = null
    }

    /** At most one log line per [FAIL_LOG_MS]; the rest are counted. */
    private fun sendFailed(e: Exception) {
        val now = SystemClock.elapsedRealtime()
        if (lastFailLogMs != 0L && now - lastFailLogMs < FAIL_LOG_MS) {
            failSuppressed++
            return
        }
        lastFailLogMs = now
        MbLog.w("wol_send_failed", "err=${e.javaClass.simpleName} suppressed=$failSuppressed")
        failSuppressed = 0
    }

    private companion object {
        const val QUEUE = 16
        const val FAIL_LOG_MS = 5_000L
    }
}
