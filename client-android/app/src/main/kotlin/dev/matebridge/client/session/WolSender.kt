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
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/**
 * T-129: sends Wake-on-LAN magic packets ([WolPacket]) on its own thread, always over the Wi-Fi network (the socket is
 * bound to it with [Network.bindSocket], so it goes out on Wi-Fi even while an `adb reverse` USB session exists).
 * Driven by [WakePlanner] steps from the main thread: [start], [send], [stop]. Without Wi-Fi nothing is sent (logged).
 * MAC and IP addresses are never logged. Thin Android wrapper, verified on the device only.
 *
 * A stop is never lost: [stop] clears the running episode synchronously (a queued send checks it before every
 * datagram), at most one send is queued at a time, and a stop the queue cannot take runs inline.
 */
class WolSender(context: Context) {
    private val cm = context.applicationContext.getSystemService(ConnectivityManager::class.java)
    private val exec = ThreadPoolExecutor(
        1, 1, 0L, TimeUnit.MILLISECONDS, ArrayBlockingQueue(QUEUE),
        { r -> Thread(r, "mb-wol").also { it.isDaemon = true } },
        ThreadPoolExecutor.AbortPolicy(), // rejections are handled in post()
    )

    /** Id of the running episode, 0 = none. Written on the caller's (main) thread, read on the executor before each send. */
    @Volatile private var episode = 0
    private var nextEpisode = 0 // main thread only
    private val sendQueued = AtomicBoolean(false)
    private val sent = AtomicInteger(0)
    @Volatile private var socket: DatagramSocket? = null

    // Episode state, touched on the executor thread only.
    private var runningEpisode = 0
    private var packets: List<ByteArray> = emptyList()
    private var lastHost: String? = null
    private var targets: List<InetAddress> = emptyList()
    private var noWifiLogged = false
    private var lastFailLogMs = 0L
    private var failSuppressed = 0

    fun start(reason: String, macs: List<String>, host: String?) {
        val id = ++nextEpisode
        episode = id
        val ok = post {
            closeSocket()
            runningEpisode = id
            packets = macs.mapNotNull { WolTxt.bytes(it) }.map { WolPacket.magic(it) }
            lastHost = host
            sent.set(0)
            noWifiLogged = false
            failSuppressed = 0
            lastFailLogMs = 0L
            openSocket()
            MbLog.i("wol_start", "reason=$reason macs=${packets.size} targets=${targets.size}")
        }
        if (!ok) MbLog.w("wol_queue_full", "op=start")
    }

    fun send() {
        if (episode == 0 || !sendQueued.compareAndSet(false, true)) return // one queued send at a time
        val ok = post {
            sendQueued.set(false)
            sendRound()
        }
        if (!ok) sendQueued.set(false)
    }

    fun stop(reason: String) {
        episode = 0 // from here no datagram goes out, whatever is still queued
        val task = {
            closeSocket()
            MbLog.i("wol_stop", "reason=$reason sent=${sent.get()}" + if (failSuppressed > 0) " fail_suppressed=$failSuppressed" else "")
        }
        if (!post(task)) {
            // Queue full or shut down: close and log here; DatagramSocket.close is safe from another thread.
            closeSocket()
            MbLog.i("wol_stop", "reason=$reason sent=${sent.get()} inline=1")
        }
    }

    fun shutdown() {
        episode = 0
        exec.shutdown() // a queued stop still runs and closes the socket
    }

    /**
     * IPv4 subnets of the current Wi-Fi network (empty without Wi-Fi). Binder calls only; safe on any thread, cheap
     * enough for the planner's rate-limited home check.
     */
    fun wifiSubnets(): List<Ipv4Subnet> = findWifi()?.second.orEmpty().mapNotNull { (addr, prefix) -> Ipv4Subnet.of(addr, prefix) }

    private fun post(task: () -> Unit): Boolean = try {
        exec.execute(task)
        true
    } catch (_: RejectedExecutionException) {
        false
    }

    private fun sendRound() {
        val id = runningEpisode
        if (id == 0 || episode != id || packets.isEmpty()) return
        if (socket == null) openSocket()
        val s = socket ?: return
        var ok = 0
        for (t in targets) {
            for (p in packets) {
                if (episode != id) return // stopped meanwhile
                try {
                    s.send(DatagramPacket(p, p.size, t, WolPacket.PORT))
                    ok++
                    sent.incrementAndGet()
                } catch (e: Exception) {
                    sendFailed(e) // one target may refuse (e.g. limited broadcast); the others still go out
                }
            }
        }
        if (ok == 0) closeSocket() // nothing went out: re-resolve the Wi-Fi network on the next send
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
        val (network, links) = wifi
        val broadcasts = links.mapNotNull { (addr, prefix) -> WolTargets.subnetBroadcast(addr, prefix) }
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

    /** The Wi-Fi network and its IPv4 link addresses (address bytes, prefix length). */
    @Suppress("DEPRECATION") // allNetworks: the callback API is overkill for an occasional lookup
    private fun findWifi(): Pair<Network, List<Pair<ByteArray, Int>>>? = try {
        cm?.allNetworks?.firstNotNullOfOrNull { n ->
            val caps = cm.getNetworkCapabilities(n)
            if (caps == null || !caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) return@firstNotNullOfOrNull null
            val links = cm.getLinkProperties(n)?.linkAddresses.orEmpty()
                .filter { it.address is Inet4Address }
                .map { it.address.address to it.prefixLength }
            n to links
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
