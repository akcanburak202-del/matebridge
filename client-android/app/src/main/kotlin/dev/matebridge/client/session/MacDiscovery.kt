package dev.matebridge.client.session

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Handler
import android.os.Looper

/**
 * Finds the host via mDNS `_matebridge._tcp` (PROTOCOL.md section 3.1). NsdManager resolves one
 * service at a time, so found services are queued. Callbacks arrive on NsdManager's own thread.
 * After [stop] no more results are delivered (a late resolve is dropped), and a failed discovery start
 * is retried after a delay while still started. Thin Android wrapper, verified on the device only.
 */
@Suppress("DEPRECATION")
class MacDiscovery(context: Context, private val onFound: (Endpoint) -> Unit) {
    private val nsd = context.applicationContext.getSystemService(Context.NSD_SERVICE) as NsdManager
    private val main = Handler(Looper.getMainLooper())
    private val pending = ArrayDeque<NsdServiceInfo>()
    private var resolving = false
    private var listener: NsdManager.DiscoveryListener? = null

    /** Bumped on every start/stop; callbacks of an older generation are ignored. */
    private var generation = 0
    private var started = false

    @Synchronized
    fun start() {
        if (started) return
        started = true
        beginDiscovery()
    }

    @Synchronized
    private fun beginDiscovery() {
        if (!started || listener != null) return
        val gen = ++generation
        val l = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) {}
            override fun onDiscoveryStopped(serviceType: String) {}
            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {}
            override fun onServiceLost(info: NsdServiceInfo) {}
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                synchronized(this@MacDiscovery) {
                    if (gen != generation) return
                    listener = null
                }
                main.postDelayed({ beginDiscovery() }, RETRY_MS)
            }

            override fun onServiceFound(info: NsdServiceInfo) {
                synchronized(this@MacDiscovery) {
                    if (gen != generation) return
                    pending.removeAll { it.serviceName == info.serviceName }
                    pending.addLast(info)
                    while (pending.size > MAX_PENDING) pending.removeFirst() // drop the oldest
                }
                resolveNext(gen)
            }
        }
        listener = l
        try {
            nsd.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, l)
        } catch (e: RuntimeException) {
            listener = null
            main.postDelayed({ beginDiscovery() }, RETRY_MS)
        }
    }

    @Synchronized
    fun stop() {
        started = false
        generation++
        pending.clear()
        resolving = false
        main.removeCallbacksAndMessages(null)
        val l = listener ?: return
        listener = null
        try { nsd.stopServiceDiscovery(l) } catch (_: IllegalArgumentException) {}
    }

    private fun resolveNext(gen: Int) {
        val next = synchronized(this) {
            if (gen != generation || resolving) return
            val n = pending.removeFirstOrNull() ?: return
            resolving = true
            n
        }
        val done = {
            synchronized(this) { if (gen == generation) resolving = false }
            resolveNext(gen)
        }
        try {
            nsd.resolveService(next, object : NsdManager.ResolveListener {
                override fun onResolveFailed(info: NsdServiceInfo, errorCode: Int) = done()
                override fun onServiceResolved(info: NsdServiceInfo) {
                    val addr = info.host
                    val alive = synchronized(this@MacDiscovery) { gen == generation }
                    if (alive && addr != null && info.port > 0) {
                        // Literal IPv4 only; link-local IPv6 would need a scope id.
                        val host = addr.hostAddress
                        if (host != null && !host.contains(':')) onFound(Endpoint(host, info.port))
                    }
                    done()
                }
            })
        } catch (e: RuntimeException) {
            done()
        }
    }

    private companion object {
        const val SERVICE_TYPE = "_matebridge._tcp."
        const val RETRY_MS = 3000L
        const val MAX_PENDING = 16
    }
}
